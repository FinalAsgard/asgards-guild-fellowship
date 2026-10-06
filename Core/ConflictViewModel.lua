local _, addon = ...

-- Builds the rows of the conflict review panel. Pure: the caller passes the
-- partition, live roster facts (the note text is read live and never
-- stored), and a NameNormalizer for display names.
local ConflictViewModel = {}
addon.ConflictViewModel = ConflictViewModel

local PROBLEMS = {
    unresolved = "Main not found in the guild",
    ambiguous = "Main name matches more than one character",
    cycle = "Mains point at each other",
    ["self reference"] = "Note names the character itself as main",
    ["chain too long"] = "Chain of mains is too long",
    ["competing aliases"] = "Different aliases for one player",
}

local SOURCES = {
    note = "From a note",
    manual = "Set by hand",
    roster = "From the roster",
}

local function displayName(inputs, key)
    local live = inputs.members[key]
    local character = inputs.partition:GetCharacter(key)
    local raw = (live and live.name) or (character and character.name)
    return inputs.normalizer:Display(raw) or key
end

-- What the database says now about the character's player.
local function currentText(inputs, key, kind)
    local character = inputs.partition:GetCharacter(key)
    local player = character and inputs.partition:GetPlayer(character.player)
    if player == nil then
        return "Not organized yet"
    end
    if kind == "alias" or kind == "competing aliases" then
        return player.alias and ("Alias \"" .. player.alias .. "\"") or "No alias"
    end
    if player.main == key then
        local count = #inputs.partition:CharactersOf(character.player)
        if count > 1 then
            return "Main, with " .. (count - 1) .. (count == 2 and " alt" or " alts")
        end
        return "Own player"
    end
    return "Alt of " .. displayName(inputs, player.main)
end

local function sourceText(inputs, key, kind)
    local character = inputs.partition:GetCharacter(key)
    if character == nil then
        return ""
    end
    local source = character.source
    if kind == "alias" or kind == "competing aliases" then
        local player = inputs.partition:GetPlayer(character.player)
        source = player and player.aliasSource
    end
    return SOURCES[source] or ""
end

-- inputs: partition, members (live roster facts by key), normalizer.
-- Returns rows:
--   { character, kind, name, note, suggests, current, source, canAccept }
-- `note` is the live public note, or nil when the character isn't in the
-- current roster.
function ConflictViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    local rows = {}
    local conflicts = inputs.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local conflict = conflicts[index]
        local key = conflict.character
        local suggests
        if conflict.kind == "main" and conflict.suggestion then
            suggests = "Alt of " .. displayName(inputs, conflict.suggestion.main)
        elseif conflict.kind == "alias" and conflict.suggestion then
            suggests = "Alias \"" .. conflict.suggestion.alias .. "\""
        else
            suggests = PROBLEMS[conflict.kind] or conflict.kind
        end
        local live = inputs.members[key]
        table.insert(rows, {
            character = key,
            kind = conflict.kind,
            name = displayName(inputs, key),
            note = live and live.note or nil,
            suggests = suggests,
            current = currentText(inputs, key, conflict.kind),
            source = sourceText(inputs, key, conflict.kind),
            canAccept = addon.PlayerService.ACCEPTABLE[conflict.kind] == true
                and type(conflict.suggestion) == "table",
        })
    end
    return rows
end
