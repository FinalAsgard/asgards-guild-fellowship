local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local MODULES = {
    "Adapters/ClientProfile.lua",
    "Adapters/WoW.lua",
    "Core/NameNormalizer.lua",
    "Core/NoteParser.lua",
    "Core/FellowshipStore.lua",
    "Core/ReconcileEngine.lua",
    "Core/ScanScheduler.lua",
}

local GUILD = { name = "Knights of Camelot", realm = "Area 52" }

-- A scheduler over the Retail fixture guild. Finished scans are collected
-- in `setup.finished`.
local function build(options)
    options = options or {}
    local world = fixtures.newEnvironment("Retail", options.world)
    local addon = test.newAddon(unpack(MODULES))
    local client = addon.Compatibility.Create(world.environment)
    local database = options.database or { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = GUILD.realm })
    local setup = { addon = addon, database = database, finished = {}, world = world }
    setup.scheduler = addon.ScanScheduler.Create({
        client = client,
        rules = { twoPartNames = false },
        context = function()
            return GUILD, store:Partition(GUILD), normalizer
        end,
        onFinished = function(result, summary)
            table.insert(setup.finished, summary)
        end,
    })
    function setup.partition()
        return store:Partition(GUILD)
    end
    function setup.login()
        setup.scheduler:OnSavedDataReady()
        setup.scheduler:OnRosterUpdate()
        fixtures.runTimers(world)
    end
    return setup
end

test.test("a full scan runs at login when the guild was never scanned", function()
    local setup = build()

    setup.login()

    test.assertEqual(1, #setup.finished)
    test.assertEqual("initial", setup.finished[1].mode)
    test.assertEqual(3, setup.finished[1].newCharacters)
    test.assertEqual(setup.world.time, setup.partition():GetLastScan())
end)

test.test("the daily scan is skipped when the last full scan is under 24 hours old", function()
    local setup = build()
    setup.login()
    -- Next session, 23 hours later.
    local later = build({ database = setup.database })
    later.world.time = setup.world.time + 23 * 3600

    later.login()

    test.assertEqual(0, #later.finished)
end)

test.test("the daily scan runs again once the last full scan is over 24 hours old", function()
    local setup = build()
    setup.login()
    local later = build({ database = setup.database })
    later.world.time = setup.world.time + 24 * 3600 + 1

    later.login()

    test.assertEqual(1, #later.finished)
    test.assertEqual("full", later.finished[1].mode)
    test.assertEqual(later.world.time, later.partition():GetLastScan())
end)

test.test("roster updates pick up unseen characters incrementally", function()
    local setup = build()
    setup.login()
    local lastFullScan = setup.partition():GetLastScan()
    setup.world.guild.members[4] = { name = "Newcomer", class = "ROGUE", level = 1, rank = 4,
        rankName = "Initiate", online = true, note = ">Toolbox" }

    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 2)

    test.assertEqual(2, #setup.finished)
    test.assertEqual("incremental", setup.finished[2].mode)
    test.assertEqual(1, setup.finished[2].newCharacters)
    -- A newcomer's note seeds it like any other character.
    local partition = setup.partition()
    test.assertEqual(partition:GetCharacter("toolbox-area52").player, partition:GetCharacter("newcomer-area52").player)
    -- Incremental pickups are not full scans.
    test.assertEqual(lastFullScan, partition:GetLastScan())
end)

test.test("a burst of roster updates is coalesced into one check", function()
    local setup = build()
    setup.login()
    setup.world.guild.members[4] = { name = "Newcomer", class = "ROGUE", level = 1, rank = 4,
        rankName = "Initiate", online = true }

    local burst
    for burst = 1, 10 do
        setup.scheduler:OnRosterUpdate()
    end
    test.assertEqual(1, #setup.world.timers)
    fixtures.runTimers(setup.world, 2)

    test.assertEqual(2, #setup.finished)
end)

test.test("roster updates with nobody new finish quietly", function()
    local setup = build()
    setup.login()

    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 2)

    test.assertEqual(1, #setup.finished)
end)

test.test("a manual scan requests a roster refresh and reprocesses every note", function()
    local setup = build()
    setup.login()
    local parses = 0
    local parse = setup.addon.NoteParser.Parse
    setup.addon.NoteParser.Parse = function(...)
        parses = parses + 1
        return parse(...)
    end
    local requests = setup.world.rosterRequests

    test.assertTrue(setup.scheduler:RequestFull(true))
    test.assertEqual(requests + 1, setup.world.rosterRequests)
    setup.scheduler:OnRosterUpdate()

    test.assertEqual(2, #setup.finished)
    test.assertEqual("full", setup.finished[2].mode)
    test.assertEqual(3, parses)
end)

test.test("a scan already running is not started twice", function()
    local setup = build()
    setup.login()

    test.assertTrue(setup.scheduler:RequestFull(true))
    local started, reason = setup.scheduler:RequestFull(true)

    test.assertFalse(started)
    test.assertEqual("running", reason)
end)

test.test("an empty or partial roster is never treated as complete", function()
    local setup = build({ world = { rosterReady = false } })

    setup.login()
    test.assertEqual(0, #setup.finished)
    test.assertEqual(nil, setup.partition():GetLastScan())

    -- Partial: the count is known but one member hasn't loaded.
    setup.world.rosterReady = true
    local environment = setup.world.environment
    local getInfo = environment.GetGuildRosterInfo
    environment.GetGuildRosterInfo = function(index)
        if index == 2 then
            return nil
        end
        return getInfo(index)
    end
    setup.scheduler:OnRosterUpdate()
    test.assertEqual(0, #setup.finished)
    test.assertEqual(nil, setup.partition():GetCharacter("toolbox-area52"))

    environment.GetGuildRosterInfo = getInfo
    setup.scheduler:OnRosterUpdate()
    test.assertEqual(1, #setup.finished)
end)

test.test("a roster re-sorted while it was read is never treated as complete", function()
    local setup = build()
    setup.login()
    test.assertEqual(1, #setup.finished)
    -- The roster re-sorts mid-read: index 2 repeats the member at index 1,
    -- so the member really at index 2 is never read.
    local environment = setup.world.environment
    local getInfo = environment.GetGuildRosterInfo
    environment.GetGuildRosterInfo = function(index)
        if index == 2 then
            return getInfo(1)
        end
        return getInfo(index)
    end

    setup.scheduler:RequestFull(true)
    fixtures.runTimers(setup.world, 5)

    local partition = setup.partition()
    for _, key in ipairs({ "toolbox-area52", "hammer-area52", "visitor-stormrage" }) do
        test.assertTrue(partition:IsInGuild(key), key .. " stays in the guild")
    end
end)

test.test("nothing scans before saved data is ready", function()
    local setup = build()

    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 5)

    test.assertEqual(0, #setup.finished)
end)
