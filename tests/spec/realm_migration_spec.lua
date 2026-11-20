local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/RealmMigration.lua")
end

-- Every string, key or value, anywhere in `value`.
local function strings(value, found, visited)
    found = found or {}
    visited = visited or {}
    if visited[value] then
        return found
    end
    visited[value] = true
    local key, inner
    for key, inner in pairs(value) do
        if type(key) == "string" then
            table.insert(found, key)
        end
        if type(inner) == "string" then
            table.insert(found, inner)
        elseif type(inner) == "table" then
            strings(inner, found, visited)
        end
    end
    return found
end

local function containing(value, text)
    local found = {}
    local all = strings(value)
    local index
    for index = 1, #all do
        if string.find(all[index], text, 1, true) then
            table.insert(found, all[index])
        end
    end
    return found
end

test.test("realm migration: a guild's data and every character key in it move to the new realm", function()
    local addon = load()
    local database = {
        schemaVersion = 4,
        guilds = {
            ["Knights of Camelot-Camelot"] = {
                characters = {
                    ["tool box-camelot"] = { name = "Tool Box", player = "p1", note = "@TheTool raid lead" },
                    ["hammer smith-camelot"] = { name = "Hammer Smith", player = "p1", aliasBy = "tool box-camelot" },
                },
                players = { p1 = { main = "tool box-camelot", characters = { "tool box-camelot", "hammer smith-camelot" } } },
                ledger = { ["alias|tool box-camelot"] = { at = 1790000000, by = "tool box-camelot" } },
                rankRequirements = { ["tool box-camelot:1790000000"] = { level = 60 } },
                groupHistory = { { at = 1790000000, characters = { "hammer smith-camelot" } } },
            },
        },
        greet = { slowPressedBy = "tool box-camelot" },
    }

    local moved, kept = addon.RealmMigration.Run(database, "US")

    test.assertEqual(1, moved)
    test.assertEqual(0, #kept)
    test.assertEqual(nil, database.guilds["Knights of Camelot-Camelot"])
    local data = database.guilds["Knights of Camelot-US"]
    test.assertEqual("Tool Box", data.characters["tool box-us"].name)
    test.assertEqual("@TheTool raid lead", data.characters["tool box-us"].note)
    test.assertEqual("tool box-us", data.characters["hammer smith-us"].aliasBy)
    test.assertEqual("tool box-us", data.players.p1.main)
    test.assertEqual("hammer smith-us", data.players.p1.characters[2])
    test.assertEqual("tool box-us", data.ledger["alias|tool box-us"].by)
    test.assertEqual(60, data.rankRequirements["tool box-us:1790000000"].level)
    test.assertEqual("hammer smith-us", data.groupHistory[1].characters[1])
    test.assertEqual("tool box-us", database.greet.slowPressedBy)
    test.assertEqual(0, #containing(database, "-camelot"))
end)

test.test("realm migration: text that only looks like a realm ending is left alone", function()
    local addon = load()
    local database = { guilds = { ["Knights-Camelot"] = { characters = {
        ["tool box-camelot"] = { note = "Raids on Camelot-Camelot", bio = "from the-camelotish woods" },
    } } } }

    addon.RealmMigration.Run(database, "US")

    local character = database.guilds["Knights-US"].characters["tool box-us"]
    test.assertEqual("Raids on Camelot-Camelot", character.note)
    test.assertEqual("from the-camelotish woods", character.bio)
end)

test.test("realm migration: a guild whose new key is taken stays where it was, untouched", function()
    local addon = load()
    local old = { characters = { ["tool box-camelot"] = { name = "Tool Box" } } }
    local current = { characters = { ["tool box-us"] = { name = "Tool Box" } } }
    local database = { guilds = { ["Knights-Camelot"] = old, ["Knights-US"] = current } }

    local moved, kept = addon.RealmMigration.Run(database, "US")

    test.assertEqual(0, moved)
    test.assertEqual("Knights-Camelot", kept[1])
    test.assertTrue(database.guilds["Knights-Camelot"] == old)
    test.assertEqual("Tool Box", old.characters["tool box-camelot"].name)
    test.assertTrue(database.guilds["Knights-US"] == current)
end)

test.test("realm migration: an entry whose renamed key is taken keeps its old key, so nothing is lost", function()
    local addon = load()
    local database = { guilds = { ["Knights-Camelot"] = { characters = {
        ["tool box-camelot"] = { name = "old" },
        ["tool box-us"] = { name = "new" },
    } } } }

    addon.RealmMigration.Run(database, "US")

    local characters = database.guilds["Knights-US"].characters
    test.assertEqual("new", characters["tool box-us"].name)
    test.assertEqual("old", characters["tool box-camelot"].name)
end)

test.test("realm migration: guilds from two old realms both move, and running again changes nothing", function()
    local addon = load()
    local database = { guilds = {
        ["Knights-Camelot"] = { characters = { ["tool box-camelot"] = {} } },
        ["Squires-Avalon"] = { characters = { ["zap arcane-avalon"] = {} } },
    } }

    test.assertEqual(2, (addon.RealmMigration.Run(database, "US")))
    test.assertTrue(database.guilds["Knights-US"].characters["tool box-us"] ~= nil)
    test.assertTrue(database.guilds["Squires-US"].characters["zap arcane-us"] ~= nil)

    local moved, kept = addon.RealmMigration.Run(database, "US")
    test.assertEqual(0, moved)
    test.assertEqual(0, #kept)
end)

test.test("realm migration: a realm differing only in case or spaces isn't moved, and no realm moves nothing", function()
    local addon = load()
    local data = { characters = { ["tool box-camelot"] = {} } }
    local database = { guilds = { ["Knights-camelot"] = data } }

    test.assertEqual(0, (addon.RealmMigration.Run(database, "Camelot")))
    test.assertEqual(0, (addon.RealmMigration.Run(database, nil)))
    test.assertEqual(0, (addon.RealmMigration.Run(database, " ")))
    test.assertTrue(database.guilds["Knights-camelot"] == data)
end)

-- Composed: a Forever install's data from before realms were hidden. -------------

local function loginForever(options)
    local world = fixtures.newEnvironment("Forever", options)
    world.region = options and options.region
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

test.test("composed: Forever data saved under the old realm moves to the region at login, and is found again", function()
    -- Saved before realms were hidden, when the game named the realm.
    local before = loginForever({ region = "Camelot" })
    local database = before.database
    test.assertTrue(database.guilds["Knights of Camelot-Camelot"] ~= nil)
    local characters = 0
    local _
    for _ in pairs(database.guilds["Knights of Camelot-Camelot"].characters) do
        characters = characters + 1
    end
    test.assertTrue(characters >= 3)

    local world = loginForever({ database = database, region = "US" })

    test.assertEqual(nil, world.database.guilds["Knights of Camelot-Camelot"])
    local _, partition = world.addon.rosterController:QuietContext()
    test.assertEqual("Knights of Camelot-US", partition.key)
    test.assertEqual("Tool Box", partition:GetCharacter("tool box-us").name)
    test.assertEqual("tool box-us", world.addon.rosterController:SelfKey())
    local moved = 0
    for _ in pairs(partition.data.characters) do
        moved = moved + 1
    end
    test.assertEqual(characters, moved)
    test.assertEqual(0, #containing(world.database, "-camelot"))
end)

test.test("composed: Forever with no region from the game opens nothing and says so, leaving saved data alone", function()
    local before = loginForever({ region = "Camelot" })
    local world = fixtures.newEnvironment("Forever", { database = before.database })
    world.environment.GetCurrentRegionName = function()
        return ""
    end
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")

    local guild, reason = world.addon.rosterController:QuietContext()
    test.assertEqual(nil, guild)
    test.assertEqual("Guild information isn't available yet. Try again in a moment.", reason)
    test.assertTrue(world.database.guilds["Knights of Camelot-Camelot"] ~= nil)
end)
