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
        "Core/SuggestionService.lua",
        "Core/SuggestionBundles.lua"
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

-- The member's own edits: Wrench linked to Hammer, and Hammer named "Hammy".
local function memberEdited(setup)
    setup.partition:JoinPlayerOf("wrench-area52", MEMBER, "manual")
    setup.partition:SetMainStamp("wrench-area52", NOW, MEMBER)
    setup.partition:SetAlias(setup.partition:GetCharacter(MEMBER).player, "Hammy", "manual")
    setup.partition:SetAliasStamp(MEMBER, NOW, MEMBER)
    setup.service:Record({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "Hammy", NOW) })
end

local function rejection(kind, character, official, at)
    return { kind = kind, character = character, from = MEMBER, at = at or NOW, approved = false,
        official = official }
end

test.test("a rejected suggestion reverts the member's edit to the officer's value, unstamped", function()
    local setup = newSetup()
    memberEdited(setup)

    test.assertEqual(1, setup.service:Revert(rejection("suggested main", "wrench-area52",
        { main = "wrench-area52" })))
    test.assertEqual(1, setup.service:Revert(rejection("suggested alias", MEMBER, { alias = "" })))

    test.assertEqual("wrench-area52", mainOf(setup.partition, "wrench-area52"))
    test.assertEqual(nil, setup.partition:GetPlayer(setup.partition:GetCharacter(MEMBER).player).alias)
    test.assertEqual(0, (setup.partition:GetMainStamp("wrench-area52")))
    test.assertEqual(0, (setup.partition:GetAliasStamp(MEMBER)))
    test.assertEqual(2, setup.service:Prune(nil))
    -- Unstamped, so the officer's own fact applies over it.
    test.assertEqual(1, setup.facts:ApplyAll({ link("wrench-area52", "anvil-area52", NOW - 100, OFFICER) }))
    test.assertEqual("anvil-area52", mainOf(setup.partition, "wrench-area52"))
end)

test.test("a rejection reverts an alias to the officer's alias", function()
    local setup = newSetup()
    memberEdited(setup)

    test.assertEqual(1, setup.service:Revert(rejection("suggested alias", MEMBER, { alias = "The Hammer" })))

    test.assertEqual("The Hammer", setup.partition:GetPlayer(setup.partition:GetCharacter(MEMBER).player).alias)
    test.assertEqual(1, setup.service:Prune(nil))
    test.assertEqual("main", setup.service:Pending()[1].kind, "the link suggestion stays pending")
end)

test.test("a rejection leaves alone an edit made after the rejected one, approvals, and other members' edits", function()
    local setup = newSetup()
    memberEdited(setup)

    test.assertEqual(0, setup.service:Revert(rejection("suggested main", "wrench-area52",
        { main = "wrench-area52" }, NOW - 1)), "the rejected edit was older")
    local approval = rejection("suggested main", "wrench-area52", { main = "wrench-area52" })
    approval.approved = true
    test.assertEqual(0, setup.service:Revert(approval), "approved")
    local other = rejection("suggested main", "wrench-area52", { main = "wrench-area52" })
    other.from = "anvil-area52"
    test.assertEqual(0, setup.service:Revert(other), "someone else's suggestion")
    test.assertEqual(0, setup.service:Revert(rejection("suggested main", "wrench-area52",
        { main = "nobody-area52" })), "an unknown main")
    test.assertEqual(MEMBER, mainOf(setup.partition, "wrench-area52"))
    test.assertEqual(NOW, (setup.partition:GetMainStamp("wrench-area52")))
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

test.test("a rejection carries the officer's value, and the officer's own fact when an officer set it", function()
    local setup = newSetup()
    setup.facts:ApplyAll({ alias(MEMBER, "The Hammer", NOW - 100, OFFICER) })
    setup.service:Queue({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "Hammy", NOW) }, MEMBER)
    local linkEntry = setup.service:Entry("wrench-area52", "suggested main")
    local aliasEntry = setup.service:Entry(MEMBER, "suggested alias")

    test.assertEqual("wrench-area52", setup.service:Decision(linkEntry, false).official.main)
    test.assertEqual("The Hammer", setup.service:Decision(aliasEntry, false).official.alias)
    test.assertEqual(nil, setup.service:Decision(aliasEntry, true).official)
    test.assertEqual(nil, setup.service:OfficialFact(linkEntry), "notes or the roster set it")
    local fact = setup.service:OfficialFact(aliasEntry)
    test.assertEqual("The Hammer", fact.alias)
    test.assertEqual(OFFICER, fact.by)
    test.assertEqual(NOW - 100, fact.at)
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

-- Bundles: the member's side ---------------------------------------------------

local function normalizer(setup)
    return setup.addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = "Area52" })
end

local function texts(items)
    local list = {}
    local index
    for index = 1, #items do
        list[index] = items[index].text
    end
    return table.concat(list, "; ")
end

test.test("bundles: a member's pending items are those of their player, from any of its characters", function()
    local setup = newSetup()
    local partition = setup.partition
    -- Hammer and Wrench are one player; Anvil is someone else on this install.
    partition:JoinPlayerOf("wrench-area52", MEMBER, "manual")
    setup.service:Record({ link("anvil-area52", MEMBER, NOW, MEMBER) })
    setup.service:Record({ alias(MEMBER, "Hammers", NOW + 1, "wrench-area52") })
    setup.service:Record({ alias("anvil-area52", "Anvils", NOW + 2, "anvil-area52") })

    local items = setup.addon.SuggestionBundles.MemberItems(partition, normalizer(setup),
        partition:GetCharacter(MEMBER).player, setup.service:Pending())

    test.assertEqual("anvil as an alt of hammer; Alias: Hammers", texts(items))
    test.assertEqual("main", items[1].kind)
    test.assertEqual("alias", items[2].kind)
    test.assertEqual("Clear the alias",
        setup.addon.SuggestionBundles.Describe(partition, normalizer(setup), alias(MEMBER, "")))
    test.assertEqual("hammer as main",
        setup.addon.SuggestionBundles.Describe(partition, normalizer(setup), link(MEMBER, MEMBER)))
end)

test.test("bundles: a re-edit replaces the item and keeps what it replaced; changing it back drops and withdraws it", function()
    local setup = newSetup()
    local partition = setup.partition
    local function prior()
        return { main = "wrench-area52" }
    end

    setup.service:Record({ link("wrench-area52", MEMBER, NOW) }, prior)
    -- The second edit's prior is the member's own first edit; the officers'
    -- value is still what the first one replaced.
    setup.service:Record({ link("wrench-area52", "anvil-area52", NOW + 5) }, function()
        return { main = MEMBER }
    end)
    local pending = setup.service:Pending()
    test.assertEqual(1, #pending)
    test.assertEqual("anvil-area52", pending[1].main)
    test.assertEqual("wrench-area52", pending[1].was.main)
    test.assertTrue(pending[1].was ~= nil)
    test.assertTrue(setup.service:Outgoing()[1].was == nil)

    -- Back to Wrench as its own main: nothing is pending any more.
    partition:SetMainStamp("wrench-area52", NOW + 9, MEMBER)
    test.assertEqual(1, setup.service:Record({ link("wrench-area52", "wrench-area52", NOW + 9) }, function()
        return { main = "anvil-area52" }
    end))
    test.assertEqual(0, #setup.service:Pending())
    -- Unstamped again, so officer data wins over it; the withdrawal goes out.
    test.assertEqual(0, (partition:GetMainStamp("wrench-area52")))
    local outgoing = setup.service:Outgoing()
    test.assertEqual(1, #outgoing)
    test.assertEqual("wrench-area52", outgoing[1].main)
    test.assertEqual(NOW + 9, outgoing[1].at)
end)

test.test("bundles: undo puts back what the suggestion replaced, here, and withdraws it", function()
    local setup = newSetup()
    local partition = setup.partition
    -- The member linked Wrench to Hammer, as stamping leaves it.
    partition:JoinPlayerOf("wrench-area52", MEMBER, "manual")
    partition:SetMainStamp("wrench-area52", NOW, MEMBER)
    setup.service:Record({ link("wrench-area52", MEMBER, NOW) }, function()
        return { main = "wrench-area52" }
    end)
    setup.service:Record({ alias(MEMBER, "Hammers", NOW) })

    test.assertTrue(setup.service:Undo("wrench-area52", "main"))

    test.assertEqual("wrench-area52", mainOf(partition, "wrench-area52"))
    test.assertEqual(0, (partition:GetMainStamp("wrench-area52")))
    -- Only that item went; the alias without a known prior can't be undone.
    test.assertEqual(1, #setup.service:Pending())
    local undone, reason = setup.service:Undo(MEMBER, "alias")
    test.assertFalse(undone)
    test.assertContains(reason, "isn't known")
    test.assertFalse(setup.service:Undo("wrench-area52", "main"))
    local outgoing = setup.service:Outgoing()
    test.assertEqual("alias", outgoing[1].kind)
    test.assertEqual("main", outgoing[2].kind)
    test.assertEqual("wrench-area52", outgoing[2].main)
    test.assertEqual(NOW + 1, outgoing[2].at)
end)

test.test("bundles: withdrawals are kept two weeks, and a new edit to the same thing replaces one", function()
    local setup = newSetup()
    local now = NOW
    local service = setup.addon.SuggestionService.Create(setup.partition, {
        now = function()
            return now
        end,
    })
    service:Record({ link("wrench-area52", MEMBER, NOW) }, function()
        return { main = "wrench-area52" }
    end)
    service:Undo("wrench-area52", "main")
    test.assertEqual(1, #service:Outgoing())

    service:Record({ link("wrench-area52", "anvil-area52", NOW + 2) }, function()
        return { main = "wrench-area52" }
    end)
    local outgoing = service:Outgoing()
    test.assertEqual(1, #outgoing)
    test.assertEqual("anvil-area52", outgoing[1].main)

    service:Undo("wrench-area52", "main")
    now = NOW + 15 * 86400
    -- Only the withdrawal was left, and it's too old now.
    test.assertEqual(0, #service:Outgoing())
end)

test.test("bundles: an officer's queue drops a member's suggestion they withdrew, and only theirs", function()
    local setup = newSetup()
    setup.service:Queue({ link("wrench-area52", MEMBER, NOW) }, MEMBER)
    setup.service:Queue({ link("anvil-area52", "wrench-area52", NOW, "wrench-area52") }, "wrench-area52")
    test.assertEqual(2, #queued(setup))

    -- Another member's "withdrawal" of Hammer's suggestion is ignored.
    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", "wrench-area52", NOW + 5, "anvil-area52") },
        "anvil-area52"))
    -- An older one too.
    test.assertEqual(0, setup.service:Queue({ link("wrench-area52", "wrench-area52", NOW - 5) }, MEMBER))
    test.assertEqual(2, #queued(setup))

    test.assertEqual(1, setup.service:Queue({ link("wrench-area52", "wrench-area52", NOW + 5) }, MEMBER))
    local left = queued(setup)
    test.assertEqual(1, #left)
    test.assertEqual("anvil-area52", left[1].character)
end)

test.test("bundles: a decision names the member's pending items it settles", function()
    local setup = newSetup()
    setup.service:Record({ link("wrench-area52", MEMBER, NOW), alias(MEMBER, "Hammy", NOW) })

    local named = setup.service:Named({ kind = "suggested main", character = "wrench-area52", from = MEMBER,
        at = NOW, approved = true })
    test.assertEqual(1, #named)
    test.assertEqual("wrench-area52", named[1].character)
    test.assertEqual(0, #setup.service:Named({ kind = "suggested main", character = "wrench-area52",
        from = "anvil-area52", at = NOW }))
    test.assertEqual(0, #setup.service:Named(nil))
end)
