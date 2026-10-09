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
--   search       text to match against character names and aliases,
--                ignoring case; a matching player shows its whole group
--   onlineOnly   true to show only players with a character online
-- Returns rows. A player with several characters gets a header row:
--   { kind = "player", id, label, alias, mainName, online, onlineAs,
--     collapsed, count }
-- where `label` is "Alias (Main)", or the main's name without an alias, and
-- `onlineAs` names the online character (the main if it is online),
-- followed (unless collapsed) by its character rows:
--   { kind = "character", key, player, isMain, name, coloredName,
--     classToken, level, rank, online, departed, location }
-- where `location` is the zone when online, the last-online text, or when
-- the character left. Departed characters are hidden unless showDeparted;
-- a player with no visible characters is left out.
-- A single-character player is just its character row, marked
-- `standalone = true` and carrying the player's `label` and `coloredLabel`.
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
    if needle == "" or contains(group.alias, needle) then
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
            row.coloredLabel = group.alias and (group.alias .. " (" .. row.coloredName .. ")")
                or row.coloredName
            table.insert(rows, row)
        else
            table.insert(rows, {
                kind = "player",
                id = group.id,
                label = group.label,
                alias = group.alias,
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
