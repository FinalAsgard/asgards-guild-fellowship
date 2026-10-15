local test = require("tests.test_helper")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/NoteAudit.lua"
    )
end

local RETAIL = { twoPartNames = false, homeRealm = "Area52" }
local FOREVER = { twoPartNames = true, homeRealm = "Camelot" }

-- A guild partition recorded from `entries` ({ name, note }), with no
-- relationships yet; `organize(partition)` arranges players by hand.
-- Returns an audit function of the roster's notes.
local function setup(rules, entries, organize)
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = rules.homeRealm })
    local normalizer = addon.NameNormalizer.Create(rules)
    local members = {}
    local index
    for index = 1, #entries do
        local key = normalizer:Key(entries[index][1])
        members[key] = { name = entries[index][1], note = entries[index][2] }
        partition:RecordCharacter(key, { name = entries[index][1], level = 60 })
    end
    if organize ~= nil then
        organize(partition)
    end
    local state = { addon = addon, partition = partition, members = members }
    function state.audit()
        local rows = addon.NoteAudit.Build({
            partition = partition,
            members = members,
            normalizer = normalizer,
            rules = rules,
        })
        local byKey = {}
        for index = 1, #rows do
            byKey[rows[index].key] = rows[index]
        end
        return byKey, rows
    end
    function state.setNote(name, note)
        members[normalizer:Key(name)].note = note
    end
    return state
end

local function playerId(partition, key)
    return partition:GetCharacter(key).player
end

local function hasProblem(row, problem)
    local index
    for index = 1, #row.problems do
        if row.problems[index] == problem then
            return true
        end
    end
    return false
end

-- Toolbox is the main of Hammer and Wrench; Visitor is on its own.
local function retailGuild(notes, alias)
    return setup(RETAIL, {
        { "Toolbox-Area52", notes.toolbox or "" },
        { "Hammer-Area52", notes.hammer or "" },
        { "Wrench-Area52", notes.wrench or "" },
        { "Visitor-Area52", notes.visitor or "" },
    }, function(partition)
        partition:JoinPlayerOf("hammer-area52", "toolbox-area52", "manual")
        partition:JoinPlayerOf("wrench-area52", "toolbox-area52", "manual")
        if alias ~= nil then
            partition:SetAlias(playerId(partition, "toolbox-area52"), alias, "manual")
        end
    end)
end

test.test("notes that already read correctly are not listed", function()
    local state = retailGuild({
        toolbox = "@Tinker raid lead",
        hammer = ">Tinker",
        wrench = "Main: Toolbox, healer",
        visitor = "Social",
    }, "Tinker")

    local _, rows = state.audit()

    test.assertEqual(0, #rows)
end)

test.test("an alt with no main marker is missing its main, and the suggestion uses the unique alias", function()
    local state = retailGuild({ toolbox = "@Tinker", hammer = "Healer, crafts maces", wrench = ">Toolbox" }, "Tinker")

    local row = state.audit()["hammer-area52"]

    test.assertEqual("Hammer", row.name)
    test.assertEqual("Healer, crafts maces", row.current)
    test.assertEqual(">Tinker Healer, crafts maces", row.suggested)
    test.assertTrue(hasProblem(row, "missing main"))
    test.assertFalse(row.tooLong)
end)

test.test("an alt naming another player is the wrong player; without an alias the main's name is suggested", function()
    local state = retailGuild({ hammer = ">Visitor tank" })

    local row = state.audit()["hammer-area52"]

    test.assertTrue(hasProblem(row, "wrong player"))
    test.assertEqual(">Toolbox tank", row.suggested)
end)

test.test("an alias several players hold isn't suggested, and a note naming it is unreadable", function()
    local state = retailGuild({ hammer = ">Tinker" }, "Tinker")
    state.partition:SetAlias(playerId(state.partition, "visitor-area52"), "tinker", "manual")

    local byKey = state.audit()

    test.assertTrue(hasProblem(byKey["hammer-area52"], "unreadable main"))
    test.assertEqual(">Toolbox", byKey["hammer-area52"].suggested)
end)

test.test("a main is missing its alias, or carries the wrong one, and keeps other text", function()
    local state = retailGuild({ toolbox = "Raid lead", hammer = ">Toolbox", wrench = ">Toolbox" }, "Tinker")

    local row = state.audit()["toolbox-area52"]
    test.assertTrue(hasProblem(row, "missing alias"))
    test.assertEqual("@Tinker Raid lead", row.suggested)

    state.setNote("Toolbox-Area52", "Raid lead, Alias: Tools")
    row = state.audit()["toolbox-area52"]
    test.assertTrue(hasProblem(row, "wrong alias"))
    test.assertEqual("@Tinker Raid lead", row.suggested)
end)

test.test("an alias of several words can't be written, so a main's note carries none", function()
    local state = retailGuild({ toolbox = "@The", hammer = ">Toolbox", wrench = ">Toolbox" }, "The Tool")

    local row = state.audit()["toolbox-area52"]

    test.assertTrue(hasProblem(row, "wrong alias"))
    test.assertEqual("", row.suggested)
end)

test.test("a main marker on an undeclared main or a lone character is stale", function()
    local state = retailGuild({ toolbox = ">Toolbox", hammer = ">Toolbox", wrench = ">Toolbox", visitor = ">Toolbox ex-alt" })

    local byKey = state.audit()

    test.assertTrue(hasProblem(byKey["toolbox-area52"], "stale main"))
    test.assertEqual("", byKey["toolbox-area52"].suggested)
    test.assertTrue(hasProblem(byKey["visitor-area52"], "stale main"))
    test.assertEqual("ex-alt", byKey["visitor-area52"].suggested)
end)

test.test("a declared main carries a main marker naming itself", function()
    local state = retailGuild({ toolbox = "@Tinker", hammer = ">Toolbox", wrench = ">Toolbox" }, "Tinker")
    state.partition:SetDeclared("toolbox-area52", true, "manual")

    local row = state.audit()["toolbox-area52"]
    test.assertTrue(hasProblem(row, "missing main"))
    test.assertEqual(">Toolbox @Tinker", row.suggested)

    -- Its own alias names the player, not the character: not a declaration.
    state.setNote("Toolbox-Area52", ">Tinker @Tinker")
    test.assertTrue(hasProblem(state.audit()["toolbox-area52"], "wrong player"))

    state.setNote("Toolbox-Area52", "Main: Toolbox, Alias: Tinker")
    test.assertEqual(nil, state.audit()["toolbox-area52"])
end)

test.test("a suggestion longer than a public note is flagged and keeps only the markers", function()
    local state = retailGuild({ hammer = "Healer and part-time raid tank" }, "Tinker")

    local row = state.audit()["hammer-area52"]

    test.assertTrue(row.tooLong)
    test.assertEqual(">Tinker", row.suggested)
end)

test.test("departed characters and characters the store hasn't seen are skipped", function()
    local state = retailGuild({ hammer = "" })
    state.partition:MarkDeparted("hammer-area52", 1790000000)
    state.members["newbie-area52"] = { name = "Newbie-Area52", note = ">Nobody" }

    local byKey = state.audit()

    test.assertEqual(nil, byKey["hammer-area52"])
    test.assertEqual(nil, byKey["newbie-area52"])
    test.assertTrue(byKey["wrench-area52"] ~= nil)
end)

-- Forever: Tool Box is the main of Hammer Smith; Ann Lee and Ann Ray share
-- a first name.
local function foreverGuild(notes, alias)
    return setup(FOREVER, {
        { "Tool Box", notes.tool or "" },
        { "Hammer Smith", notes.hammer or "" },
        { "Ann Lee", notes.lee or "" },
        { "Ann Ray", notes.ray or "" },
    }, function(partition)
        partition:JoinPlayerOf("hammer smith-camelot", "tool box-camelot", "manual")
        partition:JoinPlayerOf("ann ray-camelot", "ann lee-camelot", "manual")
        if alias ~= nil then
            partition:SetAlias(playerId(partition, "tool box-camelot"), alias, "manual")
        end
    end)
end

test.test("Forever: the shortest main name that reads back is suggested, a unique first name first", function()
    local state = foreverGuild({ hammer = "Main: Tool Box", ray = "Tank" })

    local byKey = state.audit()

    -- The full two-word name reads back correctly.
    test.assertEqual(nil, byKey["hammer smith-camelot"])
    -- "Ann" is shared, so the full name is needed.
    test.assertEqual(">Ann Lee Tank", byKey["ann ray-camelot"].suggested)

    state.setNote("Hammer Smith", "Crafter")
    test.assertEqual(">Tool Crafter", state.audit()["hammer smith-camelot"].suggested)
end)

test.test("Forever: >Alias and the main's name both count as correct for an alt", function()
    local state = foreverGuild({ tool = "@Tinker", hammer = ">tinker", ray = ">Ann Lee" }, "Tinker")

    test.assertEqual(0, #select(2, state.audit()))

    state.setNote("Hammer Smith", ">Tool Box")
    test.assertEqual(0, #select(2, state.audit()))

    state.setNote("Hammer Smith", "")
    test.assertEqual(">Tinker", state.audit()["hammer smith-camelot"].suggested)
end)

test.test("Forever: a two-word main marker is removed whole from the kept text", function()
    local state = foreverGuild({ hammer = ">Ann Lee, crafter" })

    local row = state.audit()["hammer smith-camelot"]

    test.assertTrue(hasProblem(row, "wrong player"))
    test.assertEqual(">Tool crafter", row.suggested)
end)
