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
        -- The name's class color ("ffrrggbb"), as the roster colors it.
        color = inputs.classColor and inputs.classColor(live.classToken or character.class) or nil,
        level = live.level or character.level,
        isMain = isMain,
        inGuild = inGuild,
        status = status,
        source = SOURCES[character.source],
        roles = roles,
        -- The name's right-click menu, matching the roster's.
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

-- The player's profile text of `field`, or nil when it's not set (or was
-- cleared).
local function profileText(partition, playerId, field)
    local text = partition:PlayerProfileText(playerId, field)
    if text == "" then
        return nil
    end
    return text
end

-- The Bio tab: a Location heading and the player's location, then a Bio
-- heading and their bio, each "Not set" when it isn't. Each heading names
-- the field it edits. `wrap(text) -> lines` breaks each into lines that
-- fit the panel.
local function bioRows(location, bio, wrap)
    local rows = {}
    local function add(heading, field, text)
        table.insert(rows, { kind = "section", text = heading, field = field })
        if text == nil then
            table.insert(rows, { kind = "empty", text = "Not set" })
            return
        end
        local lines = wrap(text)
        local index
        for index = 1, #lines do
            table.insert(rows, { kind = "about", text = lines[index] })
        end
    end
    add("Location", "location", location)
    add("Bio", "bio", bio)
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
-- formatDate (function(timestamp) -> text), classColor (optional
-- function(classToken) -> "ffrrggbb" or nil), adStats (optional function(keys)
-- -> the player's ad count line, or nil), rolesOf (optional function(key)
-- -> the character's role preferences as text, or nil), grouped (optional
-- function(keys) -> how many times this user grouped with the player and
-- when last, or nil), joined (optional function(keys) -> when the player
-- first joined, as text, or nil; only officers get it), membership
-- (optional function(keys) -> lines about each character's join and rank
-- dates, or nil; only officers get them), promotion (optional
-- function(keys, playerId) -> the Promotion tab's rows, see
-- PromotionsViewModel.PanelRows, or nil), wrap (optional function(text) ->
-- a long line's lines as they fit the panel; by default, lines of at most
-- BIO_LINE bytes).
-- Returns nil when the player no longer exists, or:
--   { id, label, alias, main, mainName, canMerge, discord, location, bio,
--     joined, grouped, rows, bioRows, logRows, promotionRows }
-- where `main` is the main's character key, `canMerge` whether the player
-- can be merged into another (only with no alts), `discord` the player's
-- Discord username or nil, `location` and `bio` the player's location and
-- bio or nil, `bioRows` the Bio tab's rows:
--   { kind = "section", text, field } ("Location" or "Bio", with the field
--   it edits: "location" or "bio"), then { kind = "about", text } lines, or
--   { kind = "empty", text = "Not set" },
-- `joined` "Joined: …" or nil, `grouped`
-- "Grouped together 3 times", 0 included (the header shows these),
-- `promotionRows` the Promotion tab's rows (nil when there's no such tab
-- for this player), `logRows` the Log tab's rows: the ad count, when they
-- last grouped with this user, and each character's dates, wrapped, then
-- the Changes section (what changed about the player, and who changed it,
-- newest first), then the History section (characters that left the
-- player):
--   { kind = "log", text }, { kind = "section", text },
--   { kind = "history", name, role, dates, reason } or { kind = "empty", text }
-- and `rows` is a flat list for the Profile tab's scroll list:
--   { kind = "section", text }
--   { kind = "character", key, name, color, level, isMain, inGuild, status,
--     source, roles, canMakeMain, canDetach }
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
    local wrap = inputs.wrap or function(text)
        return PlayerPanelViewModel.Wrap(text, PlayerPanelViewModel.BIO_LINE)
    end
    -- An optional input's answer (up to two values), or nil when it's
    -- missing or fails.
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

    -- The Log tab: the ad count, when they last grouped with this user, and
    -- each character's dates, each wrapped to the panel.
    local logRows = {}
    local function log(text)
        if type(text) ~= "string" then
            return
        end
        local lines = wrap(text)
        local lineIndex
        for lineIndex = 1, #lines do
            table.insert(logRows, { kind = "log", text = lines[lineIndex] })
        end
    end
    log(ask(inputs.adStats, keys))
    -- How often they grouped shows even when it's never.
    local groupCount, groupLast = ask(inputs.grouped, keys)
    if type(groupCount) ~= "number" then
        groupCount = 0
    end
    local grouped = "Grouped together " .. groupCount .. (groupCount == 1 and " time" or " times")
    if groupCount > 0 and type(groupLast) == "number" then
        log("Last grouped together on " .. formatDate(groupLast))
    end
    local membership = ask(inputs.membership, keys)
    if type(membership) == "table" then
        for index = 1, #membership do
            log(membership[index])
        end
    end
    local changes = partition:GetChanges(inputs.playerId)
    -- With changes below, the activity lines' empty state would contradict
    -- them, so it only shows when there's nothing at all.
    if logRows[1] == nil and changes[1] == nil then
        table.insert(logRows, { kind = "empty", text = "Nothing logged yet" })
    end
    local joined = ask(inputs.joined, keys)
    joined = type(joined) == "string" and ("Joined: " .. joined) or nil

    local promotionRows
    if inputs.promotion ~= nil then
        local ok, promotion = pcall(inputs.promotion, keys, inputs.playerId)
        if ok and type(promotion) == "table" then
            promotionRows = promotion
        end
    end
    local location = profileText(partition, inputs.playerId, "location")
    local bio = profileText(partition, inputs.playerId, "bio")
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

    -- Then what changed about the player and who changed it, newest first.
    table.insert(logRows, { kind = "section", text = "Changes" })
    local function nameOf(key)
        local character = type(key) == "string" and partition:GetCharacter(key) or nil
        return (inputs.normalizer and inputs.normalizer:Display((character and character.name) or key))
            or tostring(key)
    end
    for index = #changes, 1, -1 do
        local entry = changes[index]
        if type(entry) == "table" and addon.PlayerAudit ~= nil then
            log((type(entry.at) == "number" and (formatDate(entry.at) .. ": ") or "") ..
                addon.PlayerAudit.ChangeText(entry, nameOf))
        end
    end
    if changes[1] == nil then
        table.insert(logRows, { kind = "empty", text = "No changes logged yet" })
    end

    -- The Log tab ends with the History section.
    table.insert(logRows, { kind = "section", text = "History" })
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
        table.insert(logRows, {
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
        table.insert(logRows, { kind = "empty", text = "No former characters" })
    end

    local mainName = mainRow.name
    return {
        id = inputs.playerId,
        label = player.alias and (player.alias .. " (" .. mainName .. ")") or mainName,
        alias = player.alias,
        main = player.main,
        mainName = mainName,
        canMerge = altCount == 0,
        discord = (partition:PlayerProfileText(inputs.playerId, "discord")),
        joined = joined,
        grouped = grouped,
        location = location,
        bio = bio,
        rows = rows,
        bioRows = bioRows(location, bio, wrap),
        logRows = logRows,
        promotionRows = promotionRows,
    }
end
