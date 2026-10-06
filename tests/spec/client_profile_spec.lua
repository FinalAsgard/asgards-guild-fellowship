local test = require("tests.test_helper")

local function detect(environment)
    local addon = test.newAddon("Adapters/ClientProfile.lua")
    return addon.ClientProfile.Detect(environment, "AsgardsGuildFellowship")
end

local function metadata(value)
    return {
        GetAddOnMetadata = function(addonName, field)
            test.assertEqual("AsgardsGuildFellowship", addonName)
            test.assertEqual("X-Client", field)
            return value
        end,
    }
end

local DETECTION_CASES = {
    {
        name = "Forever manifest on the Forever client",
        environment = { GetAddOnMetadata = metadata("Forever").GetAddOnMetadata },
        id = "forever",
        label = "WoW Forever",
    },
    {
        name = "Forever manifest while sharing Retail project constants",
        environment = {
            GetAddOnMetadata = metadata("Forever").GetAddOnMetadata,
            WOW_PROJECT_ID = 1,
            WOW_PROJECT_MAINLINE = 1,
        },
        id = "forever",
        label = "WoW Forever",
    },
    {
        name = "Retail manifest on the Retail client",
        environment = {
            C_AddOns = metadata("Retail"),
            WOW_PROJECT_ID = 1,
            WOW_PROJECT_MAINLINE = 1,
        },
        id = "retail",
        label = "WoW Retail",
    },
    {
        name = "Retail manifest on a non-Retail project",
        environment = {
            C_AddOns = metadata("Retail"),
            WOW_PROJECT_ID = 2,
            WOW_PROJECT_MAINLINE = 1,
        },
        id = "unsupported",
        reason = "Retail manifest loaded on a non-Retail client",
    },
    {
        name = "Retail manifest without project constants",
        environment = { C_AddOns = metadata("Retail") },
        id = "unsupported",
        reason = "non-Retail client",
    },
    {
        name = "manifest without a client declaration",
        environment = {
            C_AddOns = metadata(nil),
            WOW_PROJECT_ID = 1,
            WOW_PROJECT_MAINLINE = 1,
        },
        id = "unsupported",
        reason = "does not declare a supported client",
    },
    {
        name = "manifest declaring an unknown client",
        environment = { C_AddOns = metadata("Classic") },
        id = "unsupported",
        reason = "unknown client 'Classic'",
    },
    {
        name = "client without a metadata API",
        environment = { WOW_PROJECT_ID = 1, WOW_PROJECT_MAINLINE = 1 },
        id = "unsupported",
        reason = "does not declare a supported client",
    },
    {
        name = "metadata API that raises an error",
        environment = {
            GetAddOnMetadata = function()
                error("metadata unavailable")
            end,
        },
        id = "unsupported",
        reason = "does not declare a supported client",
    },
}

local caseIndex
for caseIndex = 1, #DETECTION_CASES do
    local case = DETECTION_CASES[caseIndex]
    test.test("client profile classifies " .. case.name, function()
        local profile = detect(case.environment)

        test.assertEqual(case.id, profile.id)
        test.assertEqual(case.id ~= "unsupported", profile.supported)
        if case.label ~= nil then
            test.assertEqual(case.label, profile.label)
        else
            test.assertEqual("Unsupported client", profile.label)
            test.assertContains(profile.reason, case.reason)
        end
    end)
end

test.test("core modules never inspect the client", function()
    local files = {
        "Core/Identity.lua",
        "Core/Persistence.lua",
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/RosterViewModel.lua",
        "Core/RosterController.lua",
        "Core/LibraryCheck.lua",
        "Core/CommandRouter.lua",
        "Core/Lifecycle.lua",
    }
    local forbidden = { "ClientProfile", "X-Client", "WOW_PROJECT", "clientProfile" }
    local index, termIndex
    for index = 1, #files do
        local handle = assert(io.open(files[index], "r"))
        local source = handle:read("*a")
        handle:close()
        for termIndex = 1, #forbidden do
            test.assertEqual(
                nil,
                string.find(source, forbidden[termIndex], 1, true),
                files[index] .. " mentions " .. forbidden[termIndex]
            )
        end
    end
end)
