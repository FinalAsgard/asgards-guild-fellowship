local test = require("tests.test_helper")

-- Declared mains: a player saying "this is really my main", even with no
-- alts. Officer data, read from notes and synced.
local RULES = { twoPartNames = false, homeRealm = "Area52" }
local NOW = 1790000000
local OFFICER = "toolbox-area52"

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/SyncFacts.lua",
        "Core/SyncDigest.lua",
        "Core/SuggestionService.lua",
        "Core/RosterViewModel.lua"
    )
end

-- A guild scanned from `entries` ({ name, note }), then scanned again with
-- `later` when given.
local function scanned(entries, later)
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 4, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local function scan(list, mode)
        local members = {}
        local index
        for index = 1, #list do
            members[normalizer:Key(list[index][1])] = { name = list[index][1], note = list[index][2], level = 60 }
        end
        return addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
            partition = partition, members = members, normalizer = normalizer,
            rules = RULES, mode = mode or "initial", now = NOW, force = mode == "full",
        }))
    end
    local result = scan(entries)
    if later ~= nil then
        result = scan(later, "full")
    end
    local facts = addon.SyncFacts.Create(partition, {
        isOfficer = function(key)
            return key == OFFICER
        end,
        now = function()
            return NOW
        end,
    })
    return { addon = addon, partition = partition, normalizer = normalizer, result = result, facts = facts,
        scan = scan }
end

local function conflictKinds(partition)
    local kinds = {}
    local conflicts = partition:GetConflicts()
    local index
    for index = 1, #conflicts do
        kinds[conflicts[index].character] = conflicts[index].kind
    end
    return kinds
end

-- Notes ------------------------------------------------------------------------

test.test("a note naming its own character as main declares it, seeded on the first scan", function()
    local world = scanned({
        { "Toolbox-Area52", ">Toolbox @TheTool" },
        { "Hammer-Area52", "Main: Hammer" },
        { "Wrench-Area52", "" },
    })

    test.assertTrue(world.partition:IsDeclared("toolbox-area52"))
    test.assertTrue(world.partition:IsDeclared("hammer-area52"))
    test.assertFalse(world.partition:IsDeclared("wrench-area52"))
    test.assertEqual(2, world.result.declared)
    test.assertEqual(nil, next(conflictKinds(world.partition)))
    test.assertEqual("TheTool", world.partition:GetPlayer(world.partition:GetCharacter("toolbox-area52").player).alias)
end)

test.test("a later note fills in a main's declaration, but never overrides one set by hand or sync", function()
    local world = scanned({
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Toolbox" },
    }, {
        { "Toolbox-Area52", ">Toolbox" },
        { "Hammer-Area52", ">Toolbox" },
    })
    test.assertTrue(world.partition:IsDeclared("toolbox-area52"))

    -- An officer took it back: the note doesn't bring it back.
    world.facts:ApplyAll({
        { kind = "declared", character = "toolbox-area52", declared = false, at = NOW + 1, by = OFFICER },
    })
    world.partition:ForgetNoteFingerprint("toolbox-area52")
    world.scan({
        { "Toolbox-Area52", ">Toolbox" },
        { "Hammer-Area52", ">Toolbox" },
    }, "full")
    test.assertFalse(world.partition:IsDeclared("toolbox-area52"))
end)

test.test("on a character the roster has as an alt, a self marker is still a conflict", function()
    local world = scanned({
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Toolbox" },
    }, {
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Hammer" },
    })

    test.assertEqual("self reference", conflictKinds(world.partition)["hammer-area52"])
    test.assertFalse(world.partition:IsDeclared("hammer-area52"))
end)

test.test("a main's note naming itself next to an alias reads as declared, with the alias", function()
    local fresh = scanned({
        { "Toolbox-Area52", ">Toolbox @TheTool raid lead" },
        { "Hammer-Area52", ">Toolbox" },
    })
    test.assertTrue(fresh.partition:IsDeclared("toolbox-area52"))
    test.assertEqual("TheTool", fresh.partition:GetPlayer(fresh.partition:GetCharacter("toolbox-area52").player).alias)
    test.assertEqual(nil, next(conflictKinds(fresh.partition)))
end)

-- Facts ------------------------------------------------------------------------

test.test("declared-main facts are officer data, newest wins, and are part of catch-up", function()
    local world = scanned({ { "Toolbox-Area52", "" }, { "Hammer-Area52", "" } })
    local facts = world.facts
    local function declared(at, by, value)
        return { kind = "declared", character = "hammer-area52", declared = value, at = at, by = by }
    end

    test.assertEqual("not an officer", facts:Refusal(declared(NOW, "hammer-area52", true)))
    test.assertEqual("malformed", facts:Refusal({ kind = "declared", character = "hammer-area52", declared = "yes",
        at = NOW, by = OFFICER }))
    test.assertEqual(1, facts:ApplyAll({ declared(NOW, OFFICER, true) }))
    test.assertTrue(world.partition:IsDeclared("hammer-area52"))
    test.assertEqual(0, facts:ApplyAll({ declared(NOW - 1, OFFICER, false) }))
    test.assertTrue(world.partition:IsDeclared("hammer-area52"))

    local shared = facts:OfficerFacts()
    test.assertEqual(1, #shared)
    test.assertEqual("declared", shared[1].kind)
    test.assertTrue(shared[1].declared)
    local digest = world.addon.SyncDigest.Of(shared)
    world.partition:SetDeclared("hammer-area52", false)
    test.assertTrue(#world.addon.SyncDigest.Differing(digest, world.addon.SyncDigest.Of(facts:OfficerFacts())) >= 1)
end)

test.test("a member's declaration is a suggestion that can be queued, approved and undone", function()
    local world = scanned({ { "Toolbox-Area52", "" }, { "Hammer-Area52", "" } })
    local service = world.addon.SuggestionService.Create(world.partition, {
        isOfficer = function(key)
            return key == OFFICER
        end,
        now = function()
            return NOW
        end,
    })
    local fact = { kind = "declared", character = "hammer-area52", declared = true, at = NOW, by = "hammer-area52" }

    test.assertEqual(1, service:Queue({ fact }, "hammer-area52"))
    local entry = service:Entry("hammer-area52", "suggested declared")
    test.assertTrue(entry.suggestion.declared)
    local approved = service:FactFor(entry, OFFICER, NOW + 5)
    test.assertEqual("declared", approved.kind)
    test.assertTrue(approved.declared)
    test.assertEqual(OFFICER, approved.by)

    -- On the member's side: undo puts back "not declared".
    world.partition:SetDeclared("hammer-area52", true)
    world.partition:SetDeclaredStamp("hammer-area52", NOW, "hammer-area52")
    service:Record({ fact }, function()
        return { declared = false }
    end)
    test.assertTrue(service:Undo("hammer-area52", "declared"))
    test.assertFalse(world.partition:IsDeclared("hammer-area52"))
end)

-- Roster -------------------------------------------------------------------------

test.test("the roster marks declared mains, apart from characters nobody organized", function()
    local world = scanned({
        { "Toolbox-Area52", ">Toolbox" },
        { "Wrench-Area52", "" },
    })
    local rows = world.addon.RosterViewModel.Build({
        partition = world.partition,
        normalizer = world.normalizer,
        members = {},
        classColor = function()
            return nil
        end,
        collapsed = {},
    })

    local declared = {}
    local index
    for index = 1, #rows do
        if rows[index].kind == "character" then
            declared[rows[index].key] = rows[index].declared
        end
    end
    test.assertTrue(declared["toolbox-area52"])
    test.assertFalse(declared["wrench-area52"])
end)

test.test("a declaration set by hand, even without guild sync stamping it, is never overridden by a note", function()
    local world = scanned({
        { "Toolbox-Area52", "" },
        { "Hammer-Area52", ">Toolbox" },
    })
    local service = world.addon.PlayerService.Create(world.partition)

    -- Taken back by hand, with no stamp: the self marker doesn't bring it back.
    test.assertTrue(service:SetDeclared("toolbox-area52", false))
    test.assertEqual(0, (world.partition:GetDeclaredStamp("toolbox-area52")))
    world.scan({
        { "Toolbox-Area52", ">Toolbox" },
        { "Hammer-Area52", ">Toolbox" },
    }, "full")
    test.assertFalse(world.partition:IsDeclared("toolbox-area52"))

    -- Only a player's main can be declared.
    local ok, reason = service:SetDeclared("hammer-area52", true)
    test.assertFalse(ok)
    test.assertContains(reason, "make it the main first")
end)
