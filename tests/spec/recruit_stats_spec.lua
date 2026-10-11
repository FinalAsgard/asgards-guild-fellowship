local test = require("tests.test_helper")

local START = 1790000000
local DAY = 24 * 60 * 60

local function load()
    return test.newAddon("Core/RecruitStats.lua")
end

test.test("recruit stats: a report replaces the held record only when its total is higher", function()
    local addon = load()
    local saved = {}
    local stats = addon.RecruitStats.Create(saved)

    test.assertTrue(stats:File("anvil-area52", { n = 5, t = { START } }))
    test.assertFalse(stats:File("anvil-area52", { n = 4, t = { START, START + 1 } }))
    test.assertFalse(stats:File("anvil-area52", { n = 5, t = {} }))
    test.assertEqual(5, saved["anvil-area52"].n)
    test.assertTrue(stats:File("anvil-area52", { n = 6, t = { START, START + 60 } }))
    test.assertEqual(6, saved["anvil-area52"].n)
    test.assertEqual(2, #saved["anvil-area52"].t)
end)

test.test("recruit stats: malformed reports are ignored", function()
    local addon = load()
    local stats = addon.RecruitStats.Create({})

    test.assertFalse(stats:File("anvil-area52", "lots"))
    test.assertFalse(stats:File("anvil-area52", { n = -1, t = {} }))
    test.assertFalse(stats:File("anvil-area52", { n = 1.5, t = {} }))
    test.assertFalse(stats:File("anvil-area52", { n = 2, t = { "yesterday" } }))
    test.assertFalse(stats:File("anvil-area52", { n = 2 }))
    test.assertFalse(stats:File(nil, { n = 2, t = {} }))
end)

test.test("recruit stats: a player's characters add up to their highest record", function()
    local addon = load()
    local stats = addon.RecruitStats.Create({})
    -- The same account's record, heard from its main and later its alt.
    stats:File("anvil-area52", { n = 3, t = { START } })
    stats:File("tongs-area52", { n = 7, t = { START, START + 1 } })

    test.assertEqual(7, stats:Best({ "anvil-area52", "tongs-area52" }).n)
    test.assertEqual(nil, stats:Best({ "bolt-area52" }))
end)

test.test("recruit stats: the 30-day count falls as ads age out, with no new report", function()
    local addon = load()
    local record = { n = 9, t = { START, START + 10 * DAY, START + 20 * DAY } }

    test.assertEqual("Advertised: 9 (3 in last 30 days)", addon.RecruitStats.Line(record, START + 20 * DAY))
    test.assertEqual("Advertised: 9 (2 in last 30 days)", addon.RecruitStats.Line(record, START + 30 * DAY))
    test.assertEqual("Advertised: 9 (0 in last 30 days)", addon.RecruitStats.Line(record, START + 60 * DAY))
    test.assertEqual(nil, addon.RecruitStats.Line(nil, START))
end)

test.test("recruit stats: the user's own record counts each ad and drops old times", function()
    local addon = load()
    local record = { n = 0, t = {} }

    local report = addon.RecruitStats.AddOwn(record, START)
    test.assertEqual(1, record.n)
    test.assertEqual(1, report.n)
    addon.RecruitStats.AddOwn(record, START + 31 * DAY)
    test.assertEqual(2, record.n)
    test.assertEqual(1, #record.t)
    test.assertEqual(START + 31 * DAY, record.t[1])
    -- The report sent is a copy.
    test.assertEqual(1, #report.t)

    local broken = { n = "lots" }
    addon.RecruitStats.AddOwn(broken, START)
    test.assertEqual(1, broken.n)
end)
