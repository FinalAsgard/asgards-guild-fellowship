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

-- Newcomers -------------------------------------------------------------------

local DAY = 24 * 60 * 60

-- An officer's add-on in a guild with Tool Box (the officer) and Ann Bell,
-- welcome mail switched on at 1000. `world.joined(name)` and
-- `world.scan(names)` stand in for the join message and a roster scan.
local function newGuild()
    local addon, world = newWelcome("tool box-camelot", { time = 1000 })
    local partition = world.partition
    partition:RecordCharacter("tool box-camelot", { name = "Tool Box", rankIndex = 1 })
    partition:RecordCharacter("ann bell-camelot", { name = "Ann Bell", rankIndex = 2 })
    world.welcome.keyOf = function(rawName)
        return string.lower(rawName) .. "-camelot"
    end
    world.welcome:Set({ on = true })
    function world.joined(name)
        return world.welcome:OnJoined(name)
    end
    -- Records the characters, then tells the welcome about them.
    function world.scan(names)
        local keys = {}
        local index
        for index = 1, #names do
            local key = string.lower(names[index]) .. "-camelot"
            partition:RecordCharacter(key, { name = names[index], rankIndex = 3 })
            table.insert(keys, key)
        end
        return world.welcome:OnScan(keys)
    end
    return addon, world
end

test.test("guild welcome newcomers: someone who joins is due 24 hours after being first seen", function()
    local _, world = newGuild()
    world.time = 2000

    test.assertTrue(world.joined("Zed Stone"))
    world.scan({ "Zed Stone" })
    test.assertEqual(2000, world.partition:GetWelcomeLedger().seen["zed stone-camelot"])
    test.assertEqual(0, #world.welcome:Due(2000 + DAY - 1))
    test.assertEqual("zed stone-camelot", table.concat(world.welcome:Due(2000 + DAY), ","))
end)

test.test("guild welcome newcomers: a scan notes new characters, but not the guild's first scan", function()
    -- Everyone in this scan is new to the add-on: it's the first look.
    local _, fresh = newWelcome("tool box-camelot", { time = 1000 })
    fresh.welcome:Set({ on = true })
    fresh.partition:RecordCharacter("tool box-camelot", { name = "Tool Box", rankIndex = 1 })
    test.assertEqual(0, fresh.welcome:OnScan({ "tool box-camelot" }))

    local _, world = newGuild()
    world.time = 3000
    test.assertEqual(2, world.scan({ "Zed Stone", "Bo Reed" }))
    test.assertEqual(2, #world.welcome:Due(3000 + DAY))
end)

test.test("guild welcome newcomers: nobody is noted while it's off, or before it was switched on", function()
    local _, world = newGuild()
    world.welcome:Set({ on = false })
    world.time = 2000
    test.assertFalse(world.joined("Zed Stone"))
    test.assertEqual(0, world.scan({ "Zed Stone" }))

    world.welcome:Set({ on = true })
    world.time = 2500
    -- Zed is known now: the rejoin message doesn't make Zed new.
    test.assertFalse(world.joined("Zed Stone"))
    test.assertEqual(0, #world.welcome:Due(2500 + 2 * DAY))
end)

test.test("guild welcome newcomers: someone the add-on already knew is rejoining, not new", function()
    local _, world = newGuild()
    world.partition:MarkDeparted("ann bell-camelot", 1500)
    world.time = 2000

    test.assertFalse(world.joined("Ann Bell"))
    test.assertEqual(0, #world.welcome:Due(2000 + DAY))
end)

test.test("guild welcome newcomers: an alt linked during the wait is skipped for good", function()
    local _, world = newGuild()
    world.time = 2000
    world.scan({ "Cog Wheel" })
    world.partition:JoinPlayerOf("cog wheel-camelot", "ann bell-camelot", "note")

    test.assertEqual(0, #world.welcome:Due(2000 + DAY))
    test.assertEqual(nil, world.partition:GetWelcomeLedger().seen["cog wheel-camelot"])
end)

test.test("guild welcome newcomers: a member's new alt never gets it, even after the member left", function()
    local _, world = newGuild()
    world.partition:MarkDeparted("ann bell-camelot", 1500)
    world.time = 2000
    world.scan({ "Cog Wheel" })
    world.partition:JoinPlayerOf("cog wheel-camelot", "ann bell-camelot", "note")

    test.assertEqual(0, #world.welcome:Due(2000 + DAY))
end)

test.test("guild welcome newcomers: a new player with two new characters gets one, on their main", function()
    local _, world = newGuild()
    world.time = 2000
    world.scan({ "Zed Stone" })
    world.time = 2100
    world.scan({ "Bo Stone" })
    world.partition:JoinPlayerOf("zed stone-camelot", "bo stone-camelot", "note")

    -- Bo is the main; Bo was seen later, so it's due a little later.
    test.assertEqual(0, #world.welcome:Due(2000 + DAY))
    test.assertEqual("bo stone-camelot", table.concat(world.welcome:Due(2100 + DAY), ","))

    -- Once Bo is welcomed, Zed is done too.
    test.assertTrue(world.welcome:MarkWelcomed("bo stone-camelot", 2100 + DAY, "tool box-camelot"))
    test.assertEqual(0, #world.welcome:Due(2100 + 2 * DAY))
    test.assertEqual(nil, world.partition:GetWelcomeLedger().seen["zed stone-camelot"])
end)

test.test("guild welcome newcomers: without a main, the first seen of a new player's characters gets it", function()
    local _, world = newGuild()
    world.time = 2000
    world.scan({ "Zed Stone" })
    world.time = 2100
    world.scan({ "Bo Stone" })
    world.partition:JoinPlayerOf("bo stone-camelot", "zed stone-camelot", "note")
    local zed = world.partition:GetCharacter("zed stone-camelot")
    world.partition:GetPlayer(zed.player).main = nil

    test.assertEqual("zed stone-camelot", table.concat(world.welcome:Due(2100 + DAY), ","))
end)

test.test("guild welcome newcomers: someone who leaves before they're due is dropped", function()
    local _, world = newGuild()
    world.time = 2000
    world.scan({ "Zed Stone" })
    world.partition:MarkDeparted("zed stone-camelot", 2500)

    test.assertEqual(0, #world.welcome:Due(2000 + DAY))
    test.assertEqual(nil, world.partition:GetWelcomeLedger().seen["zed stone-camelot"])
end)

test.test("guild welcome newcomers: a welcome is recorded with its player, when and by whom, and kept", function()
    local addon, world = newGuild()
    world.time = 2000
    world.scan({ "Zed Stone" })
    world.welcome:MarkWelcomed("zed stone-camelot", 2000 + DAY, "tool box-camelot")

    local _, after = newWelcome("tool box-camelot", { addon = addon, partition = world.partition })
    test.assertTrue(after.welcome:IsWelcomed("zed stone-camelot"))
    local record = world.partition:GetWelcomeLedger().welcomed["zed stone-camelot"]
    test.assertEqual("zed stone-camelot", record.main)
    test.assertEqual(2000 + DAY, record.at)
    test.assertEqual("tool box-camelot", record.by)
    test.assertEqual(0, #after.welcome:Due(2000 + 2 * DAY))
    -- A welcomed character joining again isn't new.
    world.partition:MarkDeparted("zed stone-camelot", 9000)
    test.assertFalse(world.joined("Zed Stone"))
end)
