local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000
local DEADMINES = { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 }

local function load()
    return test.newAddon("Core/FellowshipStore.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Core/GroupFinderProtocol.lua", "Core/JoinRequests.lua", "Core/GroupCandidates.lua",
        "Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua", "Adapters/JoinPrompts.lua")
end

-- The protocol -------------------------------------------------------------------

test.test("join protocol: request, answer and cancel are targeted and checked", function()
    local protocol = load().GroupFinderProtocol

    local request = protocol.Request("hammer", "1-1", DEADMINES, { "healer", "dps" })
    test.assertTrue(protocol.IsValid(request))
    test.assertEqual("hammer", request.to)
    test.assertEqual("The Deadmines", request.dn)
    test.assertEqual(17, request.lo)
    test.assertTrue(protocol.IsValid(protocol.Cancel("hammer", "1-1")))
    test.assertTrue(protocol.IsValid(protocol.Answer("toolbox", "1-1", nil)))
    local accept = protocol.Answer("toolbox", "1-1", { role = "healer", key = "hammer", name = "Hammer", level = 24 })
    test.assertTrue(protocol.IsValid(accept))
    test.assertTrue(accept.ok)

    -- No recipient, no id, or the wrong shapes: ignored.
    test.assertFalse(protocol.IsValid({ v = 1, t = "gf-cancel", id = "1-1" }))
    test.assertFalse(protocol.IsValid({ v = 1, t = "gf-cancel", to = "hammer" }))
    test.assertFalse(protocol.IsValid(protocol.Request("hammer", "1-1", DEADMINES, {})))
    test.assertFalse(protocol.IsValid(protocol.Request("hammer", "1-1", DEADMINES, { "healer", "healer" })))
    test.assertFalse(protocol.IsValid(protocol.Request("hammer", "1-1", { name = "X", minLevel = 30, maxLevel = 20 },
        { "dps" })))
    test.assertFalse(protocol.IsValid({ v = 1, t = "gf-answer", to = "toolbox", id = "1-1", ok = true, role = "dps" }))
    test.assertFalse(protocol.IsValid({ v = 2, t = "gf-cancel", to = "hammer", id = "1-1" }))
end)

-- The organizer's side: GroupSession requests ---------------------------------------

local function newSession(addon)
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    session:UpdateParty({ { key = "me", name = "Me", classToken = "WARRIOR", inGuild = true, isPlayer = true } }, false)
    return session
end

local HAMMER = { playerId = 2, key = "hammer", label = "Thunderer" }

test.test("group session: a request is pending until answered, once per player", function()
    local addon = load()
    local session = newSession(addon)

    local request = session:Request(HAMMER, NOW)

    test.assertEqual("pending", request.state)
    test.assertEqual("hammer", request.to)
    test.assertEqual(nil, session:Request(HAMMER, NOW + 1))
    test.assertEqual(request, session:RequestFor(2))
    test.assertEqual(1, #session:PendingRequests())
end)

test.test("group session: requests expire after about 2 minutes", function()
    local addon = load()
    local session = newSession(addon)
    local request = session:Request(HAMMER, NOW)

    test.assertEqual(0, #session:Expire(NOW + 119))
    test.assertEqual("pending", request.state)
    local expired = session:Expire(NOW + 120)

    test.assertEqual(1, #expired)
    test.assertEqual("expired", request.state)
    -- An answer after that changes nothing, and the player can be asked again.
    test.assertEqual(nil, session:Answer(request.id, "hammer", nil))
    test.assertTrue(session:Request(HAMMER, NOW + 121) ~= nil)
end)

test.test("group session: the organizer can cancel a pending request", function()
    local addon = load()
    local session = newSession(addon)
    local request = session:Request(HAMMER, NOW)

    test.assertEqual(request, session:Cancel(request.id))
    test.assertEqual("cancelled", request.state)
    test.assertEqual(nil, session:Cancel(request.id))
end)

test.test("group session: a decline shows as declined", function()
    local addon = load()
    local session = newSession(addon)
    local request = session:Request(HAMMER, NOW)

    -- Only the character asked can answer.
    test.assertEqual(nil, session:Answer(request.id, "wrench", nil))
    test.assertEqual("declined", session:Answer(request.id, "hammer", nil))
    test.assertEqual("declined", request.state)
end)

test.test("group session: accepting locks the invitee into the slot they chose", function()
    local addon = load()
    local session = newSession(addon)
    local request = session:Request(HAMMER, NOW)

    test.assertEqual("accepted", session:Answer(request.id, "hammer",
        { role = "healer", key = "hammer", name = "Hammer", level = 24 }))

    local healer = session:Slots()[2]
    test.assertEqual("Hammer", healer.member.name)
    test.assertEqual("accepted", healer.state)
    test.assertEqual(request.id, healer.request)
    -- The slot holds as the party changes, ahead of class defaults.
    session:UpdateParty({
        { key = "me", name = "Me", classToken = "WARRIOR", inGuild = true, isPlayer = true },
        { key = "cleric", name = "Cleric", classToken = "PRIEST", inGuild = true },
    }, true)
    test.assertEqual("Hammer", session:Slots()[2].member.name)
    test.assertEqual("Cleric", session:Slots()[3].member.name)
end)

test.test("group session: an answer for a role no longer open withdraws the request", function()
    local addon = load()
    local session = newSession(addon)
    local request = session:Request(HAMMER, NOW)

    test.assertEqual("withdrawn", session:Answer(request.id, "hammer",
        { role = "tank", key = "hammer", name = "Hammer", level = 24 }))
    test.assertEqual("me", session:Slots()[1].member.key)
end)

-- The invitee's side: JoinRequests ---------------------------------------------

-- Hammer's player: Hammer, a paladin (24), with alts Bolt, a shaman (22),
-- and Oldbolt, a warrior (60). Hammer is logged in.
local function newInvitee()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter("hammer", { name = "Hammer", classToken = "PALADIN", level = 24 })
    partition:RecordCharacter("bolt", { name = "Bolt", classToken = "SHAMAN", level = 22 })
    partition:RecordCharacter("oldbolt", { name = "Oldbolt", classToken = "WARRIOR", level = 60 })
    partition:JoinPlayerOf("bolt", "hammer", "manual")
    partition:JoinPlayerOf("oldbolt", "hammer", "manual")
    partition:RecordCharacter("toolbox", { name = "Toolbox", classToken = "WARRIOR", level = 24 })
    local world = { addon = addon, partition = partition, available = true }
    world.requests = addon.JoinRequests.Create({
        partition = function() return partition end,
        roles = addon.RoleCatalog.For("forever"),
        selfKey = function() return "hammer" end,
        available = function() return world.available end,
    })
    world.protocol = addon.GroupFinderProtocol
    return world
end

local function optionLabels(prompt)
    local labels = {}
    local index
    for index = 1, #prompt.options do
        labels[index] = prompt.options[index].role .. ":" .. prompt.options[index].name
    end
    return table.concat(labels, ", ")
end

test.test("join requests: options are the open roles each fitting character would play", function()
    local world = newInvitee()

    test.assertEqual(nil, world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES,
        { "tank", "healer" }), "toolbox", "Toolbox", NOW))

    local prompt = world.requests:Pending()[1]
    test.assertEqual("toolbox", prompt.organizer)
    test.assertEqual("The Deadmines", prompt.dungeon.name)
    -- Oldbolt is too high for the Deadmines; DPS isn't open.
    test.assertEqual("tank:Hammer, healer:Bolt, healer:Hammer", optionLabels(prompt))
    test.assertEqual("Healer — Bolt (22)", world.addon.JoinRequests.OptionLabel(prompt.options[2]))
end)

test.test("join requests: roles a character turned off aren't offered", function()
    local world = newInvitee()
    world.partition:SetRoles("hammer", { "dps" }, NOW, "hammer")

    world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES, { "tank", "healer", "dps" }),
        "toolbox", "Toolbox", NOW)

    test.assertEqual("healer:Bolt, dps:Bolt, dps:Hammer", optionLabels(world.requests:Pending()[1]))
end)

test.test("join requests: refused at once while unavailable, or when nothing fits", function()
    local world = newInvitee()

    world.available = false
    test.assertEqual("unavailable", world.requests:OnRequest(
        world.protocol.Request("hammer", "1-1", DEADMINES, { "dps" }), "toolbox", "Toolbox", NOW))
    world.available = true
    test.assertEqual("no fit", world.requests:OnRequest(
        world.protocol.Request("hammer", "1-2", { name = "Scholomance", minLevel = 58, maxLevel = 60 },
            { "healer" }), "toolbox", "Toolbox", NOW))
    test.assertEqual(0, #world.requests:Pending())
end)

test.test("join requests: choosing an option or declining closes the prompt", function()
    local world = newInvitee()
    local request = world.protocol.Request("hammer", "1-1", DEADMINES, { "healer" })
    world.requests:OnRequest(request, "toolbox", "Toolbox", NOW)

    local prompt, option = world.requests:Accept("1-1", 1)
    test.assertEqual("toolbox", prompt.organizer)
    test.assertEqual("bolt", option.key)
    test.assertEqual(0, #world.requests:Pending())

    world.requests:OnRequest(request, "toolbox", "Toolbox", NOW)
    test.assertEqual("1-1", world.requests:Decline("1-1").id)
    test.assertEqual(nil, world.requests:Accept("1-1", 1))
end)

test.test("join requests: only the organizer's cancel, or 2 minutes, close a prompt", function()
    local world = newInvitee()
    world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES, { "healer" }), "toolbox", "Toolbox", NOW)

    test.assertFalse(world.requests:OnCancel("1-1", "wrench"))
    test.assertEqual(0, #world.requests:Expire(NOW + 119))
    test.assertTrue(world.requests:OnCancel("1-1", "toolbox"))

    world.requests:OnRequest(world.protocol.Request("hammer", "1-2", DEADMINES, { "healer" }), "toolbox", "Toolbox", NOW)
    test.assertEqual(1, #world.requests:Expire(NOW + 120))
    test.assertEqual(0, #world.requests:Pending())
end)

-- The prompt, with fake frames ---------------------------------------------------

test.test("join prompt: names the organizer and dungeon, with a button per option and Decline", function()
    local world = newInvitee()
    world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES, { "healer" }), "toolbox",
        "Toolbox-Camelot", NOW)
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local prompts = world.addon.JoinPrompts.Create({ environment = environment })
    local answered = {}

    prompts:Show(world.requests:Pending(), {
        accept = function(id, choice) table.insert(answered, "accept " .. id .. " " .. choice) end,
        decline = function(id) table.insert(answered, "decline " .. id) end,
    })

    test.assertTrue(prompts.frame.shown)
    test.assertEqual("Toolbox asks you to join The Deadmines (17–26)", prompts.headers[1].text.text)
    test.assertEqual("Healer — Bolt (22)", prompts.options[1].button.text)
    test.assertEqual("Healer — Hammer (24)", prompts.options[2].button.text)
    prompts.options[2].button.scripts.OnClick()
    prompts.headers[1].decline.scripts.OnClick()
    test.assertEqual("accept 1-1 2", answered[1])
    test.assertEqual("decline 1-1", answered[2])

    prompts:Show({}, {})
    test.assertFalse(prompts.frame.shown)
end)

-- The organizer's window ---------------------------------------------------------

test.test("group finder window: add-on users get Request, then Cancel while it's pending", function()
    local addon = load()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    environment.DetailsFramework = {
        CreateSimplePanel = function()
            local panel = environment.CreateFrame("Frame", nil, nil)
            rawset(panel, "IsShown", function(self) return self.shown end)
            return panel
        end,
    }
    local session = newSession(addon)
    local players = {
        { id = 2, label = "Thunderer", addon = true, current = { key = "hammer", name = "Hammer" },
            fitting = { { name = "Hammer", level = 24 } } },
        { id = 3, label = "Cleric", addon = false, current = { key = "cleric", name = "Cleric" },
            fitting = { { name = "Cleric", level = 20 } } },
    }
    local candidates = {
        Suggestions = function() return { { role = "healer", players = players } } end,
        Counts = function() return { tank = 0, healer = 2, dps = 0 } end,
    }
    local calls = {}
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES }) end,
        playerLevel = function() return 24 end,
        session = session,
        roles = addon.RoleCatalog.For("forever"),
        candidates = function() return candidates end,
        request = function(entry)
            table.insert(calls, "request " .. entry.label)
            session:Request({ playerId = entry.id, key = entry.current.key, label = entry.label }, NOW)
        end,
        cancelRequest = function(id)
            table.insert(calls, "cancel " .. id)
            session:Cancel(id)
        end,
    })
    window:Toggle()

    -- Line 1 is the role heading; Thunderer is line 2, Cleric (no add-on) 3.
    test.assertFalse(window.suggestionButtons[1].button.shown)
    test.assertTrue(window.suggestionButtons[2].button.shown)
    test.assertEqual("Request", window.suggestionButtons[2].button.text)
    test.assertFalse(window.suggestionButtons[3].button.shown)

    window.suggestionButtons[2].button.scripts.OnClick()
    test.assertEqual("request Thunderer", calls[1])
    test.assertEqual("Cancel", window.suggestionButtons[2].button.text)
    test.assertContains(window.suggestionLines[2].text, "[pending]")

    window.suggestionButtons[2].button.scripts.OnClick()
    test.assertContains(calls[2], "cancel ")
    test.assertContains(window.suggestionLines[2].text, "[cancelled]")
    test.assertEqual("Request", window.suggestionButtons[2].button.text)
end)

-- Two add-on users in the composed add-on -----------------------------------------

local TEST_DUNGEON = { id = "test", name = "Test Dungeon", minLevel = 60, maxLevel = 80 }

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
            { name = "Wrench-Area52", class = "MAGE", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Retail", { guild = guild(), playerName = playerName })
    fixtures.joinChannel(channel, world)
    local addon = fixtures.loadAddon(world)
    world.window = { open = false }
    function world.window:Toggle()
        self.open = not self.open
        return self.open
    end
    function world.window:Refresh() end
    function world.window:Picked() return TEST_DUNGEON end
    addon.GroupFinderWindow.Create = function(_, options)
        world.window.options = options
        return world.window
    end
    -- The fixtures' frames can't draw the prompt, so it records what it's
    -- asked to show.
    world.shown = {}
    addon.joinPrompts.Show = function(_, prompts, handlers)
        world.shown = prompts
        world.handlers = handlers
        return true
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

-- The organizer opens the Group Finder, starts a group, and asks Hammer.
local function organize()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local invitee = login(channel, "Hammer-Area52")
    local bystander = login(channel, "Wrench-Area52")
    fixtures.deliver(channel)
    fixtures.slash(organizer, "group")
    organizer.addon.groupSession:Start("test")
    organizer.window.options.request({
        id = 99, label = "Hammer", current = { key = "hammer-area52", name = "Hammer" },
    })
    fixtures.deliver(channel)
    return channel, organizer, invitee, bystander
end

test.test("join requests: the invitee is prompted, and only the invitee", function()
    local _, _, invitee, bystander = organize()

    local prompt = invitee.addon.joinRequests:Pending()[1]
    test.assertEqual("toolbox-area52", prompt.organizer)
    test.assertEqual("Test Dungeon", prompt.dungeon.name)
    -- Every role is open; a paladin offers all three.
    test.assertEqual(3, #prompt.options)
    test.assertEqual(1, #invitee.shown)
    test.assertEqual(0, #bystander.addon.joinRequests:Pending())
end)

test.test("join requests: accepting locks the invitee into the organizer's slot", function()
    local channel, organizer, invitee = organize()
    local prompt = invitee.addon.joinRequests:Pending()[1]

    -- Healer is the second option.
    invitee.handlers.accept(prompt.id, 2)
    fixtures.deliver(channel)

    local session = organizer.addon.groupSession
    test.assertEqual("accepted", session:Requests()[1].state)
    test.assertEqual("hammer-area52", session:Slots()[2].member.key)
    test.assertEqual(0, #invitee.addon.joinRequests:Pending())
    test.assertTrue(prompt ~= nil)
end)

test.test("join requests: Decline shows as declined to the organizer", function()
    local channel, organizer, invitee = organize()

    invitee.handlers.decline(invitee.shown[1].id)
    fixtures.deliver(channel)

    test.assertEqual("declined", organizer.addon.groupSession:Requests()[1].state)
end)

test.test("join requests: cancelling closes the invitee's prompt", function()
    local channel, organizer, invitee = organize()
    local request = organizer.addon.groupSession:Requests()[1]

    organizer.window.options.cancelRequest(request.id)
    fixtures.deliver(channel)

    test.assertEqual("cancelled", request.state)
    test.assertEqual(0, #invitee.addon.joinRequests:Pending())
    test.assertEqual(0, #invitee.shown)
end)

test.test("join requests: both sides expire after about 2 minutes", function()
    local _, organizer, invitee = organize()

    fixtures.runTimers(organizer, 125)
    fixtures.runTimers(invitee, 125)

    test.assertEqual("expired", organizer.addon.groupSession:Requests()[1].state)
    test.assertEqual(0, #invitee.addon.joinRequests:Pending())
end)

test.test("join requests: an unavailable invitee declines automatically", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local invitee = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    fixtures.slash(invitee, "dnd")
    fixtures.slash(organizer, "group")
    organizer.addon.groupSession:Start("test")

    organizer.window.options.request({ id = 99, label = "Hammer", current = { key = "hammer-area52", name = "Hammer" } })
    fixtures.deliver(channel)

    test.assertEqual(0, #invitee.addon.joinRequests:Pending())
    test.assertEqual("declined", organizer.addon.groupSession:Requests()[1].state)
end)
