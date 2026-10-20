local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Membership dates: when each character joined, and since when it has held
-- its rank.
local NOW = 1790000000
local HOUR, DAY = 3600, 86400
local OFFICER = "toolbox-area52"
local OTHER_OFFICER = "gm-area52"
local MEMBER = "hammer-area52"

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua",
        "Core/GuildLog.lua",
        "Core/MembershipDates.lua"
    )
end

local OFFICERS = { [OFFICER] = true, [OTHER_OFFICER] = true }

local function isOfficer(key)
    return OFFICERS[key] == true
end

local function newDates(saved)
    local addon = load()
    saved = saved or {}
    return addon.MembershipDates.Create(saved, { isOfficer = isOfficer }), addon.MembershipDates, saved
end

-- A log entry, as GuildLog keeps them.
local function logged(kind, character, at, extra)
    local entry = { type = kind, character = character, at = at, tolerance = 2 * HOUR, source = "log" }
    local key, value
    for key, value in pairs(extra or {}) do
        entry[key] = value
    end
    return entry
end

-- Join -------------------------------------------------------------------------

test.test("a join comes from the log when known, else from when the add-on first saw the character", function()
    local dates, MembershipDates = newDates()
    dates:ObserveScan({ bolt = 3 }, NOW - 10 * DAY)
    dates:ObserveScan({ bolt = 3, nail = 4 }, NOW - 5 * DAY)

    test.assertEqual("first-seen", dates:Joined("nail").source)
    test.assertEqual(NOW - 5 * DAY, dates:Joined("nail").time)
    test.assertEqual("2026-01-01 (approx.)", MembershipDates.Describe(dates:Joined("nail"), function()
        return "2026-01-01"
    end))

    local facts = dates:FromLog({ logged("join", "nail", NOW - 8 * DAY) }, OFFICER, NOW)
    test.assertEqual(1, #facts)
    test.assertEqual("log", dates:Joined("nail").source)
    test.assertEqual(NOW - 8 * DAY, dates:Joined("nail").time)
    test.assertEqual(OFFICER, facts[1].by)
    -- Seeing the character again changes nothing.
    dates:ObserveScan({ bolt = 3, nail = 4 }, NOW)
    test.assertEqual("log", dates:Joined("nail").source)
end)

test.test("among records of one join, officer-set beats log, log beats live, live beats first-seen", function()
    local _, MembershipDates = newDates()
    local function replaces(heldSource, newSource, heldTime, newTime)
        return MembershipDates.Replaces("joined", { time = heldTime or NOW, source = heldSource },
            { time = newTime or NOW, source = newSource, at = NOW, by = OFFICER })
    end

    test.assertTrue(replaces("first-seen", "live", NOW, NOW - DAY))
    test.assertTrue(replaces("live", "log", NOW, NOW - HOUR))
    test.assertFalse(replaces("log", "live", NOW, NOW - HOUR))
    test.assertTrue(replaces("log", "officer", NOW, NOW - 3 * DAY))
    test.assertFalse(replaces("officer", "log", NOW, NOW - HOUR))
    test.assertFalse(replaces("live", "first-seen", NOW, NOW + HOUR))
    -- Two reads of one join settle on the earlier.
    test.assertTrue(replaces("log", "log", NOW, NOW - HOUR))
    test.assertFalse(replaces("log", "log", NOW - HOUR, NOW))
end)

test.test("a rejoin restarts the join, whether logged or seen by a roster scan", function()
    local dates = newDates()
    dates:ObserveScan({ bolt = 3 }, NOW - 100 * DAY)
    dates:FromLog({ logged("join", "nail", NOW - 60 * DAY) }, OFFICER, NOW - 60 * DAY)
    dates:SetByOfficer("bolt", "joined", NOW - 400 * DAY, nil, OFFICER, NOW - 50 * DAY)

    -- Nail rejoins: logged.
    dates:FromLog({ logged("join", "nail", NOW - 2 * DAY) }, OFFICER, NOW)
    test.assertEqual(NOW - 2 * DAY, dates:Joined("nail").time)
    -- Bolt leaves and comes back while nobody logged it: a scan finds it
    -- gone, then back.
    dates:ObserveScan({ nail = 4 }, NOW - DAY)
    dates:ObserveScan({ nail = 4, bolt = 4 }, NOW)
    test.assertEqual(NOW, dates:Joined("bolt").time)
    test.assertEqual("first-seen", dates:Joined("bolt").source)
end)

-- Before tracking ----------------------------------------------------------------

test.test("the first scan sets the tracking mark and marks everyone present before tracking", function()
    local dates, MembershipDates = newDates()

    test.assertTrue(dates:ObserveScan({ bolt = 3, nail = 4 }, NOW - 10 * DAY))
    test.assertFalse(dates:ObserveScan({ bolt = 3, nail = 4, rivet = 4 }, NOW))

    test.assertEqual(NOW - 10 * DAY, dates:TrackingStart())
    test.assertEqual("before-tracking", dates:Joined("bolt").source)
    test.assertEqual("before-tracking", dates:RankSince("bolt", 3).source)
    test.assertEqual("before tracking", MembershipDates.Describe(dates:Joined("bolt"), tostring))
    test.assertEqual("first-seen", dates:Joined("rivet").source)

    -- A logged join replaces the mark, even an old one.
    dates:FromLog({ logged("join", "bolt", NOW - 300 * DAY) }, OFFICER, NOW)
    test.assertEqual("log", dates:Joined("bolt").source)
    -- A before-tracking mark never replaces a known date.
    test.assertFalse(MembershipDates.Replaces("joined", { time = NOW, source = "first-seen" },
        { time = NOW - DAY, source = "before-tracking" }))

    -- The officer shares the mark they set; the earliest mark wins.
    local fact = dates:StampTracking(OFFICER, NOW)
    test.assertEqual("tracking", fact.kind)
    test.assertEqual(NOW - 10 * DAY, fact.time)
    test.assertTrue(dates:Wins({ kind = "tracking", character = OTHER_OFFICER, time = NOW - 20 * DAY, at = NOW,
        by = OTHER_OFFICER }))
    test.assertFalse(dates:Wins({ kind = "tracking", character = OTHER_OFFICER, time = NOW - 5 * DAY, at = NOW,
        by = OTHER_OFFICER }))
end)

-- Rank since -----------------------------------------------------------------------

test.test("rank-since comes from logged promotions and demotions, or from a scan that sees the rank change", function()
    local dates = newDates()
    dates:ObserveScan({ bolt = 4 }, NOW - 30 * DAY)

    -- A scan sees Bolt promoted to rank 3.
    dates:ObserveScan({ bolt = 3 }, NOW - 5 * DAY)
    test.assertEqual("seen", dates:RankSince("bolt", 3).source)
    test.assertEqual(NOW - 5 * DAY, dates:RankSince("bolt", 3).time)
    test.assertEqual(nil, dates:RankSince("bolt", 4))

    -- The log says when it really happened.
    dates:FromLog({ logged("promote", "bolt", NOW - 6 * DAY, { toRank = 3, actor = "boss" }) }, OFFICER, NOW)
    test.assertEqual("log", dates:RankSince("bolt", 3).source)
    test.assertEqual(NOW - 6 * DAY, dates:RankSince("bolt", 3).time)
    -- An older change to another rank doesn't replace it.
    dates:FromLog({ logged("promote", "bolt", NOW - 20 * DAY, { toRank = 4 }) }, OFFICER, NOW)
    test.assertEqual(3, dates:RankSince("bolt").rank)
    -- A newer demotion does.
    dates:FromLog({ logged("demote", "bolt", NOW - DAY, { toRank = 4 }) }, OFFICER, NOW)
    test.assertEqual(NOW - DAY, dates:RankSince("bolt", 4).time)
end)

-- Set by hand ----------------------------------------------------------------------

test.test("officers can set join and rank-since dates by hand; others can't", function()
    local dates = newDates()
    dates:FromLog({ logged("join", "bolt", NOW - 3 * DAY) }, OFFICER, NOW - DAY)

    local fact, reason = dates:SetByOfficer("bolt", "joined", NOW - 2 * DAY, nil, MEMBER, NOW)
    test.assertEqual(nil, fact)
    test.assertEqual("only officers can set dates", reason)

    fact = dates:SetByOfficer("bolt", "joined", NOW - 5 * DAY, nil, OFFICER, NOW)
    test.assertEqual("officer", fact.source)
    test.assertEqual(NOW - 5 * DAY, dates:Joined("bolt").time)
    fact = dates:SetByOfficer("bolt", "rankSince", NOW - 4 * DAY, 3, OTHER_OFFICER, NOW)
    test.assertEqual(3, fact.rank)
    test.assertEqual(NOW - 4 * DAY, dates:RankSince("bolt", 3).time)
    test.assertEqual(nil, (dates:SetByOfficer("bolt", "joined", NOW + DAY, nil, OFFICER, NOW)))
    -- A later read of the same join leaves the officer's date alone.
    dates:FromLog({ logged("join", "bolt", NOW - 3 * DAY) }, OFFICER, NOW)
    test.assertEqual("officer", dates:Joined("bolt").source)
end)

-- Earliest join ----------------------------------------------------------------------

test.test("the player's earliest current join is the earliest of its characters, before tracking first", function()
    local dates = newDates()
    dates:ObserveScan({ main = 1 }, NOW - 100 * DAY)
    dates:ObserveScan({ main = 1, alt = 4, alt2 = 4 }, NOW - 3 * DAY)
    dates:FromLog({ logged("join", "alt2", NOW - 50 * DAY) }, OFFICER, NOW)

    local earliest = dates:EarliestJoin({ "alt", "alt2" })
    test.assertEqual(NOW - 50 * DAY, earliest.time)
    test.assertFalse(earliest.approximate)
    test.assertTrue(dates:EarliestJoin({ "alt", "main" }).beforeTracking)
    test.assertTrue(dates:EarliestJoin({ "alt" }).approximate)
    test.assertEqual(nil, dates:EarliestJoin({ "nobody" }))
end)

test.test("dates typed by hand are read as midnight UTC", function()
    local _, MembershipDates = newDates()

    test.assertEqual(0, MembershipDates.ParseDate("1970-01-01"))
    test.assertEqual(951782400, MembershipDates.ParseDate("2000-02-29"))
    test.assertEqual(nil, MembershipDates.ParseDate("2001-02-29"))
    test.assertEqual(nil, MembershipDates.ParseDate("yesterday"))
end)

-- Guild sync -------------------------------------------------------------------------

local function newSync(characters)
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} })
        :Partition({ name = "Knights of Camelot", realm = "Area 52" })
    local index
    for index = 1, #characters do
        partition:RecordCharacter(characters[index], { name = characters[index], level = 60, rank = 3 })
    end
    local facts = addon.SyncFacts.Create(partition, {
        isOfficer = isOfficer,
        now = function()
            return NOW
        end,
    })
    return facts, partition, addon
end

local function dateFact(kind, character, time, source, by, at, rank)
    return { kind = kind, character = character, time = time, source = source, rank = rank, at = at or NOW,
        by = by or OFFICER }
end

test.test("dates travel as officer facts: only officers' are accepted, and the better date wins", function()
    local facts, partition = newSync({ OFFICER, MEMBER, "bolt-area52" })

    test.assertEqual("not an officer", facts:Refusal(dateFact("joined", "bolt-area52", NOW - DAY, "log", MEMBER)))
    test.assertEqual(1, facts:ApplyAll({ dateFact("joined", "bolt-area52", NOW - DAY, "live") }))
    test.assertEqual("live", facts:Dates():Joined("bolt-area52").source)
    -- A worse record of the same join is refused, a better one applied.
    test.assertEqual("not newer", facts:Refusal(dateFact("joined", "bolt-area52", NOW - DAY + HOUR, "first-seen",
        OTHER_OFFICER, NOW + 1)))
    test.assertEqual(1, facts:ApplyAll({ dateFact("joined", "bolt-area52", NOW - DAY - 600, "log", OTHER_OFFICER) }))
    test.assertEqual("log", facts:Dates():Joined("bolt-area52").source)
    test.assertEqual("unknown character", facts:Refusal(dateFact("joined", "gone-area52", NOW, "log")))
    test.assertEqual("from the future", facts:Refusal(dateFact("joined", "bolt-area52", NOW + DAY, "officer")))
    test.assertEqual("malformed", facts:Refusal(dateFact("rankSince", "bolt-area52", NOW, "log")))
    test.assertEqual(1, facts:ApplyAll({ dateFact("rankSince", "bolt-area52", NOW - DAY, "log", OFFICER, NOW, 3) }))

    -- What this add-on passes on: the officers' stamped dates.
    local shared = facts:OfficerFacts()
    local kinds = {}
    local index
    for index = 1, #shared do
        kinds[shared[index].kind] = (kinds[shared[index].kind] or 0) + 1
    end
    test.assertEqual(1, kinds.joined)
    test.assertEqual(1, kinds.rankSince)
    test.assertTrue(partition.data.membershipDates ~= nil)
end)

-- In the composed add-on -------------------------------------------------------------

local NAMES = {
    Forever = { "Tool Box", "Hammer Smith" },
    Retail = { "Toolbox-Area52", "Hammer-Area52" },
}

local function guild(profile)
    local names = NAMES[profile]
    return {
        name = "Knights of Camelot",
        realm = profile == "Retail" and "Area 52" or "Camelot",
        members = {
            { name = names[1], class = "WARRIOR", level = 60, rank = 1, rankName = "Officer", online = true,
                zone = "Ironforge" },
            { name = names[2], class = "MAGE", level = 42, rank = 3, rankName = "Member", online = true,
                zone = "Ironforge" },
        },
    }
end

local function login(profile, channel, playerName)
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = playerName })
    world.time = channel.time or world.time
    channel.time = world.time
    fixtures.joinChannel(channel, world)
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

-- Delivers messages and runs every world's timers until both settle.
local function settle(channel)
    local round
    for round = 1, 5 do
        fixtures.deliver(channel)
        local index
        for index = 1, #channel.worlds do
            fixtures.runTimers(channel.worlds[index])
        end
    end
end

local function datesIn(world)
    local _, partition = world.addon.rosterController:QuietContext()
    return world.addon.MembershipDates.Create(partition:GetMembershipDates())
end

local function keyOf(world, name)
    local _, _, normalizer = world.addon.rosterController:QuietContext()
    return normalizer:Key(name)
end

for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]
    local names = NAMES[profile]

    test.test(profile .. " an officer's logged join and hand-set dates reach a member's add-on", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel)
        local hammerKey = keyOf(tool, names[2])
        test.assertEqual("before-tracking", datesIn(hammer):Joined(hammerKey).source)
        test.assertTrue(datesIn(hammer):TrackingStart() ~= nil)

        -- The officer's add-on sees Hammer leave and rejoin.
        fixtures.fire(tool, "CHAT_MSG_SYSTEM", (profile == "Retail" and "Hammer" or "Hammer Smith") ..
            " has left the guild.")
        tool.time = tool.time + 600
        hammer.time = tool.time
        fixtures.fire(tool, "CHAT_MSG_SYSTEM", (profile == "Retail" and "Hammer" or "Hammer Smith") ..
            " has joined the guild.")
        settle(channel)
        test.assertEqual("live", datesIn(hammer):Joined(hammerKey).source)
        test.assertEqual(tool.time, datesIn(hammer):Joined(hammerKey).time)

        fixtures.slash(tool, "setdate rank " .. names[2] .. " 2026-01-15")
        settle(channel)
        local since = datesIn(hammer):RankSince(hammerKey, 3)
        test.assertEqual("officer", since.source)
        test.assertEqual(1768435200, since.time)

        -- A member can't set dates.
        hammer.messages = {}
        fixtures.slash(hammer, "setdate join " .. names[1] .. " 2026-01-15")
        test.assertContains(table.concat(hammer.messages, "\n"), "Only officers can set dates.")
    end)

    test.test(profile .. " the officer's player panel shows join dates, time at rank, and earliest join", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel)

        local lines = tool.addon.rosterController.membership({ keyOf(tool, names[2]) })
        test.assertEqual("Earliest join: before tracking", lines[1])
        test.assertContains(lines[2], "joined before tracking, at this rank since before tracking")
        test.assertEqual(nil, hammer.addon.rosterController.membership({ keyOf(hammer, names[2]) }))
    end)
end
