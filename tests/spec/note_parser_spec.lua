local test = require("tests.test_helper")

local addon = test.newAddon("Core/NoteParser.lua")
local NoteParser = addon.NoteParser

local FOREVER = { twoPartNames = true }
local RETAIL = { twoPartNames = false }

-- A resolver over a small Forever guild: full names, plus first names that
-- are unique ("tool") or shared ("ann" is Ann Lee and Ann Ray).
local foreverKeys = {
    ["tool box"] = { "tool box-camelot" },
    ["hammer smith"] = { "hammer smith-camelot" },
    ["ann lee"] = { "ann lee-camelot" },
    ["ann ray"] = { "ann ray-camelot" },
    ["tool"] = { "tool box-camelot" },
    ["hammer"] = { "hammer smith-camelot" },
    ["ann"] = { "ann lee-camelot", "ann ray-camelot" },
}
local function foreverResolver(text)
    return foreverKeys[string.lower(text)] or {}
end

local retailKeys = {
    ["toolbox"] = { "toolbox-area52" },
    ["toolbox-area52"] = { "toolbox-area52" },
    ["hammer"] = { "hammer-area52" },
}
local function retailResolver(text)
    return retailKeys[string.lower(text)] or {}
end

local MAIN_CASES = {
    { rules = FOREVER, note = ">Tool Box", status = "resolved", key = "tool box-camelot",
        why = "Forever two-word name" },
    { rules = FOREVER, note = "Tank >tool box. Raids weekly", status = "resolved", key = "tool box-camelot",
        why = "Forever marker anywhere, with trailing punctuation" },
    { rules = FOREVER, note = ">Tool", status = "resolved", key = "tool box-camelot",
        why = "Forever unique first name" },
    { rules = FOREVER, note = ">Tool Heals", status = "resolved", key = "tool box-camelot",
        why = "Forever falls back to one word when two words match nobody" },
    { rules = FOREVER, note = ">Ann", status = "ambiguous", text = "Ann",
        why = "Forever shared first name is ambiguous" },
    { rules = FOREVER, note = ">Nobody Here", status = "unresolved", text = "Nobody",
        why = "Forever unknown name is unresolved" },
    { rules = RETAIL, note = ">Toolbox", status = "resolved", key = "toolbox-area52",
        why = "Retail single word" },
    { rules = RETAIL, note = "alt >Toolbox-Area52 (healer)", status = "resolved", key = "toolbox-area52",
        why = "Retail name with realm suffix" },
    { rules = RETAIL, note = ">Toolbox Hammer", status = "resolved", key = "toolbox-area52",
        why = "Retail takes only the next word" },
    { rules = RETAIL, note = ">Tool", status = "unresolved", text = "Tool",
        why = "Retail never matches partial names" },
    { rules = RETAIL, note = "first >Hammer then >Toolbox", status = "resolved", key = "hammer-area52",
        why = "only the first > marker counts" },
    { rules = FOREVER, note = "Main: Tool Box", status = "resolved", key = "tool box-camelot",
        why = "Forever Main: label with a two-word name" },
    { rules = FOREVER, note = "Healer, main:tool", status = "resolved", key = "tool box-camelot",
        why = "Forever lowercase main: label anywhere, without a space" },
    { rules = RETAIL, note = "Main: Toolbox", status = "resolved", key = "toolbox-area52",
        why = "Retail Main: label" },
    { rules = RETAIL, note = "MAIN : toolbox", status = "resolved", key = "toolbox-area52",
        why = "Main: label ignores case and a space before the colon" },
    { rules = RETAIL, note = "Main: >Toolbox", status = "resolved", key = "toolbox-area52",
        why = "Main: label followed by > is one marker" },
    { rules = RETAIL, note = "Main: Hammer, ex >Toolbox", status = "resolved", key = "hammer-area52",
        why = "a Main: label before a > marker counts first" },
    { rules = RETAIL, note = ">Hammer, Main: Toolbox", status = "resolved", key = "hammer-area52",
        why = "a > marker before a Main: label counts first" },
    { rules = RETAIL, note = "Domain: Toolbox, main: Hammer", status = "resolved", key = "hammer-area52",
        why = "main: inside another word is not a label" },
    { rules = RETAIL, note = "raid2main: Toolbox, alt_main: Toolbox, main: Hammer", status = "resolved",
        key = "hammer-area52", why = "main: after a digit or underscore is not a label" },
    { rules = RETAIL, note = "Main: Nobody", status = "unresolved", text = "Nobody",
        why = "Main: label with an unknown name is unresolved" },
}

local index
for index = 1, #MAIN_CASES do
    local case = MAIN_CASES[index]
    test.test("note parser main: " .. case.why, function()
        local resolver = case.rules == FOREVER and foreverResolver or retailResolver
        local result = NoteParser.Parse(case.note, resolver, case.rules)

        test.assertEqual(case.status, result.mainRef.status)
        if case.key ~= nil then
            test.assertEqual(case.key, result.mainRef.key)
        end
        if case.text ~= nil then
            test.assertEqual(case.text, result.mainRef.text)
        end
    end)
end

test.test("note parser reports both candidates for an ambiguous first name", function()
    local result = NoteParser.Parse(">ann", foreverResolver, FOREVER)

    test.assertEqual(2, #result.mainRef.candidates)
end)

test.test("note parser reads Main: and Alias: labels in one note", function()
    local result = NoteParser.Parse("Main: Tool Box, Alias: TheTool", foreverResolver, FOREVER)

    test.assertEqual("tool box-camelot", result.mainRef.key)
    test.assertEqual("TheTool", result.alias)
end)

test.test("note parser finds both markers in one note, in either order", function()
    local first = NoteParser.Parse("@TheTool >Toolbox", retailResolver, RETAIL)
    local second = NoteParser.Parse("Officer >Toolbox, goes by @TheTool", retailResolver, RETAIL)

    test.assertEqual("toolbox-area52", first.mainRef.key)
    test.assertEqual("TheTool", first.alias)
    test.assertEqual("toolbox-area52", second.mainRef.key)
    test.assertEqual("TheTool", second.alias)
end)

local ALIAS_CASES = {
    { note = "@TheTool", alias = "TheTool", why = "a plain alias" },
    { note = "@TheTool raid lead", alias = "TheTool", why = "only one word" },
    { note = "@Zoë_99", alias = "Zoë_99", why = "accented letters, digits, and underscore" },
    { note = "@O'Malley-Jr", alias = "O'Malley-Jr", why = "apostrophe and hyphen" },
    { note = "@Tool!", alias = "Tool", why = "stops at disallowed punctuation" },
    { note = "@ TheTool", alias = nil, why = "no alias when nothing follows the @" },
    { note = "@Tool @Other", alias = "Tool", why = "only the first @ counts" },
    { note = "Alias: TheTool", alias = "TheTool", why = "an Alias: label" },
    { note = "Raid lead, alias:TheTool", alias = "TheTool", why = "a lowercase alias: label anywhere, without a space" },
    { note = "ALIAS : TheTool", alias = "TheTool", why = "Alias: label ignores case and a space before the colon" },
    { note = "Alias: TheTool raid lead", alias = "TheTool", why = "Alias: label takes only one word" },
    { note = "Alias: @TheTool", alias = "TheTool", why = "Alias: label followed by @ is one marker" },
    { note = "Alias: Tool, or @Other", alias = "Tool", why = "an Alias: label before an @ counts first" },
    { note = "@Tool, Alias: Other", alias = "Tool", why = "an @ before an Alias: label counts first" },
    { note = "Healias: Tool", alias = nil, why = "alias: inside another word is not a label" },
    { note = "raid2alias: Tool, my_alias: Tool", alias = nil,
        why = "alias: after a digit or underscore is not a label" },
    { note = "Alias:", alias = nil, why = "no alias when nothing follows the label" },
}

for index = 1, #ALIAS_CASES do
    local case = ALIAS_CASES[index]
    test.test("note parser alias: " .. case.why, function()
        test.assertEqual(case.alias, NoteParser.Parse(case.note, retailResolver, RETAIL).alias)
    end)
end

test.test("note parser ignores a Main label with no name after it", function()
    test.assertEqual(nil, NoteParser.Parse("Main:", retailResolver, RETAIL).mainRef)
    test.assertEqual(nil, NoteParser.Parse("Domain: Toolbox", retailResolver, RETAIL).mainRef)
    test.assertEqual(nil, NoteParser.Parse("Main alt of the raid", retailResolver, RETAIL).mainRef)
end)

test.test("note parser ignores notes without markers", function()
    local empty = NoteParser.Parse("", retailResolver, RETAIL)
    local plain = NoteParser.Parse("Raid lead, tanks on Tuesdays", retailResolver, RETAIL)
    local bare = NoteParser.Parse("> ", retailResolver, RETAIL)

    test.assertEqual(nil, empty.mainRef)
    test.assertEqual(nil, plain.mainRef)
    test.assertEqual(nil, plain.alias)
    test.assertEqual(nil, bare.mainRef)
    test.assertEqual(nil, NoteParser.Parse(nil, retailResolver, RETAIL).mainRef)
end)

test.test("note fingerprints are short, stable, and never the note text", function()
    local fingerprint = NoteParser.Fingerprint("@TheTool raid lead")

    test.assertEqual(8, #fingerprint)
    test.assertEqual(fingerprint, NoteParser.Fingerprint("@TheTool raid lead"))
    test.assertTrue(fingerprint ~= NoteParser.Fingerprint("@TheTool raid leader"))
    test.assertEqual(nil, string.find(fingerprint, "Tool", 1, true))
    test.assertEqual(nil, NoteParser.Fingerprint(nil))
end)

-- Aliases held by players: "Tool" by player 7, "Ann" by player 9 (who isn't
-- an Ann character), "Shared" by players 3 and 4, and "Spark" by the
-- character a note is about to name.
local ALIASES = {
    ["tool"] = { { player = 7 } },
    ["ann"] = { { player = 9 } },
    ["hammer"] = { { player = 8 } },
    ["shared"] = { { player = 3 }, { player = 4 } },
    ["spark"] = { { key = "spark-area52" } },
}
local aliasCalls
local function aliasResolver(word)
    table.insert(aliasCalls, word)
    return ALIASES[string.lower(word)] or {}
end

local ALIAS_TARGET_CASES = {
    { rules = RETAIL, note = ">Tool", player = 7, why = "Retail alias names its player" },
    { rules = RETAIL, note = ">tOOL", player = 7, why = "alias match ignores case" },
    { rules = RETAIL, note = ">Hammer", player = 8, why = "an alias wins over a character name" },
    { rules = RETAIL, note = "Main: Tool", player = 7, why = "a Main: label names an alias too" },
    { rules = RETAIL, note = ">Spark", key = "spark-area52", why = "an alias a note is about to set names its character" },
    { rules = FOREVER, note = ">Tool", player = 7, why = "Forever alias wins over a unique first name" },
    { rules = FOREVER, note = ">Tool Box", player = 7, why = "Forever tries the alias on the first word before the two-word name" },
    { rules = FOREVER, note = ">Ann", player = 9, why = "Forever alias wins over a shared first name" },
    { rules = FOREVER, note = ">Hammer Smith", player = 8, why = "Forever alias wins over a full two-word name" },
}

for index = 1, #ALIAS_TARGET_CASES do
    local case = ALIAS_TARGET_CASES[index]
    test.test("note parser alias target: " .. case.why, function()
        aliasCalls = {}
        local resolver = case.rules == FOREVER and foreverResolver or retailResolver
        local ref = NoteParser.Parse(case.note, resolver, case.rules, aliasResolver).mainRef

        test.assertEqual("resolved", ref.status)
        test.assertEqual(case.player, ref.player)
        test.assertEqual(case.key, ref.key)
        test.assertTrue(ref.byAlias)
    end)
end

test.test("note parser falls back to character names when no alias matches", function()
    aliasCalls = {}
    local retail = NoteParser.Parse(">Toolbox", retailResolver, RETAIL, aliasResolver).mainRef
    local forever = NoteParser.Parse(">Tool Box", foreverResolver, FOREVER, function()
        return {}
    end).mainRef
    local unknown = NoteParser.Parse(">Nobody", retailResolver, RETAIL, aliasResolver).mainRef

    test.assertEqual("toolbox-area52", retail.key)
    test.assertEqual(nil, retail.player)
    test.assertEqual(nil, retail.byAlias)
    test.assertEqual("tool box-camelot", forever.key)
    test.assertEqual("unresolved", unknown.status)
end)

test.test("note parser reports an alias held by several players as ambiguous", function()
    aliasCalls = {}
    local ref = NoteParser.Parse(">Shared", retailResolver, RETAIL, aliasResolver).mainRef

    test.assertEqual("ambiguous", ref.status)
    test.assertEqual(2, #ref.candidates)
    test.assertTrue(ref.byAlias)
end)

test.test("note parser only asks about one-word aliases", function()
    aliasCalls = {}
    NoteParser.Parse(">Tool#1", retailResolver, RETAIL, aliasResolver)
    NoteParser.Parse(">The Tool", foreverResolver, FOREVER, aliasResolver)

    -- "Tool#1" isn't an alias word; on Forever only the first word is tried.
    test.assertEqual(1, #aliasCalls)
    test.assertEqual("The", aliasCalls[1])
end)

test.test("note parser reads just the alias marker without any resolver", function()
    test.assertEqual("TheTool", NoteParser.Alias(">Toolbox @TheTool"))
    test.assertEqual(nil, NoteParser.Alias(">Toolbox"))
    test.assertEqual(nil, NoteParser.Alias(nil))
end)
