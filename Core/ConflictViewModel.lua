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
    if kind == "alias" or kind == "competing aliases" or kind == "suggested alias" then
        return player.alias and ("Alias \"" .. player.alias .. "\"") or "No alias"
    end
    if kind == "promotion" then
        return "Main of its player"
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

-- What a member's suggestion about `key` asks for.
local function suggestionText(inputs, key, kind, suggestion)
    if kind == "suggested main" then
        if suggestion.main == key then
            return "Main of its own player"
        end
        return "Alt of " .. displayName(inputs, suggestion.main)
    end
    local alias = suggestion.alias
    return (alias ~= nil and alias ~= "") and ("Alias \"" .. alias .. "\"") or "No alias"
end

-- inputs: partition, members (live roster facts by key), normalizer, and
-- pending (this member's own pending suggestions, as stored: SyncFacts
-- facts).
-- Returns rows:
--   { character, kind, name, note, suggests, current, source, canAccept,
--     from?, pending? }
-- `note` is the live public note, or nil when the character isn't in the
-- current roster. A member's suggestion has `from` (the member's key), no
-- note, and "Suggested by <member>" as its source. This member's own
-- pending suggestions come last, with `pending` set: they wait for an
-- officer and can't be accepted or rejected here.
function ConflictViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    local rows = {}
    local conflicts = inputs.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local conflict = conflicts[index]
        local key = conflict.character
        local suggests
        local fromMember = conflict.from ~= nil and type(conflict.suggestion) == "table"
        if fromMember and (conflict.kind == "suggested main" or conflict.kind == "suggested alias") then
            suggests = suggestionText(inputs, key, conflict.kind, conflict.suggestion)
        elseif conflict.kind == "main" and conflict.suggestion then
            suggests = "Alt of " .. displayName(inputs, conflict.suggestion.main)
        elseif conflict.kind == "alias" and conflict.suggestion then
            suggests = "Alias \"" .. conflict.suggestion.alias .. "\""
        elseif conflict.kind == "unresolved" and conflict.suggestion and conflict.suggestion.outOfGuild then
            suggests = "Main \"" .. conflict.suggestion.outOfGuild .. "\", not in the guild"
        elseif conflict.kind == "promotion" and conflict.suggestion then
            suggests = "Acting main now, since " ..
                displayName(inputs, conflict.suggestion.former) .. " left"
        else
            suggests = PROBLEMS[conflict.kind] or conflict.kind
        end
        local live = inputs.members[key]
        local row = {
            character = key,
            kind = conflict.kind,
            name = displayName(inputs, key),
            note = live and live.note or nil,
            suggests = suggests,
            current = currentText(inputs, key, conflict.kind),
            source = sourceText(inputs, key, conflict.kind),
            canAccept = addon.PlayerService.ACCEPTABLE[conflict.kind] == true
                and type(conflict.suggestion) == "table",
        }
        if fromMember then
            -- A member's suggestion, not a note: say who sent it.
            row.note = nil
            row.source = "Suggested by " .. displayName(inputs, conflict.from)
            row.from = conflict.from
            row.canAccept = true
        end
        table.insert(rows, row)
    end
    local pending = inputs.pending or {}
    for index = 1, #pending do
        local fact = pending[index]
        local kind = "suggested main"
        if type(fact) == "table" and fact.kind == "alias" then
            kind = "suggested alias"
        end
        -- Suggestions about characters this client no longer knows are
        -- left out.
        if type(fact) == "table" and type(fact.character) == "string"
            and inputs.partition:GetCharacter(fact.character) ~= nil
            and (kind == "suggested alias" or type(fact.main) == "string")
        then
            local live = inputs.members[fact.character]
            table.insert(rows, {
                character = fact.character,
                kind = kind,
                name = displayName(inputs, fact.character),
                note = live and live.note or nil,
                suggests = suggestionText(inputs, fact.character, kind, fact),
                current = currentText(inputs, fact.character, kind),
                source = "Your suggestion",
                canAccept = false,
                pending = true,
            })
        end
    end
    return rows
end

-- How many rows still need a decision here: all but this member's own
-- pending suggestions.
function ConflictViewModel.CountToReview(rows)
    local count = 0
    local index
    for index = 1, #rows do
        if not rows[index].pending then
            count = count + 1
        end
    end
    return count
end
