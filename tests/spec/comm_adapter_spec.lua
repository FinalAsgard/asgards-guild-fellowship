local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- The comm adapter never raises, and does nothing when it can't work.
local function build(options)
    local world = fixtures.newEnvironment("Retail", options)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua", "Adapters/Comm.lua")
    local client = addon.Compatibility.Create(world.environment)
    return world, addon.Comm.Create(client, "AGFSync")
end

test.test("without the comm libraries, sync stays off quietly", function()
    local world, comm = build({ missingLibraries = { "AceComm-3.0" } })

    test.assertFalse(comm:Start(function() end))
    test.assertFalse(comm:Broadcast({ v = 1 }))
    test.assertEqual(0, #world.sentMessages)
end)

test.test("only guild messages that deserialize to a table are passed on", function()
    local world, comm = build()
    local received = {}
    test.assertTrue(comm:Start(function(message, sender)
        table.insert(received, { message = message, sender = sender })
    end))
    local handler = world.commHandlers.AGFSync
    local serializer = world.environment.LibStub:GetLibrary("AceSerializer-3.0")

    handler("AGFSync", serializer:Serialize({ v = 1 }), "WHISPER", "Hammer-Area52")
    handler("AGFSync", "garbage", "GUILD", "Hammer-Area52")
    handler("AGFSync", serializer:Serialize("text"), "GUILD", "Hammer-Area52")
    handler("AGFSync", serializer:Serialize({ v = 1 }), "GUILD", "Hammer-Area52")

    test.assertEqual(1, #received)
    test.assertEqual(1, received[1].message.v)
    test.assertEqual("Hammer-Area52", received[1].sender)
end)

test.test("a receiver that raises doesn't break the channel", function()
    local world, comm = build()
    comm:Start(function()
        error("receiver failed")
    end)
    local serializer = world.environment.LibStub:GetLibrary("AceSerializer-3.0")

    world.commHandlers.AGFSync("AGFSync", serializer:Serialize({ v = 1 }), "GUILD", "Hammer-Area52")
end)

test.test("rank permissions come from the rank flags, or nil when the client can't say", function()
    local world, comm = build()

    test.assertTrue(comm:RankCanViewOfficerNotes(1))
    test.assertFalse(comm:RankCanViewOfficerNotes(3))
    test.assertEqual(nil, comm:RankCanViewOfficerNotes(nil))

    world.environment.C_GuildInfo.GuildControlGetRankFlags = function()
        error("not allowed")
    end
    test.assertEqual(nil, comm:RankCanViewOfficerNotes(1))
    world.environment.C_GuildInfo.GuildControlGetRankFlags = nil
    test.assertEqual(nil, comm:RankCanViewOfficerNotes(1))
end)
