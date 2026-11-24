local test = require("tests.test_helper")

-- Every dungeon of `catalog`, lowest range first: with no level, none fits.
local function everyDungeon(catalog)
    local _, all = catalog:Split(nil)
    return all
end
local fixtures = require("tests.client_fixtures")

-- DungeonCatalog ------------------------------------------------------------

local function newCatalogModule()
    return test.newAddon("Core/DungeonCatalog.lua").DungeonCatalog
end

local SAMPLE = {
    { id = "sfk", name = "Shadowfang Keep", minLevel = 22, maxLevel = 30 },
    { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 },
    { id = "wc", name = "Wailing Caverns", minLevel = 17, maxLevel = 24 },
    { id = "strat", name = "Stratholme", minLevel = 58, maxLevel = 60 },
}

local function names(list)
    local result = {}
    local index
    for index = 1, #list do
        result[index] = list[index].name
    end
    return table.concat(result, ", ")
end

test.test("dungeon catalog: the dungeons a level fits come first, lowest range first", function()
    local catalog = newCatalogModule().Create(SAMPLE)

    local fitting, others = catalog:Split(23)

    test.assertEqual("Wailing Caverns, The Deadmines, Shadowfang Keep", names(fitting))
    test.assertEqual("Stratholme", names(others))
    test.assertEqual("Wailing Caverns, The Deadmines, Shadowfang Keep, Stratholme", names(everyDungeon(catalog)))
end)

test.test("dungeon catalog: answers whether a level fits a dungeon, ends included", function()
    local catalog = newCatalogModule().Create(SAMPLE)

    test.assertTrue(catalog:Fits("dm", 17))
    test.assertTrue(catalog:Fits("dm", 26))
    test.assertFalse(catalog:Fits("dm", 16))
    test.assertFalse(catalog:Fits("dm", 27))
    test.assertFalse(catalog:Fits("missing", 20))
    test.assertFalse(catalog:Fits("dm", nil))
    -- Without a level, nothing fits.
    local fitting, others = catalog:Split(nil)
    test.assertEqual(0, #fitting)
    test.assertEqual(4, #others)
end)

test.test("dungeon catalog: unusable and repeated entries are left out", function()
    local catalog = newCatalogModule().Create({
        { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 },
        { id = "dm", name = "Again", minLevel = 1, maxLevel = 2 },
        { id = "bad", name = "", minLevel = 1, maxLevel = 2 },
        { id = "upside", name = "Upside Down", minLevel = 30, maxLevel = 20 },
        { name = "No id", minLevel = 1, maxLevel = 2 },
        "not a dungeon",
    })

    test.assertEqual("The Deadmines", names(everyDungeon(catalog)))
    test.assertEqual("The Deadmines", catalog:Get("dm").name)
end)

test.test("dungeon catalog: the Dungeon Finder's list wins, else the client's static table", function()
    local DungeonCatalog = newCatalogModule()

    local supplied = DungeonCatalog.For("retail", { { id = 1, name = "Finder Dungeon", minLevel = 80, maxLevel = 90 } })
    test.assertEqual("Finder Dungeon", names(everyDungeon(supplied)))

    -- Nothing from the Dungeon Finder: Retail's own table.
    local retail = DungeonCatalog.For("retail", nil)
    test.assertTrue(#everyDungeon(retail) > 0)
    test.assertEqual(#DungeonCatalog.STATIC.retail, #everyDungeon(DungeonCatalog.For("retail", {})))
end)

test.test("dungeon catalog: WoW Forever uses the Classic dungeons with fixed ranges", function()
    local catalog = newCatalogModule().For("forever", nil)

    local deadmines = catalog:Get("dm")
    test.assertEqual("The Deadmines", deadmines.name)
    test.assertEqual(17, deadmines.minLevel)
    test.assertEqual(26, deadmines.maxLevel)
    test.assertTrue(catalog:Fits("strat", 60))
    -- Forever's own dungeons sit alongside the Classic ones.
    test.assertEqual("Hall of Thanes", catalog:Get("thanes").name)
    test.assertTrue(catalog:Fits("dalaran", 30))
    local fitting = catalog:Split(15)
    test.assertEqual("Hall of Thanes, Ragefire Chasm, Ruins of Lordaeron", names(fitting))
end)

-- The WoW adapter -------------------------------------------------------------

local function newClient(world)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(world.environment)
end

-- Retail's Dungeon Finder API with `entries` ({ id, name, typeId,
-- subtypeId, minLevel, maxLevel }).
local function installDungeonFinder(environment, entries)
    environment.GetLFDChoiceOrder = function(list)
        local index
        for index = 1, #entries do
            list[index] = entries[index].id
        end
        return list
    end
    environment.GetLFGDungeonInfo = function(id)
        local index
        for index = 1, #entries do
            local entry = entries[index]
            if entry.id == id then
                return entry.name, entry.typeId, entry.subtypeId, entry.minLevel, entry.maxLevel
            end
        end
        return nil
    end
end

test.test("Retail adapter lists the Dungeon Finder's normal dungeons with their ranges", function()
    local world = fixtures.newEnvironment("Retail")
    installDungeonFinder(world.environment, {
        { id = 1001, name = "Windrunner Spire", typeId = 1, subtypeId = 1, minLevel = 80, maxLevel = 90 },
        { id = 1002, name = "Random Dungeon", typeId = 6, subtypeId = 1, minLevel = 80, maxLevel = 90 },
        { id = 1003, name = "Windrunner Spire (Heroic)", typeId = 1, subtypeId = 2, minLevel = 90, maxLevel = 90 },
        { id = 1004, name = "", typeId = 1, subtypeId = 1, minLevel = 80, maxLevel = 90 },
    })

    local dungeons = newClient(world):GetDungeonList()

    test.assertEqual(1, #dungeons)
    test.assertEqual(1001, dungeons[1].id)
    test.assertEqual("Windrunner Spire", dungeons[1].name)
    test.assertEqual(80, dungeons[1].minLevel)
    test.assertEqual(90, dungeons[1].maxLevel)
end)

-- The Classic-era Dungeon Finder's API with `activities` (activity info
-- tables, each with its `id`), as WoW Forever has.
local function installActivityFinder(environment, activities)
    environment.C_LFGList = {
        GetAvailableActivities = function(category)
            local ids = {}
            local index
            for index = 1, #activities do
                if category == 2 then
                    ids[index] = activities[index].id
                end
            end
            return ids
        end,
        GetActivityInfoTable = function(id)
            local index
            for index = 1, #activities do
                if activities[index].id == id then
                    return activities[index]
                end
            end
            return nil
        end,
    }
end

test.test("Forever adapter lists the Classic-era Dungeon Finder's dungeons with their suggested ranges", function()
    local world = fixtures.newEnvironment("Forever")
    installActivityFinder(world.environment, {
        { id = 798, fullName = "The Deadmines", minLevel = 10, minLevelSuggestion = 18, maxLevelSuggestion = 23 },
        { id = 799, fullName = "Wailing Caverns", minLevel = 10, maxLevel = 25 },
        { id = 800, fullName = "The Deadmines (Heroic)", minLevelSuggestion = 60, maxLevelSuggestion = 60,
            isHeroicActivity = true },
        { id = 801, fullName = "Somewhere", minLevel = 10 },
    })

    local dungeons = newClient(world):GetDungeonList()

    test.assertEqual(2, #dungeons)
    test.assertEqual(798, dungeons[1].id)
    test.assertEqual("The Deadmines", dungeons[1].name)
    test.assertEqual(18, dungeons[1].minLevel)
    test.assertEqual(23, dungeons[1].maxLevel)
    test.assertEqual("Wailing Caverns", dungeons[2].name)
    test.assertEqual(25, dungeons[2].maxLevel)
end)

test.test("adapter reports no dungeon list without a Dungeon Finder, or when it lists none", function()
    local forever = fixtures.newEnvironment("Forever")
    test.assertEqual(nil, newClient(forever):GetDungeonList())

    local empty = fixtures.newEnvironment("Retail")
    installDungeonFinder(empty.environment, {})
    test.assertEqual(nil, newClient(empty):GetDungeonList())

    local broken = fixtures.newEnvironment("Retail")
    broken.environment.GetLFDChoiceOrder = function()
        error("not ready")
    end
    broken.environment.GetLFGDungeonInfo = function() end
    test.assertEqual(nil, newClient(broken):GetDungeonList())
end)

test.test("adapter reads the character's level, or nil when the client can't say", function()
    local world = fixtures.newEnvironment("Forever")
    world.playerLevel = 23
    local client = newClient(world)

    test.assertEqual(23, client:GetPlayerLevel())
    world.playerLevel = 0
    test.assertEqual(nil, client:GetPlayerLevel())
end)

