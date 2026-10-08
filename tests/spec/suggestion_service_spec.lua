local test = require("tests.test_helper")

-- Members' suggestions: what a member keeps pending, and what an officer
-- queues, decides, and settles.
local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local OFFICER = "toolbox-area52"
local MEMBER = "hammer-area52"
local NOW = 1790000000

local function newSetup()
    local addon = test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua",
        "Core/SuggestionService.lua"
    )
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    local keys = { OFFICER, MEMBER, "wrench-area52", "anvil-area52" }
    local index
    for index = 1, #keys do
        partition:RecordCharacter(keys[index], { name = keys[index], level = 60 - index })
    end
    local options = {
        isOfficer = function(key)
            return key == OFFICER
        end,
        now = function()
            return NOW
        end,
    }
    return {
        addon = addon,
        partition = partition,
        service = addon.SuggestionService.Create(partition, options),
        facts = addon.SyncFacts.Create(partition, options),
    }
end

local function link(character, main, at, by)
    return { kind = "main", character = character, main = main, at = at or NOW, by = by or MEMBER }
end

local function alias(character, text, at, by)
    return { kind = "alias", character = character, alias = text, at = at or NOW, by = by or MEMBER }
end

local function mainOf(partition, key)
    return partition:GetPlayer(partition:GetCharacter(key).player).main
end

local function queued(setup)
    local entries = {}
    local conflicts = setup.partition:GetConflicts()
    local index
    for index = 1, #conflicts do
        if conflicts[index].from ~= nil then
            table.insert(entries, conflicts[index])
        end
    end
    return entries
end

-- The member's side ----------------------------------------------------------

test.test("a member's edits are kept pending, a newer one replacing an older one about the same thing", function()
    local setup = newSetup()

    setup.service:Record({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "Hammy", NOW) })
    setup.service:Record({ link("wrench-area52", "anvil-area52", NOW + 5) })

    local pending = setup.service:Pending()
    test.assertEqual(2, #pending)
    test.assertEqual("Hammy", pending[1].alias)
    test.assertEqual("anvil-area52", pending[2].main)
    test.assertEqual(NOW + 5, pending[2].at)
end)

test.test("a pending suggestion is dropped once decided, or once a newer officer fact overtakes it", function()
    local setup = newSetup()
    -- The member's own edits, as stamping leaves them.
    setup.partition:SetMainStamp("wrench-area52", NOW, MEMBER)
    setup.partition:SetAliasStamp(MEMBER, NOW, MEMBER)
    setup.service:Record({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "Hammy", NOW) })

    -- Still the member's own edit: kept.
    test.assertEqual(0, setup.service:Prune(nil))
    -- A decision about the link.
    test.assertEqual(1, setup.service:Prune({ kind = "suggested main", character = "wrench-area52", from = MEMBER,
        at = NOW }))
    -- An officer's newer alias.
    setup.facts:ApplyAll({ alias(MEMBER, "Hammer Time", NOW + 10, OFFICER) })
    test.assertEqual(1, setup.service:Prune(nil))
    test.assertEqual(0, #setup.service:Pending())
end)

-- The officer's side ----------------------------------------------------------

test.test("a member's suggestions are queued with who sent them", function()
    local setup = newSetup()

    local count = setup.service:Queue({ link("wrench-area52", MEMBER), alias(MEMBER, "Hammy") }, MEMBER)

    test.assertEqual(2, count)
    local entries = queued(setup)
    test.assertEqual("wrench-area52", entries[1].character)
    test.assertEqual("suggested main", entries[1].kind)
    test.assertEqual(MEMBER, entries[1].suggestion.main)
    test.assertEqual(MEMBER, entries[1].from)
    test.assertEqual(NOW, entries[1].at)
    test.assertEqual("suggested alias", entries[2].kind)
    test.assertEqual("Hammy", entries[2].suggestion.alias)
    -- Queuing changes nothing in the roster.
    test.assertEqual("wrench-area52", mainOf(setup.partition, "wrench-area52"))
end)

test.test("only suggestions that are the sender's own, newer, and would change something are queued", function()
    local setup = newSetup()
    setup.facts:ApplyAll({ link("anvil-area52", OFFICER, NOW + 100, OFFICER) })

    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", MEMBER, NOW, "wrench-area52") }, MEMBER),
        "someone else's edit")
    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", MEMBER, NOW, OFFICER) }, OFFICER),
        "an officer's edits are facts, not suggestions")
    test.assertEqual(0, setup.service:Queue({ link("anvil-area52", MEMBER, NOW) }, MEMBER),
        "older than the officer's data")
    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", "wrench-area52") }, MEMBER),
        "already so")
    test.assertEqual(0, setup.service:Queue({ alias(MEMBER, "") }, MEMBER), "no alias already")
    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", MEMBER, NOW + 86400) }, MEMBER),
        "dated in the future")
    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", "nobody-area52") }, MEMBER), "unknown main")
    test.assertEqual(0, setup.service:Queue({ { kind = "main" } }, MEMBER), "malformed")
    test.assertEqual(0, setup.service:Queue("everything", MEMBER), "not a list")
    test.assertEqual(0, #queued(setup))
end)

test.test("a newer suggestion about the same thing replaces the older one, and resending changes nothing", function()
    local setup = newSetup()
    setup.service:Queue({ link("wrench-area52", MEMBER, NOW) }, MEMBER)

    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", MEMBER, NOW) }, MEMBER))
    test.assertEqual(1, setup.service:Queue({ link("wrench-area52", "anvil-area52", NOW + 5) }, MEMBER))

    local entries = queued(setup)
    test.assertEqual(1, #entries)
    test.assertEqual("anvil-area52", entries[1].suggestion.main)
end)

test.test("approving makes an officer fact under the approver's name, newer than what is held", function()
    local setup = newSetup()
    setup.service:Queue({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "") }, MEMBER)
    setup.service:Queue({ alias(MEMBER, "Hammy", NOW) }, MEMBER)
    setup.partition:SetMainStamp("wrench-area52", NOW + 50, OFFICER)

    local entry = setup.service:Entry("wrench-area52", "suggested main")
    local fact = setup.service:FactFor(entry, OFFICER, NOW + 20)

    test.assertEqual("main", fact.kind)
    test.assertEqual("wrench-area52", fact.character)
    test.assertEqual(MEMBER, fact.main)
    test.assertEqual(OFFICER, fact.by)
    test.assertEqual(NOW + 51, fact.at)
    local aliasFact = setup.service:FactFor(setup.service:Entry(MEMBER, "suggested alias"), OFFICER, NOW + 20)
    test.assertEqual("alias", aliasFact.kind)
    test.assertEqual("Hammy", aliasFact.alias)
    test.assertEqual(NOW + 20, aliasFact.at)
    test.assertEqual(nil, setup.service:Entry("wrench-area52", "main"))
end)

test.test("a decision settles the suggestion it names, and newer officer facts settle the ones they overtake", function()
    local setup = newSetup()
    setup.service:Queue({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "Hammy", NOW) }, MEMBER)
    local decision = setup.service:Decision(setup.service:Entry("wrench-area52", "suggested main"), true)
    test.assertTrue(setup.addon.SuggestionService.IsDecision(decision))
    test.assertTrue(decision.approved)

    test.assertEqual(1, setup.service:Settle(decision))
    test.assertEqual(1, #queued(setup))

    setup.facts:ApplyAll({ alias(MEMBER, "Hammer Time", NOW + 10, OFFICER) })
    test.assertEqual(1, setup.service:Settle(nil))
    test.assertEqual(0, #queued(setup))
    test.assertFalse(setup.addon.SuggestionService.IsDecision({ kind = "main", character = MEMBER }))
end)

test.test("suggestions stay queued through note scans", function()
    local setup = newSetup()
    setup.service:Queue({ link("wrench-area52", MEMBER) }, MEMBER)
    local normalizer = setup.addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = "Area52" })

    setup.addon.ReconcileEngine.Apply(setup.partition, setup.addon.ReconcileEngine.Plan({
        partition = setup.partition,
        members = { ["wrench-area52"] = { name = "Wrench-Area52", note = "" } },
        normalizer = normalizer,
        rules = { twoPartNames = false, homeRealm = "Area52" },
        mode = "full",
        force = true,
    }))

    test.assertEqual(1, #queued(setup))
end)
