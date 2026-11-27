local _, addon = ...

-- The rows of the new window's Roster column: one player card per player
-- (a lone character is a player of its own), under a Players label with
-- their count, sorted by Name (the default), Last online, Rank or how often
-- the user grouped with them. Alts don't get rows of their own; the player
-- panel lists them. A player with no character left in the guild has no
-- card. Sorted by anything but Name, a card carries a quiet tag after its
-- name with what it's sorted by: when they were last online, their rank,
-- or the party count ("12×").
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
    PLAYERS = "Players",
    -- The sorts, in the order Sort offers them; the first is the default.
    SORTS = {
        { id = "name", label = "Name" },
        { id = "lastOnline", label = "Last online" },
        { id = "rank", label = "Rank" },
        { id = "grouped", label = "Grouped with" },
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
        lastOnline = onlineKey ~= nil and RosterListModel.ONLINE
            or addon.RosterViewModel.FormatLastOnline((members[latestKey or leadKey] or {}).lastOnline),
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

-- Online first, then the most recent login (players on less than an hour
-- ago, who count as 0 hours, after those online now), unknown last, then
-- by name.
local function byLastOnline(a, b)
    if a.online ~= b.online then
        return a.online
    end
    return byField("away")(a, b)
end

-- Most parties first, then by name; never grouped with, last.
local function byGrouped(a, b)
    if (a.grouped or 0) ~= (b.grouped or 0) then
        return (a.grouped or 0) > (b.grouped or 0)
    end
    return byName(a, b)
end

local ORDERS = {
    name = byName,
    lastOnline = byLastOnline,
    rank = byField("rankIndex"),
    grouped = byGrouped,
}

-- The tag a card carries for `sort`, or nil.
local function tagFor(entry, sort)
    if sort == "lastOnline" then
        return entry.lastOnline
    elseif sort == "rank" then
        return entry.rankName
    elseif sort == "grouped" and (entry.grouped or 0) > 0 then
        return entry.grouped .. "×"
    end
    return nil
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
--   search      text to find in aliases, character names and Discord
--               names, ignoring case
--   sort        a SORTS id (default "name")
--   rank        a rank index: only players at that rank show
--   onlineOnly  true to show only players with a character online
--   groupedOf   function(key) -> how many parties the user was in with
--               that character's player (GroupFriends:StatsOf)
--   selfKey     the user's own character key; their own player has no
--               party count
-- Returns {
--   rows      the column's rows, in order: { kind = "section", text, count }
--             then that section's cards, { kind = "player", playerId, key,
--             keys, name, alias, mainName, classToken, className, color,
--             online, away, lastOnline, rankIndex, rankName, grouped,
--             characters, star, sub, tag }
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
    local sort = ORDERS[inputs.sort] ~= nil and inputs.sort or RosterListModel.SORTS[1].id
    local selfCharacter = inputs.selfKey and partition:GetCharacter(inputs.selfKey) or nil
    local selfPlayer = selfCharacter and selfCharacter.player or nil
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
        if playerId ~= selfPlayer then
            local count = ask(inputs.groupedOf, entry.key)
            entry.grouped = type(count) == "number" and count or 0
        end
        entry.tag = tagFor(entry, sort)
        table.insert(shown, entry)
    end)
    table.sort(rankList, function(a, b)
        return a.index < b.index
    end)
    table.sort(shown, ORDERS[sort])
    local sections = { { text = RosterListModel.PLAYERS, cards = shown } }
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

-- The officers' Departed tab: every character that left the guild, most
-- recent first. inputs: partition, normalizer, classColor, className, now.
-- Returns rows { key, name, color, level, className, playerId, player (the
-- player's alias, else its main's name), left ("Left 3 days ago"),
-- remaining (the names of the player's characters still in the guild, in
-- the roster's order; empty when the whole player left), departed (when) }.
function RosterListModel.Departed(inputs)
    local partition, normalizer = inputs.partition, inputs.normalizer
    local function nameOf(key)
        local raw = (partition:GetCharacter(key) or {}).name or key
        return normalizer and normalizer:Display(raw) or raw
    end
    local rows = {}
    partition:EachCharacter(function(key, character)
        if character.departed == nil then
            return
        end
        local player = character.player and partition:GetPlayer(character.player) or nil
        local alias = player and player.alias or nil
        if type(alias) ~= "string" or alias == "" then
            alias = nil
        end
        local remaining = {}
        local keys = character.player and partition:CharactersOf(character.player) or {}
        local index
        for index = 1, #keys do
            if partition:IsInGuild(keys[index]) then
                table.insert(remaining, nameOf(keys[index]))
            end
        end
        table.insert(rows, {
            key = key,
            name = nameOf(key),
            color = ask(inputs.classColor, character.class),
            level = character.level,
            className = ask(inputs.className, character.class),
            playerId = character.player,
            player = alias or (player and nameOf(player.main)) or nameOf(key),
            left = addon.RosterViewModel.LeftText(character.departed, inputs.now),
            remaining = remaining,
            departed = character.departed,
        })
    end)
    table.sort(rows, function(a, b)
        if a.departed ~= b.departed then
            return a.departed > b.departed
        end
        return a.key < b.key
    end)
    return rows
end
