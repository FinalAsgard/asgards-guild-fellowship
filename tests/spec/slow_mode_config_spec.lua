local test = require("tests.test_helper")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua",
        "Core/RecruitConfig.lua",
        "Core/SlowModeConfig.lua"
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
        world.database = { schemaVersion = 1, guilds = {} }
        local store = addon.FellowshipStore.Create(world.database)
        world.partition = store:Partition({ name = "Knights", realm = "Camelot" })
    end
    world.config = addon.SlowModeConfig.Create({
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

local function change(value, at, by)
    return { v = 1, t = "slowmode-config", s = { slowModeMinutes = { value = value, at = at, by = by } } }
end

test.test("slow mode config: off (0) until an officer changes it, from 0 to 15 minutes", function()
    local addon, world = newConfig("bob ward-camelot")

    test.assertEqual(0, world.config:Minutes())
    -- Reading it saves nothing (it's read on every prompt redraw).
    test.assertEqual(nil, world.partition:PeekSlowModeConfig())
    -- Outside a guild too.
    world.partition = nil
    test.assertEqual(0, world.config:Minutes())
    test.assertEqual(0, addon.SlowModeConfig.SETTINGS.slowModeMinutes.min)
    test.assertEqual(15, addon.SlowModeConfig.SETTINGS.slowModeMinutes.max)
end)

test.test("slow mode config: an officer's change is saved per guild, shared, and lasts across a reload", function()
    local addon, world = newConfig("tool box-camelot")

    test.assertTrue(world.config:SetMinutes(5))

    test.assertEqual(5, world.config:Minutes())
    test.assertEqual(1, world.changes)
    local last = world.sent[#world.sent]
    test.assertEqual("slowmode-config", last.t)
    test.assertEqual(5, last.s.slowModeMinutes.value)
    test.assertEqual("tool box-camelot", last.s.slowModeMinutes.by)

    local _, reloaded = newConfig("tool box-camelot", { addon = addon, partition = world.partition })
    test.assertEqual(5, reloaded.config:Minutes())

    -- Setting the value it already has changes and sends nothing.
    local sent = #world.sent
    test.assertTrue(world.config:SetMinutes(5))
    test.assertEqual(sent, #world.sent)

    -- Back to 0 turns it off, and that's shared too.
    test.assertTrue(world.config:SetMinutes(0))
    test.assertEqual(0, world.config:Minutes())
    test.assertEqual(0, world.sent[#world.sent].s.slowModeMinutes.value)
end)

test.test("slow mode config: the saved partition with the new container passes the schema check", function()
    local addon, world = newConfig("tool box-camelot")
    world.config:SetMinutes(7)

    local again = addon.FellowshipStore.Create(world.database)
    local partition = again:Partition({ name = "Knights", realm = "Camelot" })

    test.assertTrue(partition ~= nil)
    test.assertEqual(7, partition:GetSlowModeConfig().slowModeMinutes.value)
end)

test.test("slow mode config: only whole numbers from 0 to 15 are accepted", function()
    local _, world = newConfig("tool box-camelot")

    local bad = { -1, 16, 2.5, "5", true }
    local index
    for index = 1, #bad do
        local ok, reason = world.config:SetMinutes(bad[index])
        test.assertEqual(nil, ok)
        test.assertEqual("it must be a whole number from 0 to 15", reason)
    end
    test.assertTrue(world.config:SetMinutes(15))
    test.assertTrue(world.config:SetMinutes(0))
end)

test.test("slow mode config: only officers can change it", function()
    local _, world = newConfig("bob ward-camelot")

    local ok, reason = world.config:SetMinutes(5)

    test.assertEqual(nil, ok)
    test.assertEqual("only officers can change it", reason)
    test.assertEqual(0, world.config:Minutes())
    test.assertEqual(0, #world.sent)
end)

test.test("slow mode config: a received change applies only from officers, in range, and when newer", function()
    local _, officer = newConfig("tool box-camelot", { time = 2000 })
    local _, member = newConfig("bob ward-camelot")
    officer.config:SetMinutes(5)
    local message = officer.sent[#officer.sent]

    -- A non-officer sender, or a change authored by a non-officer, is ignored.
    test.assertFalse(member.config:OnMessage(message, "Cal Dorn"))
    test.assertFalse(member.config:OnMessage(change(9, 3000, "cal dorn-camelot"), "Tool Box"))
    -- Out of range or not whole, even from an officer, is ignored.
    test.assertFalse(member.config:OnMessage(change(16, 3000, "tool box-camelot"), "Tool Box"))
    test.assertFalse(member.config:OnMessage(change(7.5, 3000, "tool box-camelot"), "Tool Box"))
    test.assertEqual(0, member.config:Minutes())

    test.assertTrue(member.config:OnMessage(message, "Tool Box"))
    test.assertEqual(5, member.config:Minutes())
    test.assertEqual(1, member.changes)

    -- An older change loses; a newer one wins.
    test.assertFalse(member.config:OnMessage(change(10, 1500, "ann bell-camelot"), "Ann Bell"))
    test.assertEqual(5, member.config:Minutes())
    test.assertTrue(member.config:OnMessage(change(10, 2500, "ann bell-camelot"), "Ann Bell"))
    test.assertEqual(10, member.config:Minutes())
end)

test.test("slow mode config: two officers' changes at the same moment settle on one value everywhere", function()
    local addon, first = newConfig("tool box-camelot", { time = 1000 })
    local _, second = newConfig("ann bell-camelot", { addon = addon, time = 1000 })
    first.config:SetMinutes(3)
    second.config:SetMinutes(12)

    first.config:OnMessage(second.sent[#second.sent], "Ann Bell")
    second.config:OnMessage(first.sent[#first.sent], "Tool Box")

    test.assertEqual(first.config:Minutes(), second.config:Minutes())
end)

test.test("slow mode config: an officer holding a newer change sends it back on hearing an older one", function()
    local addon, newer = newConfig("tool box-camelot", { time = 2000 })
    local _, older = newConfig("ann bell-camelot", { addon = addon, time = 1000 })
    older.config:SetMinutes(3)
    newer.config:SetMinutes(9)
    local sent = #newer.sent

    test.assertFalse(newer.config:OnMessage(older.sent[#older.sent], "Ann Bell"))
    test.assertEqual(sent + 1, #newer.sent)
    test.assertEqual(9, newer.sent[#newer.sent].s.slowModeMinutes.value)

    -- The older side takes it and sends nothing back, so there's no loop.
    local olderSent = #older.sent
    test.assertTrue(older.config:OnMessage(newer.sent[#newer.sent], "Tool Box"))
    test.assertEqual(9, older.config:Minutes())
    test.assertEqual(olderSent, #older.sent)

    -- The same change heard again isn't resent.
    test.assertFalse(newer.config:OnMessage(older.sent[#older.sent], "Ann Bell"))
    test.assertFalse(older.config:OnMessage(newer.sent[#newer.sent], "Tool Box"))
    test.assertEqual(olderSent, #older.sent)

    -- A member's add-on never answers with its own copy.
    local _, member = newConfig("bob ward-camelot", { addon = addon })
    member.config:OnMessage(newer.sent[#newer.sent], "Tool Box")
    member.config:OnMessage(change(1, 500, "ann bell-camelot"), "Ann Bell")
    test.assertEqual(0, #member.sent)
end)

test.test("slow mode config: an add-on asks once, a while after the rank scan, and an officer answers", function()
    local _, officer = newConfig("tool box-camelot")
    local _, member = newConfig("bob ward-camelot")
    officer.config:SetMinutes(4)

    test.assertTrue(member.config:AskOnce())
    test.assertFalse(member.config:AskOnce())
    test.assertEqual(0, #member.sent)
    test.assertEqual(120, member.timers[1].seconds)
    runTimers(member)
    test.assertEqual(1, #member.sent)
    local askMessage = member.sent[1]
    test.assertEqual("ask-slowmode-config", askMessage.t)

    -- A member doesn't answer; the officer does, after a short wait.
    local _, other = newConfig("cal dorn-camelot")
    test.assertFalse(other.config:OnMessage(askMessage, "Bob Ward"))
    local sent = #officer.sent
    test.assertTrue(officer.config:OnMessage(askMessage, "Bob Ward"))
    test.assertEqual(sent, #officer.sent)
    runTimers(officer)
    local answer = officer.sent[#officer.sent]
    test.assertEqual("slowmode-config", answer.t)

    test.assertTrue(member.config:OnMessage(answer, "Tool Box"))
    test.assertEqual(4, member.config:Minutes())
end)

test.test("slow mode config: after a guild change without a reload, the new guild is asked too", function()
    local addon, member = newConfig("bob ward-camelot")
    local _, officer = newConfig("tool box-camelot", { addon = addon })
    officer.config:SetMinutes(4)
    member.config:AskOnce()
    member.config:OnMessage(officer.sent[#officer.sent], "Tool Box")
    runTimers(member)
    test.assertEqual(0, #member.sent, "heard in the first guild, so no ask there")

    local store = addon.FellowshipStore.Create(member.database)
    member.partition = store:Partition({ name = "Squires", realm = "Camelot" })

    test.assertTrue(member.config:AskOnce())
    test.assertFalse(member.config:AskOnce())
    runTimers(member)
    test.assertEqual(1, #member.sent)
    test.assertEqual("ask-slowmode-config", member.sent[1].t)
end)

test.test("slow mode config: leaving a guild before its ask goes out asks it again on return", function()
    local addon, member = newConfig("bob ward-camelot")
    local knights = member.partition
    member.config:AskOnce()

    local store = addon.FellowshipStore.Create(member.database)
    member.partition = store:Partition({ name = "Squires", realm = "Camelot" })
    runTimers(member)
    test.assertEqual(0, #member.sent, "not sent to the guild the user left")

    member.partition = knights
    test.assertTrue(member.config:AskOnce())
    runTimers(member)
    test.assertEqual(1, #member.sent)
    test.assertEqual("ask-slowmode-config", member.sent[1].t)
    test.assertFalse(member.config:AskOnce())
end)

test.test("slow mode config: the ask isn't sent once an officer's setting was heard", function()
    local _, officer = newConfig("tool box-camelot")
    local _, member = newConfig("bob ward-camelot")
    officer.config:SetMinutes(6)

    member.config:AskOnce()
    member.config:OnMessage(officer.sent[#officer.sent], "Tool Box")
    runTimers(member)

    test.assertEqual(0, #member.sent)
    test.assertEqual(6, member.config:Minutes())
end)

test.test("slow mode config: an officer's answer is dropped when another answer covers it", function()
    local addon, first = newConfig("tool box-camelot")
    local _, second = newConfig("ann bell-camelot", { addon = addon, partition = first.partition })
    first.config:SetMinutes(8)
    local ask = { v = 1, t = "ask-slowmode-config" }

    test.assertTrue(second.config:OnMessage(ask, "Bob Ward"))
    second.config:OnMessage(first.sent[#first.sent], "Tool Box")
    local sent = #second.sent
    runTimers(second)

    test.assertEqual(sent, #second.sent)
end)

test.test("slow mode config: an officer with nothing changed doesn't answer; own and unknown messages are ignored",
    function()
        local _, officer = newConfig("tool box-camelot")

        test.assertFalse(officer.config:OnMessage({ v = 1, t = "ask-slowmode-config" }, "Bob Ward"))
        officer.config:SetMinutes(2)
        test.assertFalse(officer.config:OnMessage({ v = 1, t = "ask-slowmode-config" }, "Tool Box"))
        test.assertFalse(officer.config:OnMessage(officer.sent[#officer.sent], "Tool Box"))
        test.assertFalse(officer.config:OnMessage({ v = 1, t = "something-else" }, "Bob Ward"))
        test.assertFalse(officer.config:OnMessage({ v = 2, t = "slowmode-config", s = {} }, "Ann Bell"))
    end)
