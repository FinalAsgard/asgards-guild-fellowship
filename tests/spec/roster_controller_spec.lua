local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- A window that records what the controller asks of it.
local function newWindow()
    local window = { shown = false, rows = nil, title = nil, status = nil }
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
    function window:SetStatus(text)
        self.status = text
    end
    function window:SetConflicts(rows)
        self.conflicts = rows
        return true
    end
    function window:SetRows(rows)
        self.rows = rows
        return true
    end
    return window
end

local MODULES = {
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
    "Core/RosterController.lua",
}

local function build(profile, options)
    options = options or {}
    local world = fixtures.newEnvironment(profile, options.world)
    local addon = test.newAddon(unpack(MODULES))
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
    local setup = {
        controller = controller,
        database = database,
        window = window,
        world = world,
    }
    function setup.windowsCreated()
        return windowsCreated
    end
    -- Logs in: saved data becomes ready and the roster reports in.
    function setup.login()
        controller:OnSavedDataReady()
        controller:OnRosterUpdate()
        fixtures.runTimers(world)
    end
    function setup.partition()
        local key = profile == "Forever" and "Knights of Camelot-Camelot" or "Knights of Camelot-Area52"
        return database.guilds[key]
    end
    return setup
end

local function countKeys(map)
    local count = 0
    local _
    for _ in pairs(map) do
        count = count + 1
    end
    return count
end

local EXPECTED_FIRST = {
    Forever = { key = "tool box-camelot", name = "Tool Box", alt = "hammer smith-camelot" },
    Retail = { key = "toolbox-area52", name = "Toolbox", alt = "hammer-area52" },
}

local function newcomer()
    return { name = "Newcomer", class = "ROGUE", level = 1, rank = 4, rankName = "Initiate",
        online = true, zone = "Elwynn" }
end

local function registerProfileTests(profile)
    local first = EXPECTED_FIRST[profile]
    local newcomerKey = profile == "Forever" and "newcomer-camelot" or "newcomer-area52"

    test.test(profile .. " login runs the first full scan and seeds players from notes", function()
        local setup = build(profile)

        setup.login()

        local partition = setup.partition()
        local main = partition.characters[first.key]
        test.assertEqual(main.player, partition.characters[first.alt].player)
        test.assertEqual("TheTool", partition.players[main.player].alias)
        test.assertEqual(setup.world.time, partition.lastFullScan)
        test.assertContains(setup.world.messages[1],
            "Roster scanned: 3 new characters, 1 alt linked, 1 alias set.")

        test.assertTrue(setup.controller:Toggle())
        test.assertEqual(4, #setup.window.rows)
        test.assertEqual("TheTool (" .. first.name .. ")", setup.window.rows[1].label)
        test.assertContains(setup.window.status, "Last scan just now: 3 new characters")
        test.assertContains(setup.window.status, "\nNot synced yet")
    end)

    test.test(profile .. " opening the window never scans", function()
        local setup = build(profile)

        test.assertTrue(setup.controller:Toggle())

        test.assertEqual(0, setup.world.rosterRequests)
        test.assertEqual(0, #setup.window.rows)
        test.assertEqual(nil, setup.partition().lastFullScan)
        test.assertContains(setup.window.status, "Not scanned yet")
        test.assertEqual(0, #setup.world.messages)
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

    test.test(profile .. " rescan waits for the refreshed roster, then scans", function()
        local setup = build(profile)
        setup.login()
        setup.world.guild.members[4] = newcomer()
        local requests = setup.world.rosterRequests

        test.assertTrue(setup.controller:Rescan())
        test.assertEqual(requests + 1, setup.world.rosterRequests)
        test.assertContains(setup.world.messages[#setup.world.messages], "Scanning the guild roster")
        setup.controller:OnRosterUpdate()

        test.assertContains(setup.world.messages[#setup.world.messages], "Roster scanned: 1 new character")
        test.assertTrue(setup.partition().characters[newcomerKey] ~= nil)
    end)

    test.test(profile .. " rescan reads the roster anyway when no update arrives", function()
        local setup = build(profile)
        setup.login()

        setup.controller:Rescan()
        fixtures.runTimers(setup.world, 3)

        test.assertContains(setup.world.messages[#setup.world.messages], "Roster scanned: 0 new characters")
    end)

    test.test(profile .. " a second rescan while one is running is refused", function()
        local setup = build(profile)
        setup.login()

        test.assertTrue(setup.controller:Rescan())
        test.assertFalse(setup.controller:Rescan())

        test.assertContains(setup.world.messages[#setup.world.messages], "already running")
    end)

    test.test(profile .. " a roster still loading at login is never treated as complete", function()
        local setup = build(profile, { world = { rosterReady = false } })

        setup.login()
        test.assertEqual(nil, setup.partition().lastFullScan)
        test.assertEqual(0, countKeys(setup.partition().characters))

        setup.world.rosterReady = true
        setup.controller:OnRosterUpdate()

        test.assertEqual(3, countKeys(setup.partition().characters))
        test.assertTrue(setup.partition().lastFullScan ~= nil)
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
    setup.login()
    setup.controller:Toggle()
    local header = setup.window.rows[1]

    setup.controller:ToggleGroup(header.id)
    test.assertEqual(2, #setup.window.rows)
    test.assertTrue(setup.window.rows[1].collapsed)

    setup.controller:ToggleGroup(header.id)
    test.assertEqual(4, #setup.window.rows)
end)

test.test("roster updates refresh an open window with live facts", function()
    local setup = build("Retail")
    setup.login()
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

test.test("scan descriptions name what was found", function()
    local addon = test.newAddon(unpack(MODULES))
    local describe = addon.RosterController.DescribeScan

    test.assertEqual("0 new characters", describe({ newCharacters = 0 }))
    test.assertEqual("1 new character, 2 alts linked, 2 aliases set, 3 new conflicts to review",
        describe({ newCharacters = 1, linked = 2, aliased = 2, conflicts = 3 }))
end)
