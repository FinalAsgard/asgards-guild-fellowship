local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/RosterViewModel.lua"
    )
end

-- TheTool: Tool Box (main, offline) + Hammer Smith (online);
-- Zed One and Anna Two on their own, both offline.
local function setup()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Camelot" })
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = true, homeRealm = "Camelot" })
    partition:RecordCharacter("tool box-camelot", { name = "Tool Box", level = 60 })
    partition:RecordCharacter("hammer smith-camelot", { name = "Hammer Smith", level = 42 })
    partition:RecordCharacter("zed one-camelot", { name = "Zed One" })
    partition:RecordCharacter("anna two-camelot", { name = "Anna Two" })
    partition:JoinPlayerOf("hammer smith-camelot", "tool box-camelot", "note")
    partition:SetAlias(partition:GetCharacter("tool box-camelot").player, "TheTool", "note")
    local members = {
        ["tool box-camelot"] = { name = "Tool Box", online = false },
        ["hammer smith-camelot"] = { name = "Hammer Smith", online = true, zone = "Ironforge" },
        ["zed one-camelot"] = { name = "Zed One", online = false },
        ["anna two-camelot"] = { name = "Anna Two", online = false },
    }
    local function build(extra)
        local inputs = { partition = partition, members = members, normalizer = normalizer }
        local key, value
        for key, value in pairs(extra or {}) do
            inputs[key] = value
        end
        return addon.RosterViewModel.Build(inputs)
    end
    return { addon = addon, partition = partition, build = build, members = members }
end

local function labels(rows)
    local found = {}
    local index
    for index = 1, #rows do
        if rows[index].kind == "player" or rows[index].standalone then
            table.insert(found, rows[index].label)
        end
    end
    return table.concat(found, ", ")
end

test.test("search matches aliases and character names, ignoring case", function()
    local state = setup()

    test.assertEqual("TheTool (Tool Box)", labels(state.build({ search = "thetool" })))
    test.assertEqual("TheTool (Tool Box)", labels(state.build({ search = "  HAMMER " })))
    test.assertEqual("Zed One", labels(state.build({ search = "zed" })))
    test.assertEqual("", labels(state.build({ search = "nobody" })))
end)

test.test("a player matched by one character shows its whole group", function()
    local state = setup()

    local rows = state.build({ search = "hammer" })

    test.assertEqual(3, #rows)
    test.assertEqual("Tool Box", rows[2].name)
    test.assertEqual("Hammer Smith", rows[3].name)
end)

test.test("online only shows players with at least one character online", function()
    local state = setup()

    test.assertEqual("TheTool (Tool Box)", labels(state.build({ onlineOnly = true })))

    state.members["hammer smith-camelot"].online = false
    test.assertEqual("", labels(state.build({ onlineOnly = true })))
end)

test.test("players sort online first, then by display name, with the main first in each group", function()
    local state = setup()

    local rows = state.build()

    test.assertEqual("TheTool (Tool Box), Anna Two, Zed One", labels(rows))
    test.assertTrue(rows[2].isMain)
    test.assertEqual("Tool Box", rows[2].name)
end)

test.test("a player header names the character it is online as", function()
    local state = setup()

    local header = state.build()[1]

    test.assertTrue(header.online)
    test.assertEqual("Hammer Smith", header.onlineAs)
end)

test.test("the online rollup prefers the main when it is online", function()
    local state = setup()
    state.members["tool box-camelot"].online = true

    test.assertEqual("Tool Box", state.build()[1].onlineAs)
end)

test.test("collapse all lists every group with more than one character", function()
    local state = setup()

    local ids = state.addon.RosterViewModel.GroupIds(state.partition)

    test.assertEqual(1, #ids)
    test.assertEqual(state.partition:GetCharacter("tool box-camelot").player, ids[1])
end)

test.test("the build cache rebuilds only when the stamp changes", function()
    local state = setup()
    local cache = state.addon.RosterViewModel.CreateCache()
    local inputs = { partition = state.partition, members = state.members,
        normalizer = state.addon.NameNormalizer.Create({ twoPartNames = true, homeRealm = "Camelot" }) }

    local first = cache:Build(inputs, "a")
    local again = cache:Build(inputs, "a")
    test.assertEqual(first, again)
    test.assertEqual(1, cache.builds)

    cache:Build(inputs, "b")
    test.assertEqual(2, cache.builds)
end)

-- Controller: controls and rebuild-on-change ----------------------------------

local function controllerSetup()
    local world = fixtures.newEnvironment("Retail")
    local addon = test.newAddon(
        "Adapters/ClientProfile.lua",
        "Adapters/WoW.lua",
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/RosterViewModel.lua",
        "Core/ConflictViewModel.lua",
        "Core/ScanScheduler.lua",
        "Core/RosterController.lua"
    )
    local client = addon.Compatibility.Create(world.environment)
    local database = { schemaVersion = 1, guilds = {} }
    local window = { shown = false, rows = {}, setRows = 0 }
    function window:IsShown() return self.shown end
    function window:Show() self.shown = true end
    function window:Hide() self.shown = false end
    function window:SetTitle() end
    function window:SetStatus() end
    function window:SetRows(rows) self.rows = rows self.setRows = self.setRows + 1 return true end
    function window:SetConflicts() return true end
    local controller = addon.RosterController.Create({
        client = client,
        nameRules = client:GetClientProfile().nameRules,
        getDatabase = function() return database end,
        createWindow = function() return window end,
    })
    controller:OnSavedDataReady()
    controller:OnRosterUpdate()
    fixtures.runTimers(world)
    controller:Toggle()
    return controller, window
end

test.test("expand all and collapse all change every group and survive reopening", function()
    local controller, window = controllerSetup()

    controller:CollapseAll()
    test.assertTrue(window.rows[1].collapsed)
    test.assertEqual(2, #window.rows)

    controller:Toggle()
    controller:Toggle()
    test.assertTrue(window.rows[1].collapsed)

    controller:ExpandAll()
    test.assertFalse(window.rows[1].collapsed)
    test.assertEqual(4, #window.rows)
end)

test.test("the controls filter the roster", function()
    local controller, window = controllerSetup()

    controller:SetSearch("visitor")
    test.assertEqual(1, #window.rows)
    controller:SetSearch("")
    test.assertTrue(controller:ToggleOnlineOnly())
    test.assertEqual(3, #window.rows)
    test.assertEqual("Toolbox", window.rows[1].onlineAs)
end)

test.test("reopening the window without changes doesn't rebuild the rows", function()
    local controller, window = controllerSetup()
    local builds = controller.cache.builds

    controller:Toggle()
    controller:Toggle()
    controller:Toggle()
    controller:Toggle()

    test.assertEqual(builds, controller.cache.builds)
    controller:SetSearch("tool")
    test.assertEqual(builds + 1, controller.cache.builds)
    controller:SetSearch("tool")
    test.assertEqual(builds + 1, controller.cache.builds)
end)
