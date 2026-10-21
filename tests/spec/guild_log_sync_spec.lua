local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Sharing the officers' guild log between officers' add-ons.
local NOW = 1790000000
local DAY = 86400

local function load()
    return test.newAddon("Core/GuildLog.lua", "Core/GuildLogSync.lua")
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    local key, inner
    for key, inner in pairs(value) do
        result[key] = copy(inner)
    end
    return result
end

local normalizer = {
    Key = function(_, name)
        return type(name) == "string" and string.lower(name) or nil
    end,
}

-- Add-ons named in `names`, joined by one fake officer channel: what one
-- sends reaches every other (and echoes back to the sender) once deliver
-- runs. Those in `officers` are officers. Background work runs at once;
-- timers wait for `hub:runTimers()`, which fires them one at a time with
-- messages delivered after each, as random delays do.
local function newHub(names, officers)
    local addon = load()
    local hub = { queue = {}, timers = {}, nodes = {}, sent = 0 }
    local officerKeys = {}
    local index
    for index = 1, #officers do
        officerKeys[string.lower(officers[index])] = true
    end
    for index = 1, #names do
        local node = { name = names[index], key = string.lower(names[index]), merged = 0 }
        node.log = addon.GuildLog.Create({})
        node.sync = addon.GuildLogSync.Create({
            send = function(message)
                hub.sent = hub.sent + 1
                table.insert(hub.queue, { from = node, message = copy(message) })
            end,
            log = function()
                if officerKeys[node.key] then
                    return node.log, normalizer
                end
                return nil
            end,
            selfKey = function()
                return node.key
            end,
            isOfficer = function(key)
                return officerKeys[key] == true
            end,
            worker = {
                Queue = function(_, work)
                    work()
                end,
                Checkpoint = function() end,
            },
            after = function(_, callback)
                table.insert(hub.timers, callback)
                return true
            end,
            onMerged = function(entries)
                node.merged = node.merged + #entries
            end,
        })
        hub.nodes[names[index]] = node
        table.insert(hub.nodes, node)
    end
    function hub:deliver()
        while self.queue[1] ~= nil do
            local item = table.remove(self.queue, 1)
            local nodeIndex
            for nodeIndex = 1, #self.nodes do
                self.nodes[nodeIndex].sync:Receive(copy(item.message), item.from.name)
            end
        end
    end
    function hub:runTimers()
        self:deliver()
        while self.timers[1] ~= nil do
            table.remove(self.timers, 1)()
            self:deliver()
        end
    end
    return hub, addon
end

test.test("a newly recorded entry reaches the other officers' logs, and no member's", function()
    local hub = newHub({ "Tool", "Anvil", "Hammer" }, { "Tool", "Anvil" })
    local tool = hub.nodes.Tool
    local _, changed = tool.log:RecordLive("join", "bolt", NOW, "Bolt")

    tool.sync:Share(changed)
    hub:deliver()

    test.assertEqual(1, #hub.nodes.Anvil.log:Entries())
    test.assertEqual("Bolt", hub.nodes.Anvil.log:Entries()[1].name)
    test.assertEqual(1, hub.nodes.Anvil.merged)
    test.assertEqual(0, #hub.nodes.Hammer.log:Entries())
    -- The echo of its own message changes nothing on the sender.
    test.assertEqual(1, #tool.log:Entries())
    test.assertEqual(0, tool.merged)
end)

test.test("entries from a member's add-on are ignored", function()
    local hub = newHub({ "Tool", "Hammer" }, { "Tool" })
    local hammer = hub.nodes.Hammer
    local _, changed = hammer.log:RecordLive("kick", "bolt", NOW, "Bolt")

    hammer.sync:Share(changed)
    hub:deliver()

    test.assertEqual(0, #hub.nodes.Tool.log:Entries())
end)

test.test("an officer who was offline catches up after login, and the logs settle both ways", function()
    local hub = newHub({ "Tool", "Anvil" }, { "Tool", "Anvil" })
    local tool, anvil = hub.nodes.Tool, hub.nodes.Anvil
    -- What Tool recorded while Anvil was away, and an old entry only Anvil has.
    tool.log:RecordLive("join", "bolt", NOW, "Bolt")
    tool.log:RecordLive("leave", "nail", NOW - 40 * DAY, "Nail")
    anvil.log:RecordLive("kick", "rust", NOW - 400 * DAY, "Rust")
    -- Both have the same event.
    tool.log:RecordLive("join", "wrench", NOW - 3 * DAY, "Wrench")
    anvil.log:RecordLive("join", "wrench", NOW - 3 * DAY + 60, "Wrench")

    anvil.sync:Start()
    hub:runTimers()

    test.assertEqual(4, #anvil.log:Entries())
    test.assertEqual(4, #tool.log:Entries())
    local addon = load()
    test.assertEqual(0, #addon.GuildLog.DifferingMonths(tool.log:Digest(), anvil.log:Digest()))
end)

test.test("officers who agree exchange one digest and nothing else", function()
    local hub = newHub({ "Tool", "Anvil" }, { "Tool", "Anvil" })
    hub.nodes.Tool.log:RecordLive("join", "bolt", NOW, "Bolt")
    hub.nodes.Anvil.log:RecordLive("join", "bolt", NOW, "Bolt")

    hub.nodes.Anvil.sync:Start()
    hub:runTimers()

    test.assertEqual(1, hub.sent)
end)

test.test("each announcement gets one reply, and members never announce", function()
    local hub = newHub({ "Tool", "Anvil", "Rivet", "Hammer" }, { "Tool", "Anvil", "Rivet" })
    hub.nodes.Tool.log:RecordLive("join", "bolt", NOW, "Bolt")
    hub.nodes.Anvil.log:RecordLive("join", "bolt", NOW, "Bolt")

    hub.nodes.Rivet.sync:Start()
    hub.nodes.Hammer.sync:Start()
    hub:runTimers()

    -- Rivet's digest and one reply; Hammer sends nothing.
    test.assertEqual(2, hub.sent)
    test.assertEqual(1, #hub.nodes.Rivet.log:Entries())
end)

test.test("a long catch-up goes out in parts", function()
    local hub, addon = newHub({ "Tool", "Anvil" }, { "Tool", "Anvil" })
    local index
    for index = 1, 120 do
        hub.nodes.Tool.log:RecordLive("join", "c" .. index, NOW - index * DAY, "C" .. index)
    end

    hub.nodes.Anvil.sync:Start()
    hub:runTimers()

    test.assertEqual(120, #hub.nodes.Anvil.log:Entries())
    test.assertTrue(addon.GuildLogSync.ENTRIES_PER_MESSAGE < 120)
    test.assertEqual(0, #addon.GuildLog.DifferingMonths(hub.nodes.Tool.log:Digest(), hub.nodes.Anvil.log:Digest()))
end)

test.test("a ping is answered by every other officer's add-on that hears it", function()
    local hub, addon = newHub({ "Tool", "Anvil", "Hammer" }, { "Tool", "Anvil" })

    local id, sent = hub.nodes.Tool.sync:Ping()
    hub:deliver()

    test.assertTrue(sent)
    local answers = hub.nodes.Tool.sync:Answers(id)
    test.assertEqual(1, #answers)
    test.assertEqual("Anvil", answers[1])

    local lines = addon.GuildLogSync.ProbeLines(answers, {
        { key = "anvil", name = "Anvil" }, { key = "rivet", name = "Rivet" },
    }, function(name)
        return string.lower(name)
    end)
    test.assertEqual("  Answered: Anvil", lines[2])
    test.assertEqual("  Officers online (by the add-on's officer rule): Anvil, Rivet", lines[3])
    test.assertEqual("  Missed by the officer channel: Rivet", lines[4])
    test.assertEqual("  Answered: nobody", addon.GuildLogSync.ProbeLines({}, {}, string.lower)[2])
end)

-- In the composed add-on -------------------------------------------------------

local NAMES = {
    Forever = { "Tool Box", "Anvil Stone", "Hammer Smith" },
    Retail = { "Toolbox-Area52", "Anvil-Area52", "Hammer-Area52" },
}

local function guild(profile)
    local names = NAMES[profile]
    return {
        name = "Knights of Camelot",
        realm = profile == "Retail" and "Area 52" or "Camelot",
        members = {
            { name = names[1], class = "WARRIOR", level = 60, rank = 1, rankName = "Officer", online = true,
                zone = "Ironforge" },
            { name = names[2], class = "PALADIN", level = 60, rank = 1, rankName = "Officer", online = true,
                zone = "Ironforge" },
            { name = names[3], class = "MAGE", level = 42, rank = 3, rankName = "Member", online = true,
                zone = "Ironforge" },
        },
    }
end

-- Logs `playerName` in on `profile`, on `channel`, with the guild event log
-- empty. `setup(world)` runs before the add-on loads.
local function login(profile, channel, playerName, setup)
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = playerName })
    world.time = channel.time or world.time
    channel.time = world.time
    if setup ~= nil then
        setup(world)
    end
    fixtures.joinChannel(channel, world)
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

-- Lets `seconds` pass on every world, delivering messages as they go.
local function settle(channel, seconds)
    local step
    for step = 1, seconds do
        local index
        for index = 1, #channel.worlds do
            fixtures.runTimers(channel.worlds[index], 1)
        end
        fixtures.deliver(channel)
    end
end

local function storedEntries(world)
    local _, partition = world.addon.rosterController:QuietContext()
    local saved = partition.data.guildLog
    return saved and saved.entries or {}
end

local function sentOn(world, distribution)
    local count = 0
    local index
    for index = 1, #world.sentMessages do
        if world.sentMessages[index].distribution == distribution then
            count = count + 1
        end
    end
    return count
end

for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]
    local names = NAMES[profile]

    test.test(profile .. " an entry one officer records reaches the other officer online, and no member", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local anvil = login(profile, channel, names[2])
        local hammer = login(profile, channel, names[3])
        settle(channel, 120)

        fixtures.fire(tool, "CHAT_MSG_SYSTEM", "Bolt has joined the guild.")
        settle(channel, 5)

        test.assertEqual(1, #storedEntries(anvil))
        test.assertEqual("Bolt", storedEntries(anvil)[1].name)
        test.assertEqual(0, #storedEntries(hammer))
        test.assertTrue(sentOn(tool, "OFFICER") >= 1, "sent to the officer channel")
        test.assertEqual(0, sentOn(tool, "WHISPER"))
        -- Anvil's add-on saw the join too: still one entry each.
        fixtures.fire(anvil, "CHAT_MSG_SYSTEM", "Bolt has joined the guild.")
        settle(channel, 5)
        test.assertEqual(1, #storedEntries(anvil))
        test.assertEqual(1, #storedEntries(tool))
    end)

    test.test(profile .. " an officer who logs in later catches up on what was recorded meanwhile", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        settle(channel, 120)
        fixtures.fire(tool, "CHAT_MSG_SYSTEM", "Bolt has joined the guild.")
        tool.time = tool.time + 60
        fixtures.fire(tool, "CHAT_MSG_SYSTEM", "Nail has left the guild.")
        settle(channel, 5)

        channel.time = tool.time
        local anvil = login(profile, channel, names[2])
        test.assertEqual(0, #storedEntries(anvil))
        settle(channel, 120)

        test.assertEqual(2, #storedEntries(anvil))
        test.assertEqual(2, #storedEntries(tool))
    end)

    test.test(profile .. " without officer chat, entries are whispered to each officer online", function()
        local channel = fixtures.newChannel()
        local function noOfficerChat(world)
            world.officerChatRanks = {}
        end
        local tool = login(profile, channel, names[1], noOfficerChat)
        local anvil = login(profile, channel, names[2], noOfficerChat)
        local hammer = login(profile, channel, names[3], noOfficerChat)
        settle(channel, 120)

        fixtures.fire(tool, "CHAT_MSG_SYSTEM", "Bolt has joined the guild.")
        settle(channel, 5)

        test.assertEqual(1, #storedEntries(anvil))
        test.assertEqual(0, #storedEntries(hammer))
        test.assertEqual(0, sentOn(tool, "OFFICER"))
        test.assertTrue(sentOn(tool, "WHISPER") >= 1)
    end)

    test.test(profile .. " /agf probe officer shows who answered next to the officers online", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local anvil = login(profile, channel, names[2])
        settle(channel, 120)

        tool.messages = {}
        fixtures.slash(tool, "probe officer")
        settle(channel, 10)
        local printed = table.concat(tool.messages, "\n")
        test.assertContains(printed, "Answered: " .. names[2])
        test.assertContains(printed, "Missed by the officer channel: nobody")

        -- An officer whose rank can't listen to officer chat is missed.
        anvil.officerChatRanks = { [0] = true }
        tool.officerChatRanks = { [0] = true, [1] = true }
        tool.messages = {}
        fixtures.slash(tool, "probe officer")
        settle(channel, 10)
        printed = table.concat(tool.messages, "\n")
        test.assertContains(printed, "Answered: nobody")
        test.assertContains(printed, "Missed by the officer channel: " .. names[2])

        local hammer = login(profile, channel, names[3])
        hammer.messages = {}
        fixtures.slash(hammer, "probe officer")
        test.assertContains(table.concat(hammer.messages, "\n"), "Only officers can probe the officer channel.")
    end)
end
