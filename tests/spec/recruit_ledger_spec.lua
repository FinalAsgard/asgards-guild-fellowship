local test = require("tests.test_helper")

local START = 1790000000
local HOUR = 60 * 60

local function load()
    return test.newAddon("Core/RecruitLedger.lua")
end

local function newLedger(addon, saved, gap)
    return addon.RecruitLedger.Create(saved, function()
        return gap or HOUR
    end)
end

test.test("recruit ledger: a channel is fresh within its gap and unknown after it", function()
    local addon = load()
    local ledger = newLedger(addon, {})
    local key = addon.RecruitLedger.GeneralKey("map:1455")

    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(key, START))
    test.assertTrue(ledger:Record(key, START))
    test.assertEqual(addon.RecruitLedger.FRESH, ledger:State(key, START + HOUR - 1))
    -- A time older than the gap is unknown, never "advertised".
    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(key, START + HOUR))
end)

test.test("recruit ledger: the newest time wins", function()
    local addon = load()
    local ledger = newLedger(addon, {})
    local key = addon.RecruitLedger.GeneralKey("map:1455")

    test.assertTrue(ledger:Record(key, START + 100))
    test.assertFalse(ledger:Record(key, START))
    test.assertFalse(ledger:Record(key, START + 100))
    test.assertEqual(START + 100, ledger:Time(key))
    test.assertTrue(ledger:Record(key, START + 200))
    test.assertEqual(START + 200, ledger:Time(key))
    test.assertFalse(ledger:Record(key, "soon"))
    test.assertFalse(ledger:Record(nil, START))
end)

test.test("recruit ledger: each zone's General has its own time", function()
    local addon = load()
    local ledger = newLedger(addon, {})
    local ironforge = addon.RecruitLedger.GeneralKey("map:1455")
    local stormwind = addon.RecruitLedger.GeneralKey("map:1453")

    ledger:Record(ironforge, START)

    test.assertEqual(addon.RecruitLedger.FRESH, ledger:State(ironforge, START + 1))
    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(stormwind, START + 1))
end)

test.test("recruit ledger: times live in the saved table and load back", function()
    local addon = load()
    local saved = {}
    local key = addon.RecruitLedger.GeneralKey("zone:Ironforge")
    newLedger(addon, saved):Record(key, START)

    test.assertEqual(START, saved[key])
    local reloaded = newLedger(addon, saved)
    test.assertEqual(START, reloaded:Time(key))
    test.assertEqual(addon.RecruitLedger.FRESH, reloaded:State(key, START + 60))
end)

test.test("recruit ledger: pruning drops stale and unreadable times and keeps fresh ones", function()
    local addon = load()
    local fresh = addon.RecruitLedger.GeneralKey("map:1")
    local stale = addon.RecruitLedger.GeneralKey("map:2")
    local saved = { [fresh] = START, [stale] = START - HOUR, broken = "yesterday", [7] = START }
    local ledger = newLedger(addon, saved)

    ledger:Prune(START + 10)

    test.assertEqual(START, saved[fresh])
    test.assertEqual(nil, saved[stale])
    test.assertEqual(nil, saved.broken)
    test.assertEqual(nil, saved[7])
end)

test.test("recruit ledger: an unreadable gap counts as unknown and keeps the time", function()
    local addon = load()
    local saved = {}
    local key = addon.RecruitLedger.GeneralKey("map:1")
    local ledger = addon.RecruitLedger.Create(saved, function()
        error("no gap")
    end)

    ledger:Record(key, START)
    ledger:Prune(START + 10 * HOUR)

    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(key, START + 1))
    test.assertEqual(START, saved[key])
end)

test.test("recruit ledger: without a saved table, times are kept in memory", function()
    local addon = load()
    local ledger = newLedger(addon, nil)
    local key = addon.RecruitLedger.GeneralKey("map:1")

    test.assertTrue(ledger:Record(key, START))
    test.assertEqual(START, ledger:Time(key))
end)

test.test("recruit ledger: Trade has one key, and each key has its own gap", function()
    local addon = load()
    local gaps = { [addon.RecruitLedger.TRADE_KEY] = 20 * 60 }
    local ledger = addon.RecruitLedger.Create({}, function(key)
        return gaps[key] or HOUR
    end)
    local general = addon.RecruitLedger.GeneralKey("map:1455")

    ledger:Record(addon.RecruitLedger.TRADE_KEY, START)
    ledger:Record(general, START)

    test.assertEqual(20 * 60 - 60, ledger:FreshFor(addon.RecruitLedger.TRADE_KEY, START + 60))
    test.assertEqual(HOUR - 60, ledger:FreshFor(general, START + 60))
    test.assertEqual(addon.RecruitLedger.UNKNOWN, ledger:State(addon.RecruitLedger.TRADE_KEY, START + 20 * 60))
    test.assertEqual(nil, ledger:FreshFor(addon.RecruitLedger.TRADE_KEY, START + 20 * 60))
    test.assertEqual(addon.RecruitLedger.FRESH, ledger:State(general, START + 20 * 60))
end)
