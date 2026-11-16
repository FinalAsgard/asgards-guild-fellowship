local test = require("tests.test_helper")

local START = 1790000000
local MINUTE = 60

local function newStats()
    local addon = test.newAddon("Core/GreetStats.lua")
    return addon.GreetStats.Create(), addon
end

test.test("greet stats: nothing counted yet", function()
    local stats = newStats()

    local report = stats:Report(START)

    test.assertEqual(0, report.hour.greetings)
    test.assertEqual(0, report.session.arrivals)
    test.assertEqual(0, report.session.antiSpamSeconds)
    test.assertFalse(report.on)
end)

test.test("greet stats: the last hour drops what's older, the session keeps it", function()
    local stats = newStats()
    stats:Greeting(START)
    stats:Arrival(START)
    stats:Greeting(START + 30 * MINUTE)
    stats:Arrival(START + 30 * MINUTE)
    stats:Arrival(START + 50 * MINUTE)

    local report = stats:Report(START + 59 * MINUTE)
    test.assertEqual(2, report.hour.greetings)
    test.assertEqual(3, report.hour.arrivals)

    -- An hour after the first: it's out of the hour.
    report = stats:Report(START + 60 * MINUTE)
    test.assertEqual(1, report.hour.greetings)
    test.assertEqual(2, report.hour.arrivals)
    test.assertEqual(2, report.session.greetings)
    test.assertEqual(3, report.session.arrivals)

    report = stats:Report(START + 3 * 60 * MINUTE)
    test.assertEqual(0, report.hour.greetings)
    test.assertEqual(0, report.hour.arrivals)
    test.assertEqual(2, report.session.greetings)
    test.assertEqual(3, report.session.arrivals)
end)

test.test("greet stats: time in anti-spam mode adds up across turning on and off", function()
    local stats = newStats()
    stats:ModeChanged(true, START)
    stats:ModeChanged(false, START + 10 * MINUTE)
    stats:ModeChanged(true, START + 20 * MINUTE)

    -- On again, for 5 minutes so far.
    local report = stats:Report(START + 25 * MINUTE)
    test.assertTrue(report.on)
    test.assertEqual(15 * MINUTE, report.hour.antiSpamSeconds)
    test.assertEqual(15 * MINUTE, report.session.antiSpamSeconds)

    stats:ModeChanged(false, START + 30 * MINUTE)
    report = stats:Report(START + 30 * MINUTE)
    test.assertFalse(report.on)
    test.assertEqual(20 * MINUTE, report.session.antiSpamSeconds)

    -- 65 minutes in: only the last 5 of the first spell's 10 minutes, and
    -- all of the second, are within the hour.
    report = stats:Report(START + 65 * MINUTE)
    test.assertEqual(15 * MINUTE, report.hour.antiSpamSeconds)
    test.assertEqual(20 * MINUTE, report.session.antiSpamSeconds)

    report = stats:Report(START + 3 * 60 * MINUTE)
    test.assertEqual(0, report.hour.antiSpamSeconds)
    test.assertEqual(20 * MINUTE, report.session.antiSpamSeconds)
end)

test.test("greet stats: a spell still on counts up to now, the hour at most an hour", function()
    local stats = newStats()
    stats:ModeChanged(true, START)
    -- Turning on again while on changes nothing.
    stats:ModeChanged(true, START + MINUTE)

    local report = stats:Report(START + 90 * MINUTE)
    test.assertTrue(report.on)
    test.assertEqual(60 * MINUTE, report.hour.antiSpamSeconds)
    test.assertEqual(90 * MINUTE, report.session.antiSpamSeconds)

    -- Off twice counts once.
    stats:ModeChanged(false, START + 90 * MINUTE)
    stats:ModeChanged(false, START + 95 * MINUTE)
    test.assertEqual(90 * MINUTE, stats:Report(START + 95 * MINUTE).session.antiSpamSeconds)
end)

test.test("greet stats: the lines show the hour, the session, the mode now and the officer settings", function()
    local stats, addon = newStats()
    stats:Greeting(START)
    stats:Arrival(START)
    stats:ModeChanged(true, START)

    local lines = addon.GreetStats.Lines(stats:Report(START + 4 * MINUTE + 30), 8, 15)

    test.assertEqual("  Last hour: 1 greeting lines, 1 arrivals, 4m 30s in anti-spam mode", lines[1])
    test.assertEqual("  This session: 1 greeting lines, 1 arrivals, 4m 30s in anti-spam mode", lines[2])
    test.assertEqual("  Anti-spam mode is on now.", lines[3])
    test.assertEqual("  Officer settings: on at 8 arrivals in 2 minutes, 15s guild cooldown.", lines[4])
    test.assertEqual("1h 05m", addon.GreetStats.Duration(65 * MINUTE))
    test.assertEqual("45s", addon.GreetStats.Duration(45))
end)
