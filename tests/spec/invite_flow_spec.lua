local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local NOW = 1790000000
local DEADMINES = { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 }

local function load()
    return test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/DungeonCatalog.lua",
        "Adapters/GroupFinderWindow.lua")
end

local ME = { key = "Player-1", name = "Me", classToken = "WARRIOR", inGuild = true, isPlayer = true, rosterKey = "me" }

-- A group where Hammer's player accepted to join as DPS on their alt Bolt.
local function accepted(addon)
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    session:UpdateParty({ ME }, false)
    local request = session:Request({ playerId = 2, key = "hammer", label = "Thunderer" }, NOW, "me")
    session:Answer(request.id, "hammer", { role = "dps", key = "bolt", name = "Bolt", level = 22 })
    return session, request
end

-- GroupSession ------------------------------------------------------------------

test.test("invite flow: waiting until the chosen character is online, then ready", function()
    local addon = load()
    local session = accepted(addon)
    local online = {}
    local function isOnline(key)
        return online[key] == true
    end

    local slot = session:Slots()[3]
    test.assertEqual("Bolt", slot.member.name)
    test.assertEqual("waiting", session:InviteState(slot, isOnline))
    -- Being online on another character doesn't count.
    online.hammer = true
    test.assertEqual("waiting", session:InviteState(slot, isOnline))
    online.bolt = true
    test.assertEqual("ready", session:InviteState(slot, isOnline))
    -- Slots without an invitee have no invite state.
    test.assertEqual(nil, session:InviteState(session:Slots()[1], isOnline))
    test.assertEqual(nil, session:InviteState(session:Slots()[2], isOnline))
end)

test.test("invite flow: once the character joins, it takes the slot as a party member", function()
    local addon = load()
    local session, request = accepted(addon)

    -- Bolt is a shaman: by class alone it would heal, but Bolt chose DPS.
    session:UpdateParty({
        ME,
        { key = "Player-9", name = "Bolt", classToken = "SHAMAN", inGuild = true, rosterKey = "bolt" },
    }, true)

    local slots = session:Slots()
    test.assertEqual("Player-9", slots[3].member.key)
    test.assertEqual(nil, slots[2].member)
    test.assertTrue(request.inParty)
    test.assertEqual(nil, session:InviteState(slots[3], function() return true end))
end)

test.test("invite flow: a joined invitee whose party name carries a realm still takes their own slot", function()
    local addon = load()
    local session, request = accepted(addon)

    -- The party gives "Bolt-Stormrage", which didn't resolve to Bolt's
    -- roster key: matched by the name without its realm.
    session:UpdateParty({
        ME,
        { key = "Player-9", name = "Bolt-Stormrage", classToken = "SHAMAN", inGuild = true },
    }, true)

    local slots = session:Slots()
    test.assertTrue(request.inParty)
    test.assertEqual("Player-9", slots[3].member.key)
    -- Not counted twice, and no Invite button left on the slot.
    test.assertEqual(nil, slots[2].member)
    test.assertEqual(nil, slots[4].member)
    test.assertEqual(nil, session:InviteState(slots[3], function() return true end))
    -- Shown without the realm.
    test.assertEqual("Bolt", addon.GroupFinderWindow.MemberLabel(slots[3].member))
end)

test.test("invite flow: a different party member never takes an invitee's slot", function()
    local addon = load()
    local session, request = accepted(addon)

    session:UpdateParty({
        ME,
        { key = "Player-8", name = "Zap", classToken = "MAGE", inGuild = true, rosterKey = "zap" },
    }, true)

    test.assertFalse(request.inParty)
    test.assertEqual("Bolt", session:Slots()[3].member.name)
end)

-- The WoW adapter -------------------------------------------------------------

local function newClient(environment)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(environment)
end

test.test("adapter: the party invite goes through the game's invite call", function()
    local invited = {}
    local retail = newClient({ C_PartyInfo = { InviteUnit = function(name) table.insert(invited, "retail " .. name) end } })
    local older = newClient({ InviteUnit = function(name) table.insert(invited, "global " .. name) end })

    test.assertTrue(retail:InviteToParty("Bolt-Area52"))
    test.assertTrue(older:InviteToParty("Bolt"))
    test.assertEqual("retail Bolt-Area52", invited[1])
    test.assertEqual("global Bolt", invited[2])
    test.assertFalse(older:InviteToParty(""))
    test.assertFalse(newClient({ InviteUnit = function() error("blocked") end }):InviteToParty("Bolt"))
    test.assertFalse(newClient({}):InviteToParty("Bolt"))
end)

-- The window ----------------------------------------------------------------------

local function newWindow(online)
    local addon = load()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local world = { invited = {}, online = online }
    world.session = accepted(addon)
    world.window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES }) end,
        playerLevel = function() return 24 end,
        session = world.session,
        roles = addon.RoleCatalog.For("forever"),
        isOnline = function(key) return world.online[key] == true end,
        invite = function(key) table.insert(world.invited, key) end,
    })
    world.window:Opened()
    return world
end

test.test("group finder window: an accepted invitee on another character reads Waiting for them", function()
    local world = newWindow({})
    local row = world.window.slotRows[3]

    test.assertEqual("Waiting for Bolt to log in", row.text.text)
    test.assertFalse(row.invite.shown)
end)

test.test("group finder window: the Invite button appears once they're on, and only a click invites", function()
    local world = newWindow({})
    local row = world.window.slotRows[3]

    world.online.bolt = true
    world.window:Refresh()

    test.assertTrue(row.invite.shown)
    test.assertEqual("Bolt (22)", row.text.text)
    test.assertEqual(0, #world.invited)
    row.invite.scripts.OnClick()
    test.assertEqual(1, #world.invited)
    test.assertEqual("bolt", world.invited[1])
    -- Other slots never offer an invite.
    test.assertFalse(world.window.slotRows[1].invite.shown)
end)

-- The composed add-on --------------------------------------------------------------

local TEST_DUNGEON = { id = "test", name = "Test Dungeon", minLevel = 60, maxLevel = 80 }

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 70, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
            -- Hammer's alt, offline.
            { name = "Bolt-Area52", class = "SHAMAN", level = 70, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 0, 1, 0 }, note = ">Hammer" },
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Retail", { guild = guild(), playerName = playerName })
    fixtures.joinChannel(channel, world)
    local addon = fixtures.loadAddon(world)
    world.window = { open = false }
    function world.window:Opened()
        self.open = not self.open
        return self.open
    end
    function world.window:Refresh() end
    function world.window:Picked() return TEST_DUNGEON end
    addon.GroupFinderWindow.Create = function(_, _, options)
        world.window.options = options
        return world.window
    end
    world.shown = {}
    addon.joinPrompts.Show = function(_, prompts, handlers)
        world.shown = prompts
        world.handlers = handlers
        return true
    end
    world.invited = {}
    world.environment.C_PartyInfo = {
        InviteUnit = function(name) table.insert(world.invited, name) end,
    }
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

test.test("composed: accepting on an alt reminds the invitee, and the organizer invites that alt once it's on", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local invitee = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("test")
    organizer.window.options.request({ id = 2, label = "Hammer", current = { key = "hammer-area52", name = "Hammer" } })
    fixtures.deliver(channel)

    -- Pick the first option on Bolt.
    local prompt = invitee.shown[1]
    local choice
    local index
    for index = #prompt.options, 1, -1 do
        if prompt.options[index].key == "bolt-area52" then
            choice = index
        end
    end
    invitee.handlers.accept(prompt.id, choice)
    fixtures.deliver(channel)

    test.assertContains(invitee.messages[#invitee.messages], "Log over to Bolt to join Toolbox's group for Test Dungeon")
    local options = organizer.window.options
    test.assertFalse(options.isOnline("bolt-area52"))
    -- Nothing was invited on its own.
    test.assertEqual(0, #organizer.invited)

    organizer.guild.members[3].online = true
    fixtures.fire(organizer, "GUILD_ROSTER_UPDATE")
    test.assertTrue(options.isOnline("bolt-area52"))
    test.assertTrue(options.invite("bolt-area52"))
    test.assertEqual("Bolt-Area52", organizer.invited[1])
end)
