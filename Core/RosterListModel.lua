local _, addon = ...

-- The rows of the new window's Roster column: one player card per player
-- (a lone character is a player of its own), split into Online and Offline
-- sections, each headed by a label with its count. Alts don't get rows of
-- their own; the player panel lists them. A player with no character left
-- in the guild has no card.
--
-- A card's big name is the player's alias, else their main's name. Its sub
-- line names the character that's online (or the main, while offline) when
-- that isn't the big name, how many characters they have, and where they
-- are: the online character's zone, or when they were last online.
--
-- Pure: the partition, live roster facts and lookups are handed in. The
-- last-online, sync and plural texts are RosterViewModel's.
local RosterListModel = {
    ONLINE = "Online",
    OFFLINE = "Offline",
}
addon.RosterListModel = RosterListModel

local DOT = " · "

local function plural(count, unit)
    return count .. " " .. unit .. (count == 1 and "" or "s")
end

local function lower(text)
    return string.lower(text or "")
end

local function colored(text, color)
    if type(color) ~= "string" then
        return text
    end
    return "|c" .. color .. text .. "|r"
end

-- An optional lookup's answer, or nil when it's missing or fails.
local function ask(callback, ...)
    if callback == nil then
        return nil
    end
    local ok, answer = pcall(callback, ...)
    if not ok then
        return nil
    end
    return answer
end

-- The players the pinned Friend keys belong to, as a set.
local function friendPlayers(partition, keys)
    local players = {}
    local index
    for index = 1, #(keys or {}) do
        local character = partition:GetCharacter(keys[index])
        players[character and character.player or keys[index]] = true
    end
    return players
end

-- Player `playerId`'s card, or nil when none of their characters is in the
-- guild.
local function card(inputs, playerId, player, friends)
    local partition = inputs.partition
    local members = inputs.members or {}
    local normalizer = inputs.normalizer
    local keys = partition:CharactersOf(playerId)
    local inGuild = {}
    local onlineKey, latestKey, latest
    local index
    for index = 1, #keys do
        local key = keys[index]
        if partition:GetCharacter(key) ~= nil and partition:IsInGuild(key) then
            table.insert(inGuild, key)
            local live = members[key] or {}
            if live.online == true and onlineKey == nil then
                onlineKey = key
            end
            local away = addon.RosterViewModel.HoursAway(live.lastOnline)
            if away ~= nil and (latest == nil or away < latest) then
                latest, latestKey = away, key
            end
        end
    end
    if inGuild[1] == nil then
        return nil
    end
    -- CharactersOf puts the main first, so the lead is the main while it's
    -- in the guild.
    local leadKey = inGuild[1]
    local function nameOf(key)
        local raw = (members[key] or {}).name or (partition:GetCharacter(key) or {}).name or key
        return normalizer and normalizer:Display(raw) or raw
    end
    local function classOf(key)
        return (members[key] or {}).classToken or (partition:GetCharacter(key) or {}).class
    end
    local alias = player and player.alias or nil
    if type(alias) ~= "string" or alias == "" then
        alias = nil
    end
    local mainName = nameOf(leadKey)
    local name = alias or mainName
    local shownKey = onlineKey or leadKey
    local shownName = nameOf(shownKey)
    local parts = {}
    if shownName ~= name then
        table.insert(parts, colored(shownName, ask(inputs.classColor, classOf(shownKey))))
    end
    if #inGuild > 1 then
        table.insert(parts, plural(#inGuild, "character"))
    end
    local where
    if onlineKey ~= nil then
        where = (members[onlineKey] or {}).zone
    else
        where = addon.RosterViewModel.FormatLastOnline((members[latestKey or leadKey] or {}).lastOnline)
    end
    if where ~= nil then
        table.insert(parts, where)
    end
    local classToken = classOf(leadKey)
    return {
        kind = "player",
        playerId = playerId,
        key = leadKey,
        keys = inGuild,
        name = name,
        alias = alias,
        mainName = mainName,
        classToken = classToken,
        className = ask(inputs.className, classToken),
        -- The initial's class color ("ffrrggbb"), the lead character's.
        color = ask(inputs.classColor, classToken),
        online = onlineKey ~= nil,
        characters = #inGuild,
        star = friends[playerId] == true,
        sub = table.concat(parts, DOT),
    }
end

-- By name, then by player id so the order never changes.
local function byName(a, b)
    if lower(a.name) ~= lower(b.name) then
        return lower(a.name) < lower(b.name)
    end
    return tostring(a.playerId) < tostring(b.playerId)
end

-- inputs:
--   partition   the guild partition
--   members     live roster facts by character key
--   normalizer  a NameNormalizer, for how names show
--   classColor  function(classToken) -> "ffrrggbb" or nil
--   className   function(classToken) -> the class as the game names it
--   friendKeys  the pinned Friend keys (FellowshipStore:GetFriends)
--   selected    the player id the page has selected, or nil
--   lastSync    when guild sync last finished, or nil
--   now         the current timestamp
-- Returns {
--   rows      the column's rows, in order: { kind = "section", text, count }
--             then that section's cards, { kind = "player", playerId, key,
--             keys, name, alias, mainName, classToken, className, color,
--             online, characters, star, sub }
--   cards     the cards alone, in the same order
--   players, online   how many players have a card, and how many of them
--             are online
--   header    "550 players · 42 online"
--   sync      "Synced 5 minutes ago", or "Not synced yet"
--   selected  `selected` when it has a card, else nil
--   selectedIndex  its row's index in `rows`, or nil
--   default   the player to select when nothing is: the first card's, or nil
-- }
function RosterListModel.Build(inputs)
    local partition = inputs.partition
    local friends = friendPlayers(partition, inputs.friendKeys)
    local online, offline = {}, {}
    partition:EachPlayer(function(playerId, player)
        local entry = card(inputs, playerId, player, friends)
        if entry ~= nil then
            table.insert(entry.online and online or offline, entry)
        end
    end)
    table.sort(online, byName)
    table.sort(offline, byName)
    local view = { rows = {}, cards = {}, players = #online + #offline, online = #online }
    local _, section
    for _, section in ipairs({
        { text = RosterListModel.ONLINE, cards = online },
        { text = RosterListModel.OFFLINE, cards = offline },
    }) do
        if section.cards[1] ~= nil then
            table.insert(view.rows, { kind = "section", text = section.text, count = #section.cards })
            local index
            for index = 1, #section.cards do
                local entry = section.cards[index]
                table.insert(view.rows, entry)
                table.insert(view.cards, entry)
                if entry.playerId == inputs.selected then
                    view.selected, view.selectedIndex = entry.playerId, #view.rows
                end
            end
        end
    end
    view.header = plural(view.players, "player") .. DOT .. view.online .. " online"
    view.sync = addon.RosterViewModel.SyncText(inputs.lastSync, inputs.now)
    view.default = view.cards[1] and view.cards[1].playerId or nil
    return view
end
