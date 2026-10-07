local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Performance and memory budget for a synthetic 1,000-member guild. A fake
-- profiler clock charges a fixed cost for each roster read and note parse,
-- so the per-frame time budget can be checked without real timing.
local MEMBERS = 1000
local READ_COST_MS = 0.02
local PARSE_COST_MS = 0.05

local function syntheticGuild()
    local members = {}
    local index
    for index = 1, MEMBERS do
        local note = ""
        -- Every tenth character is an alt of the one before it; every
        -- twentieth main has an alias.
        if index % 10 == 0 then
            note = "alt >Member" .. (index - 1)
        elseif index % 20 == 1 then
            note = "@Alias" .. index
        end
        members[index] = {
            name = "Member" .. index .. "-Area52",
            class = "WARRIOR",
            level = 10 + index % 60,
            rank = index % 6,
            rankName = "Rank",
            online = index % 7 == 0,
            zone = "Dornogal",
            lastOnline = { 0, 0, index % 30, 0 },
            note = note,
        }
    end
    return { name = "Big Guild", realm = "Area 52", members = members }
end

local function build(database)
    local world = fixtures.newEnvironment("Retail", { guild = syntheticGuild() })
    local addon = test.newAddon(
        "Adapters/ClientProfile.lua",
        "Adapters/WoW.lua",
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/ScanScheduler.lua"
    )
    local environment = world.environment
    local getInfo = environment.GetGuildRosterInfo
    environment.GetGuildRosterInfo = function(index)
        world.precise = world.precise + READ_COST_MS
        return getInfo(index)
    end
    local parses = 0
    local parse = addon.NoteParser.Parse
    addon.NoteParser.Parse = function(...)
        parses = parses + 1
        world.precise = world.precise + PARSE_COST_MS
        return parse(...)
    end

    local client = addon.Compatibility.Create(environment)
    local store = addon.FellowshipStore.Create(database)
    local guild = { name = "Big Guild", realm = "Area 52" }
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = guild.realm })
    local finished = {}
    local scheduler = addon.ScanScheduler.Create({
        client = client,
        rules = { twoPartNames = false },
        context = function()
            return guild, store:Partition(guild), normalizer
        end,
        onFinished = function(_, summary)
            table.insert(finished, summary)
        end,
    })

    -- Measure every frame's chunk of work.
    local chunks = {}
    local step = scheduler.Step
    scheduler.Step = function(self)
        local before = world.precise
        step(self)
        table.insert(chunks, world.precise - before)
    end

    return {
        addon = addon,
        chunks = chunks,
        finished = finished,
        parses = function()
            return parses
        end,
        partition = function()
            return store:Partition(guild)
        end,
        scheduler = scheduler,
        world = world,
    }
end

local function scan(setup)
    setup.scheduler:OnSavedDataReady()
    setup.scheduler:OnRosterUpdate()
    fixtures.runTimers(setup.world)
end

test.test("the first scan of a 1,000-member guild spreads its work across frames within budget", function()
    local setup = build({ schemaVersion = 1, guilds = {} })

    scan(setup)

    test.assertEqual(1, #setup.finished)
    test.assertEqual(MEMBERS, setup.finished[1].newCharacters)
    test.assertEqual(MEMBERS / 10, setup.finished[1].linked)
    test.assertTrue(#setup.chunks > 10, "the scan ran in " .. #setup.chunks .. " chunks")
    local budget = setup.addon.ScanScheduler.BUDGET_MS
    local index
    for index = 1, #setup.chunks do
        -- A chunk stops at the first checkpoint past its budget, so it can
        -- overrun by at most one character's step: a roster read, or its own
        -- note parse plus its main's when a chain is followed.
        test.assertTrue(setup.chunks[index] <= budget + 2 * PARSE_COST_MS + READ_COST_MS,
            "chunk " .. index .. " took " .. setup.chunks[index] .. " ms")
    end
end)

test.test("a repeat scan with unchanged notes does no per-character reconciliation work", function()
    local database = { schemaVersion = 1, guilds = {} }
    local first = build(database)
    scan(first)
    test.assertEqual(MEMBERS, first.parses())

    -- The next day's login runs a full scan over the same notes.
    local again = build(database)
    again.world.time = first.world.time + 24 * 3600 + 1
    scan(again)

    test.assertEqual(1, #again.finished)
    test.assertEqual("full", again.finished[1].mode)
    test.assertEqual(0, again.parses())
    test.assertEqual(0, again.finished[1].newCharacters)
    test.assertEqual(0, again.finished[1].linked)
end)

test.test("persisted records stay within a fixed field budget with no live fields", function()
    local database = { schemaVersion = 1, guilds = {} }
    local setup = build(database)
    scan(setup)

    local partition = database.guilds["Big Guild-Area52"]
    local characterFields = { class = true, departed = true, level = true, name = true, note = true,
        player = true, rank = true, rejected = true, source = true }
    local playerFields = { alias = true, aliasSource = true, history = true, main = true }
    local partitionFields = { characters = true, lastFullScan = true, lastScanSummary = true,
        nextPlayerId = true, players = true, quarantine = true, conflicts = true }

    local key, record, field
    for key in pairs(partition) do
        test.assertTrue(partitionFields[key], "unexpected partition field " .. tostring(key))
    end
    local characters = 0
    for key, record in pairs(partition.characters) do
        characters = characters + 1
        for field in pairs(record) do
            test.assertTrue(characterFields[field], "unexpected character field " .. tostring(field))
        end
        -- The note fingerprint is 8 hex digits, never the note.
        if record.note ~= nil then
            test.assertEqual(8, #record.note)
        end
    end
    test.assertEqual(MEMBERS, characters)
    for key, record in pairs(partition.players) do
        for field in pairs(record) do
            test.assertTrue(playerFields[field], "unexpected player field " .. tostring(field))
        end
    end
end)
