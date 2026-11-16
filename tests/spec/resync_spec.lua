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
-- land in `client.whispers`, lines for the user in `client.printed`.
-- `world` is shared: who's an officer and who's online, and the clock.
local function newClient(addon, world, self)
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    local key
    for key in pairs(NAMES) do
        partition:RecordCharacter(key, { name = NAMES[key], level = 60 })
    end
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = "Area52" })
    local client = { partition = partition, whispers = {}, printed = {}, applied = 0 }
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
        whisper = function(message, name)
            table.insert(client.whispers, { message = message, to = name })
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

-- Delivers `from`'s latest whisper to `to`, as sent by `sender`.
local function deliver(from, to, sender)
    local whisper = from.whispers[#from.whispers]
    return to.resync:OnMessage(whisper.message, sender)
end

test.test("resync: a member copies an online officer's roster over theirs", function()
    local world = newWorld()

    local ok, line = world.member.resync:Ask("Toolbox")

    test.assertTrue(ok)
    test.assertContains(line, "Asked Toolbox")
    test.assertEqual("Toolbox", world.member.whispers[1].to)
    test.assertEqual("resync-ask", world.member.whispers[1].message.t)

    test.assertTrue(deliver(world.member, world.officer, "Hammer"))
    test.assertEqual("Hammer", world.officer.whispers[1].to)
    test.assertEqual("resync-data", world.officer.whispers[1].message.t)
    test.assertContains(world.officer.printed[1], "Hammer")

    world.time = NOW + 90
    local changed = deliver(world.officer, world.member, "Toolbox")

    test.assertTrue(changed > 0)
    test.assertEqual(1, world.member.applied)
    test.assertEqual(ZOLL, mainOf(world.member.partition, ZOLL_ALT))
    test.assertEqual("Zoll", aliasOf(world.member.partition, ZOLL))
    test.assertEqual(nil, aliasOf(world.member.partition, TIKIT))
    test.assertContains(world.member.printed[1], "Resynced from Toolbox")
end)

test.test("resync: the officer can be named by their player's alias", function()
    local world = newWorld()
    local member = world.member.partition
    member:SetAlias(member:GetCharacter(OFFICER).player, "The Tool", "sync")

    test.assertTrue(world.member.resync:Ask("the tool"))
    test.assertEqual("Toolbox", world.member.whispers[1].to)
end)

test.test("resync: only an online officer other than the user can be asked", function()
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

test.test("resync: only the answer asked for, in time, from a current officer is applied", function()
    local world = newWorld()
    world.officers[TIKIT] = true
    world.member.resync:Ask("Toolbox")
    deliver(world.member, world.officer, "Hammer")
    local data = world.officer.whispers[1].message

    -- Unasked, or from someone else.
    test.assertEqual(nil, world.officer.resync:OnMessage(data, "Hammer"))
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Tikit"))
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))

    -- Too late.
    world.time = NOW + 5 * 60 + 1
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Toolbox"))
    test.assertContains(world.member.printed[1], "too late")
    -- Asked once, answered once.
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Toolbox"))

    -- Demoted meanwhile.
    world.member.resync:Ask("Toolbox")
    world.officers[OFFICER] = nil
    test.assertEqual(nil, world.member.resync:OnMessage(data, "Toolbox"))
    test.assertContains(world.member.printed[2], "no longer an officer")
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))
end)

test.test("resync: an unreadable answer changes nothing", function()
    local world = newWorld()
    world.member.resync:Ask("Toolbox")

    test.assertEqual(nil, world.member.resync:OnMessage({ v = 1, t = "resync-data", s = "junk" }, "Toolbox"))

    test.assertContains(world.member.printed[1], "couldn't be read")
    test.assertEqual(TIKIT, mainOf(world.member.partition, ZOLL_ALT))
end)

test.test("resync: an officer is found even when a roster gone wrong holds them with the user", function()
    local world = newWorld()
    local member = world.member.partition
    member:JoinPlayerOf(OFFICER, MEMBER, "sync")

    test.assertTrue(world.member.resync:Ask("Toolbox"))
    test.assertEqual("Toolbox", world.member.whispers[1].to)
end)
