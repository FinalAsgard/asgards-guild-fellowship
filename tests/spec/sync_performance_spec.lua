local test = require("tests.test_helper")

-- Guild sync's per-frame budget in a synthetic 1,000-member guild. A fake
-- profiler clock charges a fixed cost for each character read and each
-- fact hashed, so the budget can be checked without real timing.
local MEMBERS = 1000
local READ_COST_MS = 0.01
local HASH_COST_MS = 0.02
local NOW = 1790000000
local GUILD = { name = "Big Guild", realm = "Area 52" }
local RULES = { twoPartNames = false, homeRealm = "Area52" }
local OFFICER = "member1-area52"

local function keyOf(index)
    return "member" .. index .. "-area52"
end

-- Officer data for every member: every tenth character is an alt of the one
-- before it, and every twentieth main has an alias.
local function officerData()
    local facts = {}
    local index
    for index = 1, MEMBERS do
        local main = keyOf(index)
        if index % 10 == 0 then
            main = keyOf(index - 1)
        end
        table.insert(facts, { kind = "main", character = keyOf(index), main = main, at = NOW, by = OFFICER })
    end
    for index = 1, MEMBERS, 20 do
        table.insert(facts, { kind = "alias", character = keyOf(index), alias = "Alias" .. index, at = NOW,
            by = OFFICER })
    end
    return facts
end

-- A client logged in as `name` that knows the whole guild, with the costs
-- charged to its profiler clock and every frame of sync work measured.
local function build(name)
    local addon = test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua",
        "Core/SyncDigest.lua",
        "Core/SuggestionService.lua",
        "Core/SyncLedger.lua",
        "Core/SyncSession.lua"
    )
    local client = { precise = 0, sent = {}, timers = {}, applied = {}, chunks = {} }
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    local index
    for index = 1, MEMBERS do
        partition:RecordCharacter(keyOf(index), { name = "Member" .. index .. "-Area52", level = 80 })
    end
    partition:MarkScanned(NOW)

    local getCharacter = partition.GetCharacter
    partition.GetCharacter = function(self, key)
        client.precise = client.precise + READ_COST_MS
        return getCharacter(self, key)
    end
    local bucketOf = addon.SyncDigest.BucketOf
    addon.SyncDigest.BucketOf = function(fact)
        client.precise = client.precise + HASH_COST_MS
        return bucketOf(fact)
    end

    local normalizer = addon.NameNormalizer.Create(RULES)
    local isOfficer = function(key)
        return key == OFFICER
    end
    client.addon = addon
    client.partition = partition
    client.isOfficer = isOfficer
    client.session = addon.SyncSession.Create({
        comm = {
            Broadcast = function(_, message)
                table.insert(client.sent, message)
                return true
            end,
        },
        context = function()
            return partition, normalizer
        end,
        selfKey = function()
            return name
        end,
        isOfficer = isOfficer,
        now = function()
            return NOW
        end,
        after = function(seconds, callback)
            table.insert(client.timers, callback)
            return true
        end,
        preciseMs = function()
            return client.precise
        end,
        onApplied = function(count)
            table.insert(client.applied, count)
        end,
    })
    local step = client.session.Step
    client.session.Step = function(self)
        local before = client.precise
        step(self)
        table.insert(client.chunks, client.precise - before)
    end
    return client
end

local function give(client, facts)
    client.addon.SyncFacts.Create(client.partition, { isOfficer = client.isOfficer }):ApplyAll(facts)
end

-- Runs every timer, as frames go by.
local function runFrames(client)
    while client.timers[1] ~= nil do
        table.remove(client.timers, 1)()
    end
end

-- Every frame's chunk stays within the budget, give or take one step's
-- work, which is one fact's reads and hash.
local function assertWithinBudget(client)
    local budget = client.addon.SyncSession.BUDGET_MS
    local index
    for index = 1, #client.chunks do
        test.assertTrue(client.chunks[index] <= budget + 10 * READ_COST_MS + HASH_COST_MS,
            "chunk " .. index .. " took " .. client.chunks[index] .. " ms")
    end
end

test.test("the checksum of a 1,000-member guild's data is calculated across frames within budget", function()
    local client = build("member2-area52")
    give(client, officerData())

    client.session:Announce()
    runFrames(client)

    test.assertEqual(1, #client.sent)
    test.assertEqual("digest", client.sent[1].t)
    test.assertTrue(#client.chunks > 5, "the checksum took " .. #client.chunks .. " frames")
    assertWithinBudget(client)
end)

test.test("answering a new install in a 1,000-member guild stays within budget", function()
    local client = build("member2-area52")
    give(client, officerData())
    local newcomer = build("member3-area52")
    newcomer.session:Announce()
    runFrames(newcomer)

    client.session:Receive(newcomer.sent[1], "Member3-Area52")
    runFrames(client)

    test.assertEqual(1, #client.sent)
    test.assertEqual(#officerData(), #client.sent[1].facts)
    test.assertTrue(#client.chunks > 5, "the answer took " .. #client.chunks .. " frames")
    assertWithinBudget(client)
end)

test.test("applying a full sync to a 1,000-member guild spreads across frames within budget", function()
    local client = build("member3-area52")

    client.session:Receive({ v = 1, t = "facts", facts = officerData() }, "Member1-Area52")
    runFrames(client)

    test.assertEqual(1, #client.applied, "the roster is told once")
    test.assertEqual(#officerData(), client.applied[1])
    test.assertTrue(#client.chunks > 10, "applying took " .. #client.chunks .. " frames")
    assertWithinBudget(client)
    local partition = client.partition
    test.assertEqual(keyOf(9), partition:GetPlayer(partition:GetCharacter(keyOf(10)).player).main)
    test.assertEqual("Alias21", partition:GetPlayer(partition:GetCharacter(keyOf(21)).player).alias)
end)
