local test = require("tests.test_helper")

-- An officer's ledger of the facts they wrote, and the forgery log.
local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local OFFICER = "toolbox-area52"
local NOW = 1790000000

local function newSetup()
    local addon = test.newAddon(
        "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua",
        "Core/SyncLedger.lua"
    )
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    -- Hammer and Wrench are one player; Anvil is another.
    local _, key
    for _, key in ipairs({ "hammer-area52", "wrench-area52", "anvil-area52" }) do
        partition:RecordCharacter(key, { name = key, level = 60 })
    end
    partition:JoinPlayerOf("wrench-area52", "hammer-area52", addon.FellowshipStore.SOURCE_SYNC)
    return {
        addon = addon,
        partition = partition,
        ledger = addon.SyncLedger.Create(partition),
    }
end

local function link(character, main, at)
    return { kind = "main", character = character, main = main, at = at, by = OFFICER }
end

local function alias(character, text, at)
    return { kind = "alias", character = character, alias = text, at = at, by = OFFICER }
end

test.test("facts the officer wrote are known, and anything newer about the same thing is forged", function()
    local setup = newSetup()
    setup.ledger:Record({ link("wrench-area52", "hammer-area52", NOW), alias("hammer-area52", "Hammy", NOW) }, NOW)

    test.assertFalse(setup.ledger:IsForged(link("wrench-area52", "hammer-area52", NOW), NOW), "the same fact")
    test.assertFalse(setup.ledger:IsForged(alias("hammer-area52", "Hammy", NOW), NOW))
    test.assertTrue(setup.ledger:IsForged(link("wrench-area52", "hammer-area52", NOW + 5), NOW), "newer")
    test.assertTrue(setup.ledger:IsForged(link("anvil-area52", "hammer-area52", NOW), NOW), "never written")
    test.assertTrue(setup.ledger:IsForged(alias("hammer-area52", "Hammy", NOW + 5), NOW), "a newer alias")
    -- Older than the officer's own newer edit: it can't change anything.
    test.assertFalse(setup.ledger:IsForged(link("wrench-area52", "anvil-area52", NOW - 5), NOW))
end)

test.test("the officer's own stamp with a value a roster worked out since isn't forged", function()
    local setup = newSetup()
    setup.ledger:Record({ link("wrench-area52", "hammer-area52", NOW), alias("hammer-area52", "Hammy", NOW) }, NOW)

    -- Hammer left the guild and Wrench became the player's acting main.
    test.assertFalse(setup.ledger:IsForged(link("wrench-area52", "wrench-area52", NOW), NOW + 60), "the link")
    test.assertFalse(setup.ledger:IsForged(alias("wrench-area52", "Hammy", NOW), NOW + 60),
        "the alias, now named by the acting main")
    test.assertTrue(setup.ledger:IsForged(alias("wrench-area52", "Hammy", NOW + 1), NOW + 60),
        "an alias stamp they never wrote")
    test.assertTrue(setup.ledger:IsForged(alias("anvil-area52", "Hammy", NOW), NOW + 60),
        "their alias stamp reused for another player")
end)

test.test("an alias stamp the officer replaced since no longer vouches for drift", function()
    local setup = newSetup()
    setup.ledger:Record({ alias("hammer-area52", "Hammy", NOW) }, NOW)
    test.assertFalse(setup.ledger:IsForged(alias("wrench-area52", "Hammy", NOW), NOW))

    -- The officer renames the player while the same check is under way.
    local other = setup.addon.SyncLedger.Create(setup.partition)
    other:Record({ alias("hammer-area52", "Hammers", NOW + 10) }, NOW + 10)

    test.assertTrue(setup.ledger:IsForged(alias("wrench-area52", "Hammy", NOW), NOW + 10))
end)

test.test("a newer edit by the officer replaces the older one, and an older record never does", function()
    local setup = newSetup()
    setup.ledger:Record({ link("wrench-area52", "hammer-area52", NOW) }, NOW)
    setup.ledger:Record({ link("wrench-area52", "anvil-area52", NOW + 10) }, NOW + 10)
    setup.ledger:Record({ link("wrench-area52", "hammer-area52", NOW) }, NOW + 10)

    test.assertFalse(setup.ledger:IsForged(link("wrench-area52", "anvil-area52", NOW + 10), NOW + 10))
    test.assertTrue(setup.ledger:IsForged(link("wrench-area52", "hammer-area52", NOW + 11), NOW + 10))
end)

test.test("facts dated before the ledger started are trusted, and nothing is judged without a clock", function()
    local setup = newSetup()

    test.assertFalse(setup.ledger:IsForged(link("wrench-area52", "hammer-area52", NOW), nil), "no clock")
    test.assertEqual(nil, setup.partition:GetLedger())
    test.assertTrue(setup.ledger:IsForged(link("wrench-area52", "hammer-area52", NOW), NOW), "starts the ledger")
    test.assertEqual(NOW, setup.partition:GetLedger().since)
    test.assertFalse(setup.ledger:IsForged(link("wrench-area52", "hammer-area52", NOW - 86400), NOW + 60),
        "made before this install kept a ledger")
end)

test.test("forgeries are logged with who relayed them, keeping the newest", function()
    local setup = newSetup()
    local index
    for index = 1, setup.addon.SyncLedger.MAX_FORGERIES + 3 do
        setup.ledger:LogForgery(link("wrench-area52", "hammer-area52", NOW + index), "hammer-area52", NOW + 100)
    end

    local log = setup.ledger:Forgeries()
    test.assertEqual(setup.addon.SyncLedger.MAX_FORGERIES, #log)
    test.assertEqual(NOW + 4, log[1].at)
    test.assertEqual("hammer-area52", log[#log].relayedBy)
    test.assertEqual("wrench-area52", log[#log].character)
    test.assertEqual("hammer-area52", log[#log].main)
    test.assertEqual(NOW + 100, log[#log].seen)
end)

test.test("a saved ledger or forgery log of the wrong shape quarantines nothing and is ignored", function()
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/SyncFacts.lua", "Core/SyncLedger.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    partition:SetLedger({ since = "yesterday" })
    local ledger = addon.SyncLedger.Create(partition)

    test.assertTrue(ledger:IsForged(link("wrench-area52", "hammer-area52", NOW), NOW))
    test.assertEqual(NOW, partition:GetLedger().since, "started over")
    test.assertEqual(0, #ledger:Forgeries())
end)
