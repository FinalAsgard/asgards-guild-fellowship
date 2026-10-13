local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local function load()
    return test.newAddon("Core/GroupFinderProtocol.lua", "Core/GroupAvailability.lua")
end

-- GroupFinderProtocol -------------------------------------------------------

test.test("group finder protocol: ask and available messages are versioned and checked", function()
    local protocol = load().GroupFinderProtocol

    test.assertTrue(protocol.IsValid(protocol.Ask()))
    local available = protocol.Available("hammer-area52", true)
    test.assertTrue(protocol.IsValid(available))
    test.assertEqual("hammer-area52", available.c)
    test.assertTrue(available.a)
    test.assertFalse(protocol.Available("hammer-area52", nil).a)

    -- Another version, an unknown type, or the wrong fields: ignored.
    test.assertFalse(protocol.IsValid({ v = 2, t = protocol.TYPE_ASK }))
    test.assertFalse(protocol.IsValid({ t = protocol.TYPE_ASK }))
    test.assertFalse(protocol.IsValid({ v = 1, t = "gf-mystery" }))
    test.assertFalse(protocol.IsValid({ v = 1, t = protocol.TYPE_AVAILABLE, c = "", a = true }))
    test.assertFalse(protocol.IsValid({ v = 1, t = protocol.TYPE_AVAILABLE, c = "hammer-area52", a = "yes" }))
    test.assertFalse(protocol.IsValid("gf-ask"))
end)

test.test("group finder protocol: its types never clash with the add-on's other messages", function()
    local addon = test.newAddon("Core/GroupFinderProtocol.lua", "Core/GuildRecruit.lua", "Core/SyncSession.lua",
        "Core/GuildGreet.lua")
    local others = {
        addon.GuildGreet.TYPE_GREETED,
        addon.SyncSession.TYPE_FACTS, addon.SyncSession.TYPE_DIGEST, addon.SyncSession.TYPE_SUGGEST,
    }
    local type_
    for type_ in pairs(addon.GuildRecruit.TYPES) do
        table.insert(others, type_)
    end
    local index
    for index = 1, #others do
        test.assertEqual(nil, addon.GroupFinderProtocol.TYPES[others[index]], tostring(others[index]))
    end
end)

-- GroupAvailability with fakes ----------------------------------------------

local function newClient(key, options)
    options = options or {}
    local addon = load()
    local client = { key = key, sent = {}, timers = {}, dnd = false, occupied = false, busy = false, changes = 0 }
    client.availability = addon.GroupAvailability.Create({
        send = function(message)
            table.insert(client.sent, message)
            return true
        end,
        after = function(seconds, callback)
            table.insert(client.timers, { seconds = seconds, callback = callback })
            return true
        end,
        random = function(low, high)
            client.randomRange = { low, high }
            return high
        end,
        selfKey = function()
            return client.key
        end,
        keyOf = function(sender)
            return string.lower(sender)
        end,
        doNotDisturb = function()
            return client.dnd
        end,
        occupied = function()
            return client.occupied
        end,
        busy = function()
            return client.busy
        end,
        onChanged = function()
            client.changes = client.changes + 1
        end,
    })
    client.protocol = addon.GroupFinderProtocol
    return client
end

local function runTimers(client)
    local timers = client.timers
    client.timers = {}
    local index
    for index = 1, #timers do
        timers[index].callback()
    end
end

test.test("group availability: opening asks the guild once and forgets older replies", function()
    local organizer = newClient("toolbox")
    organizer.availability:OnMessage(organizer.protocol.Available("hammer", true), "Hammer")
    test.assertEqual(1, #organizer.availability:Replies())

    test.assertTrue(organizer.availability:Ask())

    test.assertEqual(1, #organizer.sent)
    test.assertEqual("gf-ask", organizer.sent[1].t)
    test.assertEqual(0, #organizer.availability:Replies())

    -- Nothing is sent while busy.
    organizer.busy = true
    test.assertFalse(organizer.availability:Ask())
    test.assertEqual(1, #organizer.sent)
end)

test.test("group availability: an ask gets one reply after a short random delay", function()
    local member = newClient("hammer")

    member.availability:OnMessage(member.protocol.Ask(), "Toolbox")
    member.availability:OnMessage(member.protocol.Ask(), "Wrench")

    test.assertEqual(0, #member.sent)
    test.assertEqual(1, #member.timers)
    test.assertEqual(1, member.randomRange[1])
    test.assertEqual(5, member.randomRange[2])
    test.assertEqual(5, member.timers[1].seconds)
    runTimers(member)
    test.assertEqual(1, #member.sent)
    test.assertEqual("gf-available", member.sent[1].t)
    test.assertEqual("hammer", member.sent[1].c)
    test.assertTrue(member.sent[1].a)
end)

test.test("group availability: Do Not Disturb, a group or an instance reply as unavailable", function()
    local member = newClient("hammer")
    member.dnd = true
    member.availability:OnMessage(member.protocol.Ask(), "Toolbox")
    runTimers(member)
    test.assertFalse(member.sent[1].a)

    member.dnd = false
    member.occupied = true
    member.availability:OnMessage(member.protocol.Ask(), "Toolbox")
    runTimers(member)
    test.assertFalse(member.sent[2].a)

    member.occupied = false
    test.assertTrue(member.availability:IsAvailable())
end)

test.test("group availability: no reply while busy, and the player's own ask is ignored", function()
    local member = newClient("hammer")

    member.availability:OnMessage(member.protocol.Ask(), "Hammer")
    test.assertEqual(0, #member.timers)

    member.availability:OnMessage(member.protocol.Ask(), "Toolbox")
    member.busy = true
    runTimers(member)
    test.assertEqual(0, #member.sent)
end)

test.test("group availability: replies are recorded per guildmate; unknown messages are ignored", function()
    local organizer = newClient("toolbox")
    local protocol = organizer.protocol

    test.assertTrue(organizer.availability:OnMessage(protocol.Available("wrench", false), "Wrench"))
    test.assertTrue(organizer.availability:OnMessage(protocol.Available("hammer", true), "Hammer"))
    test.assertTrue(organizer.availability:OnMessage(protocol.Available("anvil", true), "Hammer"))
    test.assertFalse(organizer.availability:OnMessage({ v = 9, t = "gf-available", c = "x", a = true }, "Anvil"))
    test.assertFalse(organizer.availability:OnMessage({ v = 1, t = "gf-unknown" }, "Anvil"))

    local replies = organizer.availability:Replies()
    test.assertEqual(2, #replies)
    -- The newest reply from a guildmate replaces their older one.
    test.assertEqual("hammer", replies[1].key)
    test.assertEqual("anvil", replies[1].character)
    test.assertEqual("wrench", replies[2].key)
    test.assertFalse(replies[2].available)
    test.assertEqual(3, organizer.changes)
end)

test.test("group availability: an organizer hears who is online and available", function()
    local organizer = newClient("toolbox")
    local members = { newClient("hammer"), newClient("wrench") }
    members[2].dnd = true

    organizer.availability:Ask()
    local index
    for index = 1, #members do
        members[index].availability:OnMessage(organizer.sent[1], "Toolbox")
        runTimers(members[index])
        organizer.availability:OnMessage(members[index].sent[1], members[index].key == "hammer" and "Hammer" or "Wrench")
    end

    local replies = organizer.availability:Replies()
    test.assertEqual(2, #replies)
    test.assertTrue(replies[1].available)
    test.assertFalse(replies[2].available)
end)

-- The window's footer -----------------------------------------------------------

test.test("group finder window: lists who replied, and its Do Not Disturb box follows the setting", function()
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Adapters/GroupFinderWindow.lua")
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local state = { dnd = false, replies = {} }
    local roles = addon.RoleCatalog.For("forever")
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({}) end,
        playerLevel = function() return 20 end,
        session = addon.GroupSession.Create(roles),
        roles = roles,
        replies = function() return state.replies end,
        dnd = {
            get = function() return state.dnd end,
            set = function(enabled) state.dnd = enabled end,
        },
    })
    window:Opened()
    test.assertEqual("No other add-on users have replied yet.", window.repliesText.text)
    test.assertFalse(window.dndButton:GetChecked())

    state.replies = {
        { sender = "Hammer-Area52", available = true },
        { sender = "Wrench-Area52", available = false },
    }
    state.dnd = true
    window:Refresh()

    test.assertEqual("Add-on users online: Hammer, Wrench (unavailable)", window.repliesText.text)
    test.assertTrue(window.dndButton:GetChecked())

    window.dndButton:SetChecked(false)
    window.dndButton.scripts.OnClick(window.dndButton)
    test.assertFalse(state.dnd)
end)

-- The composed add-on -----------------------------------------------------------

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
        },
    }
end

local function login(channel, playerName, profile)
    local world = fixtures.newEnvironment(profile or "Retail", { guild = guild(), playerName = playerName })
    if channel ~= nil then
        fixtures.joinChannel(channel, world)
    end
    local addon = fixtures.loadAddon(world)
    -- A window that only records being opened and refreshed.
    world.window = { open = false, refreshes = 0 }
    function world.window:Opened()
        self.open = not self.open
        return self.open
    end
    function world.window:Refresh()
        self.refreshes = self.refreshes + 1
    end
    addon.GroupFinderWindow.Create = function(_, _, options)
        world.window.options = options
        return world.window
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

local function decode(world, sent)
    local _, message = world.environment.LibStub.libs["AceSerializer-3.0"]:Deserialize(sent.text)
    return message
end

test.test("opening the Group Finder asks the guild, and add-on users' replies show in it", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    organizer.sentMessages = {}

    fixtures.openGroupFinder(organizer)

    test.assertEqual(1, #organizer.sentMessages)
    test.assertEqual("gf-ask", decode(organizer, organizer.sentMessages[1]).t)
    test.assertEqual("NORMAL", organizer.sentMessages[1].priority)
    fixtures.deliver(channel)
    fixtures.runTimers(member, 5)
    fixtures.deliver(channel)

    local replies = organizer.window.options.replies()
    test.assertEqual(1, #replies)
    test.assertEqual("hammer-area52", replies[1].character)
    test.assertTrue(replies[1].available)
    test.assertTrue(organizer.window.refreshes > 0)
    -- Closing it sends nothing.
    organizer.sentMessages = {}
    fixtures.openGroupFinder(organizer)
    test.assertEqual(0, #organizer.sentMessages)
end)

test.test("a guildmate in Do Not Disturb, or in a group, replies as unavailable", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    fixtures.slash(member, "dnd")

    fixtures.openGroupFinder(organizer)
    fixtures.deliver(channel)
    fixtures.runTimers(member, 5)
    fixtures.deliver(channel)
    test.assertFalse(organizer.window.options.replies()[1].available)

    fixtures.slash(member, "dnd")
    member.environment.IsInGroup = function() return true end
    fixtures.openGroupFinder(organizer)
    fixtures.openGroupFinder(organizer)
    fixtures.deliver(channel)
    fixtures.runTimers(member, 5)
    fixtures.deliver(channel)
    test.assertFalse(organizer.window.options.replies()[1].available)
end)

local function registerProfileTests(profile)
    test.test(profile .. " /agf dnd, the setting and the window agree, on every character", function()
        local world = login(nil, nil, profile)
        local settings = world.addon.settings
        fixtures.openGroupFinder(world)
        local dnd = world.window.options.dnd

        fixtures.slash(world, "dnd")
        test.assertContains(world.messages[#world.messages], "Do Not Disturb on")
        test.assertTrue(settings:Get("dnd"))
        test.assertTrue(dnd.get())
        -- Saved account-wide, not per character.
        test.assertTrue(world.database.groupFinder.dnd)

        test.assertTrue(dnd.set(false))
        test.assertFalse(settings:Get("dnd"))
        test.assertEqual(nil, world.database.groupFinder.dnd)

        test.assertTrue(settings:Set("dnd", true))
        test.assertTrue(dnd.get())
        fixtures.slash(world, "dnd")
        test.assertContains(world.messages[#world.messages], "Do Not Disturb off")
        test.assertFalse(dnd.get())
    end)

    test.test(profile .. " /agf help lists /agf dnd", function()
        local world = login(nil, nil, profile)

        fixtures.slash(world, "help")

        test.assertContains(table.concat(world.messages, "\n"), "/agf dnd - turn Group Finder Do Not Disturb on or off")
    end)
end

registerProfileTests("Forever")
registerProfileTests("Retail")

test.test("group finder window: Refresh asks again who is online, and party slots show class colors", function()
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Core/GroupCandidates.lua", "Adapters/GroupFinderWindow.lua")
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local refreshes = 0
    local roles = addon.RoleCatalog.For("forever")
    local session = addon.GroupSession.Create(roles)
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({ { id = "dm", name = "DM", minLevel = 17, maxLevel = 26 } }) end,
        playerLevel = function() return 20 end,
        session = session,
        roles = roles,
        syncParty = function()
            if session:IsActive() then
                session:UpdateParty({ { key = "p1", name = "Me", classToken = "WARRIOR", isPlayer = true, inGuild = true } }, false)
            end
        end,
        classColor = function(class) return class == "WARRIOR" and "ffc69b6d" or nil end,
        refresh = function() refreshes = refreshes + 1 end,
    })
    window:Opened()

    window.refreshButton.scripts.OnClick()
    test.assertEqual(1, refreshes)

    window:Pick("dm")
    test.assertEqual("|cffc69b6dMe|r", window.slotRows[1].text.text)
end)
