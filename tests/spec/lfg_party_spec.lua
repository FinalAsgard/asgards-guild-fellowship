local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

-- LfgTrigger -------------------------------------------------------------------------

local function newTrigger()
    local addon = test.newAddon("Core/LfgTrigger.lua")
    return addon.LfgTrigger.Create(), addon.LfgTrigger
end

-- The actions `actions` names, joined.
local function names(actions)
    local list = {}
    local index
    for index = 1, #actions do
        list[index] = actions[index].action
    end
    return table.concat(list, ",")
end

local SOLO = { inGroup = false }
local function party(fields)
    local facts = { inGroup = true, isLeader = false, isRaid = false, leaderKey = "tool", listed = false }
    local name, value
    for name, value in pairs(fields or {}) do
        facts[name] = value
    end
    return facts
end

test.test("lfg trigger: a party formed by my invite asks what it's for; a solo listing carries over", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)

    test.assertEqual("ask", names(trigger:Observe(party({ isLeader = true, leaderKey = "me" }), 0)))
    test.assertTrue(trigger:Asking())

    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("joined", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", listed = true }), 0)))
    test.assertFalse(trigger:Asking())
end)

test.test("lfg trigger: joining someone else's party ends a solo listing, and asks nothing", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("end", names(trigger:Observe(party({ listed = true }), 0)))

    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("", names(trigger:Observe(party(), 0)))
end)

test.test("lfg trigger: made leader, I take over a listed party quietly, else I'm asked", function()
    local trigger = newTrigger()
    trigger:Observe(party(), 0)
    local listed = { id = "tool", purpose = "Stratholme" }
    local actions = trigger:Observe(party({ isLeader = true, leaderKey = "me", listingOf = function(key)
        return key == "tool" and listed or nil
    end }), 0)
    test.assertEqual("takeOver", names(actions))
    test.assertEqual(listed, actions[1].listing)
    test.assertFalse(trigger:Asking())

    trigger = newTrigger()
    trigger:Observe(party(), 0)
    test.assertEqual("ask", names(trigger:Observe(party({ isLeader = true, leaderKey = "me",
        listingOf = function() return nil end }), 0)))
end)

test.test("lfg trigger: handing the lead on, becoming a raid, and the party ending", function()
    local trigger = newTrigger()
    trigger:Observe(party({ isLeader = true, leaderKey = "me", listed = true }), 0)

    test.assertEqual("raid", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", listed = true,
        isRaid = true }), 0)))
    test.assertEqual("handOff", names(trigger:Observe(party({ isRaid = true, listed = true }), 0)))
    test.assertEqual("end", names(trigger:Observe({ inGroup = false, listed = true }, 0)))
    -- Not listed, nothing to end.
    trigger:Observe(party(), 0)
    test.assertEqual("", names(trigger:Observe(SOLO, 0)))
end)

test.test("lfg trigger: Not looking snoozes this party; the next party asks again", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me" }), 0)
    trigger:NotLooking()
    test.assertFalse(trigger:Asking())

    -- Lead handed away and back in the same party: still not asked.
    trigger:Observe(party(), 10)
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me" }), 20)))

    trigger:Observe(SOLO, 30)
    test.assertEqual("ask", names(trigger:Observe(party({ isLeader = true, leaderKey = "me" }), 40)))
end)

test.test("lfg trigger: don't ask for 30 minutes covers new parties until then", function()
    local trigger, LfgTrigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me" }), 0)
    trigger:Snooze(100)

    trigger:Observe(SOLO, 200)
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me" }), 300)))
    trigger:Observe(SOLO, 400)
    test.assertEqual("ask", names(trigger:Observe(party({ isLeader = true, leaderKey = "me" }),
        100 + LfgTrigger.SNOOZE_SECONDS)))
end)

-- LfgListing: party roles and sizes ------------------------------------------------------

local function newListing()
    return test.newAddon("Core/LfgProtocol.lua", "Core/LfgListing.lua", "Core/RoleCatalog.lua")
end

test.test("lfg listing: a dungeon role is the game's, else the leader's choice, else the class's first", function()
    local addon = newListing()
    local roles = addon.RoleCatalog.For("forever")
    local members = {
        { key = "a", classToken = "WARRIOR", assignedRole = "dps" },
        { key = "b", classToken = "PALADIN" },
        { key = "c", classToken = "MAGE" },
        { key = "d", classToken = "PRIEST", role = "dps" },
        { key = "e", classToken = "DRUID" },
    }
    local filled = addon.LfgListing.FillRoles(members, { a = "tank", b = "healer", c = "tank" }, function(token)
        return roles:RolesFor(token)
    end)

    -- The game's role wins over a choice; a choice the class can't play is
    -- ignored; a player's own willing role comes before the class's first.
    test.assertEqual("dps", filled[1].role)
    test.assertEqual("healer", filled[2].role)
    test.assertEqual("dps", filled[3].role)
    test.assertEqual("dps", filled[4].role)
    test.assertEqual("tank", filled[5].role)
    test.assertEqual(nil, members[2].role)
end)

test.test("lfg listing: a dungeon party is 1 tank, 1 healer, 3 DPS; questing 5 of any; a raid its players", function()
    local addon = newListing()
    local listing = addon.LfgListing.Create()
    local party = {
        { name = "Tool", role = "tank" }, { name = "Zap", role = "dps" }, { name = "Spark", role = "dps" },
    }
    listing:Start({ kind = "dungeon", dungeon = { name = "Stratholme", minLevel = 58, maxLevel = 60 } }, nil, 0, true)

    local fields = listing:Announcement(party)
    test.assertEqual(3, fields.s)
    test.assertEqual("healer,dps", table.concat(fields.r, ","))
    party[4] = { name = "Bolt", role = "dps" }
    test.assertEqual("healer", table.concat(listing:Announcement(party).r, ","))

    listing:Update({ kind = "questing", zone = "Duskwood" }, nil)
    fields = listing:Announcement(party)
    test.assertEqual(4, fields.s)
    test.assertEqual(5, fields.x)
    test.assertEqual(nil, fields.r)

    listing:Update({ kind = "raid" }, nil)
    local raid = {}
    local index
    for index = 1, 12 do
        raid[index] = { name = "Raider" .. index }
    end
    fields = listing:Announcement(raid)
    test.assertEqual(12, fields.s)
    test.assertEqual(40, fields.x)
    test.assertTrue(addon.LfgProtocol.IsValid(addon.LfgProtocol.Listing(fields)))
    -- A party's listing never runs out the solo way.
    test.assertFalse(listing:Expired(60 * 60, 1))
end)

-- The composed add-on ----------------------------------------------------------------

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box", class = "WARRIOR", level = 60, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge" },
            { name = "Hammer Smith", class = "PALADIN", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
            { name = "Zap Arcane", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Forever", { guild = guild(), playerName = playerName })
    world.playerLevel = 60
    world.grouped = false
    world.environment.IsInGroup = function() return world.grouped end
    world.environment.IsInRaid = function() return false end
    fixtures.joinChannel(channel, world)
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    local index
    for index = #world.messages, 1, -1 do
        table.remove(world.messages, index)
    end
    fakeFrames.install(world.environment)
    addon.lfgButton:Refresh()
    return world, addon
end

local CHARACTERS = {
    ["Tool Box"] = { class = "WARRIOR" },
    ["Hammer Smith"] = { class = "PALADIN" },
    ["Zap Arcane"] = { class = "MAGE" },
}

-- Puts `world` in a party of `names` (the player among them), led by
-- `leader`. Forever gives party members their first name only.
local function partyUp(world, names, leader)
    local units = {}
    local others = 0
    local index
    for index = 1, #names do
        local name = names[index]
        local unit
        if name == world.playerName then
            unit = "player"
        else
            others = others + 1
            unit = "party" .. others
        end
        units[unit] = { name = string.match(name, "^(%S+)"), guid = "Player-1-" .. name,
            class = CHARACTERS[name].class, leader = name == leader }
    end
    local environment = world.environment
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit) return units[unit] and units[unit].name end
    environment.UnitGUID = function(unit) return units[unit] and units[unit].guid end
    environment.UnitClass = function(unit) return "Localized", units[unit] and units[unit].class, 1 end
    environment.UnitLevel = function() return 60 end
    environment.UnitIsInMyGuild = function(unit) return units[unit] ~= nil end
    environment.UnitIsGroupLeader = function(unit) return units[unit] ~= nil and units[unit].leader end
    world.grouped = #names > 1
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
end

local function leaveParty(world)
    world.grouped = false
    world.environment.UnitExists = function(unit) return unit == "player" end
    world.environment.UnitIsGroupLeader = function() return false end
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
end

local function click(button)
    button.scripts.OnClick(button, "LeftButton")
end

local function roleRow(page, name)
    local index
    for index = 1, #page.roleRows do
        if page.roleRows[index].shown and page.roleRows[index].name.text == name then
            return page.roleRows[index]
        end
    end
    return nil
end

test.test("Forever forming a party opens the drawer to ask; listing it goes through the board with roles", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local zap = login(channel, "Zap Arcane")

    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")

    local button = addon.lfgButton
    test.assertTrue(button:DrawerOpen())
    test.assertEqual("LIST YOUR PARTY?", button.drawer.heading.text)
    test.assertTrue(button.listButton.shown)
    click(button.listButton)

    local page = addon.lfgPage
    test.assertTrue(addon.agfWindow:IsOpen())
    test.assertEqual("edit", page:Mode())
    -- Roles in your party: the warrior can't heal.
    local toolRow = roleRow(page, "Tool")
    local hammerRow = roleRow(page, "Hammer")
    test.assertTrue(toolRow ~= nil and hammerRow ~= nil)
    test.assertFalse(toolRow.buttons[2].enabled)
    test.assertTrue(hammerRow.buttons[2].enabled)
    click(hammerRow.buttons[2])
    test.assertTrue(roleRow(page, "Hammer").buttons[2].selected)

    page.draft.dungeon = addon.DungeonCatalog.For("forever", nil):Get("strat")
    test.assertTrue(page:Save())
    fixtures.deliver(channel)

    local heard = zap.addon.lfgBoard:Listings(zap.time)[1]
    test.assertEqual(2, heard.size)
    test.assertEqual("Stratholme", heard.purpose)
    test.assertEqual("tank", heard.members[1].role)
    test.assertEqual("healer", heard.members[2].role)
    test.assertEqual("dps", table.concat(heard.openRoles, ","))
    -- Asked once: the drawer no longer asks.
    test.assertFalse(addon.lfgTrigger:Asking())
end)

test.test("Forever closing the drawer on the question is Not looking; the snooze skips the next party", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")

    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    click(addon.lfgButton.drawerClose)
    test.assertFalse(addon.lfgTrigger:Asking())
    test.assertFalse(addon.lfgListing:IsActive())
    fixtures.deliver(channel)
    test.assertEqual(0, #channel.queue)

    leaveParty(tool)
    partyUp(tool, { "Tool Box", "Zap Arcane" }, "Tool Box")
    test.assertTrue(addon.lfgButton:DrawerOpen())
    click(addon.lfgButton.snoozeButton)
    leaveParty(tool)
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    test.assertFalse(addon.lfgButton:DrawerOpen())
    test.assertFalse(addon.lfgTrigger:Asking())
end)

test.test("Forever a solo listing becomes the party's when someone joins, and ends when it disbands", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local zap = login(channel, "Zap Arcane")
    test.assertTrue(addon.agfWindow:Open("lfg"))
    addon.lfgPage:StartEditing()
    addon.lfgPage.draft.dungeon = addon.DungeonCatalog.For("forever", nil):Get("strat")
    test.assertTrue(addon.lfgPage:Save())
    fixtures.deliver(channel)

    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    fixtures.deliver(channel)

    test.assertFalse(addon.lfgButton:DrawerOpen())
    test.assertEqual(2, zap.addon.lfgBoard:Listings(zap.time)[1].size)

    leaveParty(tool)
    fixtures.deliver(channel)
    test.assertFalse(addon.lfgListing:IsActive())
    test.assertEqual(0, #zap.addon.lfgBoard:Listings(zap.time))
end)

test.test("Forever in someone else's party, its listing is read-only on the board and the drawer", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    partyUp(hammer, { "Tool Box", "Hammer Smith" }, "Tool Box")
    test.assertFalse(addon.lfgButton:DrawerOpen())
    click(toolAddon.lfgButton.listButton)
    toolAddon.lfgPage.draft.kind = "raid"
    test.assertTrue(toolAddon.lfgPage:Save())
    fixtures.deliver(channel)

    test.assertTrue(addon.agfWindow:Open("lfg"))
    local page = addon.lfgPage
    test.assertEqual("member", page:Mode())
    test.assertEqual("Raid", page.view.purpose.text)
    test.assertContains(page.view.details.text, "led by Tool Box")
    test.assertFalse(page.editButton.shown)
    test.assertFalse(page.notLookingButton.shown)
    -- A member can't list the party.
    local saved, reason = addon.lfgPage.options.onSave({ kind = "raid" }, nil)
    test.assertFalse(saved)
    test.assertEqual("only your party's leader can list it", reason)
end)

test.test("Forever made leader of a listed party, I take its listing over quietly", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    local zap = login(channel, "Zap Arcane")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    partyUp(hammer, { "Tool Box", "Hammer Smith" }, "Tool Box")
    click(toolAddon.lfgButton.listButton)
    toolAddon.lfgPage.draft.dungeon = toolAddon.DungeonCatalog.For("forever", nil):Get("strat")
    toolAddon.lfgPage.draft.note = "Live side"
    test.assertTrue(toolAddon.lfgPage:Save())
    fixtures.deliver(channel)

    -- Tool hands Hammer the lead.
    partyUp(hammer, { "Tool Box", "Hammer Smith" }, "Hammer Smith")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Hammer Smith")
    test.assertFalse(addon.lfgButton:DrawerOpen())
    test.assertTrue(addon.lfgListing:IsActive())
    test.assertEqual("Live side", addon.lfgListing:Note())
    fixtures.runTimers(tool, 5)
    fixtures.deliver(channel)

    test.assertFalse(toolAddon.lfgListing:IsActive())
    local listings = zap.addon.lfgBoard:Listings(zap.time)
    test.assertEqual(1, #listings)
    test.assertEqual("Hammer Smith", listings[1].leader)
    test.assertEqual("Stratholme", listings[1].purpose)
end)
