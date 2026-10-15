local _, addon = ...

-- Works out which in-guild characters' public notes are out of date with
-- the add-on's record, what each should say, and why. Pure: the caller
-- passes the partition, the roster's members with their note text, a
-- NameNormalizer, and the client's name rules. The add-on never writes
-- notes; officers retype the suggestion in the game's note editor.
--
-- What a note should carry, read back the way NoteParser reads it
-- (aliases first, then character names):
--   * an alt: a main marker naming its own player. `>Alias` and `>Main`
--     are both correct. A suggestion uses `>Alias` when the player has a
--     one-word alias no other player in the guild holds, and otherwise the
--     shortest form of the main's name that reads back as that main.
--   * a player's main: `@Alias` when the player has a one-word alias, and
--     none otherwise. A declared main also carries a main marker naming
--     itself.
--   * a character alone in its player and not declared: no main marker.
-- Label forms (`Main:`, `Alias:`) that read correctly are correct: style
-- alone is never a problem.
local NoteAudit = {
    -- The public note's length limit, in bytes, confirmed on both clients.
    MAX_LENGTH = 31,
    PROBLEMS = {
        MISSING_MAIN = "missing main",
        WRONG_PLAYER = "wrong player",
        STALE_MAIN = "stale main",
        MISSING_ALIAS = "missing alias",
        WRONG_ALIAS = "wrong alias",
        UNREADABLE_MAIN = "unreadable main",
    },
}
addon.NoteAudit = NoteAudit

local PROBLEMS = NoteAudit.PROBLEMS

-- An alias a note can carry: one word, as NoteParser reads it.
local function noteAlias(alias)
    if type(alias) ~= "string" then
        return nil
    end
    local word = string.match(alias, addon.NoteParser.ALIAS_WORD)
    return word == alias and alias or nil
end

-- Where the name words after a main marker end: up to `count` words
-- starting at `from`. Returns the end position of each word.
local function nameEnds(note, from, count)
    local ends = {}
    local position = from
    while #ends < count do
        local spaces = string.match(note, "^%s*", position)
        local start = position + #spaces
        local word = string.match(string.sub(note, start), addon.NoteParser.NAME_WORD)
        if word == nil then
            break
        end
        table.insert(ends, start + #word - 1)
        position = start + #word
        if string.match(note, "^%s", position) == nil then
            break
        end
    end
    return ends
end

-- The first marker in `note`: its kind ("main" or "alias"), where it
-- starts, and where the text it carries starts. Nil when there's none.
local function firstMarker(note)
    local found
    local function consider(kind, start, textStart)
        if start ~= nil and (found == nil or start < found.start) then
            found = { kind = kind, start = start, textStart = textStart }
        end
    end
    local symbolAt = string.find(note, ">", 1, true)
    consider("main", symbolAt, symbolAt and symbolAt + 1)
    local labelStart, labelEnd = addon.NoteParser.FindLabel(note, "main")
    if labelStart ~= nil then
        local skip = string.match(string.sub(note, labelEnd + 1), "^%s*>?")
        consider("main", labelStart, labelEnd + 1 + #skip)
    end
    symbolAt = string.find(note, "@", 1, true)
    consider("alias", symbolAt, symbolAt and symbolAt + 1)
    labelStart, labelEnd = addon.NoteParser.FindLabel(note, "alias")
    if labelStart ~= nil then
        local skip = string.match(string.sub(note, labelEnd + 1), "^%s*@?")
        consider("alias", labelStart, labelEnd + 1 + #skip)
    end
    return found
end

-- Where the text a marker carries ends (the last position it covers). On
-- Forever both name words go when they name a character together.
local function markerEnd(note, marker, rules, isName)
    if marker.kind == "alias" then
        local alias = string.match(string.sub(note, marker.textStart), addon.NoteParser.ALIAS_WORD)
        return marker.textStart + (alias and #alias or 0) - 1
    end
    local ends = nameEnds(note, marker.textStart, rules.twoPartNames and 2 or 1)
    if ends[1] == nil then
        return marker.textStart - 1
    end
    if ends[2] ~= nil then
        local both = string.sub(note, marker.textStart, ends[2])
        both = string.gsub(both, "^%s+", "")
        both = string.gsub(both, "%.+$", "")
        if isName(both) then
            return ends[2]
        end
    end
    return ends[1]
end

-- `note` without any main or alias marker (symbol or label form), its
-- other words kept in order.
function NoteAudit.FreeText(note, rules, isName)
    rules = rules or {}
    isName = isName or function()
        return false
    end
    local rest = type(note) == "string" and note or ""
    while true do
        local marker = firstMarker(rest)
        if marker == nil then
            break
        end
        local last = markerEnd(rest, marker, rules, isName)
        -- A comma or semicolon right after the marker went with it.
        local separator = string.match(rest, "^%s*[,;]", last + 1)
        last = last + (separator and #separator or 0)
        rest = string.sub(rest, 1, marker.start - 1) .. " " .. string.sub(rest, last + 1)
    end
    rest = string.gsub(rest, "%s+", " ")
    rest = string.gsub(rest, "^[%s,;]+", "")
    return (string.gsub(rest, "[%s,;]+$", ""))
end

-- The ways a note may name `key`, shortest first: on Forever a first name
-- then the full name, on Retail the name then the name with its realm.
local function nameForms(partition, normalizer, key)
    local character = partition:GetCharacter(key)
    local raw = (character and character.name) or key
    local display = normalizer:Display(raw) or raw
    local forms = {}
    local first = string.match(display, "^(%S+)%s")
    if first ~= nil then
        table.insert(forms, first)
    end
    table.insert(forms, display)
    local name, realm = normalizer:Split(raw)
    if name ~= nil and realm ~= "" and not string.find(display, "-", 1, true) then
        table.insert(forms, name .. "-" .. realm)
    end
    return forms
end

-- inputs:
--   partition   the guild's FellowshipStore partition
--   members     key -> roster facts with `name` and `note`
--   normalizer  a NameNormalizer
--   rules       the client's name rules ({ twoPartNames })
--   maxLength   optional; the public note limit (MAX_LENGTH)
-- Returns rows, sorted by key, for in-guild characters whose note is out of
-- date: { key, name, current, suggested, problems, tooLong }. `problems`
-- lists PROBLEMS values; `tooLong` means the note's other text didn't fit,
-- so `suggested` is the markers alone.
function NoteAudit.Build(inputs)
    local partition = inputs.partition
    local members = inputs.members or {}
    local normalizer = inputs.normalizer
    local rules = inputs.rules or {}
    local limit = inputs.maxLength or NoteAudit.MAX_LENGTH
    local twoPartNames = rules.twoPartNames == true
    local resolver = addon.ReconcileEngine.NewResolver(members, normalizer, twoPartNames, partition)
    local function aliasResolver(word)
        local targets = {}
        local ids = partition:PlayersWithAlias(word)
        local index
        for index = 1, #ids do
            table.insert(targets, { player = ids[index] })
        end
        return targets
    end
    local function parse(note)
        return addon.NoteParser.Parse(note, resolver, rules, aliasResolver)
    end
    local function isName(text)
        return #(resolver(text) or {}) > 0
    end
    local function playerOfRef(ref)
        if ref.player ~= nil then
            return ref.player
        end
        local character = ref.key and partition:GetCharacter(ref.key)
        return character and character.player
    end
    -- The shortest marker text that reads back as `key` itself, or as its
    -- player when `asPlayer`.
    local function shortestName(key, playerId, asPlayer)
        local forms = nameForms(partition, normalizer, key)
        local index
        for index = 1, #forms do
            local ref = parse(">" .. forms[index]).mainRef
            if ref ~= nil and ref.status == "resolved" then
                if asPlayer and playerOfRef(ref) == playerId then
                    return forms[index]
                end
                if not asPlayer and not ref.byAlias and ref.key == key then
                    return forms[index]
                end
            end
        end
        return forms[#forms]
    end

    local keys = {}
    local key
    for key in pairs(members) do
        if partition:IsInGuild(key) then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local rows = {}
    local index
    for index = 1, #keys do
        key = keys[index]
        local member = members[key]
        local character = partition:GetCharacter(key)
        local player = partition:GetPlayer(character.player)
        if player ~= nil then
            local note = type(member.note) == "string" and member.note or ""
            local parsed = parse(note)
            local ref = parsed.mainRef
            local problems = {}
            local markers = {}
            local wantedAlias
            if player.main ~= key then
                -- An alt: a main marker naming its own player.
                if ref == nil then
                    table.insert(problems, PROBLEMS.MISSING_MAIN)
                elseif ref.status ~= "resolved" then
                    table.insert(problems, PROBLEMS.UNREADABLE_MAIN)
                elseif playerOfRef(ref) ~= character.player then
                    table.insert(problems, PROBLEMS.WRONG_PLAYER)
                end
                local alias = noteAlias(player.alias)
                if alias ~= nil and #partition:PlayersWithAlias(alias) == 1 then
                    markers.main = alias
                else
                    markers.main = shortestName(player.main, character.player, true)
                end
                -- An alias on an alt's note names the whole player too.
                if parsed.alias ~= nil
                    and (player.alias == nil or string.lower(parsed.alias) ~= string.lower(player.alias))
                then
                    table.insert(problems, PROBLEMS.WRONG_ALIAS)
                end
            else
                local declared = partition:IsDeclared(key)
                if declared then
                    if ref == nil then
                        table.insert(problems, PROBLEMS.MISSING_MAIN)
                    elseif ref.status ~= "resolved" then
                        table.insert(problems, PROBLEMS.UNREADABLE_MAIN)
                    elseif ref.byAlias or ref.key ~= key then
                        table.insert(problems, PROBLEMS.WRONG_PLAYER)
                    end
                    markers.main = shortestName(key, character.player, false)
                elseif ref ~= nil then
                    table.insert(problems, PROBLEMS.STALE_MAIN)
                end
                wantedAlias = noteAlias(player.alias)
                if wantedAlias ~= nil and parsed.alias == nil then
                    table.insert(problems, PROBLEMS.MISSING_ALIAS)
                elseif parsed.alias ~= nil
                    and (wantedAlias == nil or string.lower(parsed.alias) ~= string.lower(wantedAlias))
                then
                    table.insert(problems, PROBLEMS.WRONG_ALIAS)
                end
                markers.alias = wantedAlias
            end

            if #problems > 0 then
                local parts = {}
                if markers.main ~= nil then
                    table.insert(parts, ">" .. markers.main)
                end
                if markers.alias ~= nil then
                    table.insert(parts, "@" .. markers.alias)
                end
                local head = table.concat(parts, " ")
                local free = NoteAudit.FreeText(note, rules, isName)
                local suggested = head
                if free ~= "" then
                    suggested = head == "" and free or (head .. " " .. free)
                end
                local tooLong = #suggested > limit
                if tooLong then
                    suggested = head
                end
                table.insert(rows, {
                    key = key,
                    name = normalizer:Display(member.name or character.name) or key,
                    current = note,
                    suggested = suggested,
                    problems = problems,
                    tooLong = tooLong,
                })
            end
        end
    end
    return rows
end
