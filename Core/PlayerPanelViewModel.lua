local _, addon = ...

-- Builds the player edit panel: the player's alias, acting main, alts, and
-- character history. Pure: the caller passes the partition, live roster
-- facts, a NameNormalizer, and a date formatter.
local PlayerPanelViewModel = {}
addon.PlayerPanelViewModel = PlayerPanelViewModel

local SOURCES = {
    note = "from a note",
    manual = "set by hand",
    roster = "from the roster",
}

local REASONS = {
    departed = "left the guild",
    purged = "left the guild, purged",
    ["out of guild"] = "not in the guild",
}

local function characterEntry(inputs, key, isMain, altCount)
    local character = inputs.partition:GetCharacter(key)
    local live = inputs.members[key] or {}
    local inGuild = inputs.partition:IsInGuild(key)
    local status
    if not inGuild then
        status = "Left the guild"
    elseif live.online then
        status = "Online" .. (live.zone and (", " .. live.zone) or "")
    else
        status = addon.RosterViewModel.FormatLastOnline(live.lastOnline) or "Offline"
    end
    return {
        kind = "character",
        key = key,
        name = inputs.normalizer:Display(live.name or character.name) or key,
        level = live.level or character.level,
        isMain = isMain,
        inGuild = inGuild,
        status = status,
        source = SOURCES[character.source],
        -- Actions, matching the right-click menu.
        canMakeMain = not isMain and inGuild,
        canDetach = altCount > 0,
    }
end

-- A history entry's dates: "since 2026-10-01", "until 2026-10-05", or both.
local function datesText(entry, formatDate)
    local parts = {}
    if type(entry.since) == "number" and entry.since > 0 then
        table.insert(parts, "since " .. formatDate(entry.since))
    end
    if type(entry["until"]) == "number" and entry["until"] > 0 then
        table.insert(parts, "until " .. formatDate(entry["until"]))
    end
    return table.concat(parts, ", ")
end

-- inputs: partition, playerId, members (live facts by key), normalizer,
-- formatDate (function(timestamp) -> text).
-- Returns nil when the player no longer exists, or:
--   { id, label, alias, aliasSource, main, mainName, dontSync, rows }
-- where `main` is the main's character key, `dontSync` whether guild sync
-- leaves this player alone, and `rows` is a flat list for the
-- panel's scroll list:
--   { kind = "section", text }
--   { kind = "character", key, name, level, isMain, inGuild, status, source,
--     canMakeMain, canDetach }
--   { kind = "history", name, role, dates, reason }
--   { kind = "empty", text }
function PlayerPanelViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    local formatDate = inputs.formatDate or function(timestamp)
        return tostring(timestamp)
    end
    local partition = inputs.partition
    local player = partition:GetPlayer(inputs.playerId)
    if player == nil then
        return nil
    end
    local keys = partition:CharactersOf(inputs.playerId)
    local altCount = #keys - 1
    local rows = {}

    table.insert(rows, { kind = "section", text = "Main" })
    table.insert(rows, characterEntry(inputs, player.main, true, altCount))

    table.insert(rows, { kind = "section", text = "Alts" })
    local index
    for index = 1, #keys do
        if keys[index] ~= player.main then
            table.insert(rows, characterEntry(inputs, keys[index], false, altCount))
        end
    end
    if altCount == 0 then
        table.insert(rows, { kind = "empty", text = "No alts" })
    end

    table.insert(rows, { kind = "section", text = "History" })
    -- Former characters only: an entry for a character that is back in this
    -- player and in the guild (moved back, or rejoined) is left out.
    local history = {}
    local all = partition:GetHistory(inputs.playerId)
    for index = 1, #all do
        local current = all[index].character and partition:GetCharacter(all[index].character)
        if not (current ~= nil and current.player == inputs.playerId and partition:IsInGuild(all[index].character)) then
            table.insert(history, all[index])
        end
    end
    for index = #history, 1, -1 do
        local entry = history[index]
        table.insert(rows, {
            kind = "history",
            -- Shown as the roster spells names (no home realm); an
            -- out-of-guild name from a note is shown as written.
            name = (inputs.normalizer and inputs.normalizer:Display(entry.name)) or entry.name,
            role = entry.role == "main" and "Main" or "Alt",
            dates = datesText(entry, formatDate),
            reason = REASONS[entry.reason] or entry.reason or "",
        })
    end
    if history[1] == nil then
        table.insert(rows, { kind = "empty", text = "No former characters" })
    end

    local mainName = rows[2].name
    return {
        id = inputs.playerId,
        label = player.alias and (player.alias .. " (" .. mainName .. ")") or mainName,
        alias = player.alias,
        aliasSource = SOURCES[player.aliasSource],
        main = player.main,
        mainName = mainName,
        dontSync = player.noSync == true,
        rows = rows,
    }
end
