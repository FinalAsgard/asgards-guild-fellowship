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

test.test("lfg listing: a dungeon role is the game's, else the player's own, else the class's first", function()
    local addon = newListing()
    local roles = addon.RoleCatalog.For("forever")
    local members = {
        { key = "a", classToken = "WARRIOR", assignedRole = "dps", role = "tank" },
        { key = "b", classToken = "PALADIN" },
        { key = "c", classToken = "MAGE" },
        { key = "d", classToken = "PRIEST", role = "dps" },
        { key = "e", classToken = "DRUID" },
    }
    local filled = addon.LfgListing.FillRoles(members, function(token)
        return roles:RolesFor(token)
    end)

    -- The game's role (set in its party menu) wins; a player's own willing
    -- role comes before the class's first.
    test.assertEqual("dps", filled[1].role)
    test.assertEqual(roles:RolesFor("PALADIN")[1], filled[2].role)
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

local function login(channel, playerName, addonName)
    local world = fixtures.newEnvironment("Forever", { guild = guild(), playerName = playerName,
        addonName = addonName })
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
    -- Not in the guild.
    ["Stranger Danger"] = { class = "ROGUE", outsider = true },
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
            class = CHARACTERS[name].class, leader = name == leader,
            outsider = CHARACTERS[name].outsider == true }
    end
    local environment = world.environment
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit) return units[unit] and units[unit].name end
    environment.UnitGUID = function(unit) return units[unit] and units[unit].guid end
    environment.UnitClass = function(unit) return "Localized", units[unit] and units[unit].class, 1 end
    environment.UnitLevel = function() return 60 end
    environment.UnitIsInMyGuild = function(unit) return units[unit] ~= nil and not units[unit].outsider end
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
        if page.roleRows[index].shown and page.roleRows[index].memberName == name then
            return page.roleRows[index]
        end
    end
    return nil
end

-- The game's party menu gives `name` (a unit's name) the role `role`
-- ("TANK", "HEALER" or "DAMAGER") on `world`'s client.
local function setGameRole(world, name, role)
    world.gameRoles = world.gameRoles or {}
    world.gameRoles[name] = role
    local environment = world.environment
    environment.UnitGroupRolesAssigned = function(unit)
        local unitName = environment.UnitName and environment.UnitName(unit)
        return unitName and world.gameRoles[unitName] or "NONE"
    end
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
    -- Roles in your party: each member's role icon by their name, the
    -- role the game's party menu gave them.
    local toolRow = roleRow(page, "Tool")
    local hammerRow = roleRow(page, "Hammer")
    test.assertTrue(toolRow ~= nil and hammerRow ~= nil)
    test.assertTrue(toolRow.roleIcon.shown)
    setGameRole(tool, "Hammer", "HEALER")
    page:Refresh()
    test.assertEqual("healer", roleRow(page, "Hammer").role)

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

-- Quiet listings and the hidden button ------------------------------------------------

test.test("lfg trigger: filling up with another guildmate lists it quietly; with none, nothing", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 2, guildmates = 1 }), 0)
    test.assertTrue(trigger:Asking())

    test.assertEqual("listQuietly", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 5,
        guildmates = 1 }), 0)))
    test.assertFalse(trigger:Asking())
    -- Still full: nothing more.
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 5,
        guildmates = 1, listed = true }), 0)))

    -- The only guildmate: nothing happens.
    trigger = newTrigger()
    trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 4, guildmates = 0 }), 0)
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 5,
        guildmates = 0 }), 0)))

    -- Formed full at once: listed, not asked.
    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("listQuietly", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 5,
        guildmates = 2 }), 0)))
    test.assertFalse(trigger:Asking())
end)

test.test("lfg trigger: Not looking keeps a full party off the board; a member never lists it", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 3, guildmates = 2 }), 0)
    trigger:NotLooking()
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 5,
        guildmates = 2 }), 0)))

    trigger = newTrigger()
    trigger:Observe(party({ size = 4, guildmates = 2 }), 0)
    test.assertEqual("", names(trigger:Observe(party({ size = 5, guildmates = 2 }), 0)))
end)

test.test("lfg trigger: with the button hidden, nothing is asked: listed quietly, with a reminder", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("listQuietly,remind", names(trigger:Observe(party({ isLeader = true, leaderKey = "me",
        size = 2, guildmates = 1, hidden = true }), 0)))
    test.assertFalse(trigger:Asking())

    trigger = newTrigger()
    trigger:Observe(party({ size = 3, hidden = true }), 0)
    test.assertEqual("listQuietly,remind", names(trigger:Observe(party({ isLeader = true, leaderKey = "me",
        size = 3, hidden = true, listingOf = function() return nil end }), 0)))
end)

test.test("lfg listing: the guess is the dungeon, else questing here; a guess follows into a dungeon", function()
    local addon = newListing()
    local LfgListing = addon.LfgListing
    local strat = { name = "Stratholme", minLevel = 58, maxLevel = 60 }

    test.assertEqual("dungeon", LfgListing.Guess(strat, "Eastern Plaguelands", nil).kind)
    local questing = LfgListing.Guess(nil, "Duskwood", { minLevel = 18, maxLevel = 30 })
    test.assertEqual("Duskwood", questing.zone)
    test.assertEqual(18, questing.minLevel)
    test.assertEqual(nil, LfgListing.Guess(nil, nil, nil))

    local listing = LfgListing.Create()
    listing:Start(questing, nil, 0, true, true)
    test.assertTrue(listing:Guessed())
    test.assertTrue(listing:EnteredDungeon(strat))
    test.assertEqual("Stratholme", listing:Purpose().dungeon.name)
    test.assertFalse(listing:EnteredDungeon(strat))

    -- Set by hand: left alone.
    listing:Update(questing, nil)
    test.assertFalse(listing:Guessed())
    test.assertFalse(listing:EnteredDungeon(strat))
    test.assertEqual("questing", listing:Purpose().kind)
end)

CHARACTERS["Spark Arcane"] = { class = "MAGE" }
CHARACTERS["Bolt Smith"] = { class = "PRIEST" }

local FIVE = { "Tool Box", "Hammer Smith", "Zap Arcane", "Spark Arcane", "Bolt Smith" }

test.test("Forever a full party with guildmates is listed quietly, guessed, and follows it into a dungeon", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    test.assertTrue(addon.lfgTrigger:Asking())

    partyUp(tool, FIVE, "Tool Box")
    fixtures.deliver(channel)

    test.assertFalse(addon.lfgTrigger:Asking())
    test.assertTrue(addon.lfgListing:Guessed())
    local heard = hammer.addon.lfgBoard:Listings(hammer.time)[1]
    test.assertEqual("questing", heard.kind)
    test.assertEqual("Ironforge", heard.purpose)
    test.assertEqual(5, heard.size)

    tool.environment.GetInstanceInfo = function()
        return "Stratholme", "party"
    end
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    fixtures.deliver(channel)
    heard = hammer.addon.lfgBoard:Listings(hammer.time)[1]
    test.assertEqual("dungeon", heard.kind)
    test.assertEqual("Stratholme", heard.purpose)
end)

test.test("Forever a purpose set by hand stays when the party enters a dungeon", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    click(addon.lfgButton.listButton)
    addon.lfgPage.draft.kind = "raid"
    test.assertTrue(addon.lfgPage:Save())

    tool.environment.GetInstanceInfo = function()
        return "Stratholme", "party"
    end
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")

    test.assertEqual("raid", addon.lfgListing:Purpose().kind)
end)

test.test("Forever a questing leader who changes zones is asked whether to move the listing there", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    click(addon.lfgButton.listButton)
    addon.lfgPage.draft.kind = "questing"
    test.assertTrue(addon.lfgPage:Save())
    addon.lfgButton:CloseDrawer(true)
    local drawer = addon.lfgButton.drawer

    -- Moving zones asks, in the drawer, which opens.
    tool.zone = { name = "Dun Morogh", mapID = tool.zone.mapID }
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    test.assertTrue(addon.lfgButton:DrawerOpen())
    test.assertEqual("zone", drawer.kind)
    test.assertEqual("You're in Dun Morogh now. Move your questing listing here?", drawer.question.text)
    test.assertEqual("Yes", addon.lfgButton.listButton.label.text)
    -- No leaves it where it was, and that zone isn't asked about again.
    click(addon.lfgButton.notLookingButton)
    test.assertEqual("Ironforge", addon.lfgListing:Purpose().zone)
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    test.assertFalse(addon.lfgButton:DrawerOpen())
    -- Every zone said No to stays that way, not just the last one.
    tool.zone = { name = "Wetlands", mapID = tool.zone.mapID }
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual("zone", drawer.kind)
    click(addon.lfgButton.notLookingButton)
    tool.zone = { name = "Dun Morogh", mapID = tool.zone.mapID }
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    test.assertFalse(addon.lfgButton:DrawerOpen())

    -- Another zone asks again; Yes moves it, and guildmates hear.
    tool.zone = { name = "Loch Modan", mapID = tool.zone.mapID }
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual("zone", drawer.kind)
    click(addon.lfgButton.listButton)
    test.assertEqual("Loch Modan", addon.lfgListing:Purpose().zone)
    fixtures.deliver(channel)
    test.assertEqual("Loch Modan", hammer.addon.lfgBoard:Listings(hammer.time)[1].purpose)
    test.assertFalse(addon.lfgButton:DrawerOpen())

    -- A dungeon isn't a zone to quest in: nothing's asked inside one.
    tool.inInstance = "party"
    tool.zone = { name = "Stratholme", mapID = tool.zone.mapID }
    fixtures.fire(tool, "ZONE_CHANGED_NEW_AREA")
    test.assertFalse(addon.lfgButton:DrawerOpen())
end)

test.test("Forever with the button hidden, a new party is listed quietly with a reminder", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    addon.settings:Set("lfgButton", false)
    test.assertFalse(addon.lfgButton:IsShowing())

    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    fixtures.deliver(channel)

    test.assertFalse(addon.lfgButton:DrawerOpen())
    test.assertFalse(addon.lfgTrigger:Asking())
    test.assertTrue(addon.lfgListing:Guessed())
    test.assertContains(tool.messages[#tool.messages],
        "Your party is listed on the Guild LFG Board as Questing in Ironforge. Type /agf lfg to take part.")
    test.assertEqual(1, #hammer.addon.lfgBoard:Listings(hammer.time))
end)

-- Parties led from outside the guild ----------------------------------------------------

test.test("lfg trigger: a party with players outside the guild asks first whether to list it", function()
    local trigger, LfgTrigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual(LfgTrigger.GATE, names(trigger:Observe(party({ isLeader = true, leaderKey = "me",
        outsiders = 1, size = 2 }), 0)))
    test.assertTrue(trigger:Asking())
    test.assertTrue(trigger:Gating())

    -- No: nothing more is asked in this party, even made leader again.
    trigger:NotLooking()
    trigger:Observe(party({ outsiders = 1, size = 2 }), 10)
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", outsiders = 1,
        size = 2 }), 20)))
    test.assertFalse(trigger:Asking())

    -- Made leader of an unlisted party with an outsider in it: asked first.
    trigger = newTrigger()
    trigger:Observe(party({ outsiders = 1, size = 2 }), 0)
    test.assertEqual("gate", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", outsiders = 1,
        size = 2, listingOf = function() return nil end }), 0)))
end)

test.test("lfg trigger: a party with outsiders is never listed quietly", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", outsiders = 1,
        size = 2, hidden = true }), 0)))

    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 2, outsiders = 1 }), 0)
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 5,
        guildmates = 1, outsiders = 3 }), 0)))
    test.assertTrue(trigger:Gating())
end)

test.test("lfg trigger: led from outside the guild, its guildmates are asked; the first yes is contact", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("gate", names(trigger:Observe(party({ leaderKey = "stranger", guildLed = false,
        outsiders = 1, selfKey = "me", present = { "me", "zap" } }), 0)))

    -- I say yes.
    trigger:Claim("me")
    test.assertEqual("me", trigger:Contact())
    test.assertFalse(trigger:Asking())

    -- Someone else said yes first: they're contact, and I'm not asked.
    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ leaderKey = "stranger", guildLed = false, outsiders = 1, selfKey = "me",
        present = { "me", "zap" } }), 0)
    test.assertFalse(trigger:Claimed("zap", "me"))
    test.assertEqual("zap", trigger:Contact())
    test.assertFalse(trigger:Asking())

    -- Both at once: the lower key keeps it.
    trigger:Claim("me")
    test.assertFalse(trigger:Claimed("zap", "me"))
    test.assertEqual("me", trigger:Contact())
    test.assertTrue(trigger:Claimed("amy", "me"))
    test.assertEqual("amy", trigger:Contact())

    -- Hidden button: never asked.
    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    test.assertEqual("", names(trigger:Observe(party({ leaderKey = "stranger", guildLed = false, outsiders = 1,
        selfKey = "me", present = { "me" }, hidden = true }), 0)))
end)

test.test("lfg trigger: handing the lead to someone outside the guild keeps me on as contact", function()
    local trigger = newTrigger()
    trigger:Observe(party({ isLeader = true, leaderKey = "me", listed = true, selfKey = "me" }), 0)
    test.assertEqual("claim", names(trigger:Observe(party({ leaderKey = "stranger", guildLed = false,
        outsiders = 1, listed = true, selfKey = "me", present = { "me" } }), 0)))
    test.assertEqual("me", trigger:Contact())
    -- Nothing changes while I'm still there.
    test.assertEqual("", names(trigger:Observe(party({ leaderKey = "stranger", guildLed = false,
        outsiders = 1, listed = true, selfKey = "me", present = { "me" } }), 0)))
end)

test.test("lfg trigger: when the contact or guild leader goes, the first guildmate left takes it over", function()
    local listed = { id = "tool", purpose = "Stratholme" }
    local function listingOf(key)
        return key == "tool" and listed or nil
    end
    local function led(fields)
        local facts = party({ leaderKey = "stranger", guildLed = false, outsiders = 1, selfKey = "me",
            listingOf = listingOf })
        local name, value
        for name, value in pairs(fields) do
            facts[name] = value
        end
        return facts
    end

    -- The contact (tool) leaves; I'm first of those left.
    local trigger = newTrigger()
    trigger:Observe(led({ present = { "me", "tool" } }), 0)
    trigger:Claimed("tool", "me")
    local actions = trigger:Observe(led({ present = { "me", "zap" } }), 10)
    test.assertEqual("takeOver,claim", names(actions))
    test.assertEqual(listed, actions[1].listing)
    test.assertEqual("me", trigger:Contact())

    -- Someone else is first: they take it, I do nothing.
    trigger = newTrigger()
    trigger:Observe(led({ present = { "me", "tool" } }), 0)
    trigger:Claimed("tool", "me")
    test.assertEqual("", names(trigger:Observe(led({ present = { "amy", "me" } }), 10)))
    test.assertEqual("amy", trigger:Contact())

    -- The guild leader logs off (the lead stays with them): taken over too.
    trigger = newTrigger()
    trigger:Observe(party({ leaderKey = "tool", selfKey = "me", present = { "me", "tool" } }), 0)
    test.assertEqual("takeOver,claim", names(trigger:Observe(led({ leaderKey = "tool", outsiders = 0,
        present = { "me" } }), 10)))

    -- Nothing was listed: nothing to take over, and nobody's asked again.
    trigger = newTrigger()
    trigger:Observe(led({ present = { "me", "tool" } }), 0)
    trigger:Claimed("tool", "me")
    test.assertEqual("", names(trigger:Observe(led({ present = { "me" }, listingOf = function() return nil end }),
        10)))
end)

-- LfgProtocol and LfgBoard: contacts ---------------------------------------------------

test.test("lfg protocol: contact claims, contact listings and ends by leaving are validated", function()
    local addon = test.newAddon("Core/LfgProtocol.lua")
    local protocol = addon.LfgProtocol
    test.assertTrue(protocol.IsValid(protocol.Contact("Stranger")))
    test.assertFalse(protocol.IsValid(protocol.Contact(nil)))
    test.assertFalse(protocol.IsValid(protocol.Contact("")))
    test.assertFalse(protocol.IsValid(protocol.Contact(string.rep("a", protocol.TEXT_LETTERS + 1))))
    test.assertFalse(protocol.IsValid(protocol.Contact(7)))

    test.assertTrue(protocol.IsValid(protocol.End(true)))
    test.assertEqual(true, protocol.End(true).lf)
    test.assertEqual(nil, protocol.End().lf)
    local bad = protocol.End()
    bad.lf = "yes"
    test.assertFalse(protocol.IsValid(bad))

    local listing = protocol.Listing({ k = "raid", s = 1, x = 40, mb = { { n = "Tool" } }, aj = true, ct = true })
    test.assertTrue(protocol.IsValid(listing))
    listing.ct = false
    test.assertFalse(protocol.IsValid(listing))
end)

test.test("lfg board: a listing ended by leaving is kept for a guildmate to take over", function()
    local addon = test.newAddon("Core/LfgProtocol.lua", "Core/LfgRelevance.lua", "Core/LfgBoard.lua")
    local board = addon.LfgBoard.Create()
    local message = addon.LfgProtocol.Listing({ k = "raid", s = 2, x = 40,
        mb = { { n = "Stranger" }, { n = "Tool" } }, aj = true, ct = true })
    board:OnListing(message, "tool", "Tool-Camelot", 0)
    test.assertTrue(board:Get("tool", 0).contact)
    board:OnEnd("tool", true)
    test.assertEqual(nil, board:Get("tool", 0))
    test.assertEqual("Tool", board:Ended("tool").leader)

    -- Heard again, it's live; ended plainly, it's gone for good.
    board:OnListing(message, "tool", "Tool-Camelot", 10)
    test.assertEqual(nil, board:Ended("tool"))
    board:OnEnd("tool")
    test.assertEqual(nil, board:Ended("tool"))
end)

test.test("lfg listing: a listing announced by its contact says so", function()
    local addon = test.newAddon("Core/LfgProtocol.lua", "Core/LfgListing.lua")
    local listing = addon.LfgListing.Create()
    listing:Start({ kind = "raid" }, nil, 0, true)
    test.assertEqual(true, listing:Announcement({ { name = "Stranger", isPlayer = false },
        { name = "Tool", isPlayer = true } }).ct)
    test.assertEqual(nil, listing:Announcement({ { name = "Tool", isPlayer = true } }).ct)
end)

test.test("Forever a party led from outside the guild: the first guildmate to say yes is its contact", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    local zap = login(channel, "Zap Arcane")
    local members = { "Stranger Danger", "Tool Box", "Hammer Smith" }
    partyUp(tool, members, "Stranger Danger")
    partyUp(hammer, members, "Stranger Danger")

    -- Both guildmates are asked whether to list it.
    local button = toolAddon.lfgButton
    test.assertTrue(button:DrawerOpen())
    test.assertEqual(toolAddon.LfgButton.GATE_TEXT, button.drawer.question.text)
    test.assertEqual("Yes", button.listButton.label.text)
    test.assertFalse(button.snoozeButton.shown)
    test.assertTrue(addon.lfgTrigger:Gating())

    -- Tool says yes first, and lists it as its contact.
    click(button.listButton)
    fixtures.deliver(channel)
    test.assertFalse(addon.lfgTrigger:Asking())
    test.assertEqual("edit", toolAddon.lfgPage:Mode())
    toolAddon.lfgPage.draft.kind = "raid"
    test.assertTrue(toolAddon.lfgPage:Save())
    fixtures.deliver(channel)

    local heard = zap.addon.lfgBoard:Listings(zap.time)[1]
    test.assertTrue(heard.contact)
    test.assertEqual("Tool Box", heard.leader)
    test.assertEqual("Stranger", heard.members[1].name)
    test.assertTrue(zap.addon.agfWindow:Open("lfg"))
    local card = zap.addon.lfgPage.largeCards[1]
    test.assertContains(card.details.text, "contact Tool Box")
    test.assertEqual("Whisper Tool Box", card.whisper.label.text)
    -- Whisper goes to the contact, who speaks for the party; the leader's
    -- own name (its menu) whispers the leader.
    test.assertEqual("Stranger", card.members[1].whisper)

    -- Hammer sees it read-only, named by its contact, and can't edit it.
    test.assertTrue(addon.agfWindow:Open("lfg"))
    test.assertEqual("member", addon.lfgPage:Mode())
    test.assertContains(addon.lfgPage.view.details.text, "contact Tool Box")
    local saved = addon.lfgPage.options.onSave({ kind = "raid" }, nil)
    test.assertFalse(saved)
end)

test.test("Forever when the contact leaves, a guildmate still in the party takes the listing over", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    local zap = login(channel, "Zap Arcane")
    local members = { "Stranger Danger", "Tool Box", "Hammer Smith" }
    partyUp(tool, members, "Stranger Danger")
    partyUp(hammer, members, "Stranger Danger")
    click(toolAddon.lfgButton.listButton)
    fixtures.deliver(channel)
    toolAddon.lfgPage.draft.kind = "raid"
    toolAddon.lfgPage.draft.note = "Come along"
    test.assertTrue(toolAddon.lfgPage:Save())
    fixtures.deliver(channel)

    leaveParty(tool)
    fixtures.deliver(channel)
    partyUp(hammer, { "Stranger Danger", "Hammer Smith" }, "Stranger Danger")
    fixtures.deliver(channel)

    test.assertTrue(addon.lfgListing:IsActive())
    test.assertEqual("Come along", addon.lfgListing:Note())
    local listings = zap.addon.lfgBoard:Listings(zap.time)
    test.assertEqual(1, #listings)
    test.assertEqual("Hammer Smith", listings[1].leader)
    test.assertTrue(listings[1].contact)

    -- With no guildmate left, the listing goes with the last one.
    leaveParty(hammer)
    fixtures.deliver(channel)
    test.assertEqual(0, #zap.addon.lfgBoard:Listings(zap.time))
end)

test.test("Forever when a listed guild leader logs off, a guildmate in the party takes the listing over", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    local zap = login(channel, "Zap Arcane")
    local members = { "Tool Box", "Hammer Smith", "Stranger Danger" }
    partyUp(tool, members, "Tool Box")
    partyUp(hammer, members, "Tool Box")
    -- The leader is asked first whether to list a party with an outsider.
    test.assertTrue(toolAddon.lfgTrigger:Gating())
    click(toolAddon.lfgButton.listButton)
    toolAddon.lfgPage.draft.kind = "raid"
    test.assertTrue(toolAddon.lfgPage:Save())
    fixtures.deliver(channel)
    test.assertEqual(1, #zap.addon.lfgBoard:Listings(zap.time))

    -- Tool logs off, still leading.
    hammer.environment.UnitIsConnected = function(unit) return unit ~= "party1" end
    fixtures.fire(hammer, "CHAT_MSG_SYSTEM", "Tool Box has gone offline.")
    fixtures.fire(zap, "CHAT_MSG_SYSTEM", "Tool Box has gone offline.")
    fixtures.deliver(channel)

    test.assertTrue(addon.lfgListing:IsActive())
    test.assertEqual(hammer.addon.rosterController:SelfKey(), addon.lfgTrigger:Contact())
    local listings = zap.addon.lfgBoard:Listings(zap.time)
    test.assertEqual(1, #listings)
    test.assertEqual("Hammer Smith", listings[1].leader)
    test.assertTrue(listings[1].contact)
end)

-- Ask to join --------------------------------------------------------------------------

-- Tool lists Stratholme alone; Hammer opens the board.
local function listedStrat(channel)
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    test.assertTrue(toolAddon.agfWindow:Open("lfg"))
    toolAddon.lfgPage:StartEditing()
    toolAddon.lfgPage.draft.dungeon = toolAddon.DungeonCatalog.For("forever", nil):Get("strat")
    test.assertTrue(toolAddon.lfgPage:Save())
    fixtures.deliver(channel)
    test.assertTrue(addon.agfWindow:Open("lfg"))
    return tool, toolAddon, hammer, addon
end

test.test("Forever Ask to join reaches the leader as a request under the drawer; Invite invites", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    local invited
    tool.environment.C_PartyInfo = { InviteUnit = function(name) invited = name end }
    test.assertFalse(toolAddon.lfgButton:DrawerOpen())

    local card = addon.lfgPage.largeCards[1]
    test.assertTrue(card.ask.shown)
    test.assertEqual("Ask to join", card.ask.label.text)
    click(card.ask)
    -- The paladin could heal or DPS: a menu picks.
    test.assertTrue(addon.lfgPage.roleMenu:IsOpen())
    click(addon.lfgPage.roleMenu.rows[1])
    test.assertEqual("pending", addon.lfgBoard:Request(card.listing.id, hammer.time).state)
    addon.lfgPage:Refresh()
    test.assertEqual("Asked \194\183 pending", card.ask.label.text)
    fixtures.deliver(channel)

    -- The leader's drawer opens with the request under it.
    local button = toolAddon.lfgButton
    test.assertTrue(button:DrawerOpen())
    local toast = button.toasts[1]
    test.assertTrue(toast.shown)
    test.assertContains(toast.name.text, "Hammer")
    test.assertEqual("Healer, 60", toast.details.text)
    -- Nothing was invited by itself.
    test.assertEqual(nil, invited)

    click(toast.invite)
    test.assertEqual("Hammer Smith", string.match(invited, "^[^%-]+"))
    test.assertFalse(toast.shown)
    fixtures.deliver(channel)
    test.assertEqual("accepted", addon.lfgBoard:Request(card.listing.id, hammer.time).state)
    addon.lfgPage:Refresh()
    test.assertEqual("Invited", card.ask.label.text)
end)

test.test("Forever Decline tells the asker no", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    local card = addon.lfgPage.largeCards[1]
    click(card.ask)
    click(addon.lfgPage.roleMenu.rows[2])
    fixtures.deliver(channel)
    test.assertEqual("DPS, 60", toolAddon.lfgButton.toasts[1].details.text)

    click(toolAddon.lfgButton.toasts[1].decline)
    fixtures.deliver(channel)
    test.assertEqual("declined", addon.lfgBoard:Request(card.listing.id, hammer.time).state)
end)

test.test("Forever a leader with the LFG button hidden is whispered instead, and takes no asks", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    toolAddon.lfgButton.options.onHide()
    fixtures.deliver(channel)

    addon.lfgPage:Refresh()
    local card = addon.lfgPage.largeCards[1]
    test.assertFalse(card.ask.shown)
    test.assertTrue(card.whisper.shown)
    test.assertEqual("Whisper Tool Box", card.whisper.label.text)

    -- An ask sent anyway goes nowhere.
    addon.lfgPage.options.onAsk(card.listing, "healer")
    fixtures.deliver(channel)
    test.assertFalse(toolAddon.lfgButton:DrawerOpen())
end)

test.test("Forever an unanswered request expires after two minutes, and the asker hears so", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    local card = addon.lfgPage.largeCards[1]
    click(card.ask)
    click(addon.lfgPage.roleMenu.rows[1])
    fixtures.deliver(channel)
    local toast = toolAddon.lfgButton.toasts[1]
    test.assertTrue(toast.shown)

    fixtures.runTimers(tool, toolAddon.LfgRequests.EXPIRE_SECONDS)
    test.assertFalse(toast.shown)
    fixtures.deliver(channel)
    test.assertEqual("expired", addon.lfgBoard:Request(card.listing.id, hammer.time).state)
end)

test.test("Forever an ask for a role that's taken is declined with role filled", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    -- The warrior leads as the tank; the tank slot isn't open.
    local listing = addon.lfgPage.largeCards[1].listing
    test.assertEqual("healer,dps", table.concat(listing.openRoles, ","))
    addon.lfgPage.options.onAsk(listing, "tank")
    fixtures.deliver(channel)
    test.assertEqual(nil, toolAddon.lfgButton.toasts[1])
    fixtures.deliver(channel)
    local request = addon.lfgBoard:Request(listing.id, hammer.time)
    test.assertEqual("declined", request.state)
    test.assertTrue(request.roleFilled)
end)

test.test("Forever in Do Not Disturb, Ask to join requests are declined without a prompt", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    test.assertTrue(toolAddon.settings:Set("dnd", true))
    local card = addon.lfgPage.largeCards[1]
    click(card.ask)
    click(addon.lfgPage.roleMenu.rows[1])
    fixtures.deliver(channel)
    test.assertFalse(toolAddon.lfgButton:DrawerOpen())
    test.assertEqual(nil, toolAddon.lfgButton.toasts[1])
    fixtures.deliver(channel)
    test.assertEqual("declined", addon.lfgBoard:Request(card.listing.id, hammer.time).state)
end)

test.test("Forever an invite the game refuses keeps the request, to try again", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    tool.environment.C_PartyInfo = { InviteUnit = function() error("refused") end }
    local card = addon.lfgPage.largeCards[1]
    click(card.ask)
    click(addon.lfgPage.roleMenu.rows[1])
    fixtures.deliver(channel)
    local toast = toolAddon.lfgButton.toasts[1]

    click(toast.invite)
    test.assertTrue(toast.shown)
    test.assertContains(tool.messages[#tool.messages], "Couldn't invite Hammer")
    fixtures.deliver(channel)
    test.assertEqual("pending", addon.lfgBoard:Request(card.listing.id, hammer.time).state)
end)

test.test("Forever an ask whispered from outside the guild never reaches the leader", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, _, addon = listedStrat(channel)
    click(addon.lfgPage.largeCards[1].ask)
    click(addon.lfgPage.roleMenu.rows[1])
    -- Hammer's ask, whispered instead by someone outside the guild.
    local index
    for index = 1, #channel.queue do
        local message = channel.queue[index]
        if message.distribution == "WHISPER" then
            tool.commHandlers[message.prefix](message.prefix, message.text, "WHISPER", "Stranger Danger")
        end
    end
    test.assertFalse(toolAddon.lfgButton:DrawerOpen())
    test.assertEqual(nil, toolAddon.lfgButton.toasts[1])
    -- The same ask from Hammer gets through.
    fixtures.deliver(channel)
    test.assertTrue(toolAddon.lfgButton.toasts[1].shown)
end)

test.test("Forever the roles the game's party menu gives go out with the listing", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local zap = login(channel, "Zap Arcane")
    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    setGameRole(tool, "Hammer", "DAMAGER")
    click(addon.lfgButton.listButton)
    local page = addon.lfgPage
    test.assertEqual("dps", roleRow(page, "Hammer").role)
    page.draft.dungeon = addon.DungeonCatalog.For("forever", nil):Get("strat")
    test.assertTrue(page:Save())
    fixtures.deliver(channel)
    test.assertEqual("dps", zap.addon.lfgBoard:Listings(zap.time)[1].members[2].role)
end)

-- Someone left --------------------------------------------------------------------------

local function fullParty(fields)
    return party(fields and fields or { isLeader = true, leaderKey = "me", listed = true, size = 5, guildmates = 4 })
end

test.test("lfg trigger: someone leaving a full, listed party opens the slot; 60 seconds without an answer posts it",
    function()
        local trigger, LfgTrigger = newTrigger()
        trigger:Observe(fullParty(), 0)
        test.assertFalse(trigger:SlotOpen())

        local four = fullParty()
        four.size = 4
        test.assertEqual("slotOpen", names(trigger:Observe(four, 10)))
        test.assertTrue(trigger:SlotOpen())
        -- No popup: nothing is asked.
        test.assertFalse(trigger:Asking())

        test.assertFalse(trigger:SlotDue(10 + LfgTrigger.SLOT_SECONDS - 1))
        test.assertTrue(trigger:SlotOpen())
        test.assertTrue(trigger:SlotDue(10 + LfgTrigger.SLOT_SECONDS))
        test.assertFalse(trigger:SlotOpen())
        -- Posted once.
        test.assertFalse(trigger:SlotDue(10 + 2 * LfgTrigger.SLOT_SECONDS))
    end)

test.test("lfg trigger: another leaving or the party disbanding within the 60 seconds keeps the slot off", function()
    local trigger = newTrigger()
    trigger:Observe(fullParty(), 0)
    local four = fullParty()
    four.size = 4
    trigger:Observe(four, 0)
    local three = fullParty()
    three.size = 3
    test.assertEqual("", names(trigger:Observe(three, 20)))
    test.assertFalse(trigger:SlotOpen())
    test.assertFalse(trigger:SlotDue(100))

    trigger = newTrigger()
    trigger:Observe(fullParty(), 0)
    trigger:Observe(four, 0)
    test.assertEqual("end", names(trigger:Observe({ inGroup = false, listed = true }, 20)))
    test.assertFalse(trigger:SlotOpen())
    test.assertFalse(trigger:SlotDue(100))
end)

test.test("lfg trigger: Yes posts the open slot, No keeps it off; filling up again closes the question", function()
    local trigger = newTrigger()
    local four = fullParty()
    four.size = 4
    trigger:Observe(fullParty(), 0)
    trigger:Observe(four, 0)
    test.assertTrue(trigger:SlotAnswered(false))
    test.assertFalse(trigger:SlotOpen())
    test.assertFalse(trigger:SlotAnswered(true))
    test.assertFalse(trigger:SlotDue(100))

    trigger = newTrigger()
    trigger:Observe(fullParty(), 0)
    trigger:Observe(four, 0)
    test.assertTrue(trigger:SlotAnswered(true))
    test.assertFalse(trigger:SlotOpen())

    trigger = newTrigger()
    trigger:Observe(fullParty(), 0)
    trigger:Observe(four, 0)
    test.assertEqual("", names(trigger:Observe(fullParty(), 5)))
    test.assertFalse(trigger:SlotOpen())
end)

test.test("lfg trigger: a guildmate in the party is asked too, when the party's listed; an unlisted one isn't",
    function()
        local trigger = newTrigger()
        local listed = { id = "tool" }
        local member = party({ size = 5, guildmates = 4, listingOf = function(key)
            return key == "tool" and listed or nil
        end })
        trigger:Observe(member, 0)
        member.size = 4
        test.assertEqual("slotOpen", names(trigger:Observe(member, 0)))

        trigger = newTrigger()
        local unlisted = party({ size = 5, guildmates = 4 })
        trigger:Observe(unlisted, 0)
        unlisted.size = 4
        test.assertEqual("", names(trigger:Observe(unlisted, 0)))
        test.assertFalse(trigger:SlotOpen())
    end)

test.test("lfg trigger: with the button hidden, the leader gets a reminder and nothing is posted", function()
    local trigger = newTrigger()
    local hidden = fullParty()
    hidden.hidden = true
    trigger:Observe(hidden, 0)
    hidden.size = 4
    test.assertEqual("slotRemind", names(trigger:Observe(hidden, 0)))
    test.assertFalse(trigger:SlotOpen())
    test.assertFalse(trigger:SlotDue(100))

    -- A member who isn't the lister: not even a reminder.
    trigger = newTrigger()
    local member = party({ size = 5, guildmates = 4, hidden = true, listingOf = function()
        return { id = "tool" }
    end })
    trigger:Observe(member, 0)
    member.size = 4
    test.assertEqual("", names(trigger:Observe(member, 0)))
end)

test.test("lfg trigger: no slot opens in a raid, a party that wasn't full, or one the player said Not looking to",
    function()
        local trigger = newTrigger()
        local four = fullParty()
        four.size = 4
        local three = fullParty()
        three.size = 3
        trigger:Observe(four, 0)
        test.assertEqual("", names(trigger:Observe(three, 0)))

        trigger = newTrigger()
        local raid = fullParty()
        raid.isRaid, raid.size = true, 10
        trigger:Observe(raid, 0)
        raid.size = 9
        test.assertEqual("", names(trigger:Observe(raid, 0)))

        trigger = newTrigger()
        trigger:Observe(fullParty(), 0)
        trigger:NotLooking()
        test.assertEqual("", names(trigger:Observe(four, 0)))
    end)

test.test("lfg drawer model: an open slot glows orange and asks to fill it, under the party's questions", function()
    local addon = test.newAddon("Core/LfgDrawerModel.lua")
    local model = addon.LfgDrawerModel.Create()
    local info = { label = "Stratholme", kind = "dungeon", size = 5, maxSize = 5, slotRole = "dps" }
    local view = model:Update({ party = info, slotOpen = true })
    test.assertEqual("orange", view.glow)
    test.assertEqual("slot", view.top.kind)
    test.assertEqual("dps", view.top.party.slotRole)
    test.assertEqual("ask", model:Update({ party = info, slotOpen = true, ask = true }).top.kind)
    view = model:Update({ party = info })
    test.assertEqual(nil, view.glow)
    test.assertEqual("party", view.top.kind)
end)

test.test("lfg trigger: an outsider joining while I'm asked what the party's for asks whether to list it", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 2, guildmates = 1 }), 0)
    test.assertFalse(trigger:Gating())
    test.assertEqual("gate", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 3,
        guildmates = 1, outsiders = 1 }), 5)))
    test.assertTrue(trigger:Gating())

    -- A question already put away isn't asked again.
    trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 2, guildmates = 1 }), 0)
    trigger:NotLooking()
    test.assertEqual("", names(trigger:Observe(party({ isLeader = true, leaderKey = "me", size = 3,
        guildmates = 1, outsiders = 1 }), 5)))
    test.assertFalse(trigger:Asking())
end)

test.test("lfg trigger: refilling while handing the lead on leaves no slot open", function()
    local trigger = newTrigger()
    local four = fullParty()
    four.size = 4
    trigger:Observe(fullParty(), 0)
    trigger:Observe(four, 0)
    test.assertTrue(trigger:SlotOpen())
    test.assertEqual("handOff", names(trigger:Observe(party({ size = 5, guildmates = 4, listed = true }), 5)))
    test.assertFalse(trigger:SlotOpen())
    test.assertFalse(trigger:SlotDue(100))
end)

test.test("lfg trigger: a slot waits while the button's hidden, and is asked about again when it's back",
    function()
        local trigger, LfgTrigger = newTrigger()
        local hidden = fullParty()
        hidden.hidden = true
        trigger:Observe(hidden, 0)
        hidden.size = 4
        trigger:Observe(hidden, 0)
        test.assertFalse(trigger:SlotOpen())
        test.assertTrue(trigger:Resume(30))
        test.assertTrue(trigger:SlotOpen())
        test.assertFalse(trigger:SlotDue(30 + LfgTrigger.SLOT_SECONDS - 1))
        test.assertTrue(trigger:SlotDue(30 + LfgTrigger.SLOT_SECONDS))

        -- Hidden while it's open: it waits instead of posting.
        trigger = newTrigger()
        local four = fullParty()
        four.size = 4
        trigger:Observe(fullParty(), 0)
        trigger:Observe(four, 0)
        trigger:Pause()
        test.assertFalse(trigger:SlotOpen())
        test.assertFalse(trigger:SlotDue(100))
        test.assertTrue(trigger:Resume(200))
        test.assertTrue(trigger:SlotOpen())

        -- No is never asked again.
        trigger = newTrigger()
        trigger:Observe(fullParty(), 0)
        trigger:Observe(four, 0)
        trigger:SlotAnswered(false)
        test.assertFalse(trigger:Resume(10))
        test.assertFalse(trigger:SlotOpen())

        -- While it waits, a guildmate's No keeps it off, and their Yes
        -- posts nothing.
        trigger = newTrigger()
        hidden = fullParty()
        hidden.hidden = true
        trigger:Observe(hidden, 0)
        hidden.size = 4
        trigger:Observe(hidden, 0)
        test.assertFalse(trigger:SlotAnswered(true))
        test.assertTrue(trigger:SlotAnswered(false))
        test.assertFalse(trigger:Resume(10))

        -- Another leaving while it waits keeps it off too.
        trigger = newTrigger()
        hidden = fullParty()
        hidden.hidden = true
        trigger:Observe(hidden, 0)
        hidden.size = 4
        trigger:Observe(hidden, 0)
        hidden.size = 3
        trigger:Observe(hidden, 5)
        test.assertFalse(trigger:Resume(10))
        test.assertFalse(trigger:SlotOpen())
    end)

test.test("lfg trigger: two claims at once settle on the lower key for everyone in the party", function()
    local trigger = newTrigger()
    trigger:Observe(SOLO, 0)
    trigger:Observe(party({ leaderKey = "stranger", guildLed = false, outsiders = 1, selfKey = "me",
        present = { "amy", "me", "zap" } }), 0)
    -- A third guildmate hears amy's claim, then zap's.
    trigger:Claimed("amy", "me")
    trigger:Claimed("zap", "me")
    test.assertEqual("amy", trigger:Contact())
end)

test.test("lfg listing: a full dungeon party asks for no roles", function()
    local listing = newListing().LfgListing.Create()
    listing:Start({ kind = "dungeon", dungeon = { name = "Stratholme", minLevel = 58, maxLevel = 60 } }, nil, 0, true)
    local dps = {}
    local index
    for index = 1, 5 do
        dps[index] = { name = "Dps" .. index, role = "dps" }
    end
    local fields = listing:Announcement(dps)
    test.assertEqual(0, #fields.r)
    test.assertEqual(nil, newListing().LfgListing.GuildLine(fields))
end)

test.test("lfg board: a listing's end takes the player's answered request with it", function()
    local addon = test.newAddon("Core/LfgBoard.lua")
    local board = addon.LfgBoard.Create()
    board:Ask("tool", "healer", 0)
    board:OnAnswer("tool", "declined")
    test.assertEqual("declined", board:Request("tool", 10).state)
    board:OnEnd("tool", false)
    test.assertEqual(nil, board:Request("tool", 20))
end)

test.test("lfg drawer model: a group that appears in combat pulses once combat's over", function()
    local addon = test.newAddon("Core/LfgDrawerModel.lua")
    local model = addon.LfgDrawerModel.Create()
    local groups = { relevant = { { id = "tool", listedAt = 1 } } }
    local view = model:Update({ groups = groups, combat = true })
    test.assertEqual(0, #view.fresh)
    test.assertEqual(nil, view.glow)
    view = model:Update({ groups = groups })
    test.assertEqual(1, #view.fresh)
    test.assertEqual("gold", view.glow)
    -- Once.
    test.assertEqual(0, #model:Update({ groups = groups }).fresh)
end)

test.test("lfg listing: held as the party was until the slot's posted, then as it is with the open role", function()
    local listing = newListing().LfgListing.Create()
    local strat = { kind = "dungeon", dungeon = { name = "Stratholme", minLevel = 58, maxLevel = 60 } }
    test.assertTrue(listing:Start(strat, nil, 0, true))
    local function member(name, role)
        return { name = name, role = role }
    end
    local five = { member("Tool", "tank"), member("Hammer", "healer"), member("Zap", "dps"), member("Spark", "dps"),
        member("Bolt", "dps") }
    local four = { five[1], five[2], five[3], five[4] }
    listing:Hold(five)
    test.assertTrue(listing:Held())
    local fields = listing:Announcement(four)
    test.assertEqual(5, fields.s)
    test.assertEqual(0, #fields.r)

    listing:Post("healer")
    test.assertFalse(listing:Held())
    fields = listing:Announcement(four)
    test.assertEqual(4, fields.s)
    test.assertEqual("healer", table.concat(fields.r, ","))

    -- Filling up again lets go of a hold.
    listing:Hold(five)
    test.assertEqual(5, listing:Announcement(five).s)
    test.assertFalse(listing:Held())
end)

test.test("lfg protocol: the answer to fill the empty slot", function()
    local addon = test.newAddon("Core/LfgProtocol.lua")
    local Protocol = addon.LfgProtocol
    test.assertTrue(Protocol.IsValid(Protocol.Slot(true)))
    test.assertTrue(Protocol.IsValid(Protocol.Slot(false)))
    test.assertFalse(Protocol.Slot(false).y)
    test.assertFalse(Protocol.IsValid({ v = Protocol.VERSION, t = Protocol.TYPE_SLOT }))
end)

CHARACTERS["Flint Smith"] = { class = "WARRIOR" }

local FULL = { "Tool Box", "Hammer Smith", "Spark Arcane", "Bolt Smith", "Flint Smith" }
local BOLT_LEFT = { "Tool Box", "Hammer Smith", "Spark Arcane", "Flint Smith" }

-- Tool leads a full party in Stratholme, listed quietly; Hammer is in it.
local function fullStrat(channel)
    local tool, toolAddon = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    tool.environment.GetInstanceInfo = function()
        return "Stratholme", "party"
    end
    partyUp(tool, FULL, "Tool Box")
    fixtures.deliver(channel)
    test.assertEqual("Stratholme", addon.lfgBoard:Listings(hammer.time)[1].purpose)
    partyUp(hammer, FULL, "Tool Box")
    return tool, toolAddon, hammer, addon
end

local function boltLeaves(...)
    local worlds = { ... }
    local index
    for index = 1, #worlds do
        partyUp(worlds[index], BOLT_LEFT, "Tool Box")
    end
end

test.test("Forever someone leaving a full party glows orange, asks to fill the slot, and posts it after 60 seconds",
    function()
        local channel = fixtures.newChannel()
        local tool, toolAddon, hammer, addon = fullStrat(channel)
        boltLeaves(tool, hammer)
        fixtures.deliver(channel)

        local button = toolAddon.lfgButton
        test.assertEqual("orange", button.view.glow)
        test.assertEqual("orange", addon.lfgButton.view.glow)
        -- No popup.
        test.assertFalse(button:DrawerOpen())
        button:OpenDrawer()
        test.assertEqual("Someone left \226\128\148 fill the empty slot?", button.drawer.question.text)
        -- Bolt, a priest, was listed as the healer.
        test.assertEqual("Stratholme \194\183 needs Healer", button.drawer.slotDetails.text)
        test.assertEqual("Yes", button.listButton.label.text)
        test.assertEqual("No", button.notLookingButton.label.text)
        test.assertFalse(button.snoozeButton.shown)
        addon.lfgButton:OpenDrawer()
        test.assertEqual("Stratholme \194\183 needs Healer", addon.lfgButton.drawer.slotDetails.text)
        -- Closing the drawer isn't an answer.
        button:CloseDrawer()
        test.assertTrue(toolAddon.lfgTrigger:SlotOpen())
        -- Still listed as it was.
        test.assertEqual(5, addon.lfgBoard:Listings(hammer.time)[1].size)

        fixtures.runTimers(tool, toolAddon.LfgTrigger.SLOT_SECONDS + 1)
        fixtures.deliver(channel)
        local heard = addon.lfgBoard:Listings(hammer.time)[1]
        test.assertEqual(4, heard.size)
        test.assertEqual("healer", table.concat(heard.openRoles, ","))
        test.assertEqual(nil, button.view.glow)
    end)

test.test("Forever no slot is posted when another member leaves within the 60 seconds", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = fullStrat(channel)
    boltLeaves(tool)
    partyUp(tool, { "Tool Box", "Hammer Smith", "Spark Arcane" }, "Tool Box")
    test.assertEqual(nil, toolAddon.lfgButton.view.glow)
    fixtures.runTimers(tool, toolAddon.LfgTrigger.SLOT_SECONDS + 1)
    fixtures.deliver(channel)
    test.assertEqual(5, addon.lfgBoard:Listings(hammer.time)[1].size)
end)

test.test("Forever No keeps the slot off the board, and a guildmate's answer is everyone's", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = fullStrat(channel)
    boltLeaves(tool, hammer)
    local button = toolAddon.lfgButton
    button:OpenDrawer()
    click(button.notLookingButton)
    fixtures.deliver(channel)
    test.assertFalse(addon.lfgTrigger:SlotOpen())
    test.assertEqual(nil, addon.lfgButton.view.glow)
    fixtures.runTimers(tool, toolAddon.LfgTrigger.SLOT_SECONDS + 1)
    fixtures.deliver(channel)
    test.assertEqual(5, addon.lfgBoard:Listings(hammer.time)[1].size)
    -- Still listed.
    test.assertTrue(toolAddon.lfgListing:IsActive())

    -- Hammer, not the leader, says Yes: the leader posts it.
    channel = fixtures.newChannel()
    tool, toolAddon, hammer, addon = fullStrat(channel)
    boltLeaves(tool, hammer)
    addon.lfgButton:OpenDrawer()
    click(addon.lfgButton.listButton)
    fixtures.deliver(channel)
    test.assertFalse(toolAddon.lfgTrigger:SlotOpen())
    fixtures.deliver(channel)
    test.assertEqual(4, addon.lfgBoard:Listings(hammer.time)[1].size)
end)

test.test("Forever with the button hidden, someone leaving only reminds the leader, and nothing is posted", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = fullStrat(channel)
    toolAddon.settings:Set("lfgButton", false)
    boltLeaves(tool)
    test.assertContains(tool.messages[#tool.messages],
        "Someone left your party. Type /agf lfg to fill the empty slot on the Guild LFG Board.")
    test.assertEqual(nil, toolAddon.lfgButton.view.glow)
    fixtures.runTimers(tool, toolAddon.LfgTrigger.SLOT_SECONDS + 1)
    fixtures.deliver(channel)
    test.assertEqual(5, addon.lfgBoard:Listings(hammer.time)[1].size)
end)

test.test("Forever a posted open slot reaches a guildmate who fits it with the count and the gold glow", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = fullStrat(channel)
    local zap, zapAddon = login(channel, "Zap Arcane")
    fixtures.deliver(channel)
    test.assertEqual(0, zapAddon.lfgButton.view.count)
    -- Spark, a mage, leaves: a DPS slot, which Zap fits.
    partyUp(tool, { "Tool Box", "Hammer Smith", "Bolt Smith", "Flint Smith" }, "Tool Box")
    toolAddon.lfgButton:OpenDrawer()
    click(toolAddon.lfgButton.listButton)
    fixtures.deliver(channel)
    test.assertEqual(1, zapAddon.lfgButton.view.count)
    test.assertEqual("gold", zapAddon.lfgButton.view.glow)
end)

test.test("Forever a slot that opened while the button was hidden is offered when it's shown again", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = fullStrat(channel)
    toolAddon.settings:Set("lfgButton", false)
    boltLeaves(tool)
    test.assertFalse(toolAddon.lfgTrigger:SlotOpen())

    fixtures.slash(tool, "lfg")
    test.assertTrue(toolAddon.lfgTrigger:SlotOpen())
    test.assertEqual("orange", toolAddon.lfgButton.view.glow)
    test.assertTrue(toolAddon.lfgButton:DrawerOpen())
    fixtures.runTimers(tool, toolAddon.LfgTrigger.SLOT_SECONDS + 1)
    fixtures.deliver(channel)
    test.assertEqual(4, addon.lfgBoard:Listings(hammer.time)[1].size)
end)

test.test("Forever a role the game's party menu changes is the one whoever leaves leaves open", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = fullStrat(channel)
    test.assertTrue(toolAddon.agfWindow:Open("lfg"))
    local page = toolAddon.lfgPage
    page:StartEditing()
    setGameRole(tool, "Hammer", "HEALER")
    page.draft.dungeon = toolAddon.DungeonCatalog.For("forever", nil):Get("strat")
    test.assertTrue(page:Save())

    partyUp(tool, { "Tool Box", "Spark Arcane", "Bolt Smith", "Flint Smith" }, "Tool Box")
    toolAddon.lfgButton:OpenDrawer()
    test.assertEqual("Stratholme \194\183 needs Healer", toolAddon.lfgButton.drawer.slotDetails.text)
end)

test.test("Forever hiding the button while a slot is open keeps it off the board", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = fullStrat(channel)
    boltLeaves(tool)
    test.assertTrue(toolAddon.lfgTrigger:SlotOpen())
    toolAddon.settings:Set("lfgButton", false)
    fixtures.runTimers(tool, toolAddon.LfgTrigger.SLOT_SECONDS + 1)
    fixtures.deliver(channel)
    test.assertEqual(5, addon.lfgBoard:Listings(hammer.time)[1].size)
end)

-- Ask in guild --------------------------------------------------------------------------

test.test("lfg listing: the Ask in guild line names a dungeon's open roles, else the players needed", function()
    local LfgListing = newListing().LfgListing
    test.assertEqual("LF healer and 2 DPS for Stratholme (58\226\128\14760), whisper me!", LfgListing.GuildLine({
        k = "dungeon", p = "Stratholme", lo = 58, hi = 60, s = 2, x = 5, r = { "healer", "dps" },
        mb = { { n = "Tool", r = "tank" }, { n = "Zap", r = "dps" } },
    }))
    test.assertEqual("LF tank, healer and DPS for Stratholme (58\226\128\14760), whisper me!", LfgListing.GuildLine({
        k = "dungeon", p = "Stratholme", lo = 58, hi = 60, s = 3, x = 5, r = { "tank", "healer", "dps" },
        mb = { { n = "A", r = "dps" }, { n = "B", r = "dps" } },
    }))
    test.assertEqual("LF 3 more for Questing in Ironforge (1\226\128\14760), whisper me!", LfgListing.GuildLine({
        k = "questing", p = "Ironforge", lo = 1, hi = 60, s = 2, x = 5, mb = {},
    }))
    test.assertEqual("LF 1 more for Ony first, whisper me!", LfgListing.GuildLine({
        k = "other", p = "Ony first", s = 4, x = 5, mb = {},
    }))
    test.assertEqual("LF 39 more for Raid, whisper me!", LfgListing.GuildLine({ k = "raid", s = 1, x = 40, mb = {} }))
    -- Nobody needed: no line.
    test.assertEqual(nil, LfgListing.GuildLine({ k = "dungeon", p = "Stratholme", s = 5, x = 5, r = {}, mb = {} }))
    test.assertEqual(nil, LfgListing.GuildLine({ k = "other", p = "x", s = 5, x = 5, mb = {} }))
end)

test.test("Forever Ask in guild types the line into guild chat and never sends it", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon = listedStrat(channel)
    local opened, sent
    tool.environment.ChatFrameUtil = nil
    tool.environment.ChatFrame_OpenChat = function(line) opened = line end
    tool.environment.SendChatMessage = function(text) sent = text end
    local button = toolAddon.lfgPage.askGuildButton
    test.assertTrue(button.shown)
    click(button)
    test.assertContains(opened, "/g LF healer and 3 DPS for Stratholme (")
    test.assertContains(opened, "), whisper me!")
    test.assertEqual(nil, sent)
end)

-- History -------------------------------------------------------------------------------

test.test("lfg history view: newest first, 20 at a time, guildmates with their friend tier", function()
    local addon = test.newAddon("Core/GroupFriends.lua", "Core/LfgHistoryView.lua")
    local view = addon.LfgHistoryView.Create()
    local entries = {}
    local index
    for index = 1, 45 do
        entries[index] = { at = index * 100, characters = { "hammer", "gone", "zap" },
            dungeon = index == 45 and "Stratholme" or nil }
    end
    local names = { hammer = "Hammer", zap = "Zap" }
    local function member(key)
        return names[key] and { name = names[key], whisper = names[key] .. "-Camelot", classToken = "MAGE" } or nil
    end
    local tiers = { hammer = addon.GroupFriends.TOP, zap = addon.GroupFriends.GROUPED }
    local function tierOf(key)
        return tiers[key]
    end

    local page = view:Page(entries, member, tierOf)
    test.assertEqual(20, #page.parties)
    test.assertTrue(page.more)
    test.assertEqual(45, page.total)
    test.assertEqual(4500, page.parties[1].at)
    test.assertEqual("Stratholme", page.parties[1].place)
    test.assertEqual(2600, page.parties[20].at)
    -- A guildmate no longer known is left out.
    test.assertEqual(2, #page.parties[1].members)
    local hammer, zap = page.parties[1].members[1], page.parties[1].members[2]
    test.assertEqual("Hammer-Camelot", hammer.whisper)
    test.assertEqual(addon.GroupFriends.TOP, hammer.tier)
    test.assertTrue(hammer.friend)
    test.assertFalse(zap.friend)

    view:More()
    test.assertEqual(40, #view:Page(entries, member, tierOf).parties)
    view:More()
    page = view:Page(entries, member, tierOf)
    test.assertEqual(45, #page.parties)
    test.assertFalse(page.more)
    test.assertEqual(100, page.parties[45].at)
    view:Reset()
    test.assertEqual(20, #view:Page(entries, member, tierOf).parties)

    -- Frequent is a friend too; nothing at all is an empty page.
    tiers.zap = addon.GroupFriends.FREQUENT
    test.assertTrue(view:Page(entries, member, tierOf).parties[1].members[2].friend)
    page = view:Page({}, member, tierOf)
    test.assertEqual(0, #page.parties)
    test.assertFalse(page.more)
end)

test.test("Forever the History tab lists my parties with stars and name menus, 20 at a time with Show more", function()
    local channel = fixtures.newChannel()
    local tool, addon = login(channel, "Tool Box")
    local _, partition = addon.rosterController:QuietContext()
    local hammerKey
    partition:EachCharacter(function(key, character)
        if string.match(character.name or "", "^Hammer") then
            hammerKey = key
        end
    end)
    test.assertTrue(hammerKey ~= nil)
    local whispered
    tool.environment.ChatFrame_SendTell = function(name) whispered = name end
    tool.environment.ChatFrameUtil = nil

    test.assertTrue(addon.agfWindow:Open("lfg"))
    local page = addon.lfgPage
    page:ShowTab("history")
    test.assertTrue(page.emptyText.shown)
    test.assertEqual("No parties in your history yet.", page.emptyText.text)

    local index
    for index = 1, 25 do
        test.assertTrue(partition:AddGroupHistory({ at = 1700000000 + index * 3600, characters = { hammerKey },
            dungeon = index == 25 and "Stratholme" or nil }))
    end
    page:ShowTab("history")
    test.assertFalse(page.emptyText.shown)
    local shown = 0
    for index = 1, #page.historyRows do
        if page.historyRows[index].shown then
            shown = shown + 1
        end
    end
    test.assertEqual(20, shown)
    local row = page.historyRows[1]
    test.assertContains(row.title.text, "Stratholme")
    local member = row.members[1]
    test.assertContains(member.name.text, "Hammer")
    -- 25 parties together, and nobody grouped with more: a top group
    -- friend, starred.
    test.assertTrue(member.star.shown)
    -- No Whisper button: the name opens the name menu, whose Whisper
    -- whispers them.
    test.assertEqual("string", type(member.whisper))
    click(member)
    test.assertTrue(page.namesMenu:IsOpen())
    test.assertContains(page.namesMenu.titleText, "Hammer")
    click(page.namesMenu.rows[1])
    test.assertContains(whispered, "Hammer")

    test.assertTrue(page.moreButton.shown)
    click(page.moreButton)
    test.assertTrue(page.historyRows[25].shown)
    test.assertFalse(page.moreButton.shown)
end)

-- Replacing the Group Finder ----------------------------------------------------------

test.test("Forever group history records the dungeon the party is listed for, for the lister and the member", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)

    partyUp(tool, { "Tool Box", "Hammer Smith" }, "Tool Box")
    partyUp(hammer, { "Tool Box", "Hammer Smith" }, "Tool Box")
    fixtures.deliver(channel)

    local _, toolPartition = toolAddon.rosterController:QuietContext()
    test.assertEqual("Stratholme", toolPartition:GetGroupHistory()[1].dungeon)
    local _, hammerPartition = addon.rosterController:QuietContext()
    test.assertEqual("Stratholme", hammerPartition:GetGroupHistory()[1].dungeon)
end)

test.test("Forever an older version's Group Finder messages are ignored", function()
    local channel = fixtures.newChannel()
    local tool, toolAddon, hammer, addon = listedStrat(channel)
    hammer.sentMessages = {}

    toolAddon.comm:Broadcast({ v = 1, t = "gf-ask" }, toolAddon.Comm.PRIORITY_NORMAL)
    toolAddon.comm:Broadcast({ v = 1, t = "gf-group-end" }, toolAddon.Comm.PRIORITY_NORMAL)
    fixtures.deliver(channel)
    fixtures.runTimers(hammer, 10)

    -- No reply, and the listing is still on the board.
    test.assertEqual(0, #hammer.sentMessages)
    test.assertTrue(addon.lfgBoard:Get("tool box-camelot", hammer.time) ~= nil)
end)

-- /agfdev lfgtest ------------------------------------------------------------------------

test.test("Forever /agfdev lfgtest shows every look with stand-ins, and nothing about them is sent", function()
    local channel = fixtures.newChannel()
    local world, addon = login(channel, "Tool Box", "AsgardsGuildFellowshipDev")
    local invited
    world.environment.C_PartyInfo = { InviteUnit = function(name) invited = name end }
    world.sentMessages = {}

    fixtures.slash(world, "lfgtest")

    test.assertContains(table.concat(world.messages, "\n"), "stand-in listings are on your Guild LFG Board")
    -- The slot question glows orange and opens the drawer, with the request
    -- under it.
    local button = addon.lfgButton
    test.assertTrue(button:DrawerOpen())
    test.assertEqual("orange", button.view.glow)
    test.assertEqual("Yes", button.listButton.label.text)
    test.assertContains(button.toasts[1].name.text, "Brightleaf")
    test.assertEqual("Healer, 24", button.toasts[1].details.text)
    -- The board: relevant (with a note and a raid), greyed and full ones.
    test.assertTrue(addon.agfWindow:Open("lfg"))
    local current = { level = 60, roles = { "tank", "dps" } }
    local groups = addon.lfgBoard:Groups(world.time, current, {})
    test.assertEqual(3, #groups.relevant)
    test.assertEqual(2, #groups.other)

    -- Asking a stand-in, answering the request and the slot: nothing goes out.
    local card = addon.lfgPage.largeCards[1]
    click(card.ask)
    if addon.lfgPage.roleMenu:IsOpen() then
        click(addon.lfgPage.roleMenu.rows[1])
    end
    test.assertEqual("pending", addon.lfgBoard:Request(card.listing.id, world.time).state)
    click(button.toasts[1].invite)
    test.assertEqual(nil, invited)
    click(button.listButton)
    test.assertEqual(nil, button.view.glow)
    -- Not even once the stand-ins' requests would expire. (Guild sync
    -- goes on as usual.)
    fixtures.runTimers(world, 180)
    local serializer = world.environment.LibStub:GetLibrary("AceSerializer-3.0")
    local index
    for index = 1, #world.sentMessages do
        local _, message = serializer:Deserialize(world.sentMessages[index].text)
        local kind = type(message) == "table" and tostring(message.t) or ""
        test.assertFalse(string.sub(kind, 1, 4) == "lfg-", "sent " .. kind)
    end
end)

test.test("Forever the release build has no lfgtest command", function()
    local world = login(fixtures.newChannel(), "Tool Box")

    fixtures.slash(world, "help")

    test.assertFalse(string.find(table.concat(world.messages, "\n"), "lfgtest", 1, true) ~= nil)
end)
