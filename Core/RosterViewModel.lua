local _, addon = ...

-- Builds the rows the roster window shows from stored players and
-- characters plus live roster facts. Pure: the caller passes in everything
-- it needs.
--
-- The result is a flat list ready for a virtualized scroll list: a header
-- row per player, followed (unless the group is collapsed) by its character
-- rows with the main first. Filters and search come in later slices.
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

local function characterRow(inputs, key, character, playerId, isMain)
    local live = inputs.members[key] or {}
    local name = inputs.normalizer:Display(live.name or character.name) or key
    local classToken = live.classToken or character.class
    local online = live.online == true
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
        location = online and live.zone or RosterViewModel.FormatLastOnline(live.lastOnline),
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
-- Returns rows. Header rows:
--   { kind = "player", id, label, alias, mainName, online, collapsed, count }
-- where `label` is "Alias (Main)", or the main's name without an alias.
-- Character rows:
--   { kind = "character", key, player, isMain, name, coloredName,
--     classToken, level, rank, online, location }
-- where `location` is the zone when online, or the last-online text.
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
            local index
            for index = 1, #keys do
                local row = characterRow(inputs, keys[index], partition:GetCharacter(keys[index]), id,
                    keys[index] == player.main)
                online = online or row.online
                table.insert(rows, row)
            end
            -- CharactersOf puts the main first.
            local mainName = rows[1].name
            table.insert(groups, {
                id = id,
                label = player.alias and (player.alias .. " (" .. mainName .. ")") or mainName,
                alias = player.alias,
                mainName = mainName,
                online = online,
                rows = rows,
            })
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
    return rows
end
