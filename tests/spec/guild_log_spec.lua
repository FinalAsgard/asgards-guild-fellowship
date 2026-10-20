local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- The officers' long-term guild log.
local NOW = 1790000000
local HOUR, DAY = 3600, 86400

local function load()
    return test.newAddon("Core/GuildLog.lua")
end

local function newLog(saved)
    local addon = load()
    saved = saved or {}
    return addon.GuildLog.Create(saved), addon.GuildLog, saved
end

local function age(years, months, days, hours)
    return { years = years, months = months, days = days, hours = hours }
end

-- A raw game log entry, as the WoW adapter reads it.
local function raw(kind, actor, target, rank, ageAgo)
    return { type = kind, actor = actor, target = target, rank = rank, age = ageAgo or age(0, 0, 0, 0) }
end

local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }

local function keyOf(name)
    return name and string.lower(name) or nil
end

local function rankIndexOf(name)
    local index
    for index = 1, #RANKS do
        if RANKS[index] == name then
            return index - 1
        end
    end
    return nil
end

local function fromGame(GuildLog, entries, now)
    return GuildLog.FromGameEntries(entries, now or NOW, keyOf, rankIndexOf)
end

-- Ages ------------------------------------------------------------------------

test.test("relative ages become approximate times, less certain the older they are", function()
    local _, GuildLog = newLog()

    local at, tolerance = GuildLog.AgeToTime(NOW, age(0, 0, 3, 5))
    test.assertEqual(NOW - 3 * DAY - 5 * HOUR, at)
    test.assertEqual(2 * HOUR, tolerance)

    at, tolerance = GuildLog.AgeToTime(NOW, age(1, 2, 0, 0))
    test.assertEqual(NOW - (365 + 60) * DAY, at)
    test.assertEqual(2 * HOUR + 14 * 2 * DAY, tolerance)

    test.assertEqual(NOW, (GuildLog.AgeToTime(NOW, {})))
    test.assertEqual(nil, (GuildLog.AgeToTime(nil, age(0, 0, 1, 0))))
    test.assertEqual(nil, (GuildLog.AgeToTime(NOW, nil)))
end)

-- Each event type ---------------------------------------------------------------

test.test("each game log type becomes an event with its character, actor, and ranks", function()
    local _, GuildLog = newLog()

    local events = fromGame(GuildLog, {
        raw("join", "Bolt", nil, nil, age(0, 0, 5, 0)),
        raw("invite", "Toolbox", "Bolt", nil, age(0, 0, 5, 1)),
        raw("promote", "Toolbox", "Bolt", "Veteran", age(0, 0, 2, 0)),
        raw("demote", "Boss", "Bolt", "Member", age(0, 0, 1, 0)),
        raw("remove", "Boss", "Bolt", nil, age(0, 0, 0, 3)),
        raw("quit", "Wrench", nil, nil, age(0, 0, 0, 1)),
        raw("unknown", "Wrench"),
        raw("join", nil),
    })

    test.assertEqual(6, #events)
    test.assertEqual("join", events[1].type)
    test.assertEqual("bolt", events[1].character)
    test.assertEqual(nil, events[1].actor)
    test.assertEqual(NOW - 5 * DAY, events[1].at)
    test.assertEqual("log", events[1].source)
    test.assertEqual("invite", events[2].type)
    test.assertEqual("bolt", events[2].character)
    test.assertEqual("toolbox", events[2].actor)
    test.assertEqual("promote", events[3].type)
    test.assertEqual("toolbox", events[3].actor)
    test.assertEqual(2, events[3].toRank)
    test.assertEqual(3, events[3].fromRank)
    test.assertEqual("Veteran", events[3].rankName)
    test.assertEqual("demote", events[4].type)
    test.assertEqual(3, events[4].toRank)
    test.assertEqual(2, events[4].fromRank)
    test.assertEqual("kick", events[5].type)
    test.assertEqual("bolt", events[5].character)
    test.assertEqual("boss", events[5].actor)
    test.assertEqual("leave", events[6].type)
    test.assertEqual("wrench", events[6].character)

    -- A rank name that isn't a rank now keeps the name, without indexes.
    local renamed = fromGame(GuildLog, { raw("promote", "Toolbox", "Bolt", "Old rank") })[1]
    test.assertEqual("Old rank", renamed.rankName)
    test.assertEqual(nil, renamed.toRank)
    test.assertEqual(nil, renamed.fromRank)
end)

test.test("each entry is described in words", function()
    local _, GuildLog = newLog()
    local function name(index)
        return RANKS[index + 1]
    end

    test.assertEqual("Joined", GuildLog.Describe({ type = "join" }, name))
    test.assertEqual("Invited", GuildLog.Describe({ type = "invite" }, name))
    test.assertEqual("Left", GuildLog.Describe({ type = "leave" }, name))
    test.assertEqual("Kicked", GuildLog.Describe({ type = "kick" }, name))
    test.assertEqual("Promoted to Veteran", GuildLog.Describe({ type = "promote", toRank = 2 }, name))
    test.assertEqual("Demoted to Old rank", GuildLog.Describe({ type = "demote", rankName = "Old rank" }, name))
end)

-- Recording and merging --------------------------------------------------------

test.test("events are recorded with every field and listed newest first", function()
    local log, GuildLog = newLog()

    test.assertEqual(3, log:RecordBatch(fromGame(GuildLog, {
        raw("invite", "Toolbox", "Bolt", nil, age(0, 0, 5, 0)),
        raw("promote", "Toolbox", "Bolt", "Veteran", age(0, 0, 2, 0)),
        raw("join", "Wrench", nil, nil, age(0, 0, 3, 0)),
    })))

    local entries = log:Entries()
    test.assertEqual("promote", entries[1].type)
    test.assertEqual("join", entries[2].type)
    test.assertEqual("invite", entries[3].type)
    test.assertEqual("toolbox", entries[3].actor)
    test.assertEqual(2, #log:EntriesFor("bolt"))
    test.assertEqual("promote", log:EntriesFor("bolt")[1].type)
end)

test.test("the same events read again are stored once", function()
    local log, GuildLog = newLog()
    local read = {
        raw("join", "Bolt", nil, nil, age(0, 0, 5, 3)),
        raw("promote", "Toolbox", "Bolt", "Veteran", age(0, 1, 2, 0)),
    }
    log:RecordBatch(fromGame(GuildLog, read))

    -- An hour later the ages have moved on, and the game rounds them.
    local later = {
        raw("join", "Bolt", nil, nil, age(0, 0, 5, 4)),
        raw("promote", "Toolbox", "Bolt", "Veteran", age(0, 1, 2, 1)),
    }
    test.assertEqual(0, log:RecordBatch(fromGame(GuildLog, later, NOW + HOUR + 1200)))
    -- A month later the promotion reads "2 months ago" on a 31-day month.
    test.assertEqual(0, log:RecordBatch(fromGame(GuildLog, {
        raw("promote", "Toolbox", "Bolt", "Veteran", age(0, 2, 3, 0)),
    }, NOW + 32 * DAY)))

    test.assertEqual(2, #log:Entries())
end)

test.test("an event seen live and then read from the game log is stored once, keeping the live time", function()
    local log, GuildLog = newLog()

    test.assertTrue(log:RecordLive(GuildLog.JOIN, "bolt", NOW - 1200))
    test.assertEqual(0, log:RecordBatch(fromGame(GuildLog, { raw("join", "Bolt", nil, nil, age(0, 0, 0, 0)) })))

    local entries = log:Entries()
    test.assertEqual(1, #entries)
    test.assertEqual(NOW - 1200, entries[1].at)
    test.assertEqual("live", entries[1].source)
end)

test.test("a read fills in an entry seen live, and a later live sighting keeps the earlier details", function()
    local log, GuildLog = newLog()
    log:RecordBatch(fromGame(GuildLog, { raw("invite", "Toolbox", "Bolt", nil, age(0, 0, 0, 1)) }))
    log:RecordBatch({ { type = "invite", character = "bolt", at = NOW - HOUR + 300, source = "live" } })

    local entries = log:Entries()
    test.assertEqual(1, #entries)
    test.assertEqual("toolbox", entries[1].actor)
end)

test.test("events from two officers' reads with different actors stay separate", function()
    local log, GuildLog = newLog()
    log:RecordBatch(fromGame(GuildLog, { raw("promote", "Toolbox", "Bolt", "Veteran", age(0, 0, 1, 0)) }))

    test.assertEqual(1, log:RecordBatch(fromGame(GuildLog, {
        raw("promote", "Boss", "Bolt", "Veteran", age(0, 0, 1, 0)),
    })))
end)

test.test("a leave and a rejoin stay separate entries, from one read and seen live", function()
    local log, GuildLog = newLog()

    -- One read with a join, a leave, and a second join within the hour.
    test.assertEqual(3, log:RecordBatch(fromGame(GuildLog, {
        raw("join", "Bolt", nil, nil, age(0, 0, 0, 1)),
        raw("quit", "Bolt", nil, nil, age(0, 0, 0, 1)),
        raw("join", "Bolt", nil, nil, age(0, 0, 0, 0)),
    })))
    -- Read again later: still three.
    test.assertEqual(0, log:RecordBatch(fromGame(GuildLog, {
        raw("join", "Bolt", nil, nil, age(0, 0, 0, 2)),
        raw("quit", "Bolt", nil, nil, age(0, 0, 0, 2)),
        raw("join", "Bolt", nil, nil, age(0, 0, 0, 1)),
    }, NOW + HOUR)))
    test.assertEqual(3, #log:EntriesFor("bolt"))

    -- Seen live: a join, a leave ten minutes later, and a rejoin.
    test.assertTrue(log:RecordLive(GuildLog.JOIN, "wrench", NOW))
    test.assertTrue(log:RecordLive(GuildLog.LEAVE, "wrench", NOW + 600))
    test.assertTrue(log:RecordLive(GuildLog.JOIN, "wrench", NOW + 1200))
    test.assertEqual(3, #log:EntriesFor("wrench"))
end)

test.test("entries are kept forever, in the saved table, and load again", function()
    local log, GuildLog, saved = newLog()
    local events = {}
    local index
    for index = 1, 3000 do
        table.insert(events, { type = "join", character = "c" .. index, at = NOW - index * 10 * 365 * DAY,
            source = "log" })
    end

    test.assertEqual(3000, log:RecordBatch(events))
    test.assertEqual(3000, #saved.entries)

    local again = GuildLog.Create(saved)
    test.assertEqual(3000, #again:Entries())
    -- Loaded entries still merge repeats.
    test.assertEqual(0, again:RecordBatch({ { type = "join", character = "c1", at = NOW - 10 * 365 * DAY } }))
end)

test.test("unusable events and saved entries are left out", function()
    local log = newLog({ entries = { { type = "join" }, "junk" } })

    test.assertEqual(0, log:RecordBatch({
        { type = "dance", character = "bolt", at = NOW },
        { type = "join", at = NOW },
        { type = "join", character = "bolt" },
        "junk",
    }))
    test.assertEqual(0, #log:Entries())
end)

-- Queries ---------------------------------------------------------------------

-- A log of `count` joins by c1, c2, ..., one a day back from NOW, plus a
-- kick of c2 and a promotion of c3.
local function queryLog()
    local log, GuildLog = newLog()
    local events = {}
    local index
    for index = 1, 5 do
        table.insert(events, { type = "join", character = "c" .. index, at = NOW - index * DAY })
    end
    table.insert(events, { type = "kick", character = "c2", actor = "boss", at = NOW - HOUR })
    table.insert(events, { type = "promote", character = "c3", at = NOW - 40 * DAY })
    log:RecordBatch(events)
    return log, GuildLog
end

local function charactersOf(result)
    local list = {}
    local index
    for index = 1, #result.entries do
        list[index] = result.entries[index].type .. ":" .. result.entries[index].character
    end
    return table.concat(list, ",")
end

test.test("a query filters by event type", function()
    local log = queryLog()

    test.assertEqual("kick:c2,promote:c3", charactersOf(log:Query({ types = { kick = true, promote = true } })))
    test.assertEqual(7, log:Query({}).total)
end)

test.test("a query filters by date range", function()
    local log = queryLog()

    local result = log:Query({ from = NOW - 3 * DAY })
    test.assertEqual("kick:c2,join:c1,join:c2,join:c3", charactersOf(result))
    test.assertEqual("join:c5,promote:c3", charactersOf(log:Query({ to = NOW - 5 * DAY })))
end)

test.test("a query filters by a set of characters", function()
    local log = queryLog()

    test.assertEqual("kick:c2,join:c2,join:c3,promote:c3",
        charactersOf(log:Query({ characters = { c2 = true, c3 = true } })))
    test.assertEqual(0, log:Query({ characters = {} }).total)
end)

test.test("a query sorts newest first, or by name and then newest first", function()
    local log = queryLog()
    local names = { c1 = "Zed", c2 = "anvil", c3 = "Bolt", c4 = "Cog", c5 = "Dart" }

    test.assertEqual("kick:c2", charactersOf(log:Query({ pageSize = 1 })))
    test.assertEqual("kick:c2,join:c2,join:c3,promote:c3,join:c4,join:c5,join:c1", charactersOf(log:Query({
        sort = "name",
        nameOf = function(entry)
            return names[entry.character]
        end,
    })))
end)

test.test("a query returns one page at a time, kept within the pages there are", function()
    local log = queryLog()

    local first = log:Query({ pageSize = 3 })
    test.assertEqual("kick:c2,join:c1,join:c2", charactersOf(first))
    test.assertEqual(1, first.page)
    test.assertEqual(3, first.pages)
    test.assertEqual(7, first.total)
    local last = log:Query({ pageSize = 3, page = 3 })
    test.assertEqual("promote:c3", charactersOf(last))
    test.assertEqual(3, log:Query({ pageSize = 3, page = 9 }).page)
    test.assertEqual(1, log:Query({ pageSize = 3, page = -2 }).page)
    local empty = log:Query({ types = {} })
    test.assertEqual(0, #empty.entries)
    test.assertEqual(1, empty.pages)
end)

test.test("a query over thousands of entries returns only the page", function()
    local log = newLog()
    local events = {}
    local index
    for index = 1, 5000 do
        table.insert(events, { type = "join", character = "c" .. index, at = NOW - index * 3 * HOUR })
    end
    log:RecordBatch(events)

    local result = log:Query({ page = 2 })
    test.assertEqual(100, #result.entries)
    test.assertEqual(50, result.pages)
    test.assertEqual("c101", result.entries[1].character)
end)

-- The probe ---------------------------------------------------------------------

test.test("the probe lists each call, the entry count, the oldest age, and the first entries raw", function()
    local _, GuildLog = newLog()
    local calls = {
        { name = "QueryGuildEventLog", present = true },
        { name = "GetNumGuildEvents", present = true },
        { name = "GetGuildEventInfo", present = true },
    }
    local entries = {}
    local index
    for index = 1, 7 do
        table.insert(entries, raw("join", "C" .. index, nil, nil, age(0, 0, index, 0)))
    end
    entries[2] = raw("promote", "Toolbox", "Bolt", "Veteran", age(1, 2, 3, 4))

    local lines = GuildLog.ProbeLines(calls, entries, 5)

    test.assertEqual("QueryGuildEventLog: yes", lines[1])
    test.assertEqual("Entries: 7", lines[4])
    test.assertEqual("Oldest entry: 1y 2m 3d 4h ago", lines[5])
    test.assertEqual("2: type=promote actor=Toolbox target=Bolt rank=Veteran age=1y 2m 3d 4h", lines[7])
    test.assertEqual(10, #lines)

    calls[3].present = false
    lines = GuildLog.ProbeLines(calls, nil, 5)
    test.assertEqual("GetGuildEventInfo: missing", lines[3])
    test.assertContains(lines[4], "can't be read")
end)

-- The WoW adapter ----------------------------------------------------------------

local function newClient(world)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(world.environment)
end

local profileIndex
for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]

    test.test(profile .. " adapter requests and reads the guild event log", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world)
        world.guildEvents = {
            { "invite", "Toolbox", "Bolt", nil, 0, 0, 5, 2 },
            { "promote", "Toolbox", "Bolt", "Veteran", 1, 2, 3, 4 },
            { "quit", "Wrench", nil, nil, nil, nil, 1, nil },
        }
        local updates = 0

        test.assertTrue(client:HasGuildEventLog())
        test.assertTrue(client:ObserveGuildEventLog(function()
            updates = updates + 1
        end))
        test.assertTrue(client:RequestGuildEventLog())
        test.assertEqual(1, world.eventLogRequests)
        fixtures.fire(world, "GUILD_EVENT_LOG_UPDATE")
        test.assertEqual(1, updates)

        local entries = client:ReadGuildEventLog()
        test.assertEqual(3, #entries)
        test.assertEqual("invite", entries[1].type)
        test.assertEqual("Toolbox", entries[1].actor)
        test.assertEqual("Bolt", entries[1].target)
        test.assertEqual(5, entries[1].age.days)
        test.assertEqual(2, entries[1].age.hours)
        test.assertEqual("Veteran", entries[2].rank)
        test.assertEqual(1, entries[2].age.years)
        test.assertEqual(nil, entries[3].target)
        test.assertEqual(0, entries[3].age.years)
        local calls = client:GuildEventLogCalls()
        test.assertTrue(calls.QueryGuildEventLog)
        test.assertTrue(calls.GetGuildEventInfo)
    end)

    test.test(profile .. " adapter without the guild event log reports it unavailable, without errors", function()
        local world = fixtures.newEnvironment(profile, { eventLog = false })
        local client = newClient(world)

        test.assertFalse(client:HasGuildEventLog())
        test.assertFalse(client:RequestGuildEventLog())
        test.assertFalse(client:ObserveGuildEventLog(function() end))
        local entries, reason = client:ReadGuildEventLog()
        test.assertEqual(nil, entries)
        test.assertEqual("unavailable", reason)
        test.assertFalse(client:GuildEventLogCalls().GetNumGuildEvents)
    end)

    test.test(profile .. " adapter reports joins and leaves from system messages", function()
        local world = fixtures.newEnvironment(profile)
        local client = newClient(world)
        local heard = {}
        client:ObservePresence(function(kind, name)
            table.insert(heard, kind .. ":" .. name)
        end)

        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Bolt has joined the guild.")
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Bolt has left the guild.")

        test.assertEqual("join:Bolt,leave:Bolt", table.concat(heard, ","))
    end)
end

-- Page visibility ------------------------------------------------------------------

test.test("a page with a visibility rule has no tab while hidden, and the home page takes over", function()
    local addon = test.newAddon("Core/PageNavigator.lua")
    local pages = addon.PageNavigator.Create()
    local officer = true
    pages:Add("roster", "Roster")
    pages:Add("guildlog", "Guild Log", nil, function()
        return officer
    end)
    pages:Add("settings", "Settings")

    test.assertEqual(3, #pages:Tabs())
    test.assertTrue(pages:Select("guildlog"))
    test.assertEqual("guildlog", pages:Current())

    officer = false
    local tabs = pages:Tabs()
    test.assertEqual(2, #tabs)
    test.assertEqual("settings", tabs[2].id)
    test.assertEqual("roster", pages:Current())
    test.assertFalse(pages:Select("guildlog"))
    test.assertEqual("roster", pages:PageFor("guildlog"))
    test.assertEqual(3, #pages:Pages())

    -- A rule that fails hides its page.
    pages:Add("broken", "Broken", nil, function()
        error("no")
    end)
    test.assertFalse(pages:IsVisible("broken"))
end)

-- In the composed add-on -------------------------------------------------------

local function loggedIn(profile, options)
    options = options or {}
    local world = fixtures.newEnvironment(profile, { playerName = options.playerName, eventLog = options.eventLog })
    if options.setup ~= nil then
        options.setup(world)
    end
    local addon = fixtures.loadAddon(world)
    local frame = { shown = false }
    function frame:IsShown() return self.shown end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:ShowPage(id)
        if id ~= nil then
            addon.pages:Select(id)
        end
        self.page = addon.pages:Current()
        return true
    end
    function frame:SetTitle() end
    function frame:SetStatus() end
    function frame:SetRows() return true end
    function frame:SetConflicts() return true end
    function frame:SetRecruiters() return true end
    function frame:SetRecentAds() return true end
    function frame:SetGuildLog(rows)
        self.guildLog = rows
        return true
    end
    addon.RosterWindow.Create = function()
        return frame
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    world.frame = frame
    return world, addon
end

local function storedLog(addon)
    local _, partition = addon.rosterController:QuietContext()
    return partition.data.guildLog
end

local function hasTab(addon, id)
    local tabs = addon.pages:Tabs()
    local index
    for index = 1, #tabs do
        if tabs[index].id == id then
            return true
        end
    end
    return false
end

local MEMBERS = { Forever = "Hammer Smith", Retail = "Hammer-Area52" }

for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]

    test.test(profile .. " an officer's add-on records the game log and live joins and leaves, and lists them", function()
        local world, addon = loggedIn(profile, { setup = function(world)
            world.guildEvents = { { "invite", "Boss", "Bolt", nil, 0, 0, 2, 0 }, { "join", "Bolt", nil, nil, 0, 0, 2, 0 } }
        end })
        test.assertTrue(world.eventLogRequests >= 1, "the officer's add-on asked for the log")

        fixtures.fire(world, "GUILD_EVENT_LOG_UPDATE")
        world.time = world.time + 60
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Wrench has joined the guild.")
        world.time = world.time + 60
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Wrench has left the guild.")
        -- The same log read again adds nothing.
        fixtures.fire(world, "GUILD_EVENT_LOG_UPDATE")

        test.assertEqual(4, #storedLog(addon).entries)
        fixtures.slash(world, "roster")
        test.assertTrue(hasTab(addon, "guildlog"))
        test.assertTrue(addon.rosterController:ShowPage("guildlog") == nil)
        test.assertEqual("guildlog", world.frame.page)
        local rows = addon.rosterController:GuildLogView()
        test.assertEqual("heading", rows[1].kind)
        test.assertEqual("Left", rows[2].event)
        test.assertEqual("leave", rows[2].eventType, "the window colors each event by its type")
        test.assertEqual("Joined", rows[3].event)
        test.assertEqual("join", rows[3].eventType)
        test.assertEqual("Invited", rows[5].event)
        test.assertEqual("Boss", rows[5].actor)
        test.assertEqual(addon.client:FormatDate(world.time - 120 - 2 * DAY), rows[5].date)
        test.assertEqual(5, #world.frame.guildLog)
    end)

    test.test(profile .. " the Guild Log page filters, searches by name, alias, or main, and pages", function()
        local world, addon = loggedIn(profile)
        local _, partition, normalizer = addon.rosterController:QuietContext()
        local keys = {}
        partition:EachCharacter(function(key)
            table.insert(keys, key)
        end)
        table.sort(keys)
        local toolbox = partition:GetPlayer(partition:GetCharacter(addon.rosterController:SelfKey()).player)
        local alt
        local index
        for index = 1, #keys do
            if keys[index] ~= toolbox.main and partition:GetCharacter(keys[index]).player
                == partition:GetCharacter(toolbox.main).player
            then
                alt = keys[index]
            end
        end
        local other
        for index = 1, #keys do
            if keys[index] ~= toolbox.main and keys[index] ~= alt then
                other = keys[index]
            end
        end
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Bolt has joined the guild.")
        local log = select(1, addon.rosterController.guildLog())
        log:RecordBatch({
            { type = "join", character = alt, at = world.time - 2 * DAY },
            { type = "promote", character = toolbox.main, toRank = 1, at = world.time - 20 * DAY },
            { type = "kick", character = other, actor = toolbox.main, at = world.time - 100 * DAY },
        })
        local controller = addon.rosterController
        local function events()
            local rows, state = controller:GuildLogView()
            local list = {}
            for index = 2, #rows do
                list[index - 1] = rows[index].kind == "entry" and rows[index].character or rows[index].event
            end
            return table.concat(list, ","), state
        end
        local mainName = normalizer:Display(partition:GetCharacter(toolbox.main).name)
        local altName = normalizer:Display(partition:GetCharacter(alt).name)
        local otherName = normalizer:Display(partition:GetCharacter(other).name)

        local all, state = events()
        test.assertEqual("Bolt," .. altName .. "," .. mainName .. "," .. otherName, all)
        test.assertEqual(4, state.total)

        -- The alias, the main, or the alt find the whole player.
        controller:SetGuildLogSearch(toolbox.alias)
        test.assertEqual(altName .. "," .. mainName, (events()))
        controller:SetGuildLogSearch(string.lower(altName))
        test.assertEqual(altName .. "," .. mainName, (events()))
        -- A character the roster doesn't know is found by its logged name.
        controller:SetGuildLogSearch("bol")
        test.assertEqual("Bolt", (events()))
        controller:SetGuildLogSearch("")

        controller:SetGuildLogType("join", false)
        test.assertEqual(mainName .. "," .. otherName, (events()))
        controller:SetGuildLogType("join", true)
        controller:SetGuildLogRange(30)
        test.assertEqual("Bolt," .. altName .. "," .. mainName, (events()))
        controller:SetGuildLogRange(7)
        test.assertEqual("Bolt," .. altName, (events()))
        controller:SetGuildLogRange(nil)
        controller:SetGuildLogSort("name")
        local byName = { "Bolt", altName, mainName, otherName }
        table.sort(byName, function(a, b)
            return string.lower(a) < string.lower(b)
        end)
        test.assertEqual(table.concat(byName, ","), (events()))

        controller:SetGuildLogType("kick", false)
        controller:SetGuildLogType("promote", false)
        controller:SetGuildLogType("join", false)
        test.assertEqual("Nothing in the guild log matches.", (events()))

        -- The page number stays within the pages there are.
        controller:SetGuildLogPage(5)
        local _, paged = events()
        test.assertEqual(1, paged.page)
        local text = addon.RosterWindow.GuildLogControlText(paged)
        test.assertEqual("Sort: Name", text.sort)
        test.assertEqual("Range: All", text.range)
        test.assertEqual("Page 1 of 1 (0 entries)", text.page)
    end)

    test.test(profile .. " a member's add-on never records or stores the guild log, and has no Guild Log tab", function()
        local world, addon = loggedIn(profile, { playerName = MEMBERS[profile], setup = function(world)
            world.guildEvents = { { "join", "Bolt", nil, nil, 0, 0, 2, 0 } }
        end })

        fixtures.fire(world, "GUILD_EVENT_LOG_UPDATE")
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Wrench has joined the guild.")
        fixtures.slash(world, "probe log")

        test.assertEqual(nil, storedLog(addon))
        test.assertEqual(0, world.eventLogRequests)
        test.assertFalse(hasTab(addon, "guildlog"))
        test.assertEqual(nil, addon.rosterController:GuildLogView())
        test.assertContains(world.messages[#world.messages], "Only officers")
    end)

    test.test(profile .. " the Guild Log tab goes away on demotion, without a reload, back to the home page", function()
        local world, addon = loggedIn(profile)
        fixtures.slash(world, "roster")
        addon.rosterController:ShowPage("guildlog")
        test.assertEqual("guildlog", world.frame.page)

        world.guild.members[1].rank = 3
        world.guild.members[1].rankName = "Member"
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)

        test.assertFalse(hasTab(addon, "guildlog"))
        test.assertEqual("roster", world.frame.page)
    end)

    test.test(profile .. " without the game's event log, live joins are still recorded and the probe says so", function()
        local world, addon = loggedIn(profile, { eventLog = false })

        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Wrench has joined the guild.")
        fixtures.slash(world, "probe log")
        fixtures.runTimers(world, 5)

        test.assertEqual(1, #storedLog(addon).entries)
        local printed = table.concat(world.messages, "\n")
        test.assertContains(printed, "QueryGuildEventLog: missing")
        test.assertContains(printed, "can't be read")
    end)

    test.test(profile .. " /agf probe log prints the calls, the count, the oldest age, and the first entries", function()
        local world = loggedIn(profile, { setup = function(world)
            world.guildEvents = { { "promote", "Boss", "Bolt", "Veteran", 0, 3, 1, 2 } }
        end })

        fixtures.slash(world, "probe log")
        fixtures.runTimers(world, 5)

        local printed = table.concat(world.messages, "\n")
        test.assertContains(printed, "GetGuildEventInfo: yes")
        test.assertContains(printed, "Entries: 1")
        test.assertContains(printed, "Oldest entry: 0y 3m 1d 2h ago")
        test.assertContains(printed, "1: type=promote actor=Boss target=Bolt rank=Veteran")
    end)
end

-- Sharing between officers ------------------------------------------------------

local MONTH = 30 * DAY

test.test("a digest has one checksum per month of entries, whatever order they were recorded in", function()
    local log, GuildLog = newLog()
    local other = GuildLog.Create({})
    local events = {
        { type = "join", character = "bolt", at = NOW - 2 * DAY },
        { type = "kick", character = "nail", actor = "boss", at = NOW - 3 * DAY },
        { type = "promote", character = "anvil", actor = "boss", toRank = 2, at = NOW - 2 * MONTH },
    }
    log:RecordBatch(events)
    other:RecordBatch({ events[3], events[1], events[2] })

    local digest = log:Digest()
    local months = 0
    local month
    for month in pairs(digest) do
        months = months + 1
    end
    test.assertTrue(GuildLog.MonthOf(NOW - 2 * DAY) ~= GuildLog.MonthOf(NOW - 2 * MONTH))
    test.assertTrue(months == 2 or months == 3, "entries land in the months they happened in")
    test.assertTrue(digest[GuildLog.MonthOf(NOW - 2 * MONTH)] ~= nil)
    test.assertEqual(0, #GuildLog.DifferingMonths(digest, other:Digest()))
    test.assertTrue(GuildLog.IsDigest(digest))

    -- A new entry changes only its own month.
    other:RecordLive("leave", "bolt", NOW)
    local differing = GuildLog.DifferingMonths(digest, other:Digest())
    test.assertEqual(1, #differing)
    test.assertEqual(GuildLog.MonthOf(NOW), differing[1])
    -- A month only one side has differs too.
    test.assertEqual(1, #GuildLog.DifferingMonths({}, { [5] = 1 }))
end)

test.test("a month's entries come as copies, and only that month's", function()
    local log, GuildLog = newLog()
    log:RecordBatch({
        { type = "join", character = "bolt", name = "Bolt", at = NOW - DAY },
        { type = "join", character = "anvil", at = NOW - 3 * MONTH },
    })

    local found = log:EntriesInMonths({ GuildLog.MonthOf(NOW - 3 * MONTH) })
    test.assertEqual(1, #found)
    test.assertEqual("anvil", found[1].character)
    found[1].character = "changed"
    test.assertEqual("anvil", log:EntriesFor("anvil")[1].character)
    test.assertEqual(0, #log:EntriesInMonths({}))
end)

test.test("another officer's entries merge without duplicates, and both logs settle on the same digest", function()
    local mine, GuildLog = newLog()
    local theirs = GuildLog.Create({})
    -- Both read the same invite from the game log an hour apart; each
    -- also saw something the other didn't.
    mine:RecordBatch(fromGame(GuildLog, { raw("invite", "Boss", "Bolt", nil, age(0, 0, 3, 0)) }, NOW))
    theirs:RecordBatch(fromGame(GuildLog, { raw("invite", "Boss", "Bolt", nil, age(0, 0, 3, 0)) }, NOW + HOUR))
    mine:RecordLive("join", "nail", NOW - DAY, "Nail")
    theirs:RecordLive("leave", "anvil", NOW - 2 * DAY, "Anvil")

    local added, changed = mine:Merge(theirs:EntriesInMonths(GuildLog.DifferingMonths(mine:Digest(), theirs:Digest())))
    test.assertEqual(1, added)
    test.assertEqual(3, #mine:Entries())
    test.assertTrue(#changed >= 1)
    theirs:Merge(mine:EntriesInMonths(GuildLog.DifferingMonths(mine:Digest(), theirs:Digest())))
    test.assertEqual(3, #theirs:Entries())
    test.assertEqual(0, #GuildLog.DifferingMonths(mine:Digest(), theirs:Digest()))
    -- Merging the same entries again changes nothing.
    local again, unchanged = mine:Merge(theirs:EntriesInMonths({ GuildLog.MonthOf(NOW) }))
    test.assertEqual(0, again)
    test.assertEqual(0, #unchanged)
end)

test.test("a more precise time from another officer replaces a vaguer one", function()
    local mine, GuildLog = newLog()
    mine:RecordBatch(fromGame(GuildLog, { raw("join", "Bolt", nil, nil, age(0, 2, 0, 0)) }, NOW))
    local entry = mine:EntriesFor("bolt")[1]
    local exact = NOW - 61 * DAY

    local added = mine:Merge({ { type = "join", character = "bolt", at = exact, tolerance = 2 * HOUR, source = "live" } })
    test.assertEqual(0, added)
    test.assertEqual(exact, entry.at)
    test.assertEqual("live", entry.source)
end)

test.test("entries from another officer that aren't entries are dropped, and odd fields are left out", function()
    local log, GuildLog = newLog()
    local long = string.rep("x", 65)

    local added = log:Merge({
        "junk",
        { type = "dance", character = "bolt", at = NOW },
        { type = "join", character = long, at = NOW },
        { type = "join", character = "bolt", at = "soon" },
        { type = "promote", character = "nail", at = NOW, toRank = 99, name = long, actor = 5, tolerance = -1,
            source = "rumour" },
    })
    test.assertEqual(1, added)
    local entry = log:EntriesFor("nail")[1]
    test.assertEqual(nil, entry.toRank)
    test.assertEqual(nil, entry.name)
    test.assertEqual(nil, entry.actor)
    test.assertEqual(2 * HOUR, entry.tolerance)
    test.assertEqual("live", entry.source)
    test.assertEqual(0, (log:Merge("junk")))

    test.assertFalse(GuildLog.IsDigest("junk"))
    test.assertFalse(GuildLog.IsDigest({ [1.5] = 1 }))
    test.assertFalse(GuildLog.IsDigest({ [3] = -1 }))
    test.assertTrue(GuildLog.IsMonthList({ 1, 2 }))
    test.assertFalse(GuildLog.IsMonthList({ "a" }))
end)
