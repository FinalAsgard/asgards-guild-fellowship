local test = require("tests.test_helper")

-- Catching up at login: digests, one reply per announcement, and the
-- announcer's follow-up. Each client has its own fake clock, profiler clock
-- and timers, and can be put in combat (`client.busy`); a fake guild
-- channel copies messages the way serializing them would. Setting
-- `client.msPerRead` makes every profiler-clock read cost that much, to
-- stand in for work.
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
        "Core/SyncLedger.lua",
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
        precise = 0,
        busy = false,
        randomCalls = {},
        forgeries = {},
        applied = {},
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
        onForgery = function(count, relayedBy)
            table.insert(client.forgeries, { count = count, relayedBy = relayedBy })
        end,
        onApplied = function(count)
            table.insert(client.applied, count)
        end,
        onSynced = function()
            client.synced = (client.synced or 0) + 1
        end,
        busy = function()
            return client.busy
        end,
        preciseMs = function()
            client.precise = client.precise + (client.msPerRead or 0)
            return client.precise
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

-- The officer's client, holding officerData() as facts they wrote.
local function newOfficer(network)
    local officer = newClient(network, "Toolbox-Area52")
    give(network, officer, officerData())
    network.addon.SyncLedger.Create(officer.partition):Record(officerData(), NOW)
    return officer
end

test.test("an online officer answers before any member, so data is checked against the officer's", function()
    local network = newNetwork()
    local newcomer = newClient(network, "Anvil-Area52")
    local member = newClient(network, "Hammer-Area52")
    local officer = newOfficer(network)
    give(network, member, officerData())

    newcomer.session:Announce()
    deliver(network)
    test.assertEqual(1, officer.randomCalls[1][1])
    test.assertEqual(2, officer.randomCalls[1][2])
    test.assertEqual(3, member.randomCalls[1][1])
    test.assertEqual(5, member.randomCalls[1][2])
    advance(officer, 2)
    deliver(network)
    advance(member, 5)
    deliver(network)

    test.assertEqual(1, #officer.sent)
    test.assertEqual(0, #member.sent, "the member hears the officer and stays silent")
    test.assertEqual(OFFICER, mainOf(newcomer, "alt1-area52"))
end)

test.test("a member's answer doesn't silence an online officer, but another officer's would", function()
    local network = newNetwork()
    local newcomer = newClient(network, "Anvil-Area52")
    local member = newClient(network, "Hammer-Area52")
    local officer = newOfficer(network)
    give(network, member, officerData())
    member.randomValue = 1
    officer.randomValue = 2

    newcomer.session:Announce()
    deliver(network)
    advance(member, 1)
    deliver(network)
    advance(officer, 2)
    deliver(network)

    test.assertEqual(1, #member.sent)
    local officerReplies = 0
    local index
    for index = 1, #officer.sent do
        officerReplies = officerReplies + (officer.sent[index].re == "anvil-area52" and 1 or 0)
    end
    test.assertEqual(1, officerReplies, "the officer still checks the newcomer's data")
end)

test.test("an officer catches an edit relayed in their name that they never made, and corrects it", function()
    local network = newNetwork()
    local officer = newOfficer(network)
    local member = newClient(network, "Wrench-Area52")
    local forger = newClient(network, "Hammer-Area52")
    give(network, member, officerData())

    forger.session:Send({ t = "facts", facts = {
        { kind = "main", character = "alt2-area52", main = "anvil-area52", at = NOW + 30, by = OFFICER },
        { kind = "alias", character = OFFICER, alias = "Fake", at = NOW + 30, by = OFFICER },
        link("alt3-area52"),
    } })
    deliver(network)
    -- Until the correction arrives, a member can't tell it's forged.
    test.assertEqual(OFFICER, mainOf(officer, "alt2-area52"), "the officer never applies it")
    test.assertEqual(nil, officer.partition:GetPlayer(officer.partition:GetCharacter(OFFICER).player).alias)

    test.assertEqual(1, #officer.forgeries)
    test.assertEqual(2, officer.forgeries[1].count)
    test.assertEqual("Hammer-Area52", officer.forgeries[1].relayedBy)
    local log = network.addon.SyncLedger.Create(officer.partition):Forgeries()
    test.assertEqual(2, #log)
    test.assertEqual("hammer-area52", log[1].relayedBy)
    test.assertEqual("alt2-area52", log[1].character)
    local correction = officer.sent[#officer.sent]
    test.assertEqual("facts", correction.t)
    test.assertEqual(2, #correction.facts)
    test.assertTrue(correction.facts[1].at > NOW + 30, "stamped newer than the forgery")

    test.assertEqual(OFFICER, mainOf(member, "alt2-area52"))
    test.assertEqual(nil, member.partition:GetPlayer(member.partition:GetCharacter(OFFICER).player).alias)
    -- The officer's own correction isn't mistaken for a forgery later.
    forger.session:Send({ t = "facts", facts = correction.facts })
    deliver(network)
    test.assertEqual(1, #officer.forgeries)
end)

test.test("an edit in an officer's name dated far ahead is refused, and its date never reaches a correction", function()
    local network = newNetwork()
    local officer = newOfficer(network)
    local member = newClient(network, "Wrench-Area52")
    local forger = newClient(network, "Hammer-Area52")
    give(network, member, officerData())
    local sentBefore = #officer.sent
    local farAhead = NOW + network.addon.SyncFacts.MAX_FUTURE_SECONDS + 86400

    forger.session:Send({ t = "facts", facts = {
        { kind = "main", character = "alt2-area52", main = "anvil-area52", at = farAhead, by = OFFICER },
    } })
    deliver(network)

    test.assertEqual(0, #officer.forgeries)
    test.assertEqual(sentBefore, #officer.sent, "no correction stamped from the forged date")
    test.assertEqual(OFFICER, mainOf(officer, "alt2-area52"))
    test.assertEqual(OFFICER, mainOf(member, "alt2-area52"))
end)

test.test("the officer's own edits, and approvals, are in their ledger, so relays of them are trusted", function()
    local network = newNetwork()
    local officer = newOfficer(network)
    local member = newClient(network, "Wrench-Area52")
    officer.time = NOW + 100
    officer.partition:JoinPlayerOf("alt5-area52", "hammer-area52", "manual")
    local edits = officer.session:LocalEdit({ ["alt5-area52"] = true })

    member.session:Send({ t = "facts", facts = edits })
    deliver(network)

    test.assertEqual(0, #officer.forgeries)
    test.assertEqual("hammer-area52", mainOf(officer, "alt5-area52"))
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
    -- The bystander's own reply would come later, so it never goes out (a
    -- member waits 3 to 5 seconds).
    bystander.randomValue = 5
    advance(replier, 3)
    deliver(network)
    advance(bystander, 5)

    test.assertEqual(OFFICER, mainOf(bystander, "alt" .. ALTS .. "-area52"))
    test.assertEqual(0, #bystander.sent)
end)

test.test("in combat nothing is worked on or sent, and it all goes on in order afterwards", function()
    local network = newNetwork()
    local announcer = newClient(network, "Hammer-Area52")
    local replier = newClient(network, "Wrench-Area52")
    give(network, replier, officerData())
    replier.busy = true

    announcer.session:Announce()
    deliver(network)
    advance(replier, 30)
    test.assertEqual(0, #replier.randomCalls, "the announcement waits")
    test.assertEqual(0, #replier.sent)

    replier.busy = false
    advance(replier, network.addon.SyncSession.PAUSE_SECONDS)
    test.assertEqual(1, #replier.randomCalls)
    replier.busy = true
    advance(replier, 5)
    test.assertEqual(0, #replier.sent, "the reply waits too")
    replier.busy = false
    advance(replier, network.addon.SyncSession.PAUSE_SECONDS)
    deliver(network)

    test.assertEqual(1, #replier.sent)
    test.assertEqual(OFFICER, mainOf(announcer, "alt" .. ALTS .. "-area52"))
end)

test.test("an announcement and an officer's edit made in combat go out, in order, once it ends", function()
    local network = newNetwork()
    local officer = newOfficer(network)
    officer.busy = true

    officer.session:Announce()
    test.assertEqual(1, #officer.session:LocalEdit({ ["alt1-area52"] = true }))
    advance(officer, 30)
    test.assertEqual(0, #officer.sent)

    officer.busy = false
    advance(officer, network.addon.SyncSession.PAUSE_SECONDS)
    test.assertEqual(2, #officer.sent)
    test.assertEqual("digest", officer.sent[1].t)
    test.assertEqual("facts", officer.sent[2].t)
end)

test.test("a large batch of facts is applied a frame's budget at a time, and the roster is told once", function()
    local network = newNetwork()
    local client = newClient(network, "Hammer-Area52")
    client.msPerRead = 1

    client.session:Receive({ v = 1, t = "facts", facts = officerData() }, "Toolbox-Area52")
    test.assertEqual(0, #client.applied, "not all at once")
    local frames = 1
    while client.timers[1] ~= nil do
        test.assertEqual(0, client.timers[1].seconds, "the next frame")
        table.remove(client.timers, 1).callback()
        frames = frames + 1
    end

    test.assertTrue(frames > 5, "applied over " .. frames .. " frames")
    test.assertEqual(1, #client.applied)
    test.assertEqual(ALTS, client.applied[1])
    test.assertEqual(OFFICER, mainOf(client, "alt1-area52"))
    test.assertEqual(OFFICER, mainOf(client, "alt" .. ALTS .. "-area52"))
end)

test.test("comparing or receiving another user's data counts as a sync, and a suggestion doesn't", function()
    local network = newNetwork()
    local announcer = newClient(network, "Hammer-Area52")
    local other = newClient(network, "Wrench-Area52")
    give(network, announcer, officerData())
    give(network, other, officerData())
    test.assertEqual(nil, other.partition:GetLastSync())

    other.time = NOW + 100
    announcer.session:Announce()
    deliver(network)
    test.assertEqual(NOW + 100, other.partition:GetLastSync(), "the digests matched")
    test.assertEqual(1, other.synced)
    test.assertEqual(nil, announcer.partition:GetLastSync(), "silence proves nothing")

    announcer.time = NOW + 200
    announcer.session:Receive({ v = 1, t = "facts", facts = { link("alt1-area52") } }, "Toolbox-Area52")
    test.assertEqual(NOW + 200, announcer.partition:GetLastSync(), "facts arrived, even ones it held")
    announcer.time = NOW + 300
    announcer.session:Receive({ v = 1, t = "suggest", facts = { link("alt1-area52") } }, "Wrench-Area52")
    announcer.session:Receive({ v = 1, t = "digest", digest = "everything" }, "Wrench-Area52")
    test.assertEqual(NOW + 200, announcer.partition:GetLastSync())
end)

test.test("the status says whether sync started and is paused, and counts a member's pending suggestions", function()
    local network = newNetwork()
    local member = newClient(network, "Hammer-Area52")
    local officer = newOfficer(network)

    local status = member.session:Status()
    test.assertFalse(status.on)
    test.assertFalse(status.paused)
    test.assertEqual(nil, status.lastSync)
    test.assertEqual(0, status.pending)

    member.session:Start()
    member.busy = true
    member.partition:MarkSynced(NOW)
    member.session:LocalEdit({ ["alt1-area52"] = true })
    status = member.session:Status()
    test.assertTrue(status.on)
    test.assertTrue(status.paused)
    test.assertEqual(NOW, status.lastSync)
    test.assertEqual(1, status.pending)

    test.assertEqual(nil, officer.session:Status().pending)
end)

test.test("malformed announcements and replies are ignored without errors", function()
    local network = newNetwork()
    local client = newClient(network, "Wrench-Area52")
    give(network, client, officerData())

    client.session:Receive({ v = 1, t = "digest", digest = "everything" }, "Hammer-Area52")
    client.session:Receive({ v = 1, t = "digest", digest = { 1, 2 } }, "Hammer-Area52")
    client.session:Receive({ v = 1, t = "facts", re = client.key, buckets = "all", facts = {} }, "Hammer-Area52")
    client.session:Receive({ v = 1, t = "facts", re = client.key, buckets = { 1 }, facts = "x" }, "Hammer-Area52")
    client.session:Receive({ v = 2, t = "digest" }, "Hammer-Area52")

    test.assertEqual(0, #client.timers)
    test.assertEqual(0, #client.sent)
    test.assertEqual(0, #client.applied)
end)
