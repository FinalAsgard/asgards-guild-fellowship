local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua"
    )
end

local RETAIL = { twoPartNames = false, homeRealm = "Area52" }
local FOREVER = { twoPartNames = true, homeRealm = "Camelot" }

-- Builds a roster keyed the way the controller keys it.
local function roster(addon, rules, entries)
    local normalizer = addon.NameNormalizer.Create(rules)
    local members = {}
    local index
    for index = 1, #entries do
        local entry = entries[index]
        members[normalizer:Key(entry[1])] = { name = entry[1], note = entry[2], classToken = "WARRIOR", level = 10 }
    end
    return members, normalizer
end

local function setup(rules, entries, database)
    local addon = load()
    database = database or { schemaVersion = 1, guilds = {} }
    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = rules.homeRealm })
    local members, normalizer = roster(addon, rules, entries)
    local function plan()
        return addon.ReconcileEngine.Plan({
            partition = partition,
            members = members,
            normalizer = normalizer,
            rules = rules,
            mode = "initial",
        })
    end
    return addon, partition, plan, database
end

local function playerOf(partition, key)
    return partition:GetPlayer(partition:GetCharacter(key).player)
end

test.test("planning never mutates the partition", function()
    local addon, partition, plan, database = setup(RETAIL, {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox" },
    })
    local before = fixtures.snapshot(database)

    local result = plan()

    fixtures.assertSameData(before, database)
    test.assertEqual("toolbox-area52", result.links["hammer-area52"])
    test.assertEqual("TheTool", result.aliases["toolbox-area52"])
    test.assertTrue(addon ~= nil and partition ~= nil)
end)

test.test("initial seeding links alts to their main and applies the alias", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@TheTool raid lead" },
        { "Hammer-Area52", "Healer >Toolbox" },
        { "Visitor-Area52", "" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(3, result.recorded)
    test.assertEqual(1, result.linked)
    test.assertEqual(1, result.aliased)
    test.assertEqual(0, result.unapplied)
    local main = playerOf(partition, "toolbox-area52")
    test.assertEqual(main, playerOf(partition, "hammer-area52"))
    test.assertEqual("toolbox-area52", main.main)
    test.assertEqual("TheTool", main.alias)
    test.assertEqual("note", main.aliasSource)
    test.assertEqual("note", partition:GetCharacter("hammer-area52").source)
    test.assertEqual("roster", partition:GetCharacter("toolbox-area52").source)
    test.assertTrue(playerOf(partition, "visitor-area52") ~= main)
    -- Hammer's own single-character player is gone.
    local players = 0
    partition:EachPlayer(function()
        players = players + 1
    end)
    test.assertEqual(2, players)
end)

test.test("an alias on an alt's note names the alt's whole player", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Toolbox @TheTool" },
    })

    addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual("TheTool", playerOf(partition, "toolbox-area52").alias)
end)

test.test("Forever seeding resolves two-word names and unique first names", function()
    local addon, partition, plan = setup(FOREVER, {
        { "Tool Box", "" },
        { "Hammer Smith", ">Tool Box" },
        { "Zélie Rune", ">Tool" },
        { "Ann Lee", "" },
        { "Ann Ray", "" },
        { "Bob Cat", ">Ann" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    local main = playerOf(partition, "tool box-camelot")
    test.assertEqual(main, playerOf(partition, "hammer smith-camelot"))
    test.assertEqual(main, playerOf(partition, "zélie rune-camelot"))
    test.assertTrue(playerOf(partition, "bob cat-camelot") ~= playerOf(partition, "ann lee-camelot"))
    test.assertEqual(1, result.unapplied)
    test.assertEqual("ambiguous", partition:GetUnapplied()[1].reason)
end)

test.test("chains collapse to the root main", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Alpha-Area52", ">Bravo" },
        { "Bravo-Area52", ">Charlie" },
        { "Charlie-Area52", "" },
    })

    local result = plan()
    addon.ReconcileEngine.Apply(partition, result)

    test.assertEqual("charlie-area52", result.links["alpha-area52"])
    test.assertEqual("charlie-area52", result.links["bravo-area52"])
    local main = playerOf(partition, "charlie-area52")
    test.assertEqual(main, playerOf(partition, "alpha-area52"))
    test.assertEqual(main, playerOf(partition, "bravo-area52"))
    test.assertEqual("charlie-area52", main.main)
end)

test.test("unresolved, ambiguous, cyclic, and self markers stay unapplied and recorded", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Alpha-Area52", ">Bravo" },
        { "Bravo-Area52", ">Alpha" },
        { "Self-Area52", ">Self" },
        { "Lost-Area52", ">Nobody" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(0, result.linked)
    local reasons = {}
    local entries = partition:GetUnapplied()
    local index
    for index = 1, #entries do
        reasons[entries[index].character] = entries[index].reason
        test.assertEqual(8, #entries[index].fingerprint)
        test.assertEqual(nil, entries[index].text)
    end
    test.assertEqual("cycle", reasons["alpha-area52"])
    test.assertEqual("cycle", reasons["bravo-area52"])
    test.assertEqual("self reference", reasons["self-area52"])
    test.assertEqual("unresolved", reasons["lost-area52"])
    test.assertTrue(playerOf(partition, "alpha-area52") ~= playerOf(partition, "bravo-area52"))
end)

test.test("competing aliases on one player are left unapplied", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox @Hammertime" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(nil, playerOf(partition, "toolbox-area52").alias)
    test.assertEqual(2, result.unapplied)
    test.assertEqual("competing aliases", partition:GetUnapplied()[1].reason)
end)

test.test("characters that already have relationships are not reseeded", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox" },
        { "Visitor-Area52", "" },
    })
    addon.ReconcileEngine.Apply(partition, plan())
    -- Hammer's note now points elsewhere, and Toolbox's alias changed.
    local members = roster(addon, RETAIL, {
        { "Toolbox-Area52", "@SomeoneElse" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    })

    addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition,
        members = members,
        normalizer = addon.NameNormalizer.Create(RETAIL),
        rules = RETAIL,
        mode = "full",
    }))

    test.assertEqual(playerOf(partition, "toolbox-area52"), playerOf(partition, "hammer-area52"))
    test.assertEqual("TheTool", playerOf(partition, "toolbox-area52").alias)
end)

test.test("the store keeps a note fingerprint, never the note text", function()
    local addon, partition, plan, database = setup(RETAIL, {
        { "Toolbox-Area52", "@TheTool raid lead on Tuesdays" },
    })

    addon.ReconcileEngine.Apply(partition, plan())

    local character = partition:GetCharacter("toolbox-area52")
    test.assertEqual(addon.NoteParser.Fingerprint("@TheTool raid lead on Tuesdays"), character.note)
    local function containsNoteText(value)
        if type(value) == "string" then
            return string.find(value, "Tuesdays", 1, true) ~= nil
        end
        if type(value) == "table" then
            local key, item
            for key, item in pairs(value) do
                if containsNoteText(key) or containsNoteText(item) then
                    return true
                end
            end
        end
        return false
    end
    test.assertFalse(containsNoteText(database))
end)
