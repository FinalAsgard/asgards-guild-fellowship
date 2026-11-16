local test = require("tests.test_helper")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua",
        "Core/RecruitConfig.lua",
        "Core/AntiSpamConfig.lua"
    )
end

local OFFICERS = { ["tool box-camelot"] = true, ["ann bell-camelot"] = true }

-- One add-on: `key` is the logged-in character, and every message it
-- announces lands in `world.sent`; timers wait in `world.timers` with their
-- delays. `options.partition` shares saved data (a reload).
local function newConfig(key, options)
    options = options or {}
    local addon = options.addon or load()
    local world = { sent = {}, changes = 0, time = options.time or 1000, timers = {} }
    if options.partition ~= nil then
        world.partition = options.partition
    else
        local store = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        world.partition = store:Partition({ name = "Knights", realm = "Camelot" })
    end
    world.config = addon.AntiSpamConfig.Create({
        partition = function()
            return world.partition
        end,
        selfKey = function()
            return key
        end,
        isOfficer = function(character)
            return OFFICERS[character] == true
        end,
        senderIsOfficer = function(sender)
            return OFFICERS[string.lower(sender) .. "-camelot"] == true
        end,
        isOwn = function(sender)
            return string.lower(sender) .. "-camelot" == key
        end,
        now = function()
            return world.time
        end,
        announce = function(message)
            table.insert(world.sent, message)
            return true
        end,
        random = function(low)
            return low
        end,
        after = function(seconds, callback)
            table.insert(world.timers, { seconds = seconds, callback = callback })
            return true
        end,
        onChange = function()
            world.changes = world.changes + 1
        end,
    })
    return addon, world
end

local function runTimers(world)
    local timers = world.timers
    world.timers = {}
    local index
    for index = 1, #timers do
        timers[index].callback()
    end
end

test.test("anti-spam config: defaults to 8 arrivals and a 15-second cooldown", function()
    local addon, world = newConfig("bob ward-camelot")

    test.assertEqual(8, world.config:Threshold())
    test.assertEqual(15, world.config:CooldownSeconds())
    -- Outside a guild too.
    world.partition = nil
    test.assertEqual(8, world.config:Threshold())
    test.assertEqual(15, world.config:CooldownSeconds())
    test.assertEqual(3, addon.AntiSpamConfig.SETTINGS.threshold.min)
    test.assertEqual(30, addon.AntiSpamConfig.SETTINGS.threshold.max)
    test.assertEqual(5, addon.AntiSpamConfig.SETTINGS.cooldownSeconds.min)
    test.assertEqual(60, addon.AntiSpamConfig.SETTINGS.cooldownSeconds.max)
end)

test.test("anti-spam config: an officer's change is saved, shared, and lasts across a reload", function()
    local addon, world = newConfig("tool box-camelot")

    test.assertTrue(world.config:Set("threshold", 12))
    test.assertTrue(world.config:Set("cooldownSeconds", 30))

    test.assertEqual(12, world.config:Threshold())
    test.assertEqual(30, world.config:CooldownSeconds())
    test.assertEqual(2, world.changes)
    local last = world.sent[#world.sent]
    test.assertEqual("antispam-config", last.t)
    test.assertEqual(12, last.s.threshold.value)
    test.assertEqual(30, last.s.cooldownSeconds.value)
    test.assertEqual("tool box-camelot", last.s.threshold.by)

    local _, reloaded = newConfig("tool box-camelot", { addon = addon, partition = world.partition })
    test.assertEqual(12, reloaded.config:Threshold())
    test.assertEqual(30, reloaded.config:CooldownSeconds())

    -- Setting the value it already has changes and sends nothing.
    local sent = #world.sent
    test.assertTrue(world.config:Set("threshold", 12))
    test.assertEqual(sent, #world.sent)
end)

test.test("anti-spam config: values out of range or not whole are refused", function()
    local _, world = newConfig("tool box-camelot")

    local bad = {
        { "threshold", 2 }, { "threshold", 31 }, { "threshold", 8.5 }, { "threshold", "8" },
        { "cooldownSeconds", 4 }, { "cooldownSeconds", 61 }, { "cooldownSeconds", 15.5 }, { "cooldownSeconds", true },
    }
    local index
    for index = 1, #bad do
        local ok, reason = world.config:Set(bad[index][1], bad[index][2])
        test.assertEqual(nil, ok)
        test.assertContains(reason, "whole number")
    end
    test.assertTrue(world.config:Set("threshold", 3))
    test.assertTrue(world.config:Set("threshold", 30))
    test.assertTrue(world.config:Set("cooldownSeconds", 5))
    test.assertTrue(world.config:Set("cooldownSeconds", 60))
    test.assertEqual(nil, world.config:Set("nonsense", 10))
end)

test.test("anti-spam config: only officers can change it", function()
    local _, world = newConfig("bob ward-camelot")

    local ok, reason = world.config:Set("threshold", 12)

    test.assertEqual(nil, ok)
    test.assertEqual("only officers can change it", reason)
    test.assertEqual(8, world.config:Threshold())
    test.assertEqual(0, #world.sent)
end)

test.test("anti-spam config: a received change applies only from officers, in range, and when newer", function()
    local _, officer = newConfig("tool box-camelot", { time = 2000 })
    local _, member = newConfig("bob ward-camelot")
    officer.config:Set("threshold", 12)
    local message = officer.sent[#officer.sent]

    -- A non-officer sender, or a change authored by a non-officer, is ignored.
    test.assertFalse(member.config:OnMessage(message, "Bob Ward"))
    test.assertFalse(member.config:OnMessage(message, "Cal Dorn"))
    test.assertFalse(member.config:OnMessage({
        v = 1, t = "antispam-config", s = { threshold = { value = 20, at = 3000, by = "cal dorn-camelot" } },
    }, "Tool Box"))
    test.assertEqual(8, member.config:Threshold())

    -- Out of range or not whole, even from an officer, is ignored.
    test.assertFalse(member.config:OnMessage({
        v = 1, t = "antispam-config", s = { threshold = { value = 31, at = 3000, by = "tool box-camelot" } },
    }, "Tool Box"))
    test.assertFalse(member.config:OnMessage({
        v = 1, t = "antispam-config", s = { cooldownSeconds = { value = 7.5, at = 3000, by = "tool box-camelot" } },
    }, "Tool Box"))
    test.assertEqual(8, member.config:Threshold())
    test.assertEqual(15, member.config:CooldownSeconds())

    test.assertTrue(member.config:OnMessage(message, "Tool Box"))
    test.assertEqual(12, member.config:Threshold())
    test.assertEqual(1, member.changes)

    -- An older change loses; a newer one wins.
    test.assertFalse(member.config:OnMessage({
        v = 1, t = "antispam-config", s = { threshold = { value = 20, at = 1500, by = "ann bell-camelot" } },
    }, "Ann Bell"))
    test.assertEqual(12, member.config:Threshold())
    test.assertTrue(member.config:OnMessage({
        v = 1, t = "antispam-config", s = { threshold = { value = 25, at = 2500, by = "ann bell-camelot" } },
    }, "Ann Bell"))
    test.assertEqual(25, member.config:Threshold())
end)

test.test("anti-spam config: two officers' changes settle on the newest everywhere", function()
    local addon, first = newConfig("tool box-camelot", { time = 1000 })
    local _, second = newConfig("ann bell-camelot", { addon = addon, time = 1000 })
    first.config:Set("cooldownSeconds", 20)
    second.config:Set("cooldownSeconds", 40)

    first.config:OnMessage(second.sent[#second.sent], "Ann Bell")
    second.config:OnMessage(first.sent[#first.sent], "Tool Box")

    test.assertEqual(first.config:CooldownSeconds(), second.config:CooldownSeconds())
end)

test.test("anti-spam config: a member's add-on asks once, a while after login, and an officer answers", function()
    local _, officer = newConfig("tool box-camelot")
    local _, member = newConfig("bob ward-camelot")
    officer.config:Set("cooldownSeconds", 25)

    test.assertTrue(member.config:AskOnce())
    test.assertFalse(member.config:AskOnce())
    test.assertEqual(0, #member.sent)
    test.assertEqual(120, member.timers[1].seconds)
    runTimers(member)
    test.assertEqual(1, #member.sent)
    local askMessage = member.sent[1]
    test.assertEqual("ask-antispam-config", askMessage.t)

    -- A member doesn't answer; the officer does, after a short wait.
    local _, other = newConfig("cal dorn-camelot")
    test.assertFalse(other.config:OnMessage(askMessage, "Bob Ward"))
    local sent = #officer.sent
    test.assertTrue(officer.config:OnMessage(askMessage, "Bob Ward"))
    test.assertEqual(sent, #officer.sent)
    runTimers(officer)
    local answer = officer.sent[#officer.sent]
    test.assertEqual("antispam-config", answer.t)

    test.assertTrue(member.config:OnMessage(answer, "Tool Box"))
    test.assertEqual(25, member.config:CooldownSeconds())
end)

test.test("anti-spam config: an ask isn't sent once an officer's settings were heard", function()
    local _, officer = newConfig("tool box-camelot")
    local _, member = newConfig("bob ward-camelot")
    officer.config:Set("threshold", 10)

    member.config:AskOnce()
    member.config:OnMessage(officer.sent[#officer.sent], "Tool Box")
    runTimers(member)

    test.assertEqual(0, #member.sent)
    test.assertEqual(10, member.config:Threshold())
end)

test.test("anti-spam config: an officer's answer is dropped when another answer covers it", function()
    local addon, first = newConfig("tool box-camelot")
    local _, second = newConfig("ann bell-camelot", { addon = addon, partition = first.partition })
    first.config:Set("threshold", 10)
    local ask = { v = 1, t = "ask-antispam-config" }

    test.assertTrue(second.config:OnMessage(ask, "Bob Ward"))
    second.config:OnMessage(first.sent[#first.sent], "Tool Box")
    local sent = #second.sent
    runTimers(second)

    test.assertEqual(sent, #second.sent)
end)

test.test("anti-spam config: an officer with nothing changed doesn't answer, and own messages are ignored", function()
    local _, officer = newConfig("tool box-camelot")

    test.assertFalse(officer.config:OnMessage({ v = 1, t = "ask-antispam-config" }, "Bob Ward"))
    officer.config:Set("threshold", 10)
    test.assertFalse(officer.config:OnMessage({ v = 1, t = "ask-antispam-config" }, "Tool Box"))
    test.assertFalse(officer.config:OnMessage(officer.sent[#officer.sent], "Tool Box"))
    test.assertFalse(officer.config:OnMessage({ v = 1, t = "something-else" }, "Bob Ward"))
end)
