local test = require("tests.test_helper")

-- Every dungeon of `catalog`, lowest range first: with no level, none fits.
local function everyDungeon(catalog)
    local _, all = catalog:Split(nil)
    return all
end
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

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

-- The window, drawn with fake frames ------------------------------------------

local function newScreen()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    return environment
end

local function newWindow(options)
    options = options or {}
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Adapters/GroupFinderWindow.lua")
    local environment = newScreen()
    local world = {
        level = options.level,
        shown = 0,
        environment = environment,
        -- The party the session is handed: `world.party` and `world.inGroup`.
        party = options.party or {},
        inGroup = options.party ~= nil,
    }
    local client = {
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }
    local roles = addon.RoleCatalog.For(options.client or "forever")
    world.session = addon.GroupSession.Create(roles)
    world.window = addon.GroupFinderWindow.Create(client, fakeFrames.host(environment), {
        dungeons = function()
            return addon.DungeonCatalog.Create(SAMPLE)
        end,
        playerLevel = function()
            return world.level
        end,
        session = world.session,
        roles = roles,
        syncParty = function()
            if world.session:IsActive() then
                world.session:UpdateParty(world.party, world.inGroup)
            end
        end,
        onShown = function()
            world.shown = world.shown + 1
        end,
    })
    return world
end

-- The labels of the dungeon rows showing, top to bottom.
local function shownRows(window)
    local labels = {}
    local index
    for index = 1, #window.rows do
        local row = window.rows[index]
        if row.button.shown then
            table.insert(labels, row.label.text)
        end
    end
    return table.concat(labels, ", ")
end

test.test("group finder window: draws on its tab, and brings it up to date each time it comes into view", function()
    local world = newWindow({ level = 23 })
    local window = world.window
    -- Drawn on the tab it was given, and nothing shows before it opens.
    test.assertEqual(nil, window.catalog)

    window.panel.hooks.OnShow()
    test.assertEqual(1, world.shown)
    test.assertEqual("Wailing Caverns (17–24), The Deadmines (17–26), Shadowfang Keep (22–30)", shownRows(window))

    -- Each time the tab comes back into view, the level is read again.
    world.level = 40
    window.panel.hooks.OnShow()
    test.assertEqual(2, world.shown)
    test.assertContains(window.hintText.text, "No dungeons fit level 40")
end)
test.test("group finder window: lists dungeons that fit the level, and Show all reveals the rest", function()
    local world = newWindow({ level = 23 })
    local window = world.window
    window:Opened()

    test.assertEqual("Wailing Caverns (17–24), The Deadmines (17–26), Shadowfang Keep (22–30)", shownRows(window))
    test.assertEqual("Pick a dungeon", window.dungeonText.text)

    window.showAllButton:SetChecked(true)
    window.showAllButton.scripts.OnClick(window.showAllButton)

    test.assertEqual("Wailing Caverns (17–24), The Deadmines (17–26), Shadowfang Keep (22–30), Stratholme (58–60)",
        shownRows(window))

    window.showAllButton:SetChecked(false)
    window.showAllButton.scripts.OnClick(window.showAllButton)
    test.assertEqual("Wailing Caverns (17–24), The Deadmines (17–26), Shadowfang Keep (22–30)", shownRows(window))
end)

test.test("group finder window: with nothing fitting the level, it says so until Show all", function()
    local world = newWindow({ level = 40 })
    local window = world.window
    window:Opened()

    test.assertEqual("", shownRows(window))
    test.assertContains(window.hintText.text, "No dungeons fit level 40")

    -- Without a level, every dungeon is listed.
    local unknown = newWindow({ level = nil }).window
    unknown:Opened()
    test.assertEqual(4, #unknown.rows)
end)

test.test("group finder window: picking a dungeon shows it and its range as the group's dungeon", function()
    local world = newWindow({ level = 23 })
    local window = world.window
    window:Opened()

    -- The Deadmines is the second row.
    window.rows[2].button.scripts.OnClick()

    test.assertEqual("dm", window:Picked().id)
    test.assertEqual("Dungeon: The Deadmines (17–26)", window.dungeonText.text)
    test.assertFalse(window:Pick("missing"))
    test.assertEqual("dm", window:Picked().id)
end)

test.test("group finder window: a tab out of view isn't redrawn", function()
    local world = newWindow({ level = 23 })
    local window = world.window
    window:Opened()
    window.panel:Hide()
    window.rows[1].label.text = "untouched"

    window:Refresh()

    test.assertEqual("untouched", window.rows[1].label.text)
    test.assertFalse(window:IsShown())
end)
test.test("group finder window: without a tab it isn't made, and says why", function()
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")

    local window, reason = addon.GroupFinderWindow.Create({ environment = {} }, nil, {})

    test.assertEqual(nil, window)
    test.assertContains(reason, "no tab")
end)
-- /agf group in the composed add-on -------------------------------------------

-- A Group Finder that records its options; the tab is the fixtures'.
local function newRecordingWindow()
    return { Refresh = function() end, Picked = function() return nil end }
end

local function loggedIn(profile, setup)
    local world = fixtures.newEnvironment(profile)
    if setup ~= nil then
        setup(world)
    end
    local addon = fixtures.loadAddon(world)
    local window = newRecordingWindow()
    window.creates = 0
    addon.GroupFinderWindow.Create = function(_, _, options)
        window.creates = window.creates + 1
        window.options = options
        return window
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    return world, addon, window
end

local function registerProfileTests(profile)
    test.test(profile .. " /agf group opens the master frame on the Group Finder tab, and again closes it", function()
        local world, addon, window = loggedIn(profile)

        fixtures.openGroupFinder(world)
        test.assertTrue(world.masterFrame.shown)
        test.assertEqual("group", world.masterFrame.page)
        fixtures.openGroupFinder(world)
        test.assertFalse(world.masterFrame.shown)
        -- Drawn once, with the frame.
        test.assertEqual(1, window.creates)
        -- The third tab, after the Roster and My Profile.
        local tabs = addon.pages:Tabs()
        test.assertEqual("roster", tabs[1].id)
        test.assertEqual("profile", tabs[2].id)
        test.assertEqual("group", tabs[3].id)
        test.assertEqual("Group Finder", tabs[3].label)
    end)

    test.test(profile .. " /agf group switches to the Group Finder tab when another tab is showing", function()
        local world, addon = loggedIn(profile)
        fixtures.openGroupFinder(world)
        addon.rosterController:ShowPage("roster")

        fixtures.openGroupFinder(world)

        test.assertTrue(world.masterFrame.shown)
        test.assertEqual("group", world.masterFrame.page)
    end)

    test.test(profile .. " /agf help lists /agf group", function()
        local world = loggedIn(profile)

        fixtures.slash(world, "help")

        test.assertContains(table.concat(world.messages, "\n"), "/agf group - open or close the Group Finder")
    end)

    test.test(profile .. " the Group Finder reads the character's level", function()
        local world, _, window = loggedIn(profile)
        world.playerLevel = 23
        fixtures.openGroupFinder(world)

        test.assertEqual(23, window.options.playerLevel())
    end)

    test.test(profile .. " /agf group says why when the tab can't be drawn", function()
        local world, addon = loggedIn(profile)
        addon.GroupFinderWindow.Create = function()
            return nil, "the Details! Framework isn't loaded"
        end

        fixtures.openGroupFinder(world)

        test.assertContains(world.messages[#world.messages],
            "The Group Finder can't be shown: the Details! Framework isn't loaded.")
    end)
end

registerProfileTests("Forever")
registerProfileTests("Retail")

test.test("Forever /agf group lists the static Classic dungeons", function()
    local world, _, window = loggedIn("Forever")
    fixtures.openGroupFinder(world)

    local catalog = window.options.dungeons()

    test.assertEqual("The Deadmines", catalog:Get("dm").name)
end)

test.test("Retail /agf group lists the Dungeon Finder's dungeons, and the static table when it has none", function()
    local entries = {
        { id = 1001, name = "Windrunner Spire", typeId = 1, subtypeId = 1, minLevel = 80, maxLevel = 90 },
    }
    local world, addon, window = loggedIn("Retail", function(world)
        installDungeonFinder(world.environment, entries)
    end)
    fixtures.openGroupFinder(world)

    test.assertEqual("Windrunner Spire", names(everyDungeon(window.options.dungeons())))

    -- The list is read again on every open.
    entries[1] = nil
    test.assertEqual(#addon.DungeonCatalog.STATIC.retail, #everyDungeon(window.options.dungeons()))
end)
