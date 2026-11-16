local test = require("tests.test_helper")

local START = 1790000000
local LIFETIME = 100

-- A monitor with the guild's settings in `settings` (threshold, cooldown),
-- recording each turn on or off in `changes`.
local function newMonitor(settings)
    settings = settings or {}
    local addon = test.newAddon("Core/AntiSpamMonitor.lua")
    local changes = {}
    local monitor = addon.AntiSpamMonitor.Create({
        threshold = function()
            return settings.threshold or 8
        end,
        cooldownSeconds = function()
            return settings.cooldown or 15
        end,
        lifetime = LIFETIME,
        onChange = function(on)
            table.insert(changes, on)
        end,
    })
    return monitor, changes, addon
end

-- Character "c<n>" of player "p<n>" arriving at `at`.
local function arrive(monitor, n, at)
    return monitor:Arrived("c" .. n, "p" .. n, "C" .. n, at)
end

test.test("anti-spam monitor: the threshold's arrivals within 2 minutes turn it on", function()
    local monitor, changes = newMonitor()
    local n
    for n = 1, 7 do
        arrive(monitor, n, START + (n - 1) * 17)
    end
    test.assertFalse(monitor:IsOn())

    arrive(monitor, 8, START + 119)

    test.assertTrue(monitor:IsOn())
    test.assertEqual(1, #changes)
    test.assertEqual(true, changes[1])
end)

test.test("anti-spam monitor: the same arrivals spread just past 2 minutes don't", function()
    local monitor, changes = newMonitor()
    local n
    for n = 1, 7 do
        arrive(monitor, n, START + (n - 1) * 17)
    end

    arrive(monitor, 8, START + 120)

    test.assertFalse(monitor:IsOn())
    test.assertEqual(0, #changes)
end)

test.test("anti-spam monitor: the officers' threshold is used", function()
    local settings = { threshold = 3 }
    local monitor = newMonitor(settings)
    arrive(monitor, 1, START)
    arrive(monitor, 2, START + 1)
    test.assertFalse(monitor:IsOn())
    arrive(monitor, 3, START + 2)
    test.assertTrue(monitor:IsOn())
end)

test.test("anti-spam monitor: a character counts once within a few minutes, and a join never", function()
    local monitor, _, addon = newMonitor({ threshold = 3 })
    local dedupe = addon.AntiSpamMonitor.DEDUPE_SECONDS

    test.assertTrue(monitor:Arrived("c1", "p1", "C1", START))
    test.assertFalse(monitor:Arrived("c1", "p1", "C1", START + 10))
    test.assertFalse(monitor:Arrived("c1", "p1", "C1", START + dedupe - 1))
    monitor:Joined("newt", START + 20)
    test.assertFalse(monitor:Arrived("newt", "pn", "Newt", START + 21))
    test.assertFalse(monitor:IsOn())

    -- Another character of the same player is another arrival.
    test.assertTrue(monitor:Arrived("c1alt", "p1", "C1alt", START + 30))
    test.assertTrue(monitor:Arrived("c1", "p1", "C1", START + dedupe + 1))
end)

test.test("anti-spam monitor: a player stops waiting when greeted, gone offline, or too long ago", function()
    local monitor = newMonitor()
    arrive(monitor, 1, START)
    arrive(monitor, 2, START)
    arrive(monitor, 3, START + 50)
    test.assertEqual(3, #monitor:Waiting(START + 50))

    test.assertTrue(monitor:Greeted("p1", START + 60))
    test.assertFalse(monitor:Greeted("p1", START + 61))
    test.assertTrue(monitor:Left("p2", START + 62))
    test.assertEqual(1, #monitor:Waiting(START + 62))
    test.assertEqual("C3", monitor:Waiting(START + 62)[1].rawName)

    test.assertTrue(monitor:HasWaiting(START + 50 + LIFETIME - 1))
    test.assertFalse(monitor:HasWaiting(START + 50 + LIFETIME))
end)

-- A monitor that has just turned on with 8 players waiting (threshold 8,
-- cooldown 15: it turns off after 150 seconds calm).
local function busy()
    local monitor, changes, addon = newMonitor()
    local n
    for n = 1, 8 do
        arrive(monitor, n, START)
    end
    test.assertTrue(monitor:IsOn())
    return monitor, changes, addon
end

test.test("anti-spam monitor: it turns off after 10 x the cooldown with 2 or fewer waiting", function()
    local monitor, changes = busy()
    local n
    for n = 1, 6 do
        monitor:Greeted("p" .. n, START + 10)
    end
    -- Two are still waiting: that's calm, from the 6th greeting.
    test.assertEqual(START + 10 + 150, monitor:NextCheckAt(START + 10))
    monitor:Update(START + 10 + 149)
    test.assertTrue(monitor:IsOn())

    monitor:Update(START + 10 + 150)
    test.assertFalse(monitor:IsOn())
    test.assertEqual(2, #changes)
    test.assertEqual(false, changes[2])
    test.assertEqual(nil, monitor:NextCheckAt(START + 10 + 150))
end)

test.test("anti-spam monitor: more than 2 waiting again restarts the exit clock", function()
    local monitor = busy()
    local n
    for n = 1, 6 do
        monitor:Greeted("p" .. n, START + 10)
    end
    -- Calm since +10, then three more arrive: five waiting.
    arrive(monitor, 9, START + 50)
    arrive(monitor, 10, START + 50)
    arrive(monitor, 11, START + 50)
    test.assertEqual(5, #monitor:Waiting(START + 50))
    monitor:Greeted("p9", START + 60)
    monitor:Greeted("p10", START + 60)
    monitor:Greeted("p11", START + 60)

    -- Calm again from +60, not +10.
    monitor:Update(START + 10 + 150)
    test.assertTrue(monitor:IsOn())
    monitor:Update(START + 60 + 149)
    test.assertTrue(monitor:IsOn())
    monitor:Update(START + 60 + 150)
    test.assertFalse(monitor:IsOn())
end)

test.test("anti-spam monitor: arrivals aging out count toward calm from when they aged out", function()
    local monitor = busy()

    -- Nobody is greeted: all 8 age out at once after the lifetime.
    test.assertEqual(START + LIFETIME, monitor:NextCheckAt(START + 1))
    monitor:Update(START + LIFETIME + 5)
    test.assertEqual(0, #monitor:Waiting(START + LIFETIME + 5))
    test.assertTrue(monitor:IsOn())
    test.assertEqual(START + LIFETIME + 150, monitor:NextCheckAt(START + LIFETIME + 5))
    monitor:Update(START + LIFETIME + 150)
    test.assertFalse(monitor:IsOn())
end)

test.test("anti-spam monitor: the officers' cooldown sets the exit time", function()
    local monitor = newMonitor({ threshold = 3, cooldown = 5 })
    arrive(monitor, 1, START)
    arrive(monitor, 2, START)
    arrive(monitor, 3, START)
    monitor:Greeted("p1", START)

    monitor:Update(START + 49)
    test.assertTrue(monitor:IsOn())
    monitor:Update(START + 50)
    test.assertFalse(monitor:IsOn())
end)

test.test("anti-spam monitor: a failing setting falls back to the defaults", function()
    local addon = test.newAddon("Core/AntiSpamMonitor.lua")
    local monitor = addon.AntiSpamMonitor.Create({
        threshold = function() error("boom") end,
        cooldownSeconds = function() error("boom") end,
        lifetime = LIFETIME,
    })
    local n
    for n = 1, 7 do
        arrive(monitor, n, START)
    end
    test.assertFalse(monitor:IsOn())
    arrive(monitor, 8, START)
    test.assertTrue(monitor:IsOn())
    test.assertEqual(150, monitor:ExitSeconds())
end)

test.test("anti-spam monitor: a flagged greeting turns it on with the sender's calm, only in the first window", function()
    local monitor, changes = newMonitor()
    monitor:Started(START)

    test.assertTrue(monitor:Heard(START + 30, START + 40))
    test.assertTrue(monitor:IsOn())
    test.assertEqual(true, changes[1])
    test.assertEqual(START + 30, monitor:CalmSince(START + 40))
    -- It ends when the sender's calm has lasted 150 seconds.
    monitor:Update(START + 30 + 149)
    test.assertTrue(monitor:IsOn())
    monitor:Update(START + 30 + 150)
    test.assertFalse(monitor:IsOn())

    -- After a full window online, flags are ignored.
    test.assertFalse(monitor:Heard(nil, START + 120))
    test.assertFalse(monitor:IsOn())
end)

test.test("anti-spam monitor: a flag from a busy sender keeps it from counting calm", function()
    local monitor = newMonitor()
    monitor:Started(START)

    monitor:Heard(START + 10, START + 20)
    monitor:Heard(nil, START + 50)

    test.assertEqual(nil, monitor:CalmSince(START + 50))
    -- Once the window ends it goes by its own count: nobody is waiting
    -- here, so it's calm from then.
    test.assertEqual(START + 120, monitor:NextCheckAt(START + 50))
    monitor:Update(START + 120)
    test.assertEqual(START + 120, monitor:CalmSince(START + 120))
    monitor:Update(START + 270)
    test.assertFalse(monitor:IsOn())
    -- Without a roster loaded yet, nothing is taken.
    local fresh = newMonitor()
    test.assertFalse(fresh:Heard(nil, START))
    test.assertEqual(nil, fresh:CalmSince(START))
end)
