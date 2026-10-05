local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function loadRuntimeModules()
    return test.newAddon(
        "Adapters/ClientProfile.lua",
        "Adapters/WoW.lua",
        "Core/CommandRouter.lua",
        "Core/Lifecycle.lua"
    )
end

local function newFrame()
    local frame = { registeredEvents = {} }

    function frame:RegisterEvent(eventName)
        self.registeredEvents[eventName] = true
    end

    function frame:SetScript(scriptName, handler)
        self.scriptName = scriptName
        self.handler = handler
    end

    return frame
end

test.test("lifecycle registers slash handling at add-on load", function()
    local addon = loadRuntimeModules()
    local frame = newFrame()
    local messages = {}
    local environment = {
        CreateFrame = function(frameType)
            test.assertEqual("Frame", frameType)
            return frame
        end,
        SlashCmdList = {},
    }
    local client = addon.Compatibility.Create(environment)
    local router = addon.CommandRouter.Create(function(message)
        table.insert(messages, message)
    end)
    router:Register("help", "show available commands", function()
        router:PrintHelp()
    end)
    local lifecycle = addon.Lifecycle.Create(client, router)

    test.assertTrue(lifecycle:Start())
    test.assertTrue(frame.registeredEvents.ADDON_LOADED)
    test.assertTrue(frame.registeredEvents.PLAYER_LOGIN)
    test.assertEqual("OnEvent", frame.scriptName)
    test.assertEqual(nil, environment.SLASH_AGF1)

    frame.handler(frame, "ADDON_LOADED", "SomeOtherAddon")
    test.assertEqual(nil, environment.SLASH_AGF1)

    frame.handler(frame, "ADDON_LOADED", "AsgardsGuildFellowship")
    test.assertTrue(lifecycle.slashRegistered)
    test.assertEqual("/agf", environment.SLASH_AGF1)
    test.assertEqual("/asgardsfellowship", environment.SLASH_AGF2)

    environment.SlashCmdList.AGF("")
    test.assertEqual(
        "|cffd4af37[Guild Fellowship]|r Commands: /agf help - show available commands",
        messages[1]
    )
end)

test.test("lifecycle registers slash handling once when duplicate load events arrive", function()
    local addon = loadRuntimeModules()
    local registrations = 0
    local client = {
        RegisterSlashCommand = function()
            registrations = registrations + 1
            return true
        end,
        IsLoggedIn = function()
            return false
        end,
    }
    local lifecycle = addon.Lifecycle.Create(client, {})

    lifecycle:OnEvent("ADDON_LOADED", "AsgardsGuildFellowship")
    lifecycle:OnEvent("ADDON_LOADED", "AsgardsGuildFellowship")

    test.assertEqual(1, registrations)
end)

test.test("lifecycle initializes state once at login and retries a failure quietly", function()
    local addon = loadRuntimeModules()
    local attempts = 0
    local messages = {}
    local client = {
        Print = function(_, message)
            table.insert(messages, message)
            return true
        end,
    }
    local state = {
        Initialize = function()
            attempts = attempts + 1
            if attempts < 2 then
                return false, "saved data is not ready"
            end
            return true
        end,
    }
    local lifecycle = addon.Lifecycle.Create(client, {}, state)

    lifecycle:OnEvent("PLAYER_LOGIN")
    lifecycle:OnEvent("PLAYER_ENTERING_WORLD")
    lifecycle:OnEvent("PLAYER_ENTERING_WORLD")

    test.assertEqual(2, attempts)
    test.assertTrue(lifecycle.stateReady)
    test.assertEqual(1, #messages)
    test.assertContains(messages[1], "saved data is not ready")
end)

test.test("lifecycle initializes state at add-on load when the player is already logged in", function()
    local addon = loadRuntimeModules()
    local initializations = 0
    local environment = {
        IsLoggedIn = function()
            return true
        end,
        SlashCmdList = {},
    }
    local client = addon.Compatibility.Create(environment)
    local state = {
        Initialize = function()
            initializations = initializations + 1
            return true
        end,
    }
    local lifecycle = addon.Lifecycle.Create(client, addon.CommandRouter.Create(), state)

    lifecycle:OnEvent("ADDON_LOADED", "AsgardsGuildFellowship")
    lifecycle:OnEvent("PLAYER_LOGIN")

    test.assertEqual(1, initializations)
    test.assertTrue(lifecycle.stateReady)
end)

test.test("state initialization exceptions are reported, not raised", function()
    local addon = loadRuntimeModules()
    local messages = {}
    local client = {
        Print = function(_, message)
            table.insert(messages, message)
            return true
        end,
    }
    local state = {
        Initialize = function()
            error("persistence exploded")
        end,
    }
    local lifecycle = addon.Lifecycle.Create(client, {}, state)

    test.assertFalse(lifecycle:InitializeState())
    test.assertContains(messages[1], "persistence exploded")
end)

test.test("missing frame capability falls back to immediate slash registration", function()
    local addon = loadRuntimeModules()
    local environment = { SlashCmdList = {} }
    local client = addon.Compatibility.Create(environment)
    local lifecycle = addon.Lifecycle.Create(client, addon.CommandRouter.Create())

    test.assertFalse(lifecycle:Start())
    test.assertTrue(lifecycle.slashRegistered)
    test.assertEqual("/agf", environment.SLASH_AGF1)
end)

test.test("all missing client capabilities are handled without an error", function()
    local addon = loadRuntimeModules()
    local client = addon.Compatibility.Create({})
    local lifecycle = addon.Lifecycle.Create(client, addon.CommandRouter.Create())

    local ok, started = pcall(function()
        return lifecycle:Start()
    end)

    test.assertTrue(ok)
    test.assertFalse(started)
    test.assertFalse(lifecycle.slashRegistered)
end)

local function registerProfileTests(profile, addonName)
    local label = "WoW " .. profile
    local name = profile .. " " .. addonName

    test.test(name .. " registers its commands at load and answers help with version and client", function()
        local world = fixtures.newEnvironment(profile, { addonName = addonName })
        local addon = fixtures.loadAddon(world)
        local identity = addon.Identity
        local version = world.manifest.Version

        test.assertEqual(profile == "Forever" and "forever" or "retail", addon.clientProfile.id)
        fixtures.fire(world, "ADDON_LOADED", addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")

        test.assertEqual(identity.slashCommand, world.environment["SLASH_" .. identity.slashKey .. "1"])
        test.assertEqual(identity.slashAlias, world.environment["SLASH_" .. identity.slashKey .. "2"])
        test.assertEqual(0, #world.messages)
        test.assertEqual(1, world.database.schemaVersion)
        test.assertEqual("table", type(world.database.guilds))

        fixtures.slash(world, "help")
        test.assertEqual(
            identity.chatPrefix .. " Version " .. version .. " on " .. label .. ".",
            world.messages[#world.messages - 1]
        )
        test.assertEqual(
            identity.chatPrefix .. " Libraries: all 6 present.",
            world.messages[#world.messages]
        )

        fixtures.slash(world, "nonsense")
        test.assertContains(world.messages[#world.messages], identity.slashCommand .. " help")
    end)

    test.test(name .. " on an unsupported client reports once and leaves saved data untouched", function()
        local existing = { schemaVersion = 99, unknown = { kept = true } }
        local before = fixtures.snapshot(existing)
        local world = fixtures.newEnvironment(profile, {
            addonName = addonName,
            database = existing,
            declaredClient = false,
        })
        local addon = fixtures.loadAddon(world)

        fixtures.fire(world, "ADDON_LOADED", addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")

        test.assertFalse(addon.clientProfile.supported)
        test.assertEqual(1, #world.messages)
        test.assertContains(world.messages[1], "This game client is not supported")
        test.assertContains(world.messages[1], "WoW Forever and WoW Retail")
        test.assertEqual(0, world.savedVariableReads)
        test.assertEqual(0, world.savedVariableWrites)
        test.assertEqual(existing, world.database)
        fixtures.assertSameData(before, existing)

        fixtures.slash(world, "help")
        test.assertContains(world.messages[#world.messages - 1], "on Unsupported client.")
        test.assertEqual(0, world.savedVariableReads)
        test.assertEqual(0, world.savedVariableWrites)
    end)
end

local profileIndex, buildIndex
for profileIndex = 1, #fixtures.PROFILES do
    for buildIndex = 1, #fixtures.BUILDS do
        registerProfileTests(fixtures.PROFILES[profileIndex], fixtures.BUILDS[buildIndex])
    end
end
