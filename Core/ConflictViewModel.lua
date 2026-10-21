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
    if kind == "suggested declared" then
        return inputs.partition:IsDeclared(key) and "Declared main" or "Not declared"
    end
    if kind == "suggested discord" then
        local discord = inputs.partition:PlayerProfileText(character.player, "discord")
        return discord and ("Discord \"" .. discord .. "\"") or "No Discord"
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
    if kind == "suggested declared" then
        return suggestion.declared and "Declared main" or "Not declared"
    end
    if kind == "suggested discord" then
        local text = suggestion.text
        return (text ~= nil and text ~= "") and ("Discord \"" .. text .. "\"") or "No Discord"
    end
    if kind == "suggested main" then
        if suggestion.main == key then
            return "Main of its own player"
        end
        return "Alt of " .. displayName(inputs, suggestion.main)
    end
    local alias = suggestion.alias
    return (alias ~= nil and alias ~= "") and ("Alias \"" .. alias .. "\"") or "No alias"
end

-- The key members' suggestions are grouped by: the submitting member's
-- player, or the member's key when this client doesn't know them.
function ConflictViewModel.GroupOf(partition, from)
    local character = partition:GetCharacter(from)
    if character ~= nil then
        return "player:" .. tostring(character.player)
    end
    return "member:" .. tostring(from)
end

-- How many things in the queue need a decision: each note conflict, and
-- each player's suggestions once (for the Conflicts button and the minimap
-- tooltip).
function ConflictViewModel.CountQueue(partition)
    local count = 0
    local groups = {}
    local conflicts = partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local entry = conflicts[index]
        if entry.from ~= nil then
            local group = ConflictViewModel.GroupOf(partition, entry.from)
            if not groups[group] then
                groups[group] = true
                count = count + 1
            end
        else
            count = count + 1
        end
    end
    return count
end

-- The name a bundle goes by: the submitting player's alias, else its main.
local function playerLabel(inputs, from)
    local character = inputs.partition:GetCharacter(from)
    local player = character and inputs.partition:GetPlayer(character.player)
    if player == nil then
        return displayName(inputs, from)
    end
    return player.alias or displayName(inputs, player.main)
end

-- Who suggested a bundle: the suggesting character, plus its player's alias
-- or main when that names someone else ("Bolt (Hammer)").
local function suggestedByText(inputs, from)
    local name = displayName(inputs, from)
    local label = playerLabel(inputs, from)
    if label ~= name then
        return name .. " (" .. label .. ")"
    end
    return name
end

-- The one wrapped column of a note conflict or a pending suggestion: the live
-- note, what it suggests, and the current state, one per line.
local function detailsText(row)
    return "Note: " .. (row.note or "(not in the roster)") ..
        "\nSuggests: " .. tostring(row.suggests) ..
        "\nCurrently: " .. tostring(row.current)
end

-- inputs: partition, members (live roster facts by key), normalizer, and
-- pending (this member's own pending suggestions, as stored: SyncFacts
-- facts).
-- Returns rows in three sections, each with its own fields, members'
-- suggestions first, then note conflicts, then this member's own pending
-- suggestions:
--   Changes to Player: { section = "changes", kind = "bundle", group, name,
--     count, changes, suggestedBy, canAccept, items }
--   Note conflicts: { section = "notes", character, kind, name, details,
--     note, suggests, current, source, canAccept }
--   Your suggestions: { section = "yours", character, kind, name, details,
--     note, suggests, current, source, canAccept = false, pending = true }
-- Members' suggestions are grouped into one bundle per submitting player
-- (see GroupOf): `name` is that player, `count` how many changes it asks
-- for (`changes` says so in words), `suggestedBy` the member who sent them,
-- and `items` the suggestion rows themselves, each with `from` (the
-- member's key), its `suggestion`, no note, and "Suggested by <member>" as
-- its source. `details` is the one wrapped column of the other sections:
-- the live note, what it suggests, and the current state. `note` is the
-- live public note, or nil when the character isn't in the current roster.
-- This member's own pending suggestions wait for an officer and can't be
-- accepted or rejected here.
function ConflictViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    local rows = {}
    local bundles, bundleOf = {}, {}
    local conflicts = inputs.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local conflict = conflicts[index]
        local key = conflict.character
        local suggests
        local fromMember = conflict.from ~= nil and type(conflict.suggestion) == "table"
        if fromMember and addon.SuggestionService.KINDS[conflict.kind] then
            suggests = suggestionText(inputs, key, conflict.kind, conflict.suggestion)
        elseif conflict.kind == "main" and conflict.suggestion then
            suggests = "Alt of " .. displayName(inputs, conflict.suggestion.main)
        elseif conflict.kind == "alias" and conflict.suggestion then
            suggests = "Alias \"" .. conflict.suggestion.alias .. "\""
        elseif conflict.kind == "unresolved" and conflict.suggestion and conflict.suggestion.outOfGuild then
            suggests = "Main \"" .. conflict.suggestion.outOfGuild .. "\", not in the guild"
        elseif conflict.kind == "ambiguous" and type(conflict.alias) == "string" then
            local names = {}
            local mains = type(conflict.mains) == "table" and conflict.mains or {}
            local mainIndex
            for mainIndex = 1, #mains do
                table.insert(names, displayName(inputs, mains[mainIndex]))
            end
            suggests = "Alias \"" .. conflict.alias .. "\" is held by several players"
            if #names > 0 then
                suggests = suggests .. ": " .. table.concat(names, ", ")
            end
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
            -- A member's suggestion, not a note: say who sent it, and keep it
            -- with the rest of that player's suggestions.
            row.note = nil
            row.source = "Suggested by " .. displayName(inputs, conflict.from)
            row.from = conflict.from
            row.suggestion = conflict.suggestion
            row.canAccept = true
            local group = ConflictViewModel.GroupOf(inputs.partition, conflict.from)
            local bundle = bundleOf[group]
            if bundle == nil then
                bundle = {
                    section = "changes",
                    kind = "bundle",
                    group = group,
                    name = playerLabel(inputs, conflict.from),
                    suggestedBy = suggestedByText(inputs, conflict.from),
                    canAccept = true,
                    items = {},
                }
                bundleOf[group] = bundle
                table.insert(bundles, bundle)
            end
            table.insert(bundle.items, row)
        else
            row.section = "notes"
            row.details = detailsText(row)
            table.insert(rows, row)
        end
    end
    for index = #bundles, 1, -1 do
        local bundle = bundles[index]
        bundle.count = #bundle.items
        bundle.changes = bundle.count == 1 and "1 change" or (bundle.count .. " changes")
        table.insert(rows, 1, bundle)
    end
    local pending = inputs.pending or {}
    for index = 1, #pending do
        local fact = pending[index]
        local kind = "suggested main"
        if type(fact) == "table" and fact.kind == "alias" then
            kind = "suggested alias"
        elseif type(fact) == "table" and fact.kind == "declared" then
            kind = "suggested declared"
        elseif type(fact) == "table" and fact.kind == "discord" then
            kind = "suggested discord"
        end
        -- Suggestions about characters this client no longer knows are
        -- left out.
        if type(fact) == "table" and type(fact.character) == "string"
            and inputs.partition:GetCharacter(fact.character) ~= nil
            and (kind ~= "suggested main" or type(fact.main) == "string")
        then
            local live = inputs.members[fact.character]
            local row = {
                section = "yours",
                character = fact.character,
                kind = kind,
                name = displayName(inputs, fact.character),
                note = live and live.note or nil,
                suggests = suggestionText(inputs, fact.character, kind, fact),
                current = currentText(inputs, fact.character, kind),
                source = "Your suggestion",
                canAccept = false,
                pending = true,
            }
            row.details = detailsText(row)
            table.insert(rows, row)
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
