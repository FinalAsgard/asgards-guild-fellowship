local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function newClient(environment)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(environment)
end

local EXPECTED = {
    Forever = { key = "map:1455", name = "Ironforge" },
    Retail = { key = "map:2339", name = "Dornogal" },
}

local index
for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]
    local expected = EXPECTED[profile]

    test.test(profile .. " adapter reports whether the character can invite to the guild", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)

        test.assertTrue(client:CanGuildInvite())
        world.canInvite = false
        test.assertFalse(client:CanGuildInvite())
    end)

    test.test(profile .. " adapter reports the zone by map ID, with its name", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)

        local zone = client:GetZone()
        test.assertEqual(expected.key, zone.key)
        test.assertEqual(expected.name, zone.name)
    end)

    test.test(profile .. " adapter finds the zone's General channel and sends to it", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)
        world.channels = { [1] = "Trade - City", [3] = "General - " .. expected.name }

        test.assertEqual(3, client:GetGeneralChannel())
        test.assertTrue(client:SendChannelMessage("Join us!", 3))
        test.assertEqual(1, #world.chat)
        test.assertEqual("Join us!", world.chat[1].text)
        test.assertEqual("CHANNEL", world.chat[1].chatType)
        test.assertEqual(3, world.chat[1].target)

        world.channels = { [2] = "Trade - City" }
        test.assertEqual(nil, client:GetGeneralChannel())
    end)

    test.test(profile .. " adapter finds Trade where the player is in it, and nowhere else", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)

        test.assertEqual(nil, client:GetTradeChannel())
        test.assertFalse(client:IsTradeAvailable())

        world.channels = {
            [1] = "General - " .. expected.name, [2] = "Trade (Services) - City", [5] = "Trade - City",
        }
        test.assertEqual(5, client:GetTradeChannel())
        test.assertTrue(client:IsTradeAvailable())
        test.assertEqual(1, client:GetGeneralChannel())
    end)

    test.test(profile .. " adapter reports instances and battlegrounds", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)

        test.assertFalse(client:IsInInstance())
        local kinds = { "party", "raid", "pvp", "arena" }
        local kindIndex
        for kindIndex = 1, #kinds do
            world.inInstance = kinds[kindIndex]
            test.assertTrue(client:IsInInstance(), kinds[kindIndex])
        end
    end)

    test.test(profile .. " adapter reports a blocked send as failed", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)
        world.chatFails = true

        test.assertFalse(client:SendChannelMessage("Join us!", 1))
        test.assertFalse(client:SendChannelMessage("", 1))
        test.assertFalse(client:SendChannelMessage("Join us!", nil))
    end)

    test.test(profile .. " adapter reports zone changes", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)
        local changes = 0

        test.assertTrue(client:ObserveZone(function()
            changes = changes + 1
        end))
        fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")
        fixtures.fire(world, "CHANNEL_UI_UPDATE")
        test.assertEqual(3, changes)
    end)
end

test.test("Retail keystone runs count as being in an instance", function()
    local world = fixtures.newEnvironment("Retail")
    local client = newClient(world.environment)
    world.environment.IsInInstance = nil

    world.inKeystone = true
    test.assertTrue(client:IsInInstance())
    world.inKeystone = false
    test.assertFalse(client:IsInInstance())
end)

test.test("the zone key falls back to the zone's name without maps", function()
    local client = newClient({
        GetZoneText = function()
            return "Elwynn Forest"
        end,
    })

    local zone = client:GetZone()
    test.assertEqual("zone:Elwynn Forest", zone.key)
    test.assertEqual("Elwynn Forest", zone.name)
end)

test.test("the zone key climbs out of dungeon levels and micro maps to the zone", function()
    local maps = {
        [100] = { mapType = 5, parentMapID = 90 },
        [90] = { mapType = 4, parentMapID = 37 },
        [37] = { mapType = 3, parentMapID = 13 },
    }
    local client = newClient({
        GetRealZoneText = function()
            return "Elwynn Forest"
        end,
        C_Map = {
            GetBestMapForUnit = function()
                return 100
            end,
            GetMapInfo = function(mapID)
                return maps[mapID]
            end,
        },
    })

    test.assertEqual("map:37", client:GetZone().key)
end)

test.test("the General and Trade channels are found by the client's own channel names", function()
    local client = newClient({
        EnumerateServerChannels = function()
            return "Allgemein", "Handel"
        end,
        GetChannelName = function(number)
            if number == 2 then
                return 2, "Allgemein - Eisenschmiede", 0
            elseif number == 3 then
                return 3, "Handel - Stadt", 0
            end
            return 0, nil, 0
        end,
    })

    test.assertEqual(2, client:GetGeneralChannel())
    test.assertEqual(3, client:GetTradeChannel())
end)

test.test("guild recruit adapter methods return nil or false when the APIs are missing or raise", function()
    local function raises()
        error("client API failed")
    end
    local clients = {
        newClient({}),
        newClient({
            CanGuildInvite = raises,
            C_GuildInfo = { CanGuildInvite = raises },
            C_Map = { GetBestMapForUnit = raises, GetMapInfo = raises },
            GetRealZoneText = raises,
            GetZoneText = raises,
            EnumerateServerChannels = raises,
            GetChannelName = raises,
            SendChatMessage = raises,
            C_ChatInfo = { SendChatMessage = raises },
            CreateFrame = raises,
            IsInInstance = raises,
            C_ChallengeMode = { IsChallengeModeActive = raises },
        }),
    }
    local clientIndex
    for clientIndex = 1, #clients do
        local client = clients[clientIndex]
        test.assertFalse(client:CanGuildInvite())
        test.assertEqual(nil, client:GetZone())
        test.assertEqual(nil, client:GetGeneralChannel())
        test.assertEqual(nil, client:GetTradeChannel())
        test.assertFalse(client:IsTradeAvailable())
        test.assertFalse(client:SendChannelMessage("Join us!", 1))
        test.assertFalse(client:ObserveZone(function() end))
        test.assertFalse(client:IsInInstance())
    end
end)

test.test("a zone whose maps can't be read still has a key from its name", function()
    local client = newClient({
        GetRealZoneText = function()
            return "Ironforge"
        end,
        C_Map = {
            GetBestMapForUnit = function()
                error("client API failed")
            end,
        },
    })

    test.assertEqual("zone:Ironforge", client:GetZone().key)
end)
