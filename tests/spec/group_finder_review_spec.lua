local test = require("tests.test_helper")
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

    local all = catalog:All()
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
    environment.DetailsFramework = {
        CreateSimplePanel = function()
            local panel = environment.CreateFrame("Frame", nil, nil)
            rawset(panel, "IsShown", function(self) return self.shown end)
            return panel
        end,
    }
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES, SFK }) end,
        playerLevel = function() return 24 end,
        session = session,
        roles = addon.RoleCatalog.For("forever"),
        cancelRequest = function(id)
            table.insert(calls, id)
            session:Cancel(id)
        end,
    })
    window:Toggle()
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
    fixtures.slash(organizer, "group")
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
