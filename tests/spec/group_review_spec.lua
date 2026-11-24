local test = require("tests.test_helper")

-- Every dungeon of `catalog`, lowest range first: with no level, none fits.
local function everyDungeon(catalog)
    local _, all = catalog:Split(nil)
    return all
end
local fixtures = require("tests.client_fixtures")

-- Edge cases of the group history, the dungeon list and party members on
-- Forever.

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000

local function load()
    return test.newAddon("Core/FellowshipStore.lua", "Core/GroupHistory.lua", "Core/DungeonCatalog.lua")
end

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

local function loginForever(channel, playerName, addonName)
    local world = fixtures.newEnvironment("Forever",
        { guild = foreverGuild(), playerName = playerName, addonName = addonName })
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

-- Puts `units` (unit -> { name, guid, class, outsider? }) in the
-- organizer's party, as the Forever client reports it, and tells the
-- add-on. Everyone but an outsider is in the guild.
local function joinParty(world, units)
    local environment = world.environment
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit) return units[unit] and units[unit].name end
    environment.UnitGUID = function(unit) return units[unit] and units[unit].guid end
    environment.UnitClass = function(unit)
        return "Localized", units[unit] and units[unit].class, 1
    end
    environment.UnitIsInMyGuild = function(unit) return units[unit] ~= nil and not units[unit].outsider end
    world.grouped = true
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
end

test.test("composed: guildmates anywhere in the raid go into the group history, not just the player's subgroup", function()
    local channel = fixtures.newChannel()
    local world = loginForever(channel, "Tool Box")
    world.environment.IsInRaid = function() return true end

    -- Zap is in another subgroup: a raid unit, but no party unit.
    joinParty(world, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        raid1 = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        raid7 = { name = "Zap", guid = "Player-1-Zap Arcane", class = "MAGE" },
    })

    local _, partition = world.addon.rosterController:QuietContext()
    local entries = partition:GetGroupHistory()
    test.assertEqual(1, #entries)
    test.assertEqual("zap arcane-camelot", table.concat(entries[1].characters, ","))
end)

test.test("composed: the Dev build's greettest shows a group friend's prompt, and its Greet posts nothing", function()
    local channel = fixtures.newChannel()
    local world = loginForever(channel, "Tool Box", "AsgardsGuildFellowshipDev")
    joinParty(world, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        party1 = { name = "Zap", guid = "Player-1-Zap Arcane", class = "MAGE" },
    })
    fixtures.slash(world, "help")
    test.assertContains(table.concat(world.messages, "\n"), "/agfdev greettest")

    fixtures.slash(world, "greettest")

    local greet = world.addon.guildGreet
    -- Zap is really Top 5; Hammer, never grouped with, shows the plain look.
    -- Spark is Zap's alt, so nobody is left to stand in for the other tiers.
    local prompts = greet.queue:All(world.time)
    test.assertEqual(2, #prompts)
    test.assertEqual("hammer smith-camelot", prompts[1].key)
    test.assertEqual(nil, prompts[1].previewTier)
    test.assertEqual("zap arcane-camelot", prompts[2].key)
    test.assertEqual("top5", prompts[2].previewTier)
    test.assertTrue(prompts[2].preview)
    local said = table.concat(world.messages, "\n")
    test.assertContains(said, "Not grouped (Hammer Smith)")
    test.assertContains(said, "Top 5 (Zap Arcane)")
    world.chat = {}
    greet:Greet(prompts[1].player)
    greet:Greet(prompts[2].player)
    test.assertEqual(0, #world.chat)
    test.assertEqual(0, #greet.queue:All(world.time))
end)

test.test("composed: greettest stands another guildmate in for a tier nobody in the history is in", function()
    local channel = fixtures.newChannel()
    local world = loginForever(channel, "Tool Box", "AsgardsGuildFellowshipDev")

    fixtures.slash(world, "greettest")

    local prompts = world.addon.guildGreet.queue:All(world.time)
    test.assertEqual(2, #prompts)
    test.assertEqual(nil, prompts[1].previewTier)
    test.assertEqual("grouped", prompts[2].previewTier)
    test.assertContains(table.concat(world.messages, "\n"), ", stand-in)")
end)

test.test("composed: the release build has no greettest command", function()
    local channel = fixtures.newChannel()
    local world = loginForever(channel, "Tool Box")

    fixtures.slash(world, "help")

    test.assertFalse(string.find(table.concat(world.messages, "\n"), "greettest", 1, true) ~= nil)
end)

test.test("composed: on Forever, a party member with no GUID is found by an unshared first name", function()
    local channel = fixtures.newChannel()
    local world = loginForever(channel, "Tool Box")

    joinParty(world, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        party1 = { name = "Hammer", class = "PALADIN" },
    })

    local _, partition = world.addon.rosterController:QuietContext()
    test.assertEqual("hammer smith-camelot", table.concat(partition:GetGroupHistory()[1].characters, ","))
end)

test.test("composed: on Forever, an outsider sharing a guildmate's first name isn't taken for them", function()
    local channel = fixtures.newChannel()
    local world = loginForever(channel, "Tool Box")

    joinParty(world, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        party1 = { name = "Zap", guid = "Player-2-Stranger", class = "MAGE", outsider = true },
    })

    local _, partition = world.addon.rosterController:QuietContext()
    test.assertEqual(0, #partition:GetGroupHistory())
end)
