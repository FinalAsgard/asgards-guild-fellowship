local _, addon = ...

-- Builds the rows the roster window shows from stored characters plus live
-- roster facts. Pure: the caller passes in everything it needs.
--
-- In this slice every character is its own single-character player, so the
-- result is a flat list of character rows. Grouping, filters, and search
-- come in later slices.
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

-- inputs:
--   partition    a FellowshipStore partition
--   members      live roster facts keyed by character key (from the adapter)
--   normalizer   a NameNormalizer, for display names
--   classColor   function(classToken) -> "ffrrggbb" or nil
-- Returns rows sorted online first, then by display name. Each row:
--   { kind = "character", key, name, coloredName, classToken, level,
--     rank, online, location }
-- where `location` is the zone when online, or the last-online text.
function RosterViewModel.Build(inputs)
    local rows = {}
    local members = inputs.members or {}
    local classColor = inputs.classColor or function() return nil end

    inputs.partition:EachCharacter(function(key, character)
        local live = members[key] or {}
        local name = inputs.normalizer:Display(live.name or character.name) or key
        local classToken = live.classToken or character.class
        local online = live.online == true
        table.insert(rows, {
            kind = "character",
            key = key,
            name = name,
            coloredName = coloredName(name, classColor(classToken)),
            classToken = classToken,
            level = live.level or character.level,
            rank = live.rankName or (character.rank and ("Rank " .. character.rank)) or nil,
            online = online,
            location = online and live.zone or RosterViewModel.FormatLastOnline(live.lastOnline),
        })
    end)

    table.sort(rows, function(first, second)
        if first.online ~= second.online then
            return first.online
        end
        local firstName, secondName = string.lower(first.name), string.lower(second.name)
        if firstName ~= secondName then
            return firstName < secondName
        end
        return first.key < second.key
    end)
    return rows
end
