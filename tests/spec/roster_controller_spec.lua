local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- A window that records what the controller asks of it.
local function newWindow()
    local window = { shown = false, rows = nil, title = nil }
    function window:IsShown()
        return self.shown
    end
    function window:Show()
        self.shown = true
    end
    function window:Hide()
        self.shown = false
    end
    function window:SetTitle(title)
        self.title = title
    end
    function window:SetRows(rows)
        self.rows = rows
        return true
    end
    return window
end

local function build(profile, options)
    options = options or {}
    local world = fixtures.newEnvironment(profile, options.world)
    local addon = test.newAddon(
        "Adapters/ClientProfile.lua",
        "Adapters/WoW.lua",
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/RosterViewModel.lua",
        "Core/RosterController.lua"
    )
    local client = addon.Compatibility.Create(world.environment)
    local database = options.database
    if database == nil then
        database = { schemaVersion = 1, guilds = {} }
    end
    local window = newWindow()
    local windowsCreated = 0
    local controller = addon.RosterController.Create({
        client = client,
        nameRules = client:GetClientProfile().nameRules,
        getDatabase = function()
            return database or nil
        end,
        createWindow = function()
            windowsCreated = windowsCreated + 1
            if options.noFramework then
                return nil, "the Details! Framework is not available"
            end
            return window
        end,
    })
    return {
        controller = controller,
        database = database,
        window = window,
        windowsCreated = function()
            return windowsCreated
        end,
        world = world,
    }
end

local EXPECTED_FIRST = {
    Forever = { key = "tool box-camelot", name = "Tool Box", alt = "hammer smith-camelot" },
    Retail = { key = "toolbox-area52", name = "Toolbox", alt = "hammer-area52" },
}

local function registerProfileTests(profile)
    local first = EXPECTED_FIRST[profile]

    test.test(profile .. " first open scans an unscanned guild and seeds players from notes", function()
        local setup = build(profile)

        test.assertTrue(setup.controller:Toggle())

        local partitionKey = profile == "Forever" and "Knights of Camelot-Camelot" or "Knights of Camelot-Area52"
        local partition = setup.database.guilds[partitionKey]
        -- Two player headers: TheTool with main and alt, and a single.
        test.assertEqual(5, #setup.window.rows)
        test.assertTrue(setup.window.shown)
        test.assertEqual(1790000000, partition.lastFullScan)
        test.assertTrue(partition.characters[first.key] ~= nil)
        test.assertEqual(setup.world.guild.members[1].name, partition.characters[first.key].name)
        test.assertEqual("TheTool (" .. first.name .. ")", setup.window.rows[1].label)
        test.assertEqual(first.name, setup.window.rows[2].name)
        test.assertTrue(setup.window.rows[2].isMain)
        test.assertContains(setup.window.title, "Knights of Camelot")
        test.assertContains(setup.world.messages[1],
            "Roster scanned: 3 characters, 1 linked and 1 aliases set from notes.")
        local main = partition.characters[first.key]
        test.assertEqual(main.player, partition.characters[first.alt].player)
        test.assertEqual("TheTool", partition.players[main.player].alias)
    end)

    test.test(profile .. " later opens never scan", function()
        local setup = build(profile)
        setup.controller:Toggle()
        setup.controller:Toggle()
        local requests = setup.world.rosterRequests
        setup.world.guild.members[4] = { name = "Newcomer-Camelot", class = "ROGUE", level = 1, rank = 4,
            rankName = "Initiate", online = true, zone = "Elwynn" }

        setup.controller:Toggle()

        test.assertEqual(requests, setup.world.rosterRequests)
        test.assertEqual(5, #setup.window.rows)
        test.assertEqual(1, setup.windowsCreated())
    end)

    test.test(profile .. " /agf toggles the window, hiding rather than destroying it", function()
        local setup = build(profile)

        setup.controller:Toggle()
        test.assertTrue(setup.window.shown)
        setup.controller:Toggle()
        test.assertFalse(setup.window.shown)
        setup.controller:Toggle()
        test.assertTrue(setup.window.shown)
        test.assertEqual(1, setup.windowsCreated())
    end)

    test.test(profile .. " rescan reads the roster again on request", function()
        local setup = build(profile)
        setup.controller:Toggle()
        setup.world.guild.members[4] = { name = "Newcomer-Camelot", class = "ROGUE", level = 1, rank = 4,
            rankName = "Initiate", online = true, zone = "Elwynn" }

        test.assertTrue(setup.controller:Rescan())

        test.assertEqual(7, #setup.window.rows)
        test.assertContains(setup.world.messages[#setup.world.messages], "Roster scanned: 4 characters")
    end)

    test.test(profile .. " a loading roster finishes the scan on the next roster update", function()
        local setup = build(profile, { world = { rosterReady = false } })

        setup.controller:Toggle()
        test.assertEqual(0, #setup.window.rows)
        test.assertEqual(1, setup.world.rosterRequests)

        setup.world.rosterReady = true
        setup.controller:OnRosterUpdate()

        test.assertEqual(5, #setup.window.rows)
        test.assertContains(setup.world.messages[1], "Roster scanned: 3 characters")
    end)

    test.test(profile .. " a character not in a guild gets a clear message", function()
        local setup = build(profile, { world = { guild = false } })

        test.assertFalse(setup.controller:Toggle())

        test.assertEqual(1, #setup.world.messages)
        test.assertContains(setup.world.messages[1], "You're not in a guild")
        test.assertEqual(0, setup.windowsCreated())
        test.assertEqual(nil, next(setup.database.guilds))
    end)

    test.test(profile .. " a missing Details! Framework gives a clear message instead of errors", function()
        local setup = build(profile, { noFramework = true })

        local ok, opened = pcall(setup.controller.Toggle, setup.controller)

        test.assertTrue(ok)
        test.assertFalse(opened)
        test.assertContains(setup.world.messages[1], "The roster window can't open")
        test.assertContains(setup.world.messages[1], "Details! Framework is not available")
        test.assertFalse(setup.database.guilds["Knights of Camelot-" ..
            (profile == "Forever" and "Camelot" or "Area52")].lastFullScan ~= nil)
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("unusable saved data stops the roster with a message", function()
    local setup = build("Retail", { database = false })

    test.assertFalse(setup.controller:Toggle())
    test.assertContains(setup.world.messages[1], "Saved data is unavailable")
end)

test.test("clicking a player header collapses and expands its group", function()
    local setup = build("Retail")
    setup.controller:Toggle()
    local header = setup.window.rows[1]

    setup.controller:ToggleGroup(header.id)
    test.assertEqual(3, #setup.window.rows)
    test.assertTrue(setup.window.rows[1].collapsed)

    setup.controller:ToggleGroup(header.id)
    test.assertEqual(5, #setup.window.rows)
end)

test.test("roster updates refresh an open window with live facts", function()
    local setup = build("Retail")
    setup.controller:Toggle()
    setup.world.guild.members[2].online = true
    setup.world.guild.members[2].zone = "Valdrakken"

    setup.controller:OnRosterUpdate()

    local hammer
    local rowIndex
    for rowIndex = 1, #setup.window.rows do
        if setup.window.rows[rowIndex].name == "Hammer" then
            hammer = setup.window.rows[rowIndex]
        end
    end
    test.assertTrue(hammer.online)
    test.assertEqual("Valdrakken", hammer.location)
end)
