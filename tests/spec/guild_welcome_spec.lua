local test = require("tests.test_helper")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua",
        "Core/RecruitConfig.lua",
        "Core/GreetingLibrary.lua",
        "Core/GuildGreet.lua",
        "Core/GuildMailComposer.lua",
        "Core/GuildWelcome.lua"
    )
end

local OFFICERS = { ["tool box-camelot"] = true, ["ann bell-camelot"] = true }

-- One officer's add-on: `key` is the logged-in character, and every message
-- it announces lands in `world.sent`. `options.partition` shares saved data
-- (a reload); `options.officers` overrides who's an officer.
local function newWelcome(key, options)
    options = options or {}
    local addon = options.addon or load()
    local world = { sent = {}, changes = 0, time = options.time or 1000, timers = {} }
    if options.partition ~= nil then
        world.partition = options.partition
    else
        local store = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        world.partition = store:Partition({ name = "Knights", realm = "Camelot" })
    end
    local officers = options.officers or OFFICERS
    world.welcome = addon.GuildWelcome.Create({
        partition = function()
            return world.partition
        end,
        selfKey = function()
            return key
        end,
        isOfficer = function(character)
            return officers[character] == true
        end,
        senderIsOfficer = function(sender)
            return officers[string.lower(sender) .. "-camelot"] == true
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
        after = function(seconds, callback)
            table.insert(world.timers, callback)
            return true
        end,
        onChange = function()
            world.changes = world.changes + 1
        end,
    })
    return addon, world
end

test.test("guild welcome: starts off and empty", function()
    local _, world = newWelcome("tool box-camelot")

    test.assertFalse(world.welcome:IsOn())
    test.assertEqual("", world.welcome:Subject())
    test.assertEqual("", world.welcome:Body())
    test.assertEqual(nil, world.welcome:OnSince())
end)

test.test("guild welcome: an officer's change is saved, shared, and lasts across a reload", function()
    local addon, world = newWelcome("tool box-camelot")

    test.assertTrue(world.welcome:Set({ subject = "Welcome, {name}!", body = "Join our Discord." }))
    test.assertEqual("Welcome, {name}!", world.welcome:Subject())
    test.assertEqual(1, #world.sent)
    test.assertEqual(addon.GuildWelcome.TYPE_CONFIG, world.sent[1].t)
    test.assertEqual("Join our Discord.", world.sent[1].s.body.value)
    test.assertEqual("tool box-camelot", world.sent[1].s.body.by)
    test.assertEqual(1, world.changes)

    -- Setting the same text again changes nothing and sends nothing.
    test.assertTrue(world.welcome:Set({ subject = "Welcome, {name}!" }))
    test.assertEqual(1, #world.sent)

    local _, after = newWelcome("tool box-camelot", { addon = addon, partition = world.partition })
    test.assertEqual("Join our Discord.", after.welcome:Body())
end)

test.test("guild welcome: the time it was switched on is kept, and forgotten when it's off", function()
    local _, world = newWelcome("tool box-camelot", { time = 5000 })

    world.welcome:Set({ on = true })
    test.assertTrue(world.welcome:IsOn())
    test.assertEqual(5000, world.welcome:OnSince())
    world.time = 6000
    world.welcome:Set({ on = true })
    test.assertEqual(5000, world.welcome:OnSince())
    world.welcome:Set({ on = false })
    test.assertEqual(nil, world.welcome:OnSince())
    world.time = 7000
    world.welcome:Set({ on = true })
    test.assertEqual(7000, world.welcome:OnSince())
end)

test.test("guild welcome: only officers change it, and only to text that fits a mail", function()
    local _, member = newWelcome("cog wheel-camelot")
    local saved, reason = member.welcome:Set({ subject = "Hi" })
    test.assertEqual(nil, saved)
    test.assertEqual("only officers can change it", reason)

    local _, world = newWelcome("tool box-camelot")
    saved, reason = world.welcome:Set({ subject = string.rep("a", 65) })
    test.assertEqual(nil, saved)
    test.assertEqual("it can't be set to that", reason)
    test.assertEqual(nil, (world.welcome:Set({ on = "yes" })))
    test.assertTrue(world.welcome:Set({ subject = string.rep("a", 64), body = string.rep("b", 500) }))
    test.assertEqual(0, #member.sent)
end)

test.test("guild welcome: two officers' add-ons settle on the newest text", function()
    local addon, tool = newWelcome("tool box-camelot", { time = 1000 })
    local _, ann = newWelcome("ann bell-camelot", { addon = addon, time = 2000 })

    tool.welcome:Set({ subject = "Old" })
    ann.welcome:Set({ subject = "New" })
    test.assertFalse(ann.welcome:OnMessage(tool.sent[1], "Tool Box"))
    test.assertEqual("New", ann.welcome:Subject())
    test.assertTrue(tool.welcome:OnMessage(ann.sent[1], "Ann Bell"))
    test.assertEqual("New", tool.welcome:Subject())
    test.assertTrue(tool.changes >= 2)
end)

test.test("guild welcome: changes from non-officers, from itself, or malformed are ignored", function()
    local addon, tool = newWelcome("tool box-camelot")
    local message = {
        v = addon.GuildWelcome.PROTOCOL, t = addon.GuildWelcome.TYPE_CONFIG,
        s = { subject = { value = "Spam", at = 5000, by = "cog wheel-camelot" } },
    }

    test.assertFalse(tool.welcome:OnMessage(message, "Cog Wheel"))
    -- An officer relaying a change a non-officer wrote.
    test.assertFalse(tool.welcome:OnMessage(message, "Ann Bell"))
    message.s.subject.by = "ann bell-camelot"
    test.assertFalse(tool.welcome:OnMessage(message, "Tool Box"))
    test.assertFalse(tool.welcome:OnMessage({ t = addon.GuildWelcome.TYPE_CONFIG }, "Ann Bell"))
    test.assertEqual("", tool.welcome:Subject())
    test.assertTrue(tool.welcome:OnMessage(message, "Ann Bell"))
    test.assertEqual("Spam", tool.welcome:Subject())
end)

test.test("guild welcome: an officer asks once, and an officer with settings answers unless covered", function()
    local addon, tool = newWelcome("tool box-camelot")
    local _, ann = newWelcome("ann bell-camelot", { addon = addon })

    test.assertTrue(ann.welcome:AskOnce())
    test.assertFalse(ann.welcome:AskOnce())
    test.assertEqual(addon.GuildWelcome.TYPE_ASK_CONFIG, ann.sent[1].t)
    local _, member = newWelcome("cog wheel-camelot", { addon = addon })
    test.assertFalse(member.welcome:AskOnce())

    -- Nothing to answer with yet.
    test.assertFalse(tool.welcome:OnMessage(ann.sent[1], "Ann Bell"))
    tool.welcome:Set({ subject = "Welcome!" })
    test.assertTrue(tool.welcome:OnMessage(ann.sent[1], "Ann Bell"))
    tool.timers[1]()
    test.assertEqual(addon.GuildWelcome.TYPE_CONFIG, tool.sent[#tool.sent].t)
    local count = #tool.sent

    -- An answer heard first, holding everything, stops this one.
    tool.welcome:OnMessage(ann.sent[1], "Ann Bell")
    ann.welcome:OnMessage(tool.sent[1], "Tool Box")
    ann.welcome:Set({ body = "Hi" })
    ann.sent = {}
    ann.welcome:send()
    tool.welcome:OnMessage(ann.sent[1], "Ann Bell")
    tool.timers[2]()
    test.assertEqual(count, #tool.sent)
end)
