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
    local roles
    if inputs.rolesOf ~= nil then
        local ok, text = pcall(inputs.rolesOf, key)
        roles = ok and type(text) == "string" and text or nil
    end
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
        roles = roles,
        -- Actions, matching the right-click menu.
        canMakeMain = not isMain and inGuild,
        canDetach = altCount > 0,
    }
end

-- How wide a line of the bio is, in characters, so it fits the panel.
PlayerPanelViewModel.BIO_LINE = 48

-- One UTF-8 character at the start of a string.
local CHARACTER = "^[%z\1-\127\194-\244][\128-\191]*"

-- The first character of `text`: a UTF-8 character, or a byte that doesn't
-- start one (malformed text) on its own.
local function firstCharacter(text)
    return string.match(text, CHARACTER) or string.sub(text, 1, 1)
end

-- `text` broken into lines at spaces where it can be (a word longer than a
-- line is split, never inside a character). A line is at most `width`
-- bytes, or, given `measure(text) -> width`, at most `width` as measured.
function PlayerPanelViewModel.Wrap(text, width, measure)
    measure = measure or function(part)
        return #part
    end
    local lines = {}
    -- A line break the player typed starts a new line, and a blank line
    -- they typed stays (one at the very end is dropped).
    if string.find(text, "\n", 1, true) ~= nil then
        local paragraph
        for paragraph in string.gmatch(string.gsub(text, "\n+$", "") .. "\n", "([^\n]*)\n") do
            local wrapped = PlayerPanelViewModel.Wrap(paragraph, width, measure)
            if wrapped[1] == nil then
                table.insert(lines, "")
            end
            local index
            for index = 1, #wrapped do
                table.insert(lines, wrapped[index])
            end
        end
        return lines
    end
    local current = ""
    local word
    for word in string.gmatch(text, "%S+") do
        while measure(word) > width do
            if current ~= "" then
                table.insert(lines, current)
                current = ""
            end
            -- As many characters from its start as fit, and always at
            -- least one, so the word gets shorter each time.
            local piece = firstCharacter(word)
            while #piece < #word do
                local character = firstCharacter(string.sub(word, #piece + 1))
                if measure(piece .. character) > width then
                    break
                end
                piece = piece .. character
            end
            table.insert(lines, piece)
            word = string.sub(word, #piece + 1)
        end
        if current == "" then
            current = word
        elseif measure(current .. " " .. word) <= width then
            current = current .. " " .. word
        else
            table.insert(lines, current)
            current = word
        end
    end
    if current ~= "" then
        table.insert(lines, current)
    end
    return lines
end

-- The player's Discord, location and bio, as "about" rows under an About
-- heading; nothing when none is set. `wrap(text) -> lines` breaks each
-- into lines that fit the panel.
local function aboutRows(partition, playerId, wrap)
    local discord = partition:PlayerProfileText(playerId, "discord")
    local location = partition:PlayerProfileText(playerId, "location")
    local bio = partition:PlayerProfileText(playerId, "bio")
    if discord == nil and location == nil and bio == nil then
        return {}
    end
    local rows = { { kind = "section", text = "About" } }
    local function add(text)
        local lines = wrap(text)
        local index
        for index = 1, #lines do
            table.insert(rows, { kind = "about", text = lines[index] })
        end
    end
    if discord ~= nil then
        add("Discord: " .. discord)
    end
    if location ~= nil then
        add("Location: " .. location)
    end
    if bio ~= nil then
        add(bio)
    end
    return rows
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
-- formatDate (function(timestamp) -> text), adStats (optional function(keys)
-- -> the player's ad count line, or nil), rolesOf (optional function(key)
-- -> the character's role preferences as text, or nil), groupedWith
-- (optional function(keys) -> how often this user grouped with the player,
-- or nil), wrap (optional function(text) -> an About entry's lines as
-- they fit the panel; by default, lines of at most BIO_LINE bytes).
-- Returns nil when the player no longer exists, or:
--   { id, label, alias, aliasSource, main, mainName, canMerge, dontSync, rows }
-- where `main` is the main's character key, `canMerge` whether the player
-- can be merged into another (only with no alts), `dontSync` whether guild
-- sync leaves this player alone, and `rows` is a flat list for the
-- panel's scroll list:
--   { kind = "stat", text }  (the player's ad count, then how often you
--                             grouped with them, first, when there are any)
--   { kind = "section", text }
--   { kind = "about", text }  (under an About heading: "Discord: name",
--                              "Location: text", then the bio's lines;
--                              only what the player set)
--   { kind = "character", key, name, level, isMain, inGuild, status, source,
--     roles, canMakeMain, canDetach }
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
    local index

    if inputs.adStats ~= nil then
        local ok, line = pcall(inputs.adStats, keys)
        if ok and type(line) == "string" then
            table.insert(rows, { kind = "stat", text = line })
        end
    end
    if inputs.groupedWith ~= nil then
        local ok, line = pcall(inputs.groupedWith, keys)
        if ok and type(line) == "string" then
            table.insert(rows, { kind = "stat", text = line })
        end
    end
    local about = aboutRows(partition, inputs.playerId, inputs.wrap or function(text)
        return PlayerPanelViewModel.Wrap(text, PlayerPanelViewModel.BIO_LINE)
    end)
    for index = 1, #about do
        table.insert(rows, about[index])
    end
    table.insert(rows, { kind = "section", text = "Main" })
    local mainRow = characterEntry(inputs, player.main, true, altCount)
    table.insert(rows, mainRow)

    table.insert(rows, { kind = "section", text = "Alts" })
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

    local mainName = mainRow.name
    return {
        id = inputs.playerId,
        label = player.alias and (player.alias .. " (" .. mainName .. ")") or mainName,
        alias = player.alias,
        aliasSource = SOURCES[player.aliasSource],
        main = player.main,
        mainName = mainName,
        canMerge = altCount == 0,
        dontSync = player.noSync == true,
        rows = rows,
    }
end
