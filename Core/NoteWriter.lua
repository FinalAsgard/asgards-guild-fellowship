local _, addon = ...

-- Rewrites a public guild note so its markers say what the database says.
-- Pure: the caller passes the note, the wanted markers, and the client's
-- rules.
--
-- Every main marker (`>Name`, `Main: Name`, `Main: >Name`, any case) and
-- every alias marker (`@Alias`, `Alias: Name`, `Alias: @Name`) is removed,
-- wherever it is in the note, along with the name or alias it carries, read
-- the way NoteParser reads it. The wanted markers are then written first,
-- and the rest of the note (professions, roles, anything else) follows,
-- cut to fit the note's length limit.
local NoteWriter = {
    -- The public note's length limit, in bytes. A best guess for both
    -- clients, to be confirmed in game (#144).
    MAX_LENGTH = 31,
}
addon.NoteWriter = NoteWriter

-- Where the name words after a main marker end: up to `count` words
-- starting at `from`, each with any trailing periods. Returns the end
-- position of each word.
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

-- Where the text a marker carries ends (the last position it covers).
local function markerEnd(note, marker, rules)
    if marker.kind == "alias" then
        local alias = string.match(string.sub(note, marker.textStart), addon.NoteParser.ALIAS_WORD)
        return marker.textStart + (alias and #alias or 0) - 1
    end
    local twoPartNames = rules.twoPartNames == true
    local ends = nameEnds(note, marker.textStart, twoPartNames and 2 or 1)
    if ends[1] == nil then
        return marker.textStart - 1
    end
    -- Both words go when they name a character together, as the parser
    -- reads them; otherwise only the first.
    if ends[2] ~= nil and rules.isName ~= nil then
        local both = string.sub(note, marker.textStart, ends[2])
        both = string.gsub(both, "^%s+", "")
        both = string.gsub(both, "%.+$", "")
        if rules.isName(both) then
            return ends[2]
        end
    end
    return ends[1]
end

-- `note` without any main or alias marker, its other words kept in order,
-- and the markers it had, in order, each { kind, text }.
function NoteWriter.FreeText(note, rules)
    rules = rules or {}
    local rest = type(note) == "string" and note or ""
    local found = {}
    while true do
        local marker = firstMarker(rest)
        if marker == nil then
            break
        end
        local last = markerEnd(rest, marker, rules)
        local text = string.gsub(string.sub(rest, marker.textStart, last), "^%s+", "")
        table.insert(found, { kind = marker.kind, text = (string.gsub(text, "%.+$", "")) })
        -- A comma or semicolon right after the marker went with it.
        local separator = string.match(rest, "^%s*[,;]", last + 1)
        last = last + (separator and #separator or 0)
        rest = string.sub(rest, 1, marker.start - 1) .. " " .. string.sub(rest, last + 1)
    end
    rest = string.gsub(rest, "%s+", " ")
    rest = string.gsub(rest, "^[%s,;]+", "")
    return (string.gsub(rest, "%s+$", "")), found
end

-- Whether `found` (a note's markers) is exactly the wanted markers: one of
-- each wanted kind, carrying the wanted text, and nothing else.
local function sameMarkers(found, markers)
    local wanted = {}
    if markers.main ~= nil then
        wanted.main = string.lower(markers.main)
    end
    if markers.alias ~= nil then
        wanted.alias = markers.alias
    end
    local seen = {}
    local index
    for index = 1, #found do
        local marker = found[index]
        local text = marker.kind == "main" and string.lower(marker.text) or marker.text
        if seen[marker.kind] or wanted[marker.kind] ~= text then
            return false
        end
        seen[marker.kind] = true
    end
    return (seen.main == true) == (wanted.main ~= nil) and (seen.alias == true) == (wanted.alias ~= nil)
end

-- `text` cut to at most `length` bytes, never inside a UTF-8 character,
-- and without trailing spaces.
local function cut(text, length)
    if #text <= length then
        return text
    end
    local stop = length
    -- A continuation byte (10xxxxxx) after the cut means the character it
    -- belongs to would be split, so the cut moves back to its start.
    while stop > 0 do
        local nextByte = string.byte(text, stop + 1)
        if nextByte == nil or nextByte < 128 or nextByte >= 192 then
            break
        end
        stop = stop - 1
    end
    return (string.gsub(string.sub(text, 1, stop), "%s+$", ""))
end

-- markers: { main = "Toolbox" or nil, alias = "TheTool" or nil }, the
--   names already written the way the client's notes name characters.
-- rules: { twoPartNames, isName(text) -> whether `text` names a character
--   (so a Forever `>First Last` is removed whole), maxLength }
-- Returns the new note, or nil when `note` already says exactly that, and
-- whether free text had to be cut. Returns nil and "too long" when the
-- markers alone don't fit.
function NoteWriter.Write(note, markers, rules)
    rules = rules or {}
    local limit = rules.maxLength or NoteWriter.MAX_LENGTH
    local parts = {}
    if markers.main ~= nil then
        table.insert(parts, ">" .. markers.main)
    end
    if markers.alias ~= nil then
        table.insert(parts, "@" .. markers.alias)
    end
    local head = table.concat(parts, " ")
    if #head > limit then
        return nil, false, "too long"
    end
    local current = type(note) == "string" and note or ""
    local free, found = NoteWriter.FreeText(current, rules)
    -- Already right: the markers it should have, wherever they are, and
    -- nothing more. It's left alone.
    if #current <= limit and sameMarkers(found, markers) then
        return nil, false
    end
    local wanted = head
    local wasCut = false
    if free ~= "" then
        local room = head == "" and limit or (limit - #head - 1)
        local kept = cut(free, math.max(room, 0))
        wasCut = kept ~= free
        if kept ~= "" then
            wanted = head == "" and kept or (head .. " " .. kept)
        end
    end
    if wanted == current then
        return nil, false
    end
    return wanted, wasCut
end
