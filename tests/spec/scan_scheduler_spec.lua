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
local FOREVER_GUILD = { name = "Knights of Camelot", realm = "Camelot" }

-- A scheduler over a fixture guild (Retail's, or options.profile's).
-- Finished scans are collected in `setup.finished`.
local function build(options)
    options = options or {}
    local profile = options.profile or "Retail"
    local guild = profile == "Forever" and FOREVER_GUILD or GUILD
    local rules = { twoPartNames = profile == "Forever", homeRealm = guild.realm }
    local world = fixtures.newEnvironment(profile, options.world)
    local addon = test.newAddon(unpack(MODULES))
    local client = addon.Compatibility.Create(world.environment)
    local database = options.database or { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)
    local normalizer = addon.NameNormalizer.Create(rules)
    local setup = { addon = addon, database = database, finished = {}, world = world, normalizer = normalizer }
    setup.scheduler = addon.ScanScheduler.Create({
        client = client,
        rules = rules,
        context = function()
            return guild, store:Partition(guild), normalizer
        end,
        onFinished = function(result, summary)
            table.insert(setup.finished, summary)
        end,
    })
    function setup.partition()
        return store:Partition(guild)
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

test.test("every login runs a full scan, so a rank changed while away shows at once", function()
    local setup = build()
    setup.login()
    -- Next session (a /reload), a minute later; meanwhile an officer
    -- promoted someone.
    local later = build({ database = setup.database })
    later.world.time = setup.world.time + 60
    later.world.guild.members[3].rank = 1

    later.login()

    test.assertEqual(1, #later.finished)
    test.assertEqual("full", later.finished[1].mode)
    local key = later.normalizer:Key(later.world.guild.members[3].name)
    test.assertEqual(1, later.partition():GetCharacter(key).rank)
end)

test.test("a roster update with a known character's new rank records it", function()
    local setup = build()
    setup.login()
    local key = setup.normalizer:Key(setup.world.guild.members[3].name)
    test.assertTrue(setup.partition():GetCharacter(key).rank ~= 1)
    -- Promoted in the game's own guild window.
    setup.world.guild.members[3].rank = 1

    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 2)

    test.assertEqual(2, #setup.finished)
    test.assertEqual("incremental", setup.finished[2].mode)
    test.assertEqual(1, setup.partition():GetCharacter(key).rank)

    -- Nothing else changed: the next update is a quiet check.
    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 2)
    test.assertEqual(2, #setup.finished)
end)

-- Counts the reconcile plans `setup` builds from now on.
local function countPlans(setup)
    local counted = { plans = 0 }
    local plan = setup.addon.ReconcileEngine.Plan
    setup.addon.ReconcileEngine.Plan = function(inputs)
        counted.plans = counted.plans + 1
        return plan(inputs)
    end
    return counted
end

local function update(setup)
    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 2)
end

test.test("an incremental check of an unchanged roster isn't planned at all", function()
    local setup = build()
    setup.login()
    local counted = countPlans(setup)

    update(setup)
    update(setup)

    test.assertEqual(0, counted.plans)
    test.assertEqual(1, #setup.finished)
end)

test.test("an incremental check still picks up a note, rank or level change, a newcomer and a departure", function()
    local members = nil
    local changes = {
        function(guild)
            guild.members[2].note = "Tank >Toolbox"
        end,
        function(guild)
            guild.members[3].rank = 2
        end,
        function(guild)
            guild.members[3].level = 81
        end,
        function(guild)
            table.insert(guild.members, { name = "Newbie-Area52", class = "ROGUE", level = 10, rank = 4,
                rankName = "Initiate", online = true, zone = "Dornogal" })
        end,
        function(guild)
            table.remove(guild.members, 3)
        end,
    }
    local index
    for index = 1, #changes do
        local setup = build()
        setup.login()
        update(setup)
        local counted = countPlans(setup)
        members = setup.world.guild.members

        changes[index](setup.world.guild)
        update(setup)

        test.assertEqual(1, counted.plans, "change " .. index .. " is planned")
    end
    test.assertTrue(members ~= nil)
end)

test.test("an incremental check is planned again once the store changed what a scan depends on", function()
    local setup = build()
    setup.login()
    local counted = countPlans(setup)
    local hammer = setup.normalizer:Key(setup.world.guild.members[2].name)

    -- A guild sync edit marks a note to be read again.
    setup.partition():ForgetNoteFingerprint(hammer)
    update(setup)

    test.assertEqual(1, counted.plans)
    update(setup)
    test.assertEqual(1, counted.plans, "then quiet again")
end)

test.test("full scans and manual rescans are never skipped", function()
    local setup = build()
    setup.login()
    local counted = countPlans(setup)

    test.assertTrue(setup.scheduler:RequestFull(true))
    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, setup.addon.ScanScheduler.REFRESH_WAIT_SECONDS)

    test.assertEqual(1, counted.plans)
    test.assertEqual(2, #setup.finished)
    test.assertEqual("full", setup.finished[2].mode)
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
    -- One coalesced check, beside the periodic roster refresh.
    local soon = 0
    local index
    for index = 1, #setup.world.timers do
        if setup.world.timers[index].at <= setup.world.time + setup.addon.ScanScheduler.COALESCE_SECONDS then
            soon = soon + 1
        end
    end
    test.assertEqual(1, soon)
    fixtures.runTimers(setup.world, 2)

    test.assertEqual(2, #setup.finished)
end)

local function registerNoteTests(profile)
    test.test(profile .. " roster updates with nothing changed finish quietly", function()
        local setup = build({ profile = profile })
        setup.login()

        setup.scheduler:OnRosterUpdate()
        fixtures.runTimers(setup.world, 2)

        test.assertEqual(1, #setup.finished)
        test.assertEqual(0, setup.finished[1].notesChanged)
    end)

    test.test(profile .. " a changed note on a known character is picked up by the next roster update", function()
        local setup = build({ profile = profile })
        setup.login()
        local members = setup.world.guild.members
        local officer = setup.normalizer:Key(members[1].name)
        local third = setup.normalizer:Key(members[3].name)
        local partition = setup.partition()
        test.assertTrue(partition:GetCharacter(third).player ~= partition:GetCharacter(officer).player)
        local lastFullScan = partition:GetLastScan()
        -- An officer edits two notes while this member is online.
        members[3].note = ">" .. members[1].name
        members[1].note = "@Tools"

        setup.scheduler:OnRosterUpdate()
        fixtures.runTimers(setup.world, 2)

        test.assertEqual(2, #setup.finished)
        test.assertEqual("incremental", setup.finished[2].mode)
        test.assertEqual(2, setup.finished[2].notesChanged)
        partition = setup.partition()
        test.assertEqual(partition:GetCharacter(officer).player, partition:GetCharacter(third).player)
        test.assertEqual("Tools", partition:GetPlayer(partition:GetCharacter(officer).player).alias)
        test.assertEqual(lastFullScan, partition:GetLastScan())

        -- Read once: the next update is a quiet check again.
        setup.scheduler:OnRosterUpdate()
        fixtures.runTimers(setup.world, 2)
        test.assertEqual(2, #setup.finished)
    end)

    test.test(profile .. " an online session asks for a fresh roster every few minutes", function()
        local setup = build({ profile = profile })
        setup.login()
        local requests = setup.world.rosterRequests
        local interval = setup.addon.ScanScheduler.ROSTER_REFRESH_SECONDS

        fixtures.runTimers(setup.world, interval - 1)
        test.assertEqual(requests, setup.world.rosterRequests)
        fixtures.runTimers(setup.world, 1)
        test.assertEqual(requests + 1, setup.world.rosterRequests)
        fixtures.runTimers(setup.world, interval)
        test.assertEqual(requests + 2, setup.world.rosterRequests)

        -- The update that follows picks up a changed note.
        setup.world.guild.members[3].note = ">" .. setup.world.guild.members[1].name
        setup.scheduler:OnRosterUpdate()
        fixtures.runTimers(setup.world, 2)
        test.assertEqual(1, setup.finished[#setup.finished].notesChanged)
    end)
end

local profileIndex
for profileIndex = 1, #fixtures.PROFILES do
    registerNoteTests(fixtures.PROFILES[profileIndex])
end

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

test.test("a roster read that a roster update interrupts is never treated as complete", function()
    local setup = build()
    setup.login()
    local partition = setup.partition()
    -- Mid-read, Visitor leaves and Newbie joins: same count, no repeats.
    -- The client fires a roster update for the change.
    local environment = setup.world.environment
    local getInfo = environment.GetGuildRosterInfo
    -- Only the first read after this point is mixed; later reads are stable.
    local reads = 0
    environment.GetGuildRosterInfo = function(index)
        if index == 1 then
            reads = reads + 1
        end
        if reads == 1 and index == 2 then
            setup.scheduler:OnRosterUpdate()
        end
        if reads == 1 and index == 3 then
            return "Newbie-Area52", "Initiate", 4, 1, "Rogue", "", "", "", true, 0, "ROGUE"
        end
        return getInfo(index)
    end

    setup.scheduler:RequestFull(true)
    -- The requested refresh never arrives, so the read starts after its
    -- 3-second wait; the retry is due 2 seconds after that.
    fixtures.runTimers(setup.world, 3)

    -- The mixed read was thrown away: nobody is marked departed.
    test.assertEqual(1, #setup.finished)
    test.assertTrue(partition:IsInGuild("visitor-stormrage"), "nobody is marked departed from a mixed read")

    -- With no further roster update, the scan still reads again and finishes.
    fixtures.runTimers(setup.world, 5)
    test.assertEqual(2, #setup.finished)
    test.assertFalse(setup.scheduler:IsRunning())
end)

test.test("a roster read while the guild changes is never saved to the old guild", function()
    local setup = build()
    setup.login()
    local partition = setup.partition()
    -- The roster now belongs to another guild with the same member count.
    local environment = setup.world.environment
    local getInfo = environment.GetGuildRosterInfo
    environment.GetGuildRosterInfo = function(index)
        GUILD.name = "Other Guild"
        return getInfo(index)
    end

    setup.scheduler:RequestFull(true)
    fixtures.runTimers(setup.world, 5)
    GUILD.name = "Knights of Camelot"

    test.assertEqual(1, #setup.finished)
    test.assertTrue(partition:IsInGuild("toolbox-area52"))
end)

test.test("roster updates before guild information is available wait without errors", function()
    local setup = build()
    local partition = setup.partition
    -- The real context returns nil and a message while the guild is unknown.
    setup.scheduler.context = function()
        return nil, "Guild information isn't available yet. Try again in a moment."
    end
    setup.scheduler:OnSavedDataReady()

    local ok, problem = pcall(setup.scheduler.OnRosterUpdate, setup.scheduler)
    fixtures.runTimers(setup.world)

    test.assertTrue(ok, tostring(problem))
    test.assertEqual(0, #setup.finished)
    -- Once the guild is known, the daily check still runs.
    setup.scheduler.context = function()
        return GUILD, partition(), setup.normalizer
    end
    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world)
    test.assertEqual(1, #setup.finished)
end)

test.test("nothing scans before saved data is ready", function()
    local setup = build()

    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world, 5)

    test.assertEqual(0, #setup.finished)
end)
