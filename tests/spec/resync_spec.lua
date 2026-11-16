local test = require("tests.test_helper")

local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local NOW = 1790000000
local OFFICER, MEMBER, ZOLL, ZOLL_ALT, TIKIT = "toolbox-area52", "hammer-area52", "zoll-area52",
    "zollalt-area52", "tikit-area52"
local NAMES = {
    [OFFICER] = "Toolbox", [MEMBER] = "Hammer", [ZOLL] = "Zoll", [ZOLL_ALT] = "Zollalt", [TIKIT] = "Tikit",
}

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua",
        "Core/Resync.lua"
    )
end

-- One add-on logged in as `self`, over its own copy of the guild. Whispers
-- land in `client.whispers` ({ message, to, options }), lines for the user
-- in `client.printed`, and timers in `client.timers`. `world` is shared:
-- who's an officer and who's online, and the clock.
local function newClient(addon, world, self)
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    local key
    for key in pairs(NAMES) do
        partition:RecordCharacter(key, { name = NAMES[key], level = 60 })
    end
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = "Area52" })
    local client = { partition = partition, whispers = {}, printed = {}, applied = 0, timers = {} }
    client.resync = addon.Resync.Create({
        context = function()
            return partition, normalizer
        end,
        selfKey = function()
            return self
        end,
        isOfficer = function(character)
            return world.officers[character] == true
        end,
        isOwn = function(character)
            return character == self
        end,
        online = function()
            local names = {}
            local character
            for character in pairs(world.online) do
                names[character] = NAMES[character]
            end
            return names
        end,
        now = function()
            return world.time
        end,
        after = function(seconds, callback)
            table.insert(client.timers, { at = world.time + seconds, callback = callback })
            return true
        end,
        whisper = function(message, name, options)
            table.insert(client.whispers, { message = message, to = name, options = options or {} })
            return true
        end,
        print = function(text)
            table.insert(client.printed, text)
        end,
        onApplied = function()
            client.applied = client.applied + 1
        end,
    })
    return client
end

local function newWorld()
    local addon = load()
    local world = {
        time = NOW,
        officers = { [OFFICER] = true },
        online = { [OFFICER] = true, [MEMBER] = true },
    }
    world.officer = newClient(addon, world, OFFICER)
    world.member = newClient(addon, world, MEMBER)
    -- The officer holds the right roster: Zollalt is Zoll's alt, and Zoll
    -- goes by "Zoll". The member wrongly holds Zollalt as Tikit's alt, with
    -- Zoll's alias on Tikit.
    local officer = world.officer.partition
    officer:JoinPlayerOf(ZOLL_ALT, ZOLL, "sync")
    officer:SetMainStamp(ZOLL_ALT, NOW - 100, OFFICER)
    officer:SetAlias(officer:GetCharacter(ZOLL).player, "Zoll", "sync")
    officer:SetAliasStamp(ZOLL, NOW - 100, OFFICER)
    local member = world.member.partition
    member:JoinPlayerOf(ZOLL_ALT, TIKIT, "sync")
    member:SetMainStamp(ZOLL_ALT, NOW, OFFICER)
    member:SetAlias(member:GetCharacter(TIKIT).player, "Zoll", "sync")
    member:SetAliasStamp(TIKIT, NOW, OFFICER)
    return world, addon
end

local function mainOf(partition, key)
    return partition:GetPlayer(partition:GetCharacter(key).player).main
end

local function aliasOf(partition, key)
    return partition:GetPlayer(partition:GetCharacter(key).player).alias
end

-- `client`'s whispers of type `kind`, in order.
local function whispersOf(client, kind)
    local found = {}
    local index
    for index = 1, #client.whispers do
        if client.whispers[index].message.t == kind then
            table.insert(found, client.whispers[index])
        end
    end
    return found
end

-- Lets `seconds` pass for `client`, running its timers due by then.
local function wait(world, client, seconds)
    world.time = world.time + seconds
    local index = 1
    while index <= #client.timers do
        if client.timers[index].at <= world.time then
            table.remove(client.timers, index).callback()
        else
            index = index + 1
        end
    end
end

local function lastPrinted(client)
    return client.printed[#client.printed]
end

test.test("resync: a member copies an online officer's roster over theirs, seeing its progress", function()
    local world = newWorld()

    local ok, line = world.member.resync:Ask("Toolbox")

    test.assertTrue(ok)
    test.assertContains(line, "Asked Toolbox")
    local ask = whispersOf(world.member, "resync-ask")[1]
    test.assertEqual("Toolbox", ask.to)
    test.assertEqual("ALERT", ask.options.priority)

    test.assertTrue(world.officer.resync:OnMessage(ask.message, "Hammer"))
    -- The officer is told to stay online; a status goes first, ahead of
    -- the roster itself.
    test.assertContains(lastPrinted(world.officer), "stay online")
    local statuses = whispersOf(world.officer, "resync-status")
    test.assertEqual(0, statuses[1].message.p)
    test.assertEqual("ALERT", statuses[1].options.priority)
    local data = whispersOf(world.officer, "resync-data")[1]
    test.assertEqual("Hammer", data.to)
    test.assertEqual("NORMAL", data.options.priority)

    test.assertTrue(world.member.resync:OnMessage(statuses[1].message, "Toolbox"))
    test.assertContains(lastPrinted(world.member), "Toolbox is sending")
    -- The game reports each piece sent: progress every 20%.
    data.options.onProgress(250, 1000)
    data.options.onProgress(450, 1000)
    statuses = whispersOf(world.officer, "resync-status")
    test.assertEqual(3, #statuses)
    test.assertEqual(25, statuses[2].message.p)
    test.assertEqual(45, statuses[3].message.p)
    world.time = NOW + 45
    world.member.resync:OnMessage(statuses[3].message, "Toolbox")
    test.assertContains(lastPrinted(world.member), "45%")
    test.assertContains(lastPrinted(world.member), "under a minute left")
    data.options.onProgress(1000, 1000)
    test.assertContains(lastPrinted(world.officer), "Finished sending your roster data to Hammer")

    local changed = world.member.resync:OnMessage(data.message, "Toolbox")

    test.assertTrue(changed > 0)
    test.assertEqual(1, world.member.applied)
    test.assertEqual(ZOLL, mainOf(world.member.partition, ZOLL_ALT))
    test.assertEqual("Zoll", aliasOf(world.member.partition, ZOLL))
    test.assertEqual(nil, aliasOf(world.member.partition, TIKIT))
    test.assertContains(lastPrinted(world.member), "Resynced from Toolbox")
    -- Nothing is left waiting to time out.
    wait(world, world.member, 200)
    test.assertContains(lastPrinted(world.member), "Resynced from Toolbox")
end)

test.test("resync: the officer can be named by their player's alias", function()
    local world = newWorld()
    local member = world.member.partition
    member:SetAlias(member:GetCharacter(OFFICER).player, "The Tool", "sync")

    test.assertTrue(world.member.resync:Ask("the tool"))
    test.assertEqual("Toolbox", world.member.whispers[1].to)
end)

test.test("resync: only an online officer other than the user can be asked, one at a time", function()
    local world = newWorld()
    world.online[ZOLL] = true
    world.online[TIKIT] = nil

    local ok, line = world.member.resync:Ask("Nobody")
    test.assertEqual(nil, ok)
    test.assertContains(line, "Nobody in the guild")
    ok, line = world.member.resync:Ask("Tikit")
    test.assertEqual(nil, ok)
    test.assertContains(line, "isn't online")
    ok, line = world.member.resync:Ask("Zoll")
    test.assertEqual(nil, ok)
    test.assertContains(line, "isn't an officer")
    ok, line = world.member.resync:Ask("")
    test.assertEqual(nil, ok)
    test.assertContains(line, "/agf resync")
    ok, line = world.officer.resync:Ask("Toolbox")
    test.assertEqual(nil, ok)
    test.assertContains(line, "That's you")
    test.assertEqual(0, #world.member.whispers)

    test.assertTrue(world.member.resync:Ask("Toolbox"))
    ok, line = world.member.resync:Ask("Toolbox")
    test.assertEqual(nil, ok)
    test.assertContains(line, "Already resyncing")
end)

test.test("resync: a member's add-on never answers, and an officer answers each guildmate once a minute", function()
    local world = newWorld()
    world.member.resync:Ask("Toolbox")
    local ask = world.member.whispers[1].message

    test.assertFalse(world.member.resync:OnMessage(ask, "Tikit"))
    test.assertTrue(world.officer.resync:OnMessage(ask, "Hammer"))
    test.assertFalse(world.officer.resync:OnMessage(ask, "Hammer"))
    world.time = NOW + 60
    test.assertTrue(world.officer.resync:OnMessage(ask, "Hammer"))
    -- From outside the guild: no answer.
    test.assertFalse(world.officer.resync:OnMessage(ask, "Stranger-Stormrage"))
end)

test.test("resync: it gives up when the officer's add-on doesn't answer", function()
    local world = newWorld()
    world.member.resync:Ask("Toolbox")

    wait(world, world.member, 29)
    test.assertEqual(0, #world.member.printed)
    wait(world, world.member, 1)

    test.assertContains(lastPrinted(world.member), "didn't answer")
    -- And can be asked again.
    test.assertTrue(world.member.resync:Ask("Toolbox"))
end)

test.test("resync: it gives up when progress stops, e.g. the officer logged off", function()
    local world = newWorld()
    world.member.resync:Ask("Toolbox")
    world.officer.resync:OnMessage(world.member.whispers[1].message, "Hammer")
    local data = whispersOf(world.officer, "resync-data")[1]
    world.member.resync:OnMessage(whispersOf(world.officer, "resync-status")[1].message, "Toolbox")

    -- Progress keeps it waiting past the first 30 seconds.
    wait(world, world.member, 60)
    test.assertContains(lastPrinted(world.member), "is sending")
    world.member.resync:OnMessage({ v = 1, t = "resync-status", p = 40 }, "Toolbox")
    wait(world, world.member, 89)
    test.assertContains(lastPrinted(world.member), "40%")
    wait(world, world.member, 1)

    test.assertContains(lastPrinted(world.member), "Lost contact with Toolbox")
    -- A late answer is ignored.
    test.assertEqual(nil, world.member.resync:OnMessage(data.message, "Toolbox"))
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))
end)

test.test("resync: only the answer asked for, from a current officer, is applied", function()
    local world = newWorld()
    world.officers[TIKIT] = true
    world.member.resync:Ask("Toolbox")
    world.officer.resync:OnMessage(world.member.whispers[1].message, "Hammer")
    local data = whispersOf(world.officer, "resync-data")[1].message

    -- Unasked, or from someone else.
    test.assertEqual(nil, world.officer.resync:OnMessage(data, "Hammer"))
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Tikit"))
    test.assertFalse(world.member.resync:OnMessage({ v = 1, t = "resync-status", p = 50 }, "Tikit"))
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))

    -- Demoted meanwhile.
    world.officers[OFFICER] = nil
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Toolbox"))
    test.assertContains(lastPrinted(world.member), "no longer an officer")
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))
    -- Asked once, answered once.
    world.officers[OFFICER] = true
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Toolbox"))
end)

test.test("resync: an unreadable answer changes nothing", function()
    local world = newWorld()
    world.member.resync:Ask("Toolbox")

    test.assertEqual(nil, world.member.resync:OnMessage({ v = 1, t = "resync-data", s = "junk" }, "Toolbox"))

    test.assertContains(lastPrinted(world.member), "couldn't be read")
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))
end)

test.test("resync: an officer is found even when a roster gone wrong holds them with the user", function()
    local world = newWorld()
    local member = world.member.partition
    member:JoinPlayerOf(OFFICER, MEMBER, "sync")

    test.assertTrue(world.member.resync:Ask("Toolbox"))
    test.assertEqual("Toolbox", world.member.whispers[1].to)
end)

-- A rough size of `value` as AceSerializer writes it: a marker per value,
-- numbers and strings as text, and every table key written out.
local function serializedSize(value)
    if type(value) == "table" then
        local size = 4
        local key, item
        for key, item in pairs(value) do
            size = size + serializedSize(key) + serializedSize(item)
        end
        return size
    end
    return 2 + #tostring(value)
end

test.test("resync: the packed roster unpacks to the same snapshot, at under half the size", function()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    -- 300 characters: 100 players with two alts each, every fourth with
    -- an alias, a few with Discord, and some characters who left.
    local index
    for index = 1, 300 do
        partition:RecordCharacter("member" .. index .. "-area52", { name = "Member" .. index, level = 60 })
    end
    for index = 1, 100 do
        local main = "member" .. index .. "-area52"
        partition:JoinPlayerOf("member" .. (100 + index) .. "-area52", main, "note")
        partition:JoinPlayerOf("member" .. (200 + index) .. "-area52", main, "sync")
        partition:SetMainStamp("member" .. (200 + index) .. "-area52", NOW + index, OFFICER)
        if index % 4 == 0 then
            partition:SetAlias(partition:GetCharacter(main).player, "Alias" .. index, "sync")
            partition:SetAliasStamp(main, NOW + index, OFFICER)
        end
        if index % 10 == 0 then
            partition:SetProfileText(main, "discord", "member" .. index, NOW + index, main)
        end
    end
    partition:GetCharacter("member300-area52").departed = NOW
    local facts = addon.SyncFacts.Create(partition)
    local snapshot = facts:ResyncSnapshot()

    local packed = addon.Resync.Pack(snapshot, "-area52")
    local unpacked = addon.Resync.Unpack(packed)

    local function lines(list)
        local out = {}
        local _, entry
        for _, entry in ipairs(list) do
            local parts = {}
            local field
            for field = 1, 5 do
                table.insert(parts, tostring(entry[field]))
            end
            table.insert(out, table.concat(parts, "|"))
        end
        table.sort(out)
        return table.concat(out, "\n")
    end
    test.assertEqual(299, #snapshot.l)
    test.assertEqual(lines(snapshot.l), lines(unpacked.l))
    test.assertEqual(lines(snapshot.d), lines(unpacked.d))
    test.assertEqual(lines(snapshot.p), lines(unpacked.p))
    -- Aliases name the main they're set through when it's the main.
    local aliases = {}
    local _, entry
    for _, entry in ipairs(snapshot.a) do
        if entry[5] == "" then
            entry = { entry[1], entry[2], entry[3], entry[4], entry[1] }
        end
        table.insert(aliases, entry)
    end
    test.assertEqual(lines(aliases), lines(unpacked.a))
    test.assertTrue(serializedSize(packed) * 2 < serializedSize({ s = snapshot }))
end)

test.test("resync: unpacking junk gives nothing, or leaves the junk out", function()
    local addon = load()
    test.assertEqual(nil, addon.Resync.Unpack("junk"))
    test.assertEqual(nil, addon.Resync.Unpack({ g = {}, a = "" }))
    local snapshot = addon.Resync.Unpack({ x = "-area52", z = NOW, a = OFFICER, g = ",:5:1;zollalt,zoll;;zollalt:x",
        s = { "nobody", "X", 0, 0, "" }, d = "zoll:maybe,,zoll", p = { "zoll", 99, "x", 1, 1 } })
    -- A group without a readable main is left out, alts and all.
    test.assertEqual(2, #snapshot.l)
    test.assertEqual(ZOLL, snapshot.l[1][1])
    -- A time that isn't a number counts as none.
    test.assertEqual(ZOLL_ALT, snapshot.l[2][1])
    test.assertEqual(ZOLL, snapshot.l[2][2])
    test.assertEqual(0, snapshot.l[2][3])
    test.assertEqual(0, #snapshot.d)
    test.assertEqual(0, #snapshot.p)
end)
