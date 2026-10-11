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

    test.test(profile .. " adapter doesn't count Trade the client has disabled outside a city", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world.environment)
        world.channels = { [1] = "General - " .. expected.name, [2] = "Trade - City" }

        test.assertEqual(2, client:GetTradeChannel())
        -- Out in the world: still joined to Trade, but it's greyed out.
        world.disabledChannels = { [2] = true }
        test.assertEqual(nil, client:GetTradeChannel())
        test.assertFalse(client:IsTradeAvailable())
        test.assertEqual(1, client:GetGeneralChannel())

        world.disabledChannels = { [1] = true }
        test.assertEqual(nil, client:GetGeneralChannel())
        test.assertEqual(2, client:GetTradeChannel())
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
        fixtures.fire(world, "CHAT_MSG_CHANNEL_NOTICE", "SUSPENDED")
        test.assertEqual(4, changes)
    end)
end

test.test("Trade and General are found by name, whatever order the client lists its channel names in", function()
    local world = fixtures.newEnvironment("Forever")
    local client = newClient(world.environment)
    -- A client whose list of server channel names isn't General, Trade, ...
    world.environment.EnumerateServerChannels = function()
        return "LocalDefense", "General", "Trade"
    end
    -- The channels a tester had out in the world.
    world.channels = {
        [1] = "General - Ironforge", [2] = "Trade - City", [3] = "LocalDefense - Ironforge",
        [4] = "Services - City", [5] = "TradeLocal - City",
    }
    world.disabledChannels = { [2] = true, [4] = true, [5] = true }

    test.assertEqual(nil, client:GetTradeChannel())
    test.assertEqual(1, client:GetGeneralChannel())

    -- In a city, Trade is enabled.
    world.disabledChannels = { [4] = true, [5] = true }
    test.assertEqual(2, client:GetTradeChannel())
end)

test.test("a channel list without disabled flags, or one that can't be read, disables nothing", function()
    local function channelName(number)
        if number == 2 then
            return 2, "Trade - City", 0
        end
        return 0, nil, 0
    end
    local older = newClient({
        GetChannelName = channelName,
        GetChannelList = function()
            return 2, "Trade"
        end,
    })
    local failing = newClient({
        GetChannelName = channelName,
        GetChannelList = function()
            error("client API failed")
        end,
    })

    test.assertEqual(2, older:GetTradeChannel())
    test.assertEqual(2, failing:GetTradeChannel())
end)

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

test.test("a client in another language finds neither channel rather than the wrong one", function()
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

    -- Channels are never found by position in the client's list of names,
    -- whose order isn't reliable: here it would make Allgemein Trade.
    test.assertEqual(nil, client:GetGeneralChannel())
    test.assertEqual(nil, client:GetTradeChannel())
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

test.test("reordered names in another language never put an ad in the wrong channel", function()
    local client = newClient({
        EnumerateServerChannels = function()
            return "LocalDefense", "Allgemein", "Handel"
        end,
        GetChannelList = function()
            return 1, "Allgemein", false, 2, "Handel", false, 3, "LocalDefense", false
        end,
        GetChannelName = function(number)
            local names = { "Allgemein - Eisenschmiede", "Handel - Stadt", "LocalDefense - Eisenschmiede" }
            if names[number] then
                return number, names[number], 0
            end
            return 0, nil, 0
        end,
    })

    test.assertEqual(nil, client:GetGeneralChannel())
    test.assertEqual(nil, client:GetTradeChannel())
end)

test.test("a zone whose maps work but haven't placed the player yet has no key", function()
    local client = newClient({
        GetRealZoneText = function()
            return "Booty Bay"
        end,
        C_Map = {
            GetBestMapForUnit = function()
                return nil
            end,
        },
    })

    test.assertEqual(nil, client:GetZone())
end)

test.test("a channel is the zone's unless its name says it's another zone's", function()
    local names = { [1] = "General - Booty Bay", [2] = "Trade - City", [3] = "General", [4] = 42 }
    local client = newClient({
        GetChannelName = function(number)
            return names[number] ~= nil and number or 0, names[number]
        end,
    })

    test.assertTrue(client:IsChannelOfZone(1, "Booty Bay"))
    test.assertFalse(client:IsChannelOfZone(1, "Stranglethorn Vale"))
    -- No zone in the name, or no readable name: nothing is ruled out.
    test.assertTrue(client:IsChannelOfZone(3, "Booty Bay"))
    test.assertTrue(client:IsChannelOfZone(4, "Booty Bay"))
    test.assertTrue(client:IsChannelOfZone(9, "Booty Bay"))
end)
