local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Loads the build and logs in, as the game does on a normal start.
local function start(profile, database)
    local world = fixtures.newEnvironment(profile, { database = database })
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    return world
end

local function registerProfileTests(profile)
    test.test(profile .. " fresh install creates a versioned store with an empty guild container", function()
        local world = start(profile)

        test.assertEqual(2, world.database.schemaVersion)
        test.assertEqual("table", type(world.database.guilds))
        test.assertEqual(nil, next(world.database.guilds))
        test.assertEqual(0, #world.messages)
        test.assertEqual(world.database, world.addon.persistence:GetDatabase())
    end)

    test.test(profile .. " repeat load leaves valid saved data unchanged", function()
        local first = start(profile)
        first.database.guilds["knights-of-camelot"] = { note = "kept" }
        local saved = first.database
        local before = fixtures.snapshot(saved)

        local second = start(profile, saved)

        test.assertEqual(saved, second.database)
        fixtures.assertSameData(before, second.database)
        test.assertEqual(0, #second.messages)
    end)

    test.test(profile .. " preserves unknown fields and fills in only missing ones", function()
        local saved = {
            futureFeature = { enabled = true },
            note = "hand edited",
        }

        local world = start(profile, saved)

        test.assertEqual(saved, world.database)
        test.assertEqual("hand edited", saved.note)
        test.assertTrue(saved.futureFeature.enabled)
        test.assertEqual(2, saved.schemaVersion)
        test.assertEqual("table", type(saved.guilds))
        test.assertEqual(0, #world.messages)
    end)

    test.test(profile .. " keeps a corrupt saved-data root, reports it once, and keeps working", function()
        local world = start(profile, "not a table")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")

        test.assertEqual("not a table", world.database)
        test.assertEqual(0, world.savedVariableWrites)
        test.assertEqual(1, #world.messages)
        test.assertContains(world.messages[1], "Saved data is unavailable")
        test.assertContains(world.messages[1], "left unchanged")
        test.assertEqual(nil, world.addon.persistence:GetDatabase())

        fixtures.slash(world, "help")
        test.assertContains(world.messages[#world.messages - 1], "Version ")
        test.assertEqual(0, world.savedVariableWrites)
    end)
end

local profileIndex
for profileIndex = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[profileIndex])
end

test.test("schema 1 saved data is raised to schema 2 with every record kept", function()
    local saved = {
        schemaVersion = 1,
        guilds = {
            ["Knights of Camelot-Area52"] = {
                characters = { ["toolbox-area52"] = { player = 1, source = "manual" } },
                players = { [1] = { main = "toolbox-area52", alias = "TheTool" } },
            },
        },
    }
    local before = fixtures.snapshot(saved.guilds)

    local world = start("Retail", saved)

    test.assertEqual(saved, world.database)
    test.assertEqual(2, saved.schemaVersion)
    fixtures.assertSameData(before, saved.guilds)
    test.assertEqual(0, #world.messages)
end)

local CORRUPT_CASES = {
    { name = "a guild container of the wrong type", database = { schemaVersion = 1, guilds = "oops" } },
    { name = "a non-numeric schema version", database = { schemaVersion = "one", guilds = {} } },
    { name = "a fractional schema version", database = { schemaVersion = 1.5, guilds = {} } },
    { name = "a schema version from a newer add-on", database = { schemaVersion = 3, guilds = {}, newer = true } },
}

local caseIndex
for caseIndex = 1, #CORRUPT_CASES do
    local case = CORRUPT_CASES[caseIndex]
    test.test("saved data with " .. case.name .. " is kept, reported once, and never written", function()
        local before = fixtures.snapshot(case.database)
        local world = start("Forever", case.database)

        test.assertEqual(case.database, world.database)
        fixtures.assertSameData(before, world.database)
        test.assertEqual(0, world.savedVariableWrites)
        test.assertEqual(1, #world.messages)
        test.assertContains(world.messages[1], "Saved data is unavailable")
        test.assertEqual(nil, world.addon.persistence:GetDatabase())
    end)
end

test.test("a store that cannot be written reports the failure", function()
    local addon = test.newAddon("Core/Persistence.lua")
    local store = addon.Persistence.Create({
        GetAccountDatabase = function()
            return nil
        end,
        SetAccountDatabase = function()
            return false
        end,
    })

    local ready, reason = store:Initialize()

    test.assertFalse(ready)
    test.assertContains(reason, "could not be stored")
    test.assertEqual(nil, store:GetDatabase())
end)
