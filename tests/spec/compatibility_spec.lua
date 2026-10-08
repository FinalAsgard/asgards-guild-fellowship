local test = require("tests.test_helper")

local function newClient(environment)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(environment)
end

local function raises()
    error("client API failed")
end

test.test("adapter returns nil or false when every client API is missing", function()
    local client = newClient({})

    test.assertEqual(nil, client:CreateEventFrame())
    test.assertFalse(client:RegisterEvent(nil, "ADDON_LOADED"))
    test.assertFalse(client:SetEventHandler(nil, function() end))
    test.assertFalse(client:IsLoggedIn())
    test.assertFalse(client:RegisterSlashCommand("/agf", "/asgardsfellowship", "AGF", function() end))
    test.assertFalse(client:Print("hello"))
    test.assertEqual(nil, client:GetAddOnMetadata("Version"))
    test.assertEqual(nil, client:GetAccountDatabase())
    test.assertFalse(client:GetClientProfile().supported)
end)

test.test("adapter contains errors raised by client APIs", function()
    local frame = { RegisterEvent = raises, SetScript = raises }
    local client = newClient({
        CreateFrame = raises,
        DEFAULT_CHAT_FRAME = { AddMessage = raises },
        GetAddOnMetadata = raises,
        IsLoggedIn = raises,
        print = raises,
        RegisterNewSlashCommand = raises,
    })

    test.assertEqual(nil, client:CreateEventFrame())
    test.assertFalse(client:RegisterEvent(frame, "ADDON_LOADED"))
    test.assertFalse(client:SetEventHandler(frame, function() end))
    test.assertFalse(client:IsLoggedIn())
    test.assertFalse(client:RegisterSlashCommand("/agf", "/asgardsfellowship", "AGF", function() end))
    test.assertFalse(client:Print("hello"))
    test.assertEqual(nil, client:GetAddOnMetadata("Version"))
end)

test.test("random numbers come from the client, or the low end without one", function()
    test.assertEqual(7, newClient({ math = { random = function(low, high)
        test.assertEqual(0, low)
        test.assertEqual(30, high)
        return 7
    end } }):Random(0, 30))
    test.assertEqual(0, newClient({}):Random(0, 30))
    test.assertEqual(1, newClient({ math = { random = raises } }):Random(1, 5))
end)

test.test("adapter falls back to print and to SlashCmdList", function()
    local printed
    local handler = function() end
    local environment = {
        print = function(message)
            printed = message
        end,
        RegisterNewSlashCommand = raises,
        SlashCmdList = {},
    }
    local client = newClient(environment)

    test.assertTrue(client:Print("hello"))
    test.assertEqual("hello", printed)
    test.assertTrue(client:RegisterSlashCommand("/agf", "/asgardsfellowship", "AGF", handler))
    test.assertEqual("/agf", environment.SLASH_AGF1)
    test.assertEqual("/asgardsfellowship", environment.SLASH_AGF2)
    test.assertEqual(handler, environment.SlashCmdList.AGF)
end)

test.test("adapter reads and writes only the current build's SavedVariables", function()
    local environment = { AsgardsGuildFellowshipDevDB = { sentinel = "dev" } }
    local client = newClient(environment)
    local database = { schemaVersion = 1 }

    test.assertTrue(client:SetAccountDatabase(database))
    test.assertEqual(database, environment.AsgardsGuildFellowshipDB)
    test.assertEqual(database, client:GetAccountDatabase())
    test.assertEqual("dev", environment.AsgardsGuildFellowshipDevDB.sentinel)
end)
