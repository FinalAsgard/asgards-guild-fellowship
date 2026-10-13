local test = require("tests.test_helper")

-- Every dungeon of `catalog`, lowest range first: with no level, none fits.
local function everyDungeon(catalog)
    local _, all = catalog:Split(nil)
    return all
end
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

-- Edge cases found in review of the Group Finder.

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000
local DEADMINES = { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 }
local SFK = { id = "sfk", name = "Shadowfang Keep", minLevel = 22, maxLevel = 30 }

local function load()
    return test.newAddon("Core/FellowshipStore.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Core/GroupFinderProtocol.lua", "Core/JoinRequests.lua", "Core/GroupHistory.lua", "Core/DungeonCatalog.lua",
        "Adapters/GroupFinderWindow.lua")
end

local ME = { key = "Player-1", name = "Me", classToken = "WARRIOR", inGuild = true, isPlayer = true }

-- Group history ------------------------------------------------------------------

local function newHistory()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    return partition, addon.GroupHistory.Create(partition)
end

test.test("group history: a guildmate swapped for another doesn't make it a new party", function()
    local partition, history = newHistory()

    history:OnParty({ "a", "b" }, NOW)
    history:OnParty({ "a" }, NOW + 60)
    local changed = history:OnParty({ "a", "c" }, NOW + 120)

    test.assertEqual(1, #partition:GetGroupHistory())
    test.assertEqual("a,b,c", table.concat(changed.characters, ","))
    test.assertEqual(1, (history:Stats({ "a" })))
end)

test.test("group history: a dungeon learned after the party was recorded is added", function()
    local partition, history = newHistory()
    history:OnParty({ "a" }, NOW)

    local changed = history:OnParty({ "a" }, NOW + 60, "The Deadmines")

    test.assertEqual("The Deadmines", changed.dungeon)
    test.assertEqual("The Deadmines", partition:GetGroupHistory()[1].dungeon)
    test.assertEqual(nil, history:OnParty({ "a" }, NOW + 120, "Somewhere Else"))
end)

-- Dungeon order ---------------------------------------------------------------------

test.test("dungeon catalog: identical dungeons keep one order, by id", function()
    local addon = load()
    local catalog = addon.DungeonCatalog.Create({
        { id = 12, name = "Same", minLevel = 10, maxLevel = 20 },
        { id = 3, name = "Same", minLevel = 10, maxLevel = 20 },
        { id = "b", name = "Same", minLevel = 10, maxLevel = 20 },
    })

    local all = everyDungeon(catalog)
    test.assertEqual("12,3,b", tostring(all[1].id) .. "," .. tostring(all[2].id) .. "," .. tostring(all[3].id))
end)

-- Requests -------------------------------------------------------------------------

local function newSession(addon)
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    session:UpdateParty({ ME }, false)
    return session
end

test.test("group session: leaving the party cancels the requests still waiting and hands them back", function()
    local addon = load()
    local session = newSession(addon)
    session:UpdateParty({ ME, { key = "Player-2", name = "Zap", classToken = "MAGE", inGuild = true } }, true)
    local waiting = session:Request({ playerId = 2, key = "hammer", label = "Hammer" }, NOW, "me")

    local still, dropped = session:UpdateParty({ ME }, false)

    test.assertFalse(still)
    test.assertEqual(1, #dropped)
    test.assertEqual(waiting.id, dropped[1].id)
    test.assertEqual("cancelled", dropped[1].state)
    test.assertFalse(session:IsActive())
end)

test.test("group session: the organizer can let go of an accepted invitee who hasn't joined", function()
    local addon = load()
    local session = newSession(addon)
    local request = session:Request({ playerId = 2, key = "hammer", label = "Hammer" }, NOW, "me")
    session:Answer(request.id, "hammer", { role = "healer", key = "bolt", name = "Bolt", level = 22 })
    test.assertEqual("Bolt", session:Slots()[2].member.name)

    test.assertEqual(request, session:Cancel(request.id))

    test.assertEqual("cancelled", request.state)
    test.assertEqual(nil, session:Slots()[2].member)
    -- Once they're in the party, there's nothing to cancel.
    local joined = session:Request({ playerId = 3, key = "anvil", label = "Anvil" }, NOW, "me")
    session:Answer(joined.id, "anvil", { role = "healer", key = "anvil", name = "Anvil", level = 22 })
    session:UpdateParty({ ME, { key = "Player-3", name = "Anvil", classToken = "PRIEST", inGuild = true, rosterKey = "anvil" } },
        true)
    test.assertEqual(nil, session:Cancel(joined.id))
end)

test.test("join requests: a repeated request that's refused closes the prompt it repeats", function()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter("hammer", { name = "Hammer", classToken = "PALADIN", level = 24 })
    local available = true
    local requests = addon.JoinRequests.Create({
        partition = function() return partition end,
        roles = addon.RoleCatalog.For("forever"),
        selfKey = function() return "hammer" end,
        available = function() return available end,
    })
    local message = addon.GroupFinderProtocol.Request("hammer", "me:1", DEADMINES, { "healer" })
    requests:OnRequest(message, "me", "Me", NOW)
    test.assertEqual(1, #requests:Pending())

    available = false
    test.assertEqual("unavailable", requests:OnRequest(message, "me", "Me", NOW + 5))

    test.assertEqual(0, #requests:Pending())
end)

-- The window --------------------------------------------------------------------

local function newWindow(addon, session, calls)
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES, SFK }) end,
        playerLevel = function() return 24 end,
        session = session,
        roles = addon.RoleCatalog.For("forever"),
        cancelRequest = function(id)
            table.insert(calls, id)
            session:Cancel(id)
        end,
    })
    window:Opened()
    return window
end

test.test("group finder window: the dungeon list fits the left column", function()
    local addon = load()
    local window = newWindow(addon, newSession(addon), {})

    test.assertEqual(addon.GroupFinderWindow.LEFT_WIDTH - 2 * addon.GroupFinderWindow.PADDING - 22, window.list.width)
end)

test.test("group finder window: changing the dungeon cancels the requests sent for the old one", function()
    local addon = load()
    local session = newSession(addon)
    local calls = {}
    local window = newWindow(addon, session, calls)
    local request = session:Request({ playerId = 2, key = "hammer", label = "Hammer" }, NOW, "me")

    window.changeButton.scripts.OnClick()
    window:Pick("dm")
    test.assertEqual(0, #calls)
    window:Pick("sfk")

    test.assertEqual(request.id, calls[1])
    test.assertEqual("cancelled", request.state)
    test.assertEqual("sfk", session:Dungeon())
end)

test.test("group finder window: an accepted invitee's slot has Cancel, which opens the slot", function()
    local addon = load()
    local session = newSession(addon)
    local calls = {}
    local window = newWindow(addon, session, calls)
    local request = session:Request({ playerId = 2, key = "hammer", label = "Hammer" }, NOW, "me")
    session:Answer(request.id, "hammer", { role = "healer", key = "bolt", name = "Bolt", level = 22 })
    window:Refresh()
    local row = window.slotRows[2]

    test.assertTrue(row.cancel.shown)
    test.assertFalse(window.slotRows[1].cancel.shown)
    row.cancel.scripts.OnClick()

    test.assertEqual(request.id, calls[1])
    test.assertEqual("open", row.text.text)
    test.assertFalse(row.cancel.shown)
end)

-- The composed add-on: leaving the party tells waiting invitees -----------------------

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
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Retail", { guild = guild(), playerName = playerName })
    fixtures.joinChannel(channel, world)
    world.grouped = false
    world.environment.IsInGroup = function() return world.grouped end
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
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

test.test("composed: an organizer leaving the party closes the prompts still waiting", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local invitee = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("test")
    organizer.grouped = true
    fixtures.fire(organizer, "GROUP_ROSTER_UPDATE")
    organizer.window.options.request({ id = 2, label = "Hammer", current = { key = "hammer-area52", name = "Hammer" } })
    fixtures.deliver(channel)
    test.assertEqual(1, #invitee.shown)

    organizer.grouped = false
    fixtures.fire(organizer, "GROUP_ROSTER_UPDATE")
    fixtures.deliver(channel)

    test.assertFalse(organizer.addon.groupSession:IsActive())
    test.assertEqual(0, #invitee.shown)
end)

-- Adversarial review ----------------------------------------------------------------

local function countDraws(window)
    local draws = 0
    local original = window.draw
    window.draw = function(self)
        draws = draws + 1
        return original(self)
    end
    return function()
        return draws
    end
end

test.test("group finder window: the tab isn't redrawn while it's out of view", function()
    local addon = load()
    local window = newWindow(addon, newSession(addon), {})
    local draws = countDraws(window)

    window.panel:Hide()
    window:Refresh()
    test.assertEqual(0, draws())

    window.panel:Show()
    window:Opened()
    test.assertEqual(1, draws())
    window:Refresh()
    test.assertEqual(2, draws())
end)

test.test("composed: with every role filled, Request makes no request", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    fixtures.openGroupFinder(organizer)
    local session = organizer.addon.groupSession
    session:Start("test")
    -- Five party members fill every slot.
    session:UpdateParty({
        { key = "p1", name = "Me", classToken = "WARRIOR", isPlayer = true, inGuild = true },
        { key = "p2", name = "Cleric", classToken = "PRIEST", inGuild = true },
        { key = "p3", name = "Zap", classToken = "MAGE", inGuild = true },
        { key = "p4", name = "Stab", classToken = "ROGUE", inGuild = true },
        { key = "p5", name = "Shot", classToken = "HUNTER", inGuild = true },
    }, true)
    organizer.sentMessages = {}

    organizer.window.options.request({ id = 2, label = "Hammer", current = { key = "hammer-area52", name = "Hammer" } })

    test.assertEqual(0, #session:Requests())
    test.assertEqual(0, #organizer.sentMessages)
end)

test.test("composed: slot updates wait until the organizer is out of combat", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local invitee = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("test")
    organizer.window.options.request({ id = 2, label = "Hammer", current = { key = "hammer-area52", name = "Hammer" } })
    fixtures.deliver(channel)
    test.assertEqual(3, #invitee.shown[1].options)

    -- In combat, the organizer (a warrior) is seen in a party: the tank
    -- slot fills.
    organizer.environment.UnitName = function(unit)
        return unit == "player" and "Toolbox" or nil
    end
    organizer.environment.UnitClass = function(unit)
        return "Warrior", unit == "player" and "WARRIOR" or nil
    end
    organizer.grouped = true
    organizer.inCombat = true
    organizer.sentMessages = {}
    fixtures.fire(organizer, "GROUP_ROSTER_UPDATE")
    fixtures.deliver(channel)

    test.assertEqual("Toolbox", organizer.addon.groupSession:Slots()[1].member.name)
    test.assertEqual(0, #organizer.sentMessages)
    test.assertEqual(3, #invitee.shown[1].options)

    -- Out of combat, the update goes out.
    organizer.inCombat = false
    fixtures.runTimers(organizer, 3)
    fixtures.deliver(channel)
    test.assertEqual(2, #invitee.shown[1].options)
end)

-- WoW Forever gives party members only their first name, while the roster
-- has "First Last": a guildmate in the party is found by GUID, or else by
-- an unshared first name.
local function foreverGuild()
    return {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box", class = "WARRIOR", level = 60, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge" },
            { name = "Zap Arcane", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
            { name = "Spark Arcane", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 0, 1, 0 }, note = ">Zap Arcane" },
            { name = "Hammer Smith", class = "PALADIN", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
        },
    }
end

local function loginForever(channel, playerName)
    local world = fixtures.newEnvironment("Forever", { guild = foreverGuild(), playerName = playerName })
    fixtures.joinChannel(channel, world)
    world.grouped = false
    world.environment.IsInGroup = function() return world.grouped end
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

-- Puts `units` (unit -> { name, guid, class }) in the organizer's party, as
-- the Forever client reports it, and tells the add-on.
local function joinParty(world, units)
    local environment = world.environment
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit) return units[unit] and units[unit].name end
    environment.UnitGUID = function(unit) return units[unit] and units[unit].guid end
    environment.UnitClass = function(unit)
        return "Localized", units[unit] and units[unit].class, 1
    end
    environment.UnitIsInMyGuild = function(unit) return units[unit] ~= nil end
    world.grouped = true
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
end

local function candidateKeys(world)
    local keys = {}
    local players = world.groupFinderOptions.candidates().players
    local index
    for index = 1, #players do
        local characters = players[index].characters
        local inner
        for inner = 1, #characters do
            keys[characters[inner].key] = true
        end
        keys[players[index].current.key] = true
    end
    return keys
end

test.test("composed: on Forever, a guildmate without the add-on who joins the party leaves the candidates", function()
    local channel = fixtures.newChannel()
    local organizer = loginForever(channel, "Tool Box")
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("sfk")
    test.assertTrue(candidateKeys(organizer)["zap arcane-camelot"])

    joinParty(organizer, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        party1 = { name = "Zap", guid = "Player-1-Zap Arcane", class = "MAGE" },
    })

    local keys = candidateKeys(organizer)
    test.assertEqual(nil, keys["zap arcane-camelot"])
    test.assertEqual(nil, keys["spark arcane-camelot"])
    test.assertTrue(keys["hammer smith-camelot"])
end)

test.test("composed: on Forever, a party member with no GUID is found by an unshared first name", function()
    local channel = fixtures.newChannel()
    local organizer = loginForever(channel, "Tool Box")
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("sfk")

    joinParty(organizer, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        party1 = { name = "Hammer", class = "PALADIN" },
    })

    local keys = candidateKeys(organizer)
    test.assertEqual(nil, keys["hammer smith-camelot"])
    test.assertTrue(keys["zap arcane-camelot"])
end)
