local _, addon = ...

-- The rows of the new window's Roster column: one player card per player
-- (a lone character is a player of its own). Sorted Online first (the
-- default), they're split into Online and Offline sections, each headed by
-- a label with its count; sorted by Name, Last online or Rank, they're one
-- Players section. Alts don't get rows of their own; the player panel lists
-- them. A player with no character left in the guild has no card.
--
-- A card's big name is the player's alias, else their main's name. Its sub
-- line names the character that's online (or the main, while offline) when
-- that isn't the big name, how many characters they have, and where they
-- are: the online character's zone, or when they were last online. A
-- search that found the player only by alts says which instead ("matches
-- Vexadin, Vexhunt and 3 more").
--
-- A player's rank is their highest-ranked character's, for sorting and the
-- Rank filter alike.
--
-- Pure: the partition, live roster facts and lookups are handed in. The
-- last-online, sync and plural texts are RosterViewModel's.
local RosterListModel = {
    ONLINE = "Online",
    OFFLINE = "Offline",
    PLAYERS = "Players",
    -- The sorts, in the order Sort offers them.
    SORTS = {
        { id = "online", label = "Online first" },
        { id = "name", label = "Name" },
        { id = "lastOnline", label = "Last online" },
        { id = "rank", label = "Rank" },
    },
    -- How many matched characters a card names before "and N more".
    MATCH_NAMES = 2,
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
    -- The highest rank (the lowest rank index) and its name.
    local rankIndex, rankName
    local index
    for index = 1, #keys do
        local key = keys[index]
        local character = partition:GetCharacter(key)
        if character ~= nil and partition:IsInGuild(key) then
            table.insert(inGuild, key)
            local live = members[key] or {}
            if live.online == true and onlineKey == nil then
                onlineKey = key
            end
            local away = addon.RosterViewModel.HoursAway(live.lastOnline)
            if away ~= nil and (latest == nil or away < latest) then
                latest, latestKey = away, key
            end
            local rank = live.rankIndex or character.rank
            if type(rank) == "number" and (rankIndex == nil or rank < rankIndex) then
                rankIndex = rank
                rankName = live.rankName or ("Rank " .. rank)
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
        -- Hours since the latest login: 0 while online, nil when unknown.
        away = onlineKey ~= nil and 0 or latest,
        rankIndex = rankIndex,
        rankName = rankName,
        characters = #inGuild,
        star = friends[playerId] == true,
        sub = table.concat(parts, DOT),
        nameOf = nameOf,
    }
end

-- "matches Vexadin", "matches Vexadin and Vexhunt", or "matches Vexadin,
-- Vexhunt and 3 more".
function RosterListModel.MatchText(names)
    local shown = RosterListModel.MATCH_NAMES
    if #names <= shown + 1 then
        if #names == 1 then
            return "matches " .. names[1]
        end
        return "matches " .. table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
    end
    return "matches " .. table.concat(names, ", ", 1, shown) .. " and " .. (#names - shown) .. " more"
end

-- Whether `needle` (lowercase, not empty) is in the card's alias, its
-- player's Discord name or any of its characters' names. When only
-- characters other than the lead match, also returns their names.
local function matches(inputs, entry, needle)
    local function has(text)
        return type(text) == "string" and string.find(lower(text), needle, 1, true) ~= nil
    end
    if has(entry.alias) or has(entry.mainName)
        or has((inputs.partition:PlayerProfileText(entry.playerId, "discord")))
    then
        return true
    end
    local names = {}
    local index
    for index = 2, #entry.keys do
        local name = entry.nameOf(entry.keys[index])
        if has(name) then
            table.insert(names, name)
        end
    end
    if names[1] == nil then
        return false
    end
    return true, names
end

-- By name, then by player id so the order never changes.
local function byName(a, b)
    if lower(a.name) ~= lower(b.name) then
        return lower(a.name) < lower(b.name)
    end
    return tostring(a.playerId) < tostring(b.playerId)
end

-- By `field` (smallest first, unknown last), then by name.
local function byField(field)
    return function(a, b)
        if a[field] ~= b[field] then
            if a[field] == nil or b[field] == nil then
                return b[field] == nil
            end
            return a[field] < b[field]
        end
        return byName(a, b)
    end
end

local ORDERS = {
    name = byName,
    lastOnline = byField("away"),
    rank = byField("rankIndex"),
}

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
--   search      text to find in aliases, character names and Discord
--               names, ignoring case
--   sort        a SORTS id (default "online")
--   rank        a rank index: only players at that rank show
--   onlineOnly  true to show only players with a character online
-- Returns {
--   rows      the column's rows, in order: { kind = "section", text, count }
--             then that section's cards, { kind = "player", playerId, key,
--             keys, name, alias, mainName, classToken, className, color,
--             online, away, rankIndex, rankName, characters, star, sub }
--   cards     the cards alone, in the same order
--   ranks     the Rank filter's choices: { index, name } for every rank a
--             player has, highest first
--   players, online   how many players have a card, and how many of them
--             are online, whatever the search and filters
--   header    "550 players · 42 online"
--   sync      "Synced 5 minutes ago", or "Not synced yet"
--   selected  `selected` when it has a card, else nil
--   selectedIndex  its row's index in `rows`, or nil
--   default   the player to select when nothing is: the first card's, or nil
-- }
function RosterListModel.Build(inputs)
    local partition = inputs.partition
    local friends = friendPlayers(partition, inputs.friendKeys)
    local needle = string.match(lower(inputs.search), "^%s*(.-)%s*$")
    local shown = {}
    local players, playersOnline = 0, 0
    local ranks, rankList = {}, {}
    partition:EachPlayer(function(playerId, player)
        local entry = card(inputs, playerId, player, friends)
        if entry == nil then
            return
        end
        players = players + 1
        playersOnline = playersOnline + (entry.online and 1 or 0)
        if entry.rankIndex ~= nil and ranks[entry.rankIndex] == nil then
            ranks[entry.rankIndex] = true
            table.insert(rankList, { index = entry.rankIndex, name = entry.rankName })
        end
        if inputs.onlineOnly and not entry.online then
            return
        end
        if inputs.rank ~= nil and entry.rankIndex ~= inputs.rank then
            return
        end
        if needle ~= "" then
            local found, names = matches(inputs, entry, needle)
            if not found then
                return
            end
            if names ~= nil then
                entry.sub = RosterListModel.MatchText(names)
            end
        end
        entry.nameOf = nil
        table.insert(shown, entry)
    end)
    table.sort(rankList, function(a, b)
        return a.index < b.index
    end)
    local sections
    local order = ORDERS[inputs.sort]
    if order ~= nil then
        table.sort(shown, order)
        sections = { { text = RosterListModel.PLAYERS, cards = shown } }
    else
        local online, offline = {}, {}
        local index
        for index = 1, #shown do
            table.insert(shown[index].online and online or offline, shown[index])
        end
        table.sort(online, byName)
        table.sort(offline, byName)
        sections = {
            { text = RosterListModel.ONLINE, cards = online },
            { text = RosterListModel.OFFLINE, cards = offline },
        }
    end
    local view = { rows = {}, cards = {}, ranks = rankList, players = players, online = playersOnline }
    local _, section
    for _, section in ipairs(sections) do
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
