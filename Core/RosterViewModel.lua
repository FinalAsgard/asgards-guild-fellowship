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
-- Returns rows. A player with several characters gets a header row:
--   { kind = "player", id, label, alias, mainName, online, collapsed, count }
-- where `label` is "Alias (Main)", or the main's name without an alias,
-- followed (unless collapsed) by its character rows:
--   { kind = "character", key, player, isMain, name, coloredName,
--     classToken, level, rank, online, departed, location }
-- where `location` is the zone when online, the last-online text, or when
-- the character left. Departed characters are hidden unless showDeparted;
-- a player with no visible characters is left out.
-- A single-character player is just its character row, marked
-- `standalone = true` and carrying the player's `label` and `coloredLabel`.
-- Players sort online first, then by label.
function RosterViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    inputs.classColor = inputs.classColor or function() return nil end
    local collapsed = inputs.collapsed or {}
    local partition = inputs.partition

    local groups = {}
    partition:EachPlayer(function(id, player)
        local keys = partition:CharactersOf(id)
        if keys[1] ~= nil then
            local rows = {}
            local online = false
            -- CharactersOf puts the main first, so the label uses the
            -- main's name even when it is hidden.
            local mainName = characterRow(inputs, keys[1], partition:GetCharacter(keys[1]), id, true).name
            local index
            for index = 1, #keys do
                local row = characterRow(inputs, keys[index], partition:GetCharacter(keys[index]), id,
                    keys[index] == player.main)
                if not row.departed or inputs.showDeparted then
                    online = online or row.online
                    table.insert(rows, row)
                end
            end
            if rows[1] ~= nil then
                table.insert(groups, {
                    id = id,
                    label = player.alias and (player.alias .. " (" .. mainName .. ")") or mainName,
                    alias = player.alias,
                    mainName = mainName,
                    online = online,
                    rows = rows,
                })
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
