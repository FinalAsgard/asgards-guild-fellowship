local _, addon = ...

-- The player detail panel's header and tiles, for the new window. Built on
-- the old player panel's view model (PlayerPanelViewModel), which it keeps
-- as `panel` for the alias, main, characters, Bio and Log, so nothing is
-- worked out twice. Kept free of the Friends page's rules, so the roster
-- can show it as-is when it moves to the new window.
--
-- Pure: the partition, live roster facts and lookups are handed in.
local PlayerDetailViewModel = {
    NOT_SET = "Not set",
    NEVER = "Never",
    LEFT_GUILD = "Left the guild",
    FRIEND = "friend",
    TOP = "top",
}

-- "You haven't grouped with <name> yet": the Grouped tab with no parties.
function PlayerDetailViewModel.NeverGrouped(name)
    return "You haven't grouped with " .. tostring(name) .. " yet"
end
addon.PlayerDetailViewModel = PlayerDetailViewModel

local DOT = " · "

-- An optional input's answer (up to two values), or nil when it's missing
-- or fails.
local function ask(callback, ...)
    if callback == nil then
        return nil
    end
    local ok, first, second = pcall(callback, ...)
    if not ok then
        return nil
    end
    return first, second
end

-- How long ago `lastOnline` ({ years, months, days, hours }) was, in hours,
-- so two can be compared.
local function hoursAgo(lastOnline)
    if type(lastOnline) ~= "table" then
        return math.huge
    end
    return (lastOnline.years or 0) * 8760 + (lastOnline.months or 0) * 730 + (lastOnline.days or 0) * 24
        + (lastOnline.hours or 0)
end

-- "Level 60 Dwarf Warrior · Officer", leaving out what isn't known.
local function factsText(level, race, className, rank)
    local words = {}
    if type(level) == "number" then
        table.insert(words, "Level " .. level)
    end
    if type(race) == "string" and race ~= "" then
        table.insert(words, race)
    end
    if type(className) == "string" and className ~= "" then
        table.insert(words, className)
    end
    local parts = {}
    if words[1] ~= nil then
        table.insert(parts, table.concat(words, " "))
    end
    if type(rank) == "string" and rank ~= "" then
        table.insert(parts, rank)
    end
    return table.concat(parts, DOT)
end

-- A tile: { id, label, value, notSet }. `value` nil (or "") is not set and
-- reads as `missing`.
local function tile(id, label, value, missing)
    if type(value) ~= "string" or value == "" then
        return { id = id, label = label, value = missing, notSet = true }
    end
    return { id = id, label = label, value = value, notSet = false }
end

-- inputs: everything PlayerPanelViewModel.Build takes (partition, playerId,
-- members, normalizer, formatDate, classColor, grouped, joined, ...), plus
--   className   function(classToken) -> the class as the game names it
--   raceOf      function(key) -> the character's race, or nil when unknown
--   friendKeys  the pinned character keys (FellowshipStore:GetFriends)
--   mostGrouped GroupFriends:MostGrouped(): { { player, count } } in order
--   history     function() -> the user's GroupHistory entries ({ at,
--               characters, dungeon? })
--   historyMember function(key) -> a guildmate's { name, whisper,
--               classToken? }, or nil for one no longer known
--   tierOf      function(key) -> their GroupFriends tier, or nil
--   groupedShown how many of the Grouped tab's parties to show (default
--               LfgHistoryView.PAGE_SIZE; Show more adds a page)
--   rankChecklist function(playerId) -> the Rank tab's checklist
--               (RankUpViewModel.Checklist, plus `editable`), or nil when
--               the user may not see it
-- Returns nil when the player no longer exists, or:
--   { playerId, panel (PlayerPanelViewModel's view), header, tiles,
--     characters, bioRows, grouped, logRows, rank (the Rank tab's
--     checklist, nil when it isn't shown) }
-- header: { name (the alias, else the main's name), alias, mainName,
--   color, level, race, className, rank, facts ("Level 60 Dwarf Warrior ·
--   Officer"), badge (nil, or { kind = FRIEND } or { kind = TOP, rank }),
--   online, left, status ("Online, Ironforge", "Last online 2 days ago",
--   "Left the guild" or ""), target (the character to whisper or invite:
--   the online main, else an online alt, else nil), key (the character to
--   pin: the main when it's in the guild, else the first one that is),
--   isFriend, full (every Friend slot is taken), canToggle (the star button
--   can add or remove them) }
-- tiles: Discord, Grouped, Last grouped and Joined guild, each { id, label,
--   value, notSet }.
-- characters: the in-guild characters, main first, each { key, name,
--   color, level, race, className, isMain, status, roles } (the Characters
--   tab; departed characters are left out).
-- bioRows and logRows: the old player panel's Bio and Log rows, as-is.
-- grouped: the Grouped tab, LfgHistoryView's page of the parties holding
--   any of this player's characters: { parties = { { at, place?, members =
--   { { key, name, whisper, classToken?, tier?, friend, theirs } } } },
--   more, total, empty (the words for no parties) }; `theirs` marks this
--   player's characters.
function PlayerDetailViewModel.Build(inputs)
    local panel = addon.PlayerPanelViewModel.Build(inputs)
    if panel == nil then
        return nil
    end
    local partition, playerId = inputs.partition, inputs.playerId
    local members = inputs.members or {}
    local formatDate = inputs.formatDate or function(timestamp)
        return tostring(timestamp)
    end
    local keys = partition:CharactersOf(playerId)
    local mainKey = panel.main
    local alias = panel.alias
    if type(alias) ~= "string" or alias == "" then
        alias = nil
    end

    -- Who's online, and which character to reach: the main first.
    local inGuild, onlineKey, lastKey = {}, nil, nil
    local index
    for index = 1, #keys do
        local key = keys[index]
        if partition:IsInGuild(key) then
            table.insert(inGuild, key)
            local live = members[key] or {}
            if live.online and (onlineKey == nil or key == mainKey) then
                onlineKey = key
            end
            if lastKey == nil or hoursAgo(live.lastOnline) < hoursAgo((members[lastKey] or {}).lastOnline) then
                lastKey = key
            end
        end
    end
    local left = inGuild[1] == nil
    local status = ""
    if left then
        status = PlayerDetailViewModel.LEFT_GUILD
    elseif onlineKey ~= nil then
        local zone = (members[onlineKey] or {}).zone
        status = "Online" .. (zone and (", " .. zone) or "")
    else
        local ago = addon.RosterViewModel.FormatLastOnline((members[lastKey] or {}).lastOnline)
        status = ago and ("Last online " .. ago) or ""
    end
    local target
    if onlineKey ~= nil then
        local character = partition:GetCharacter(onlineKey) or {}
        target = (members[onlineKey] or {}).name or character.name or onlineKey
    end

    -- The main's facts, live where the roster has them.
    local main = partition:GetCharacter(mainKey) or {}
    local live = members[mainKey] or {}
    local classToken = live.classToken or main.class
    local rankKey = partition:IsInGuild(mainKey) and mainKey or inGuild[1]
    local rank = rankKey and (members[rankKey] or {}).rankName or nil
    local className = ask(inputs.className, classToken)
    local race = ask(inputs.raceOf, mainKey)
    local level = live.level or main.level

    -- Why they're starred: pinned, else their place in Most grouped.
    local friends, friendCount, isFriend = {}, 0, false
    local friendKeys = inputs.friendKeys or {}
    for index = 1, #friendKeys do
        local character = partition:GetCharacter(friendKeys[index])
        local owner = character and character.player or friendKeys[index]
        if not friends[owner] then
            friends[owner] = true
            friendCount = friendCount + 1
        end
        if owner == playerId then
            isFriend = true
        end
    end
    local badge
    if isFriend then
        badge = { kind = PlayerDetailViewModel.FRIEND }
    else
        local mostGrouped = inputs.mostGrouped or {}
        for index = 1, #mostGrouped do
            if mostGrouped[index].player == playerId then
                badge = { kind = PlayerDetailViewModel.TOP, rank = index }
                break
            end
        end
    end
    local full = friendCount >= addon.FellowshipStore.FRIEND_SLOTS

    -- The tiles.
    local count, last = ask(inputs.grouped, keys)
    if type(count) ~= "number" then
        count = 0
    end
    local joined = ask(inputs.joined, keys)
    if joined == "unknown" then
        joined = nil
    end
    local tiles = {
        tile("discord", "Discord", panel.discord, PlayerDetailViewModel.NOT_SET),
        tile("grouped", "Grouped", count > 0 and (count .. (count == 1 and " time" or " times")) or nil,
            PlayerDetailViewModel.NEVER),
        tile("lastGrouped", "Last grouped", count > 0 and type(last) == "number" and formatDate(last) or nil,
            PlayerDetailViewModel.NEVER),
        tile("joined", "Joined guild", joined, PlayerDetailViewModel.NOT_SET),
    }

    -- The Characters tab: in-guild characters, main first (as the old
    -- panel lists them).
    local characters = {}
    for index = 1, #panel.rows do
        local row = panel.rows[index]
        if row.kind == "character" and row.inGuild then
            local character = partition:GetCharacter(row.key) or {}
            local token = (members[row.key] or {}).classToken or character.class
            table.insert(characters, {
                key = row.key,
                name = row.name,
                color = row.color,
                level = row.level,
                race = ask(inputs.raceOf, row.key),
                className = ask(inputs.className, token),
                isMain = row.isMain,
                status = row.status,
                roles = row.roles,
            })
        end
    end

    -- The Grouped tab: the parties holding any of this player's
    -- characters, newest first, a page at a time.
    local own = {}
    for index = 1, #keys do
        own[keys[index]] = true
    end
    local together = {}
    local entries = ask(inputs.history)
    for index = 1, type(entries) == "table" and #entries or 0 do
        local entry = entries[index]
        local characterIndex
        for characterIndex = 1, #(entry.characters or {}) do
            if own[entry.characters[characterIndex]] then
                table.insert(together, entry)
                break
            end
        end
    end
    local history = addon.LfgHistoryView.Create()
    if type(inputs.groupedShown) == "number" and inputs.groupedShown > 0 then
        history.shown = inputs.groupedShown
    end
    local grouped = history:Page(together, function(key)
        return ask(inputs.historyMember, key)
    end, function(key)
        return ask(inputs.tierOf, key)
    end)
    for index = 1, #grouped.parties do
        local partyMembers = grouped.parties[index].members
        local memberIndex
        for memberIndex = 1, #partyMembers do
            partyMembers[memberIndex].theirs = own[partyMembers[memberIndex].key] == true
        end
    end
    grouped.empty = PlayerDetailViewModel.NeverGrouped(alias or panel.mainName)

    return {
        playerId = playerId,
        panel = panel,
        characters = characters,
        bioRows = panel.bioRows,
        logRows = panel.logRows,
        grouped = grouped,
        rank = ask(inputs.rankChecklist, playerId),
        header = {
            name = alias or panel.mainName,
            alias = alias,
            mainName = panel.mainName,
            color = ask(inputs.classColor, classToken),
            level = level,
            race = race,
            className = className,
            rank = rank,
            facts = factsText(level, race, className, rank),
            badge = badge,
            online = onlineKey ~= nil,
            left = left,
            status = status,
            target = target,
            key = (partition:IsInGuild(mainKey) and mainKey) or inGuild[1] or mainKey,
            isFriend = isFriend,
            full = full,
            canToggle = isFriend or not full,
        },
        tiles = tiles,
    }
end
