local test = require("tests.test_helper")

-- Catching up at login: digests, one reply per announcement, and the
-- announcer's follow-up. Each client has its own fake clock and timers;
-- a fake guild channel copies messages the way serializing them would.
local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local RULES = { twoPartNames = false, homeRealm = "Area52" }
local NOW = 1790000000
local OFFICER = "toolbox-area52"
local ALTS = 40

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua",
        "Core/SyncDigest.lua",
        "Core/SuggestionService.lua",
        "Core/SyncSession.lua"
    )
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    local key, item
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function newNetwork()
    return { addon = load(), clients = {}, queue = {} }
end

-- A client logged in as `name`. Everyone knows the same guild: the officer,
-- three members, and ALTS alts. `options.scanned = false` leaves the roster
-- unscanned.
local function newClient(network, name, options)
    options = options or {}
    local addon = network.addon
    local normalizer = addon.NameNormalizer.Create(RULES)
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    local names = { "Toolbox-Area52", "Hammer-Area52", "Wrench-Area52", "Anvil-Area52" }
    local index
    for index = 1, ALTS do
        table.insert(names, "Alt" .. index .. "-Area52")
    end
    for index = 1, #names do
        partition:RecordCharacter(normalizer:Key(names[index]), { name = names[index], level = 80 - index })
    end
    if options.scanned ~= false then
        partition:MarkScanned(NOW)
    end

    local client = {
        name = name,
        key = normalizer:Key(name),
        partition = partition,
        sent = {},
        timers = {},
        time = NOW,
        randomCalls = {},
    }
    client.session = addon.SyncSession.Create({
        comm = {
            Broadcast = function(_, message)
                table.insert(client.sent, copy(message))
                table.insert(network.queue, { from = client, message = copy(message) })
                return true
            end,
        },
        context = function()
            return partition, normalizer
        end,
        selfKey = function()
            return client.key
        end,
        isOfficer = function(key)
            return key == OFFICER
        end,
        now = function()
            return client.time
        end,
        after = function(seconds, callback)
            table.insert(client.timers, { at = client.time + seconds, seconds = seconds, callback = callback })
            return true
        end,
        random = function(low, high)
            table.insert(client.randomCalls, { low, high })
            return client.randomValue or low
        end,
    })
    table.insert(network.clients, client)
    return client
end

-- Moves `client`'s clock forward and runs the timers that come due.
local function advance(client, seconds)
    client.time = client.time + seconds
    while true do
        local due
        local index
        for index = 1, #client.timers do
            if client.timers[index].at <= client.time then
                due = index
                break
            end
        end
        if due == nil then
            return
        end
        table.remove(client.timers, due).callback()
    end
end

local function deliver(network)
    while network.queue[1] ~= nil do
        local item = table.remove(network.queue, 1)
        local index
        for index = 1, #network.clients do
            local client = network.clients[index]
            if client ~= item.from then
                client.session:Receive(copy(item.message), item.from.name)
            end
        end
    end
end

local function link(alt, at)
    return { kind = "main", character = alt, main = OFFICER, at = at or NOW, by = OFFICER }
end

-- Every alt linked to the officer, as an officer said.
local function officerData()
    local facts = {}
    local index
    for index = 1, ALTS do
        table.insert(facts, link("alt" .. index .. "-area52"))
    end
    return facts
end

local function give(network, client, facts)
    network.addon.SyncFacts.Create(client.partition, {
        isOfficer = function(key)
            return key == OFFICER
        end,
    }):ApplyAll(copy(facts))
end

local function mainOf(client, key)
    return client.partition:GetPlayer(client.partition:GetCharacter(key).player).main
end

local function totalSent(network)
    local total = 0
    local index
    for index = 1, #network.clients do
        total = total + #network.clients[index].sent
    end
    return total
end

test.test("the announcement goes out 30 to 60 seconds after login, with a random offset", function()
    local network = newNetwork()
    local client = newClient(network, "Hammer-Area52")
    client.randomValue = 17

    client.session:Start()
    client.session:Start()

    test.assertEqual(1, #client.timers, "started once")
    test.assertEqual(47, client.timers[1].seconds)
    test.assertEqual(0, client.randomCalls[1][1])
    test.assertEqual(30, client.randomCalls[1][2])
    advance(client, 46)
    test.assertEqual(0, #client.sent)
    advance(client, 1)
    test.assertEqual(1, #client.sent)
    test.assertEqual("digest", client.sent[1].t)
    test.assertEqual(1, client.sent[1].v)
    test.assertTrue(network.addon.SyncDigest.IsValid(client.sent[1].digest))
end)

test.test("before the roster has been scanned, the announcement waits and tries again", function()
    local network = newNetwork()
    local client = newClient(network, "Hammer-Area52", { scanned = false })

    client.session:Start()
    advance(client, 60)

    test.assertEqual(0, #client.sent)
    client.partition:MarkScanned(client.time)
    advance(client, 30)
    test.assertEqual(1, #client.sent)
    test.assertEqual("digest", client.sent[1].t)
end)

test.test("two clients that already agree exchange only the announcement", function()
    local network = newNetwork()
    local announcer = newClient(network, "Hammer-Area52")
    local other = newClient(network, "Wrench-Area52")
    give(network, announcer, officerData())
    give(network, other, officerData())

    announcer.session:Announce()
    deliver(network)
    advance(other, 10)
    advance(announcer, 10)
    deliver(network)

    test.assertEqual(1, totalSent(network))
    test.assertEqual(0, #other.timers)
end)

test.test("when clients disagree, only the facts in differing buckets are sent", function()
    local network = newNetwork()
    local announcer = newClient(network, "Hammer-Area52")
    local replier = newClient(network, "Wrench-Area52")
    give(network, announcer, officerData())
    local newer = officerData()
    newer[7] = { kind = "main", character = "alt7-area52", main = "anvil-area52", at = NOW + 60, by = OFFICER }
    give(network, replier, newer)

    announcer.session:Announce()
    deliver(network)
    advance(replier, 5)
    deliver(network)

    test.assertEqual(1, #replier.sent)
    local reply = replier.sent[1]
    test.assertEqual("facts", reply.t)
    test.assertEqual(announcer.key, reply.re)
    test.assertEqual(1, #reply.buckets)
    local digests = network.addon.SyncDigest
    test.assertEqual(digests.BucketOf(newer[7]), reply.buckets[1])
    test.assertTrue(#reply.facts >= 1 and #reply.facts < ALTS, "only part of the data is sent")
    local index
    for index = 1, #reply.facts do
        test.assertEqual(reply.buckets[1], digests.BucketOf(reply.facts[index]))
    end
    test.assertEqual("anvil-area52", mainOf(announcer, "alt7-area52"))
    -- The reply had everything newer, so the announcer has nothing to add.
    test.assertEqual(1, #announcer.sent)
end)

test.test("any client can answer, and only one answer is sent per announcement", function()
    local network = newNetwork()
    local newcomer = newClient(network, "Anvil-Area52")
    local first = newClient(network, "Hammer-Area52")
    local second = newClient(network, "Wrench-Area52")
    give(network, first, officerData())
    give(network, second, officerData())
    first.randomValue = 1
    second.randomValue = 4

    newcomer.session:Announce()
    deliver(network)
    test.assertEqual(1, #first.timers)
    test.assertEqual(1, #second.timers)
    advance(first, 1)
    deliver(network)
    advance(second, 5)
    deliver(network)

    test.assertEqual(1, #first.sent)
    test.assertEqual(0, #second.sent, "the second replier stays silent")
    test.assertEqual(OFFICER, mainOf(newcomer, "alt1-area52"))
    test.assertEqual(OFFICER, mainOf(newcomer, "alt" .. ALTS .. "-area52"))
end)

test.test("the announcer sends back what the reply lacked or held older", function()
    local network = newNetwork()
    local announcer = newClient(network, "Hammer-Area52")
    local replier = newClient(network, "Wrench-Area52")
    local announcerData = officerData()
    announcerData[3] = { kind = "main", character = "alt3-area52", main = "anvil-area52", at = NOW + 60, by = OFFICER }
    give(network, announcer, announcerData)
    give(network, announcer, { { kind = "alias", character = OFFICER, alias = "The Tool", at = NOW, by = OFFICER } })
    local replierData = officerData()
    replierData[9] = { kind = "main", character = "alt9-area52", main = "hammer-area52", at = NOW + 60, by = OFFICER }
    give(network, replier, replierData)

    announcer.session:Announce()
    deliver(network)
    advance(replier, 5)
    deliver(network)

    test.assertEqual(2, #announcer.sent, "the announcement and a follow-up")
    test.assertEqual(nil, announcer.sent[2].re)
    test.assertEqual("anvil-area52", mainOf(replier, "alt3-area52"))
    test.assertEqual("The Tool", replier.partition:GetPlayer(replier.partition:GetCharacter(OFFICER).player).alias)
    test.assertEqual("hammer-area52", mainOf(announcer, "alt9-area52"))
    -- Both now hold the same data.
    local digests = network.addon.SyncDigest
    local function digestOf(client)
        return digests.Of(network.addon.SyncFacts.Create(client.partition, {
            isOfficer = function(key)
                return key == OFFICER
            end,
        }):OfficerFacts())
    end
    test.assertEqual(0, #digests.Differing(digestOf(announcer), digestOf(replier)))
end)

test.test("bystanders apply the facts they overhear", function()
    local network = newNetwork()
    local announcer = newClient(network, "Hammer-Area52")
    local replier = newClient(network, "Wrench-Area52")
    local bystander = newClient(network, "Anvil-Area52")
    give(network, replier, officerData())
    give(network, bystander, { link("alt1-area52") })

    announcer.session:Announce()
    deliver(network)
    -- The bystander's own reply would come later, so it never goes out.
    bystander.randomValue = 5
    advance(replier, 1)
    deliver(network)
    advance(bystander, 5)

    test.assertEqual(OFFICER, mainOf(bystander, "alt" .. ALTS .. "-area52"))
    test.assertEqual(0, #bystander.sent)
end)

test.test("malformed announcements and replies are ignored without errors", function()
    local network = newNetwork()
    local client = newClient(network, "Wrench-Area52")
    give(network, client, officerData())

    test.assertEqual(0, client.session:Receive({ v = 1, t = "digest", digest = "everything" }, "Hammer-Area52"))
    test.assertEqual(0, client.session:Receive({ v = 1, t = "digest", digest = { 1, 2 } }, "Hammer-Area52"))
    test.assertEqual(0, client.session:Receive({ v = 1, t = "facts", re = client.key, buckets = "all", facts = {} },
        "Hammer-Area52"))
    test.assertEqual(0, client.session:Receive({ v = 1, t = "facts", re = client.key, buckets = { 1 }, facts = "x" },
        "Hammer-Area52"))
    test.assertEqual(0, client.session:Receive({ v = 2, t = "digest" }, "Hammer-Area52"))

    test.assertEqual(0, #client.timers)
    test.assertEqual(0, #client.sent)
end)
