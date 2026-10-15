local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua"
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
    test.assertEqual(0, result.conflicts)
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
    test.assertEqual(1, result.conflicts)
    test.assertEqual("ambiguous", partition:GetConflicts()[1].kind)
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

test.test("unresolved and cyclic markers become conflicts, and a self marker declares a main", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Alpha-Area52", ">Bravo" },
        { "Bravo-Area52", ">Alpha" },
        { "Self-Area52", ">Self" },
        { "Lost-Area52", ">Nobody" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(0, result.linked)
    local reasons = {}
    local entries = partition:GetConflicts()
    local index
    for index = 1, #entries do
        reasons[entries[index].character] = entries[index].kind
        test.assertEqual(8, #entries[index].fingerprint)
        test.assertEqual(nil, entries[index].text)
    end
    test.assertEqual("cycle", reasons["alpha-area52"])
    test.assertEqual("cycle", reasons["bravo-area52"])
    -- Naming itself as main: a declared main, not a conflict.
    test.assertEqual(nil, reasons["self-area52"])
    test.assertTrue(partition:IsDeclared("self-area52"))
    test.assertEqual("unresolved", reasons["lost-area52"])
    test.assertTrue(playerOf(partition, "alpha-area52") ~= playerOf(partition, "bravo-area52"))
end)

test.test("competing aliases on one player become conflicts", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox @Hammertime" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(nil, playerOf(partition, "toolbox-area52").alias)
    test.assertEqual(2, result.conflicts)
    test.assertEqual("competing aliases", partition:GetConflicts()[1].kind)
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

test.test("an organized player nobody named takes a later note's alias, but a different alias is drift", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Toolbox" },
    })
    addon.ReconcileEngine.Apply(partition, plan())
    local function rescan(entries)
        local members, normalizer = roster(addon, RETAIL, entries)
        return addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
            partition = partition,
            members = members,
            normalizer = normalizer,
            rules = RETAIL,
            mode = "full",
        }))
    end

    -- The alt's note names the whole player.
    local result = rescan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox @Bity" } })

    test.assertEqual(1, result.aliased)
    test.assertEqual(0, result.conflicts)
    test.assertEqual("Bity", playerOf(partition, "toolbox-area52").alias)

    result = rescan({ { "Toolbox-Area52", "@Tools" }, { "Hammer-Area52", ">Toolbox @Bity" } })
    test.assertEqual(0, result.aliased)
    test.assertEqual("Bity", playerOf(partition, "toolbox-area52").alias)
    test.assertEqual(1, result.conflicts, "the note naming another alias is drift")
end)

test.test("an organized player's characters naming different aliases compete", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Toolbox" },
    })
    addon.ReconcileEngine.Apply(partition, plan())
    local members, normalizer = roster(addon, RETAIL, {
        { "Toolbox-Area52", "@Tools" },
        { "Hammer-Area52", ">Toolbox @Bity" },
    })

    local result = addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition,
        members = members,
        normalizer = normalizer,
        rules = RETAIL,
        mode = "full",
    }))

    test.assertEqual(0, result.aliased)
    test.assertEqual(nil, playerOf(partition, "toolbox-area52").alias)
    local kinds = {}
    local conflicts = partition:GetConflicts()
    local index
    for index = 1, #conflicts do
        kinds[conflicts[index].character] = conflicts[index].kind
    end
    test.assertEqual("competing aliases", kinds["toolbox-area52"])
    test.assertEqual("competing aliases", kinds["hammer-area52"])
end)

test.test("on a new install notes seed first, and officer data arriving later replaces them", function()
    local entries = {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox" },
        { "Visitor-Area52", "" },
        { "Wrench-Area52", "" },
    }
    local addon, partition, plan = setup(RETAIL, entries)
    addon.ReconcileEngine.Apply(partition, plan())
    test.assertEqual("toolbox-area52", playerOf(partition, "hammer-area52").main)

    local officer = "boss-area52"
    local applied = addon.SyncFacts.Create(partition, {
        isOfficer = function(key)
            return key == officer
        end,
    }):ApplyAll({
        { kind = "main", character = "hammer-area52", main = "visitor-area52", at = 1790000000, by = officer },
        { kind = "alias", character = "toolbox-area52", alias = "Tools", at = 1790000000, by = officer },
    })

    test.assertEqual(2, applied)
    test.assertEqual("visitor-area52", playerOf(partition, "hammer-area52").main)
    test.assertEqual("Tools", playerOf(partition, "toolbox-area52").alias)

    -- The notes still disagree; a later scan queues them and changes nothing.
    local result = addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition,
        members = roster(addon, RETAIL, entries),
        normalizer = addon.NameNormalizer.Create(RETAIL),
        rules = RETAIL,
        mode = "incremental",
    }))
    test.assertEqual(0, result.linked)
    test.assertEqual(0, result.aliased)
    test.assertEqual(2, result.conflicts)
    test.assertEqual("visitor-area52", playerOf(partition, "hammer-area52").main)
    test.assertEqual("Tools", playerOf(partition, "toolbox-area52").alias)
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

-- Plans and applies a scan of `entries` against an existing partition.
local function rescan(addon, partition, rules, entries, mode, force)
    local members, normalizer = roster(addon, rules, entries)
    return addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition,
        members = members,
        normalizer = normalizer,
        rules = rules,
        mode = mode or "full",
        force = force,
    }))
end

local function conflictKinds(partition)
    local kinds = {}
    local conflicts = partition:GetConflicts()
    local index
    for index = 1, #conflicts do
        kinds[conflicts[index].character] = conflicts[index]
    end
    return kinds
end

local ALIAS_SCANS = {
    { rules = RETAIL, profile = "Retail", main = "Toolbox-Area52", mainKey = "toolbox-area52",
        alts = { { "Hammer-Area52", "hammer-area52" }, { "Wrench-Area52", "wrench-area52" } } },
    { rules = FOREVER, profile = "Forever", main = "Tool Box", mainKey = "tool box-camelot",
        alts = { { "Hammer Smith", "hammer smith-camelot" }, { "Wrench Bolt", "wrench bolt-camelot" } } },
}

local scanIndex
for scanIndex = 1, #ALIAS_SCANS do
    local scan = ALIAS_SCANS[scanIndex]

    test.test(scan.profile .. ": a main's @Alias and its alts' >Alias link in one first scan", function()
        local addon, partition, plan = setup(scan.rules, {
            { scan.main, "@Tinker raid lead" },
            { scan.alts[1][1], "Healer >Tinker" },
            { scan.alts[2][1], ">tinker" },
        })

        local result = addon.ReconcileEngine.Apply(partition, plan())

        test.assertEqual(2, result.linked)
        test.assertEqual(0, result.conflicts)
        local main = playerOf(partition, scan.mainKey)
        test.assertEqual(scan.mainKey, main.main)
        test.assertEqual("Tinker", main.alias)
        test.assertEqual(main, playerOf(partition, scan.alts[1][2]))
        test.assertEqual(main, playerOf(partition, scan.alts[2][2]))
        test.assertFalse(partition:IsDeclared(scan.mainKey))
    end)

    test.test(scan.profile .. ": a >Alias alt joins a stored player and stays when the main changes", function()
        local addon, partition, plan = setup(scan.rules, {
            { scan.main, "" },
            { scan.alts[1][1], "" },
        })
        addon.ReconcileEngine.Apply(partition, plan())
        local playerId = partition:GetCharacter(scan.mainKey).player
        partition:SetAlias(playerId, "Tinker", "manual")
        local entries = {
            { scan.main, "" },
            { scan.alts[1][1], "" },
            { scan.alts[2][1], ">TINKER" },
        }

        local result = rescan(addon, partition, scan.rules, entries)

        test.assertEqual(1, result.linked)
        test.assertEqual(playerId, partition:GetCharacter(scan.alts[2][2]).player)

        -- Another character becomes the main: the alt's note still agrees.
        partition:JoinPlayerOf(scan.alts[1][2], scan.mainKey, "manual")
        partition:SetMain(playerId, scan.alts[1][2])
        result = rescan(addon, partition, scan.rules, entries, "full", true)

        test.assertEqual(0, result.conflicts)
        test.assertEqual(0, result.linked)
        test.assertEqual(playerId, partition:GetCharacter(scan.alts[2][2]).player)
        test.assertEqual(scan.alts[1][2], partition:GetPlayer(playerId).main)
    end)
end

test.test("an alias wins over a character with the same name", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@Hammer" },
        { "Hammer-Area52", "" },
        { "Wrench-Area52", ">Hammer" },
    })

    addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual("toolbox-area52", playerOf(partition, "wrench-area52").main)
    test.assertEqual("hammer-area52", playerOf(partition, "hammer-area52").main)
end)

test.test("an alt repeating its player's alias next to >Alias is not ambiguous", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@Tinker" },
        { "Hammer-Area52", ">Tinker @Tinker" },
        { "Wrench-Area52", ">Toolbox @Tinker" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(0, result.conflicts)
    test.assertEqual("toolbox-area52", playerOf(partition, "hammer-area52").main)
    test.assertEqual("toolbox-area52", playerOf(partition, "wrench-area52").main)
    test.assertEqual("Tinker", playerOf(partition, "toolbox-area52").alias)
end)

test.test("a note naming its own player's alias changes nothing and declares nothing", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", ">Tinker @Tinker" },
        { "Hammer-Area52", ">Tinker" },
    })

    local result = addon.ReconcileEngine.Apply(partition, plan())

    test.assertEqual(0, result.conflicts)
    test.assertEqual("toolbox-area52", playerOf(partition, "hammer-area52").main)
    test.assertFalse(partition:IsDeclared("toolbox-area52"))

    -- A rescan of every note: the main and its alt both still agree.
    result = rescan(addon, partition, RETAIL, {
        { "Toolbox-Area52", ">Tinker @Tinker" },
        { "Hammer-Area52", ">Tinker" },
    }, "full", true)
    test.assertEqual(0, result.conflicts)
    test.assertFalse(partition:IsDeclared("toolbox-area52"))
end)

test.test("an organized character naming another player's alias is a main conflict", function()
    local addon, partition, plan = setup(FOREVER, {
        { "Tool Box", "@Tinker" },
        { "Hammer Smith", "" },
        { "Wrench Bolt", ">Hammer Smith" },
    })
    addon.ReconcileEngine.Apply(partition, plan())

    local result = rescan(addon, partition, FOREVER, {
        { "Tool Box", "@Tinker" },
        { "Hammer Smith", "" },
        { "Wrench Bolt", ">Tinker" },
    })

    test.assertEqual(0, result.linked)
    test.assertEqual("hammer smith-camelot", playerOf(partition, "wrench bolt-camelot").main)
    local conflict = conflictKinds(partition)["wrench bolt-camelot"]
    test.assertEqual("main", conflict.kind)
    test.assertEqual("tool box-camelot", conflict.suggestion.main)
end)

test.test("existing >Main notes behave as before when the word is nobody's alias", function()
    local addon, partition, plan = setup(RETAIL, {
        { "Toolbox-Area52", "@Tinker" },
        { "Hammer-Area52", ">Toolbox" },
        { "Wrench-Area52", ">Nobody" },
    })

    local result = plan()
    addon.ReconcileEngine.Apply(partition, result)

    test.assertEqual("toolbox-area52", result.links["hammer-area52"])
    test.assertEqual("unresolved", conflictKinds(partition)["wrench-area52"].kind)
end)

test.test("a multi-word alias set by hand is never matched by a note", function()
    local addon, partition, plan = setup(FOREVER, {
        { "Tool Box", "" },
        { "Hammer Smith", "" },
    })
    addon.ReconcileEngine.Apply(partition, plan())
    partition:SetAlias(partition:GetCharacter("tool box-camelot").player, "The Tool", "manual")

    rescan(addon, partition, FOREVER, {
        { "Tool Box", "" },
        { "Hammer Smith", "" },
        { "Wrench Bolt", ">The Tool" },
    })

    test.assertEqual("unresolved", conflictKinds(partition)["wrench bolt-camelot"].kind)
    test.assertTrue(playerOf(partition, "wrench bolt-camelot") ~= playerOf(partition, "tool box-camelot"))
end)
