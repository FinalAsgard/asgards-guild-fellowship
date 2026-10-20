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

test.test("whispers go to one character at BULK, and whispered messages only to the whisper receiver", function()
    local world, comm = build()
    local guild, whispered = {}, {}
    test.assertTrue(comm:Start(function(message)
        table.insert(guild, message)
    end, function(message, sender)
        table.insert(whispered, { message = message, sender = sender })
    end))
    local serializer = world.environment.LibStub:GetLibrary("AceSerializer-3.0")

    test.assertTrue(comm:Whisper({ v = 1, t = "gm-near" }, "Hammer-Area52"))
    local sent = world.sentMessages[1]
    test.assertEqual("WHISPER", sent.distribution)
    test.assertEqual("Hammer-Area52", sent.recipient)
    test.assertEqual("BULK", sent.priority)
    test.assertFalse(comm:Whisper({ v = 1 }, ""))

    world.commHandlers.AGFSync("AGFSync", serializer:Serialize({ v = 1, t = "gm-near" }), "WHISPER", "Hammer-Area52")
    test.assertEqual(0, #guild)
    test.assertEqual(1, #whispered)
    test.assertEqual("gm-near", whispered[1].message.t)
    test.assertEqual("Hammer-Area52", whispered[1].sender)
end)

test.test("officer channel messages go out at BULK, and only to the officer receiver", function()
    local world, comm = build()
    local guild, officer = {}, {}
    test.assertTrue(comm:Start(function(message)
        table.insert(guild, message)
    end, nil, function(message, sender)
        table.insert(officer, { message = message, sender = sender })
    end))
    local serializer = world.environment.LibStub:GetLibrary("AceSerializer-3.0")

    test.assertTrue(comm:SendOfficers({ v = 1, t = "logping" }))
    test.assertEqual("OFFICER", world.sentMessages[1].distribution)
    test.assertEqual("BULK", world.sentMessages[1].priority)
    test.assertFalse(comm:SendOfficers("text"))

    world.commHandlers.AGFSync("AGFSync", serializer:Serialize({ v = 1, t = "logping" }), "OFFICER", "Anvil-Area52")
    test.assertEqual(0, #guild)
    test.assertEqual(1, #officer)
    test.assertEqual("Anvil-Area52", officer[1].sender)
end)

test.test("a whisper that fails returns false without raising", function()
    local world, comm = build()
    comm:Start(function() end)
    world.whisperFails = true

    test.assertFalse(comm:Whisper({ v = 1 }, "Hammer-Area52"))
    test.assertTrue(comm:Broadcast({ v = 1 }))
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
    test.assertTrue(comm:RankHasFlag(1, 4))
    test.assertFalse(comm:RankHasFlag(3, 3))

    world.environment.C_GuildInfo.GuildControlGetRankFlags = function()
        error("not allowed")
    end
    test.assertEqual(nil, comm:RankCanViewOfficerNotes(1))
    world.environment.C_GuildInfo.GuildControlGetRankFlags = nil
    test.assertEqual(nil, comm:RankCanViewOfficerNotes(1))
end)

test.test("the player is busy in combat, and on Retail in boss encounters and keystone runs", function()
    local world, comm = build()
    test.assertFalse(comm:IsBusy())

    world.inCombat = true
    test.assertTrue(comm:IsBusy())
    world.inCombat = false
    world.inEncounter = true
    test.assertTrue(comm:IsBusy())
    world.inEncounter = false
    world.inKeystone = true
    test.assertTrue(comm:IsBusy())
    world.inKeystone = false
    test.assertFalse(comm:IsBusy())
end)

test.test("a client without encounter or keystone checks is busy only in combat, and a failing check is ignored", function()
    local world, comm = build()
    world.environment.IsEncounterInProgress = nil
    world.environment.C_ChallengeMode = nil
    world.inEncounter = true
    world.inKeystone = true
    test.assertFalse(comm:IsBusy())

    world.environment.InCombatLockdown = function()
        error("not now")
    end
    test.assertFalse(comm:IsBusy())
end)
