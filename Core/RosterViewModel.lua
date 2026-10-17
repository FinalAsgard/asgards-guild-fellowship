local _, addon = ...

-- Builds the rows the roster window shows from stored players and
-- characters plus live roster facts. Pure: the caller passes in everything
-- it needs.
--
-- The result is a flat list ready for a virtualized scroll list: a header
-- row per player with alts, followed (unless the group is collapsed) by its
-- character rows with the main first; a player with one character is a
-- single row. Filters and search come in later slices.
local RosterViewModel = {}
addon.RosterViewModel = RosterViewModel

local function plural(count, unit)
    return count .. " " .. unit .. (count == 1 and "" or "s")
end

-- "3 days ago" from the roster's { years, months, days, hours } offline
-- time, using its largest non-zero unit. Nil when unknown.
function RosterViewModel.FormatLastOnline(lastOnline)
    if type(lastOnline) ~= "table" then
        return nil
    end
    local units = {
        { field = "years", name = "year" },
        { field = "months", name = "month" },
        { field = "days", name = "day" },
        { field = "hours", name = "hour" },
    }
    local index
    for index = 1, #units do
        local count = lastOnline[units[index].field]
        if type(count) == "number" and count > 0 then
            return plural(count, units[index].name) .. " ago"
        end
    end
    return "less than an hour ago"
end

-- "just now", "5 minutes ago", "2 hours ago" or "3 days ago" for
-- `elapsed` seconds, using its largest unit.
function RosterViewModel.Ago(elapsed)
    if elapsed < 60 then
        return "just now"
    elseif elapsed < 3600 then
        return plural(math.floor(elapsed / 60), "minute") .. " ago"
    elseif elapsed < 86400 then
        return plural(math.floor(elapsed / 3600), "hour") .. " ago"
    end
    return plural(math.floor(elapsed / 86400), "day") .. " ago"
end

-- The footer's sync line: "Synced 5 minutes ago", or "Not synced yet".
function RosterViewModel.SyncText(lastSync, now)
    if type(lastSync) ~= "number" then
        return "Not synced yet"
    end
    return "Synced " .. RosterViewModel.Ago(math.max(0, (now or lastSync) - lastSync))
end

-- What `/agf sync` prints, one line each, from SyncSession's status (nil
-- without a guild).
function RosterViewModel.SyncStatusLines(status, now)
    if status == nil then
        return { "Guild sync isn't available: you're not in a guild, or saved data isn't ready." }
    end
    if not status.on then
        return { "Guild sync is off: the libraries it needs are missing." }
    end
    local state = "Guild sync is running."
    if status.paused then
        state = "Guild sync is paused while you're in combat, a boss encounter or a keystone run."
    end
    local lines = { state .. " " .. RosterViewModel.SyncText(status.lastSync, now) .. "." }
    if status.pending ~= nil then
        if status.pending == 0 then
            table.insert(lines, "None of your suggestions are waiting for an officer.")
        else
            table.insert(lines, plural(status.pending, "suggestion") .. " of yours "
                .. (status.pending == 1 and "is" or "are") .. " waiting for an officer.")
        end
    end
    return lines
end

local function coloredName(name, color)
    if type(color) ~= "string" then
        return name
    end
    return "|c" .. color .. name .. "|r"
end

-- "Left 3 days ago" for a departed character, from its departure date.
local function leftText(departed, now)
    local elapsed = math.max(0, (now or departed) - departed)
    local days = math.floor(elapsed / 86400)
    if days < 1 then
        return "Left today"
    end
    return "Left " .. plural(days, "day") .. " ago"
end

local function characterRow(inputs, key, character, playerId, isMain)
    local live = inputs.members[key] or {}
    local name = inputs.normalizer:Display(live.name or character.name) or key
    local classToken = live.classToken or character.class
    local online = live.online == true
    local departed = character.departed ~= nil
    local location = online and live.zone or RosterViewModel.FormatLastOnline(live.lastOnline)
    if departed then
        location = leftText(character.departed, inputs.now)
    end
    return {
        kind = "character",
        key = key,
        player = playerId,
        isMain = isMain,
        -- A main the player deliberately declared.
        declared = isMain and inputs.partition:IsDeclared(key),
        name = name,
        coloredName = coloredName(name, inputs.classColor(classToken)),
        classToken = classToken,
        level = live.level or character.level,
        rank = live.rankName or (character.rank and ("Rank " .. character.rank)) or nil,
        online = online,
        departed = departed,
        location = location,
    }
end

local function byName(first, second)
    local firstName, secondName = string.lower(first.label), string.lower(second.label)
    if firstName ~= secondName then
        return firstName < secondName
    end
    return first.id < second.id
end

-- inputs:
--   partition    a FellowshipStore partition
--   members      live roster facts keyed by character key (from the adapter)
--   normalizer   a NameNormalizer, for display names
--   classColor   function(classToken) -> "ffrrggbb" or nil
--   collapsed    set of player ids whose groups are collapsed
--   showDeparted true to include characters who left the guild
--   now          the current timestamp, for "Left N days ago"
--   search       text to match against character names, aliases and
--                Discord usernames, ignoring case; a matching player shows
--                its whole group
--   onlineOnly   true to show only players with a character online
-- Returns rows. A player with several characters gets a header row:
--   { kind = "player", id, label, alias, discord, mainName, online,
--     onlineAs, collapsed, count }
-- where `label` is "Alias (Main)", or the main's name without an alias,
-- `discord` is the player's Discord username or nil, and
-- `onlineAs` names the online character (the main if it is online),
-- followed (unless collapsed) by its character rows:
--   { kind = "character", key, player, isMain, declared, name, coloredName,
--     classToken, level, rank, online, departed, location }
-- where `declared` marks a main the player declared on purpose, and
-- `location` is the zone when online, the last-online text, or when
-- the character left. Departed characters are hidden unless showDeparted;
-- a player with no visible characters is left out.
-- A single-character player is just its character row, marked
-- `standalone = true` and carrying the player's `label`, `coloredLabel` and
-- `discord`.
-- Players sort online first, then by label.
local function trimmedLower(text)
    if type(text) ~= "string" then
        return ""
    end
    return string.lower((string.gsub(text, "^%s*(.-)%s*$", "%1")))
end

local function contains(text, needle)
    return text ~= nil and string.find(string.lower(text), needle, 1, true) ~= nil
end

-- Whether a group passes the search and online filters.
local function shown(group, needle, onlineOnly)
    if onlineOnly and not group.online then
        return false
    end
    if needle == "" or contains(group.alias, needle) or contains(group.discord, needle) then
        return true
    end
    local index
    for index = 1, #group.rows do
        if contains(group.rows[index].name, needle) then
            return true
        end
    end
    return false
end

function RosterViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    inputs.classColor = inputs.classColor or function() return nil end
    local collapsed = inputs.collapsed or {}
    local partition = inputs.partition
    local needle = trimmedLower(inputs.search)

    local groups = {}
    partition:EachPlayer(function(id, player)
        local keys = partition:CharactersOf(id)
        if keys[1] ~= nil then
            local rows = {}
            local online = false
            local onlineAs
            -- CharactersOf puts the main first, so the label uses the
            -- main's name even when it is hidden.
            local mainName = characterRow(inputs, keys[1], partition:GetCharacter(keys[1]), id, true).name
            local index
            for index = 1, #keys do
                local row = characterRow(inputs, keys[index], partition:GetCharacter(keys[index]), id,
                    keys[index] == player.main)
                if not row.departed or inputs.showDeparted then
                    if row.online and onlineAs == nil then
                        onlineAs = row.name
                    end
                    online = online or row.online
                    table.insert(rows, row)
                end
            end
            local group = {
                id = id,
                label = player.alias and (player.alias .. " (" .. mainName .. ")") or mainName,
                alias = player.alias,
                discord = (partition:PlayerProfileText(id, "discord")),
                mainName = mainName,
                online = online,
                onlineAs = onlineAs,
                rows = rows,
            }
            if rows[1] ~= nil and shown(group, needle, inputs.onlineOnly) then
                table.insert(groups, group)
            end
        end
    end)

    table.sort(groups, function(first, second)
        if first.online ~= second.online then
            return first.online
        end
        return byName(first, second)
    end)

    local rows = {}
    local groupIndex
    for groupIndex = 1, #groups do
        local group = groups[groupIndex]
        if #group.rows == 1 then
            -- A single-character player is one plain row, labeled like a
            -- header would be, so the list isn't doubled up.
            local row = group.rows[1]
            row.standalone = true
            row.label = group.label
            row.discord = group.discord
            row.coloredLabel = group.alias and (group.alias .. " (" .. row.coloredName .. ")")
                or row.coloredName
            table.insert(rows, row)
        else
            table.insert(rows, {
                kind = "player",
                id = group.id,
                label = group.label,
                alias = group.alias,
                discord = group.discord,
                mainName = group.mainName,
                online = group.online,
                onlineAs = group.onlineAs,
                collapsed = collapsed[group.id] == true,
                count = #group.rows,
            })
            if not collapsed[group.id] then
                local rowIndex
                for rowIndex = 1, #group.rows do
                    table.insert(rows, group.rows[rowIndex])
                end
            end
        end
    end
    return rows
end

-- The ids of every player with more than one character, for Collapse all.
function RosterViewModel.GroupIds(partition)
    local ids = {}
    partition:EachPlayer(function(id)
        if partition:CharactersOf(id)[2] ~= nil then
            table.insert(ids, id)
        end
    end)
    table.sort(ids)
    return ids
end

-- The windows, in days, players are counted active within.
RosterViewModel.ACTIVE_DAYS = { 7, 30, 90 }

-- Hours since a character was last online, from the roster's { years,
-- months, days, hours } (a month taken as 30 days), or nil when unknown.
local function hoursAway(lastOnline)
    if type(lastOnline) ~= "table" then
        return nil
    end
    local months = (lastOnline.years or 0) * 12 + (lastOnline.months or 0)
    return (months * 30 + (lastOnline.days or 0)) * 24 + (lastOnline.hours or 0)
end

-- How big the guild is, from every player's current characters (departed
-- ones never count), whatever the roster's search and filters:
--   { known, unlinked, players, alts, characters, playersOnline,
--     charactersOnline, withAlias, declared, active = { [days] = n } }
-- A player is known when they have two or more current characters, an
-- alias, or a current main that was declared; otherwise their one character
-- is unlinked, and counts as a player of its own until it's linked.
-- players = known + unlinked. Alts are each known player's characters after
-- the first, so players + alts == characters. `members` (live roster facts
-- keyed by character key) says who is online and when each character was
-- last online: playersOnline counts players with a character online, and
-- active[days] players with one online within that many days (see
-- ACTIVE_DAYS). withAlias and declared count players with an alias, and
-- with a declared current main.
function RosterViewModel.Counts(partition, members)
    members = members or {}
    local counts = {
        known = 0, unlinked = 0, players = 0, alts = 0, characters = 0,
        playersOnline = 0, charactersOnline = 0, withAlias = 0, declared = 0, active = {},
    }
    local index
    for index = 1, #RosterViewModel.ACTIVE_DAYS do
        counts.active[RosterViewModel.ACTIVE_DAYS[index]] = 0
    end
    partition:EachPlayer(function(id, player)
        local keys = partition:CharactersOf(id)
        local current, online = 0, 0
        -- Hours since the player's most recent login; 0 while online.
        local latest
        local keyIndex
        for keyIndex = 1, #keys do
            if partition:IsInGuild(keys[keyIndex]) then
                current = current + 1
                local live = members[keys[keyIndex]]
                local away
                if live ~= nil and live.online == true then
                    online = online + 1
                    away = 0
                else
                    away = hoursAway(live and live.lastOnline)
                end
                if away ~= nil and (latest == nil or away < latest) then
                    latest = away
                end
            end
        end
        if current == 0 then
            return
        end
        counts.players = counts.players + 1
        counts.characters = counts.characters + current
        counts.charactersOnline = counts.charactersOnline + online
        counts.playersOnline = counts.playersOnline + (online > 0 and 1 or 0)
        local days
        for days in pairs(counts.active) do
            if latest ~= nil and latest < days * 24 then
                counts.active[days] = counts.active[days] + 1
            end
        end
        local declared = player.main ~= nil and partition:IsInGuild(player.main) and partition:IsDeclared(player.main)
        if current >= 2 or player.alias ~= nil or declared then
            counts.known = counts.known + 1
            counts.alts = counts.alts + current - 1
            counts.withAlias = counts.withAlias + (player.alias ~= nil and 1 or 0)
            counts.declared = counts.declared + (declared and 1 or 0)
        else
            counts.unlinked = counts.unlinked + 1
        end
    end)
    return counts
end

-- The roster's counts line: "320 players (27 known + 293 unlinked) · 31 alts
-- · 351 characters", leaving out the breakdown when none are unlinked.
function RosterViewModel.CountsText(counts)
    local players = plural(counts.players, "player")
    if counts.unlinked > 0 then
        players = players .. " (" .. counts.known .. " known + " .. counts.unlinked .. " unlinked)"
    end
    return table.concat({ players, plural(counts.alts, "alt"), plural(counts.characters, "character") }, " · ")
end

-- The counts line's tooltip, one string per line: a "Guild size" title,
-- the players and how many are known, who is active and online, how
-- complete the Fellowship data is, and (when there are any) what
-- "unlinked" means.
function RosterViewModel.CountsTooltip(counts)
    local lines = { "Guild size" }
    if counts.unlinked > 0 then
        table.insert(lines, plural(counts.players, "player") .. ": " .. counts.known .. " known + "
            .. counts.unlinked .. " unlinked")
    else
        table.insert(lines, plural(counts.players, "player") .. ", all known")
    end
    local active = {}
    local index
    for index = 1, #RosterViewModel.ACTIVE_DAYS do
        local days = RosterViewModel.ACTIVE_DAYS[index]
        table.insert(active, (counts.active and counts.active[days] or 0) .. " in " .. days .. " days")
    end
    table.insert(lines, "Active players: " .. table.concat(active, ", "))
    table.insert(lines, counts.playersOnline .. " of " .. plural(counts.players, "player") .. " online")
    table.insert(lines, counts.charactersOnline .. " of " .. plural(counts.characters, "character") .. " online")
    table.insert(lines, plural(counts.withAlias, "player") .. " " .. (counts.withAlias == 1 and "has" or "have")
        .. " an alias")
    table.insert(lines, plural(counts.declared, "main") .. " declared")
    if counts.unlinked > 0 then
        table.insert(lines, "  Unlinked: a lone character with no alias or declared main.")
        table.insert(lines, "  It counts as a player until it's linked, but may be someone's alt.")
    end
    return lines
end

-- Remembers the last build and returns it again while `stamp` (a value the
-- caller changes whenever any input changes) is the same, so reopening the
-- window or redrawing without changes doesn't rebuild.
local Cache = {}
Cache.__index = Cache

function RosterViewModel.CreateCache()
    return setmetatable({ builds = 0 }, Cache)
end

function Cache:Build(inputs, stamp)
    if self.rows ~= nil and stamp ~= nil and stamp == self.stamp then
        return self.rows
    end
    self.rows = RosterViewModel.Build(inputs)
    self.stamp = stamp
    self.builds = self.builds + 1
    return self.rows
end
