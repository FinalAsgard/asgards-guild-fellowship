local _, addon = ...

-- Reads the `>Main` and `@Alias` markers from a public guild note. Pure: the
-- caller passes a resolver that knows which characters exist.
--
--   resolver(text) -> array of character keys matching `text`, matched by
--                     full name or, for a single word on Forever, by unique
--                     first name
--
-- Only the first `>` and the first `@` count, anywhere in the note; all
-- other text is ignored. Nothing is ever guessed: a main that doesn't match
-- exactly one character is reported as unresolved or ambiguous.
local NoteParser = {}
addon.NoteParser = NoteParser

-- Characters that can't be part of a name in a `>` marker. Names may hold
-- letters (including accented ones), a space on Forever, and a realm
-- suffix after "-".
local NAME_WORD = "^([^%s,;:!%?%(%)%[%]{}\"<>@/|]+)"
-- An alias is one word of letters (including accented), digits, and a small
-- set of punctuation. Multi-word aliases can only be set in the UI.
local ALIAS_WORD = "^([%w\128-\255_'%-]+)"

-- Up to `count` name words starting at `text`, without trailing periods.
local function nameWords(text, count)
    local words = {}
    local rest = text
    while #words < count do
        rest = string.gsub(rest, "^%s+", "")
        local word = string.match(rest, NAME_WORD)
        if word == nil then
            break
        end
        rest = string.sub(rest, #word + 1)
        word = string.gsub(word, "%.+$", "")
        if word ~= "" then
            table.insert(words, word)
        end
        -- A word must be followed by whitespace to have a next word.
        if string.match(rest, "^%s") == nil then
            break
        end
    end
    return words
end

local function resolved(key, text)
    return { status = "resolved", key = key, text = text }
end

local function resolve(resolver, text)
    local matches = resolver(text) or {}
    if #matches == 1 then
        return resolved(matches[1], text)
    end
    if #matches > 1 then
        return { status = "ambiguous", text = text, candidates = matches }
    end
    return nil
end

local function parseMain(note, resolver, twoPartNames)
    local start = string.find(note, ">", 1, true)
    if start == nil then
        return nil
    end
    local words = nameWords(string.sub(note, start + 1), twoPartNames and 2 or 1)
    if #words == 0 then
        return nil
    end

    if twoPartNames and #words == 2 then
        local both = words[1] .. " " .. words[2]
        local result = resolve(resolver, both)
        if result ~= nil then
            return result
        end
    end
    -- One word: Retail's whole name, or a Forever first name.
    return resolve(resolver, words[1]) or { status = "unresolved", text = words[1] }
end

local function parseAlias(note)
    local start = string.find(note, "@", 1, true)
    if start == nil then
        return nil
    end
    local alias = string.match(string.sub(note, start + 1), ALIAS_WORD)
    if alias == nil or alias == "" then
        return nil
    end
    return alias
end

-- Returns { mainRef, alias } where mainRef is nil (no marker) or
-- { status = "resolved"|"unresolved"|"ambiguous", key?, text, candidates? }.
function NoteParser.Parse(note, resolver, rules)
    if type(note) ~= "string" or note == "" then
        return { mainRef = nil, alias = nil }
    end
    return {
        mainRef = parseMain(note, resolver, rules ~= nil and rules.twoPartNames == true),
        alias = parseAlias(note),
    }
end

-- A short fingerprint of a note, so the store can tell when a note changed
-- without keeping the note text. 8 hex digits of a 32-bit djb2 hash.
function NoteParser.Fingerprint(note)
    if type(note) ~= "string" then
        return nil
    end
    local hash = 5381
    local index
    for index = 1, #note do
        hash = (hash * 33 + string.byte(note, index)) % 4294967296
    end
    return string.format("%08x", hash)
end
