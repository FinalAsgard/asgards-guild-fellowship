local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000

local function newHistory()
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/GroupHistory.lua", "Core/NameNormalizer.lua",
        "Core/RosterViewModel.lua", "Core/PlayerPanelViewModel.lua")
    local database = { schemaVersion = 3, guilds = {} }
    local partition = addon.FellowshipStore.Create(database):Partition(GUILD)
    return addon, partition, addon.GroupHistory.Create(partition), database
end

-- Recording -----------------------------------------------------------------------

test.test("group history: a party with guildmates is recorded with its time, characters and dungeon", function()
    local _, partition, history = newHistory()

    local entry = history:OnParty({ "hammer", "bolt" }, NOW, "The Deadmines")

    test.assertEqual(NOW, entry.at)
    test.assertEqual("bolt,hammer", table.concat(entry.characters, ","))
    test.assertEqual("The Deadmines", entry.dungeon)
    test.assertEqual(1, #partition:GetGroupHistory())
    -- Without guildmates nothing is recorded.
    test.assertEqual(nil, history:OnParty({}, NOW + 10))
    test.assertEqual(1, #partition:GetGroupHistory())
end)

test.test("group history: the same party is recorded once, and guildmates joining later join its entry", function()
    local _, partition, history = newHistory()
    history:OnParty({ "hammer" }, NOW)

    test.assertEqual(nil, history:OnParty({ "hammer" }, NOW + 60))
    local grown = history:OnParty({ "hammer", "zap" }, NOW + 120, "Shadowfang Keep")

    test.assertEqual(1, #partition:GetGroupHistory())
    test.assertEqual("hammer,zap", table.concat(grown.characters, ","))
    test.assertEqual("Shadowfang Keep", grown.dungeon)
    -- Someone leaving doesn't make it a new party either.
    test.assertEqual(nil, history:OnParty({ "zap" }, NOW + 180))
    test.assertEqual(1, #partition:GetGroupHistory())
end)

test.test("group history: a different party, or the same one after breaking up, is a new entry", function()
    local addon, partition, history = newHistory()
    history:OnParty({ "hammer" }, NOW)

    history:OnParty({ "cleric" }, NOW + 60)
    test.assertEqual(2, #partition:GetGroupHistory())

    history:OnParty({}, NOW + 120)
    history:OnParty({ "cleric" }, NOW + 180)
    test.assertEqual(3, #partition:GetGroupHistory())

    -- A reload inside the same party doesn't count it again.
    local reloaded = addon.GroupHistory.Create(partition)
    test.assertEqual(nil, reloaded:OnParty({ "cleric" }, NOW + 240))
    test.assertEqual(3, #partition:GetGroupHistory())
    -- Long after, the same faces are a new party.
    local later = addon.GroupHistory.Create(partition)
    later:OnParty({ "cleric" }, NOW + addon.GroupHistory.SAME_PARTY_SECONDS + 300)
    test.assertEqual(4, #partition:GetGroupHistory())
end)

-- Counting -------------------------------------------------------------------------

test.test("group history: counted per player across all their characters", function()
    local _, _, history = newHistory()
    history:OnParty({ "hammer" }, NOW)
    history:OnParty({}, NOW + 1)
    history:OnParty({ "bolt", "zap" }, NOW + 86400)
    history:OnParty({}, NOW + 86401)
    history:OnParty({ "zap" }, NOW + 2 * 86400)

    local count, last = history:Stats({ "hammer", "bolt" })
    test.assertEqual(2, count)
    test.assertEqual(NOW + 86400, last)
    test.assertEqual(0, (history:Stats({ "cleric" })))
    test.assertEqual("Grouped together 2 times, last on day " .. (NOW + 86400),
        history:Line({ "hammer", "bolt" }, function(at) return "day " .. at end))
    test.assertEqual("Grouped together 1 time, last on day " .. NOW,
        history:Line({ "hammer" }, function(at) return "day " .. at end))
    test.assertEqual(nil, history:Line({ "cleric" }, tostring))
end)

-- Storage ---------------------------------------------------------------------------

test.test("group history: kept in the guild partition, unreadable entries skipped, oldest dropped past the cap", function()
    local addon, partition, _, database = newHistory()
    local stored = database.guilds["Knights of Camelot-Camelot"]

    test.assertTrue(partition:AddGroupHistory({ at = NOW, characters = { "hammer" } }))
    test.assertFalse(partition:AddGroupHistory({ at = "soon", characters = { "hammer" } }))
    table.insert(stored.groupHistory, { at = NOW, characters = "hammer" })
    test.assertEqual(1, #partition:GetGroupHistory())
    test.assertEqual(2, #stored.groupHistory)

    local index
    for index = 1, addon.FellowshipStore.GROUP_HISTORY_MAX + 5 do
        partition:AddGroupHistory({ at = NOW + index, characters = { "zap" } })
    end
    test.assertEqual(addon.FellowshipStore.GROUP_HISTORY_MAX, #stored.groupHistory)
end)

test.test("group history: never part of what guild sync passes on", function()
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/RoleCatalog.lua", "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua", "Core/GroupHistory.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter("hammer", { name = "Hammer", classToken = "PALADIN", level = 24 })
    addon.GroupHistory.Create(partition):OnParty({ "hammer" }, NOW)

    local facts = addon.SyncFacts.Create(partition, { now = function() return NOW end }):SharedFacts()

    test.assertEqual(0, #facts)
end)

-- The player panel --------------------------------------------------------------------

test.test("player panel: shows how often you grouped with the player, and nothing when never", function()
    local addon, partition, history = newHistory()
    partition:RecordCharacter("hammer", { name = "Hammer" })
    partition:RecordCharacter("cleric", { name = "Cleric" })
    history:OnParty({ "hammer" }, NOW)
    local function build(key)
        return addon.PlayerPanelViewModel.Build({
            partition = partition,
            playerId = partition:GetCharacter(key).player,
            normalizer = addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = "Camelot" }),
            groupedWith = function(keys)
                return history:Line(keys, function() return "2026-10-12" end)
            end,
        })
    end

    local hammer = build("hammer")
    test.assertEqual("stat", hammer.rows[1].kind)
    test.assertEqual("Grouped together 1 time, last on 2026-10-12", hammer.rows[1].text)
    test.assertEqual("section", build("cleric").rows[1].kind)
end)

-- The composed add-on -------------------------------------------------------------------

test.test("composed: joining a party with a guildmate records it, once", function()
    local world = fixtures.newEnvironment("Retail")
    local units = {
        player = { name = "Toolbox", guid = "Player-1", class = "WARRIOR", level = 80 },
    }
    local grouped = false
    local environment = world.environment
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit)
        if units[unit] == nil then
            return nil
        end
        return units[unit].name, units[unit].realm
    end
    environment.UnitClass = function(unit) return "x", units[unit] and units[unit].class end
    environment.IsInGroup = function() return grouped end
    local addon = fixtures.loadAddon(world)
    addon.RosterWindow.Create = function() return nil end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world, 60)
    local _, partition = addon.rosterController:QuietContext()

    -- Hammer is the player's own alt (by its note): never counted.
    units.party1 = { name = "Hammer", guid = "Player-2", class = "PALADIN", level = 70 }
    grouped = true
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
    test.assertEqual(0, #partition:GetGroupHistory())

    -- Visitor, a guildmate from another realm, joins.
    units.party2 = { name = "Visitor", realm = "Stormrage", guid = "Player-3", class = "MAGE", level = 80 }
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")

    local entries = partition:GetGroupHistory()
    test.assertEqual(1, #entries)
    test.assertEqual("visitor-stormrage", entries[1].characters[1])
    test.assertEqual(world.time, entries[1].at)
end)
