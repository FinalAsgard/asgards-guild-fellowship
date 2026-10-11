local test = require("tests.test_helper")

local START = 1790000000

-- A config over a plain saved table; "boss" and "lieutenant" are officers.
local function setup()
    local addon = test.newAddon("Core/SyncFacts.lua", "Core/RecruitConfig.lua")
    local saved = {}
    local officers = { boss = true, lieutenant = true }
    local config = addon.RecruitConfig.Create(saved, {
        isOfficer = function(key)
            return officers[key] == true
        end,
    })
    return addon, config, saved
end

test.test("recruit config: settings have defaults until an officer changes them", function()
    local _, config, saved = setup()

    test.assertEqual("", config:Get("guildAd"))
    test.assertTrue(config:Get("guildAdOn"))
    test.assertEqual(nil, config:Changes())

    local entry = config:Set("guildAd", "Join us!", START, "boss")
    test.assertEqual("Join us!", entry.value)
    test.assertEqual(START, saved.guildAd.at)
    test.assertEqual("boss", saved.guildAd.by)
    test.assertEqual("Join us!", config:Get("guildAd"))
    test.assertEqual("Join us!", config:Changes().guildAd.value)
    test.assertEqual(nil, config:Changes().guildAdOn)
end)

test.test("recruit config: only officers change settings, and only to acceptable values", function()
    local _, config = setup()

    test.assertEqual(nil, config:Set("guildAd", "Join us!", START, "member"))
    test.assertEqual(nil, config:Set("guildAd", string.rep("x", 256), START, "boss"))
    test.assertEqual(nil, config:Set("guildAdOn", "yes", START, "boss"))
    test.assertEqual(nil, config:Set("unknown", true, START, "boss"))
    test.assertTrue(config:Set("guildAd", string.rep("x", 255), START, "boss") ~= nil)
    test.assertEqual("", config:Set("guildAd", "", START + 1, "boss").value)
end)

test.test("recruit config: a second change in the same second still wins", function()
    local _, config = setup()

    config:Set("guildAdOn", false, START, "boss")
    local entry = config:Set("guildAdOn", true, START, "boss")

    test.assertEqual(START + 1, entry.at)
    test.assertTrue(config:Get("guildAdOn"))
end)

test.test("recruit config: received changes follow newest wins, then author", function()
    local _, config = setup()
    config:Set("guildAd", "Old ad", START, "boss")

    test.assertFalse(config:Apply("guildAd", { value = "Older", at = START - 1, by = "lieutenant" }))
    test.assertFalse(config:Apply("guildAd", { value = "Same", at = START, by = "boss" }))
    -- Same second: the later author in sort order wins, on every client.
    test.assertFalse(config:Apply("guildAd", { value = "Tie lost", at = START, by = "abbot" }))
    test.assertEqual("Old ad", config:Get("guildAd"))
    test.assertTrue(config:Apply("guildAd", { value = "Tie won", at = START, by = "lieutenant" }))
    test.assertEqual("Tie won", config:Get("guildAd"))
    test.assertTrue(config:Apply("guildAd", { value = "Newest", at = START + 5, by = "boss" }))
    test.assertEqual("Newest", config:Get("guildAd"))
end)

test.test("recruit config: changes by non-officers and malformed changes are refused", function()
    local _, config = setup()

    test.assertFalse(config:Apply("guildAd", { value = "Forged", at = START, by = "member" }))
    test.assertFalse(config:Apply("guildAd", { value = 5, at = START, by = "boss" }))
    test.assertFalse(config:Apply("guildAd", { value = "No time", by = "boss" }))
    test.assertFalse(config:Apply("guildAd", "Join us!"))
    test.assertFalse(config:Apply("nothing", { value = true, at = START, by = "boss" }))
    test.assertEqual("", config:Get("guildAd"))
end)

test.test("recruit config: heard changes cover this config only when none here is newer", function()
    local _, config = setup()
    config:Set("guildAd", "Join us!", START, "boss")

    test.assertFalse(config:CoveredBy({}))
    test.assertFalse(config:CoveredBy({ guildAd = { value = "Old", at = START - 1, by = "boss" } }))
    test.assertTrue(config:CoveredBy({ guildAd = { value = "Join us!", at = START, by = "boss" } }))
    test.assertTrue(config:CoveredBy({ guildAd = { value = "Newer", at = START + 1, by = "lieutenant" } }))
    test.assertFalse(config:CoveredBy("everything"))
end)

test.test("recruit config: PickAd picks between the usable ads, or none", function()
    local addon = setup()
    local function pick(officerAd, officerOn, useOfficer, ownAd, choice)
        return addon.RecruitConfig.PickAd({
            officerAd = officerAd,
            officerOn = officerOn,
            useOfficer = useOfficer,
            ownAd = ownAd,
            random = function(low, high)
                test.assertEqual(1, low)
                test.assertEqual(2, high)
                return choice or 1
            end,
        })
    end

    -- Both usable: either can be picked.
    test.assertEqual("Guild", pick("Guild", true, true, "Mine", 1))
    test.assertEqual("Mine", pick("Guild", true, true, "Mine", 2))
    -- Only one usable.
    test.assertEqual("Mine", pick("Guild", false, true, "Mine"))
    test.assertEqual("Mine", pick("Guild", true, false, "Mine"))
    test.assertEqual("Mine", pick("", true, true, "Mine"))
    test.assertEqual("Mine", pick("   ", true, true, "Mine"))
    test.assertEqual("Guild", pick("Guild", true, true, ""))
    test.assertEqual("Guild", pick("Guild", true, true, "  "))
    -- None usable.
    test.assertEqual(nil, pick("Guild", false, true, ""))
    test.assertEqual(nil, pick("Guild", true, false, ""))
    test.assertEqual(nil, pick("", true, true, ""))
    -- A failing random pick still gives an ad.
    test.assertEqual("Guild", addon.RecruitConfig.PickAd({
        officerAd = "Guild", officerOn = true, useOfficer = true, ownAd = "Mine",
        random = function() error("boom") end,
    }))
end)

test.test("recruit config: gaps default to 60 and 20 minutes and never go below 15 and 5", function()
    local _, config = setup()

    test.assertEqual(60, config:Get("generalGapMinutes"))
    test.assertEqual(20, config:Get("tradeGapMinutes"))
    test.assertFalse(config:Get("paused"))

    test.assertEqual(nil, config:Set("generalGapMinutes", 14, START, "boss"))
    test.assertEqual(nil, config:Set("tradeGapMinutes", 4, START, "boss"))
    test.assertEqual(nil, config:Set("generalGapMinutes", 30.5, START, "boss"))
    test.assertEqual(nil, config:Set("generalGapMinutes", 24 * 60 + 1, START, "boss"))
    test.assertTrue(config:Set("generalGapMinutes", 15, START, "boss") ~= nil)
    test.assertTrue(config:Set("tradeGapMinutes", 5, START, "boss") ~= nil)
    test.assertEqual(15, config:Get("generalGapMinutes"))
    test.assertEqual(5, config:Get("tradeGapMinutes"))

    -- A received gap under the minimum is refused too.
    test.assertFalse(config:Apply("tradeGapMinutes", { value = 1, at = START + 9, by = "boss" }))
    test.assertEqual(5, config:Get("tradeGapMinutes"))
end)

test.test("recruit config: every setting follows newest wins on its own", function()
    local _, config = setup()
    local values = {
        generalGapMinutes = { 45, 90 },
        tradeGapMinutes = { 10, 30 },
        paused = { true, false },
    }
    local name, pair
    for name, pair in pairs(values) do
        test.assertTrue(config:Apply(name, { value = pair[1], at = START + 10, by = "boss" }), name)
        test.assertFalse(config:Apply(name, { value = pair[2], at = START + 9, by = "lieutenant" }), name)
        test.assertEqual(pair[1], config:Get(name), name)
        test.assertTrue(config:Apply(name, { value = pair[2], at = START + 11, by = "boss" }), name)
        test.assertEqual(pair[2], config:Get(name), name)
    end
    -- Settings change independently.
    test.assertEqual("", config:Get("guildAd"))
end)

test.test("recruit config: the ledger's fresh and stale decisions follow the configured gaps", function()
    local addon = test.newAddon("Core/SyncFacts.lua", "Core/RecruitConfig.lua", "Core/RecruitLedger.lua",
        "Core/RecruitPolicy.lua", "Core/GuildRecruit.lua")
    local config = addon.RecruitConfig.Create({}, { isOfficer = function() return true end })
    local ledger = addon.RecruitLedger.Create({}, function(key)
        return addon.GuildRecruit.GapOf(key, config)
    end)
    local general = addon.RecruitLedger.GeneralKey("map:1")
    ledger:Record(general, START)
    ledger:Record(addon.RecruitLedger.TRADE_KEY, START)

    -- Defaults: 60 and 20 minutes.
    test.assertEqual(addon.RecruitLedger.FRESH, ledger:State(general, START + 59 * 60))
    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(addon.RecruitLedger.TRADE_KEY, START + 20 * 60))

    config:Set("generalGapMinutes", 15, START, "boss")
    config:Set("tradeGapMinutes", 30, START, "boss")
    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(general, START + 15 * 60))
    test.assertEqual(addon.RecruitLedger.FRESH, ledger:State(addon.RecruitLedger.TRADE_KEY, START + 29 * 60))
end)
