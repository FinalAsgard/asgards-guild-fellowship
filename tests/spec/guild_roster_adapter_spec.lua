local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function newClient(world)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(world.environment)
end

local EXPECTED = {
    Forever = { realm = "Camelot", first = "Tool Box-Camelot", twoPartNames = true },
    Retail = { realm = "Area 52", first = "Toolbox-Area52", twoPartNames = false },
}

local function registerProfileTests(profile)
    local expected = EXPECTED[profile]

    test.test(profile .. " adapter reads guild identity, roster count, and member facts", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world)

        local guild = client:GetGuildIdentity()
        test.assertEqual("Knights of Camelot", guild.name)
        test.assertEqual(expected.realm, guild.realm)
        test.assertTrue(client:IsInGuild())
        test.assertEqual(3, client:GetGuildRosterCount())

        local first = client:GetGuildMember(1)
        test.assertEqual(expected.first, first.name)
        test.assertEqual("WARRIOR", first.classToken)
        test.assertEqual(1, first.rankIndex)
        test.assertEqual("Officer", first.rankName)
        test.assertTrue(first.online)
        test.assertTrue(first.zone ~= nil)

        local offline = client:GetGuildMember(2)
        test.assertFalse(offline.online)
        test.assertEqual(nil, offline.zone)
        test.assertEqual("table", type(offline.lastOnline))
        test.assertEqual(nil, client:GetGuildMember(99))
    end)

    test.test(profile .. " adapter requests a roster refresh through the client's API", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world)

        test.assertTrue(client:RequestGuildRoster())
        test.assertEqual(1, world.rosterRequests)
    end)

    test.test(profile .. " client profile passes its name rules", function()
        local world = fixtures.newEnvironment(profile)

        test.assertEqual(expected.twoPartNames, newClient(world):GetClientProfile().nameRules.twoPartNames)
    end)

    test.test(profile .. " adapter reports a loading roster and no guild without errors", function()
        local loading = newClient(fixtures.newEnvironment(profile, { rosterReady = false }))
        test.assertEqual(0, loading:GetGuildRosterCount())
        test.assertEqual(nil, loading:GetGuildMember(1))

        local guildless = newClient(fixtures.newEnvironment(profile, { guild = false }))
        test.assertEqual(nil, guildless:GetGuildIdentity())
        test.assertFalse(guildless:IsInGuild())
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("guild roster adapter returns nil or false when the APIs are missing or raise", function()
    local function raises()
        error("client API failed")
    end
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    local clients = {
        addon.Compatibility.Create({}),
        addon.Compatibility.Create({
            GetGuildInfo = raises,
            IsInGuild = raises,
            GetNumGuildMembers = raises,
            GetGuildRosterInfo = raises,
            GuildRoster = raises,
            C_GuildInfo = { GuildRoster = raises },
            GetRealmName = raises,
            GetServerTime = raises,
            time = raises,
        }),
    }
    local clientIndex
    for clientIndex = 1, #clients do
        local client = clients[clientIndex]
        test.assertEqual(nil, client:GetGuildIdentity())
        test.assertFalse(client:IsInGuild())
        test.assertEqual(nil, client:GetGuildRosterCount())
        test.assertEqual(nil, client:GetGuildMember(1))
        test.assertFalse(client:RequestGuildRoster())
        test.assertEqual(nil, client:Timestamp())
        test.assertEqual(nil, client:GetClassColor("WARRIOR"))
        test.assertFalse(client:ObserveGuildRoster(function() end))
    end
end)

test.test("class colors come from colorStr or from r, g, b", function()
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    local client = addon.Compatibility.Create({
        RAID_CLASS_COLORS = {
            WARRIOR = { colorStr = "ffc69b6d" },
            PALADIN = { r = 1, g = 0.5, b = 0 },
        },
    })

    test.assertEqual("ffc69b6d", client:GetClassColor("WARRIOR"))
    test.assertEqual("ffff7f00", client:GetClassColor("PALADIN"))
    test.assertEqual(nil, client:GetClassColor("ROGUE"))
end)
