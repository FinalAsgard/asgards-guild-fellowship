local test = require("tests.test_helper")
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
    test.assertEqual("Wailing Caverns, The Deadmines, Shadowfang Keep, Stratholme", names(catalog:All()))
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

    test.assertEqual("The Deadmines", names(catalog:All()))
    test.assertEqual("The Deadmines", catalog:Get("dm").name)
end)

test.test("dungeon catalog: the Dungeon Finder's list wins, else the client's static table", function()
    local DungeonCatalog = newCatalogModule()

    local supplied = DungeonCatalog.For("retail", { { id = 1, name = "Finder Dungeon", minLevel = 80, maxLevel = 90 } })
    test.assertEqual("Finder Dungeon", names(supplied:All()))

    -- Nothing from the Dungeon Finder: Retail's own table.
    local retail = DungeonCatalog.For("retail", nil)
    test.assertTrue(#retail:All() > 0)
    test.assertEqual(#DungeonCatalog.STATIC.retail, #DungeonCatalog.For("retail", {}):All())
end)

test.test("dungeon catalog: WoW Forever uses the Classic dungeons with fixed ranges", function()
    local catalog = newCatalogModule().For("forever", nil)

    local deadmines = catalog:Get("dm")
    test.assertEqual("The Deadmines", deadmines.name)
    test.assertEqual(17, deadmines.minLevel)
    test.assertEqual(26, deadmines.maxLevel)
    test.assertEqual("Ragefire Chasm", catalog:All()[1].name)
    test.assertTrue(catalog:Fits("strat", 60))
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

-- A Details! Framework whose simple panel is a fake page that knows whether
-- it's shown and where its top-left corner is. The screen is 1000 high with
-- its top-left at (0, 1000).
local function newScreen()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    rawset(environment.UIParent, "GetTop", function() return 1000 end)
    local framework = { FrameWorkVersion = "746" }
    function framework:CreateSimplePanel(parent, width, height, title, name)
        local panel = environment.CreateFrame("Frame", name, nil)
        rawset(panel, "title", title)
        rawset(panel, "SetPoint", function(self, point, relativeTo, relativePoint, x, y)
            rawset(self, "point", { point = point, relativeTo = relativeTo, x = x, y = y })
        end)
        rawset(panel, "IsShown", function(self) return self.shown end)
        rawset(panel, "GetLeft", function(self) return rawget(self, "left") end)
        rawset(panel, "GetTop", function(self) return rawget(self, "top") end)
        return panel
    end
    environment.DetailsFramework = framework
    return environment
end

local function newWindow(options)
    options = options or {}
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    local environment = newScreen()
    local world = { level = options.level, saved = options.saved, saves = 0, environment = environment }
    local client = {
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }
    world.window = addon.GroupFinderWindow.Create(client, {
        dungeons = function()
            return addon.DungeonCatalog.Create(SAMPLE)
        end,
        playerLevel = function()
            return world.level
        end,
        loadAnchor = function()
            return world.saved
        end,
        saveAnchor = function(anchor)
            world.saves = world.saves + 1
            world.saved = anchor
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

test.test("group finder window: opens and closes, separate from the master frame", function()
    local world = newWindow({ level = 23 })
    local window = world.window

    test.assertEqual("Group Finder", window.panel.title)
    test.assertFalse(window:IsShown())
    test.assertTrue(window:Toggle())
    test.assertTrue(window:IsShown())
    test.assertFalse(window:Toggle())
    test.assertFalse(window:IsShown())
end)

test.test("group finder window: lists dungeons that fit the level, and Show all reveals the rest", function()
    local world = newWindow({ level = 23 })
    local window = world.window
    window:Toggle()

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
    window:Toggle()

    test.assertEqual("", shownRows(window))
    test.assertContains(window.hintText.text, "No dungeons fit level 40")

    -- Without a level, every dungeon is listed.
    local unknown = newWindow({ level = nil }).window
    unknown:Toggle()
    test.assertEqual(4, #unknown.rows)
end)

test.test("group finder window: picking a dungeon shows it and its range as the group's dungeon", function()
    local world = newWindow({ level = 23 })
    local window = world.window
    window:Toggle()

    -- The Deadmines is the second row.
    window.rows[2].button.scripts.OnClick()

    test.assertEqual("dm", window:Picked().id)
    test.assertEqual("Dungeon: The Deadmines (17–26)", window.dungeonText.text)
    test.assertFalse(window:Pick("missing"))
    test.assertEqual("dm", window:Picked().id)
end)

test.test("group finder window: can be dragged, saves where it's dropped, and opens there", function()
    local world = newWindow({ level = 23 })
    local panel = world.window.panel
    test.assertEqual("CENTER", panel.point.point)

    -- The panel moves itself while held; letting go at (300, 700) saves.
    rawset(panel, "left", 300)
    rawset(panel, "top", 700)
    panel.hooks.OnMouseUp()

    test.assertEqual(1, world.saves)
    test.assertEqual("TOPLEFT", world.saved.point)
    test.assertEqual(300, world.saved.x)
    test.assertEqual(-300, world.saved.y)

    local reopened = newWindow({ level = 23, saved = world.saved })
    test.assertEqual("TOPLEFT", reopened.window.panel.point.point)
    test.assertEqual(300, reopened.window.panel.point.x)
    test.assertEqual(-300, reopened.window.panel.point.y)
end)

test.test("group finder window: without the framework it isn't made, and says why", function()
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    local client = { environment = {}, GetGlobal = function() return { FrameWorkVersion = "746" } end }

    local window, reason = addon.GroupFinderWindow.Create(client, {})

    test.assertEqual(nil, window)
    test.assertContains(reason, "Details! Framework")
end)

test.test("group finder position: saved account-wide, and an unusable one counts as none", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 2, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertEqual(nil, store:GroupFinderAnchor())
    test.assertTrue(store:SetGroupFinderAnchor({ point = "TOPLEFT", x = 300, y = -300 }))
    test.assertEqual(300, addon.FellowshipStore.Create(database):GroupFinderAnchor().x)

    database.groupFinder.anchor = { point = "SIDEWAYS", x = 1, y = 1 }
    test.assertEqual(nil, store:GroupFinderAnchor())
    test.assertFalse(store:SetGroupFinderAnchor({ point = "TOPLEFT", x = "1", y = 1 }))

    database.groupFinder = "corrupt"
    test.assertFalse(store:SetGroupFinderAnchor({ point = "TOPLEFT", x = 40, y = -120 }))
    test.assertEqual("corrupt", database.groupFinder)
end)

-- /agf group in the composed add-on -------------------------------------------

-- A window that records how often it was toggled.
local function newRecordingWindow()
    local window = { open = false, toggles = 0 }
    function window:Toggle()
        self.toggles = self.toggles + 1
        self.open = not self.open
        return self.open
    end
    return window
end

local function loggedIn(profile, setup)
    local world = fixtures.newEnvironment(profile)
    if setup ~= nil then
        setup(world)
    end
    local addon = fixtures.loadAddon(world)
    local window = newRecordingWindow()
    window.creates = 0
    addon.GroupFinderWindow.Create = function(_, options)
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
    test.test(profile .. " /agf group opens the Group Finder, and again closes it", function()
        local world, _, window = loggedIn(profile)

        fixtures.slash(world, "group")
        test.assertTrue(window.open)
        fixtures.slash(world, "group")
        test.assertFalse(window.open)
        -- The window is made once and reused.
        test.assertEqual(1, window.creates)
        test.assertEqual(2, window.toggles)
    end)

    test.test(profile .. " /agf help lists /agf group", function()
        local world = loggedIn(profile)

        fixtures.slash(world, "help")

        test.assertContains(table.concat(world.messages, "\n"), "/agf group - open or close the Group Finder")
    end)

    test.test(profile .. " the Group Finder reads the character's level and saves its place", function()
        local world, _, window = loggedIn(profile)
        world.playerLevel = 23
        fixtures.slash(world, "group")

        test.assertEqual(23, window.options.playerLevel())
        test.assertEqual(nil, window.options.loadAnchor())
        window.options.saveAnchor({ point = "TOPLEFT", x = 10, y = -20 })
        test.assertEqual(10, window.options.loadAnchor().x)
        test.assertEqual(10, world.database.groupFinder.anchor.x)
    end)

    test.test(profile .. " /agf group says why when the window can't be made", function()
        local world, addon = loggedIn(profile)
        addon.GroupFinderWindow.Create = function()
            return nil, "the Details! Framework isn't loaded"
        end

        fixtures.slash(world, "group")

        test.assertContains(world.messages[#world.messages],
            "The Group Finder can't be shown: the Details! Framework isn't loaded.")
    end)
end

registerProfileTests("Forever")
registerProfileTests("Retail")

test.test("Forever /agf group lists the static Classic dungeons", function()
    local world, _, window = loggedIn("Forever")
    fixtures.slash(world, "group")

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
    fixtures.slash(world, "group")

    test.assertEqual("Windrunner Spire", names(window.options.dungeons():All()))

    -- The list is read again on every open.
    entries[1] = nil
    test.assertEqual(#addon.DungeonCatalog.STATIC.retail, #window.options.dungeons():All())
end)
