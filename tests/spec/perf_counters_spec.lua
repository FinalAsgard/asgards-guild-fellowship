local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- `/agf perf`: the add-on's memory and CPU use, and counts of its costly
-- work since login.

local function load()
    return test.newAddon("Core/PerfCounters.lua")
end

test.test("perf counters count each operation from 0, and start again on reset", function()
    local addon = load()
    local counters = addon.PerfCounters

    counters.Bump("rosterReads")
    counters.Bump("rosterReads", 2)

    test.assertEqual(3, counters.Get("rosterReads"))
    test.assertEqual(0, counters.Get("mapRedraws"))
    counters.Reset()
    test.assertEqual(0, counters.Get("rosterReads"))
end)

test.test("perf lines show memory in KB or MB, and every count, never-run ones as 0", function()
    local addon = load()
    addon.PerfCounters.Bump("chatTags", 7)

    local small = addon.PerfCounters.Lines({ memoryKB = 512.4, profiling = false })
    local large = addon.PerfCounters.Lines({ memoryKB = 3072, profiling = false })

    test.assertEqual("Memory: 512 KB", small[1])
    test.assertEqual("Memory: 3.0 MB", large[1])
    local shown = table.concat(small, "\n")
    test.assertContains(shown, "Chat tags worked out: 7")
    test.assertContains(shown, "Whole-roster reads: 0")
    test.assertContains(shown, "Incremental scans skipped (nothing changed): 0")
end)

test.test("perf lines say how to turn CPU profiling on when it's off, and show CPU when it's on", function()
    local addon = load()

    local off = table.concat(addon.PerfCounters.Lines({ profiling = false, profilingHint = "/console scriptProfile 1" }),
        "\n")
    local on = table.concat(addon.PerfCounters.Lines({ profiling = true, cpuMs = 1234.4 }), "\n")
    local missing = table.concat(addon.PerfCounters.Lines({ profiling = true }), "\n")
    local profiler = table.concat(addon.PerfCounters.Lines({ profiling = false, recentMs = 0.05, sessionMs = 0.125 }),
        "\n")

    test.assertContains(off, "Memory: unavailable on this client")
    test.assertContains(off, "CPU: profiling is off; turn it on with /console scriptProfile 1 and reload")
    test.assertContains(on, "CPU since profiling began: 1234 ms")
    test.assertContains(missing, "CPU: unavailable on this client")
    test.assertContains(profiler, "CPU per frame (game's add-on profiler): 0.050 ms recently, 0.125 ms this session")
end)

local function loggedIn(profile, setup)
    local world = fixtures.newEnvironment(profile, {})
    if setup ~= nil then
        setup(world.environment)
    end
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world, addon
end

local PROFILES = { "Retail", "Forever" }
local index
for index = 1, #PROFILES do
    local profile = PROFILES[index]

    test.test(profile .. ": /agf perf prints the add-on's memory, the profiling hint, and the counts since login",
        function()
            local asked
            local world, addon = loggedIn(profile, function(environment)
                environment.UpdateAddOnMemoryUsage = function() end
                environment.GetAddOnMemoryUsage = function(name)
                    asked = name
                    return 2048
                end
                environment.GetCVarBool = function()
                    return false
                end
            end)
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            local printed = #world.messages

            fixtures.slash(world, "perf")

            local shown = table.concat(world.messages, "\n", printed + 1)
            test.assertEqual(world.addonName, asked)
            test.assertContains(shown, "Memory: 2.0 MB")
            test.assertContains(shown, "turn it on with /console scriptProfile 1")
            test.assertContains(shown, "Roster updates heard: " .. addon.PerfCounters.Get("rosterUpdates"))
            test.assertTrue(addon.PerfCounters.Get("rosterUpdates") >= 2, "both roster updates counted")
            test.assertTrue(addon.PerfCounters.Get("rosterReads") > 0, "roster reads counted")
        end)

    test.test(profile .. ": /agf perf works on a client that can't report memory or CPU", function()
        local world = loggedIn(profile)
        local printed = #world.messages

        fixtures.slash(world, "perf")

        local shown = table.concat(world.messages, "\n", printed + 1)
        test.assertContains(shown, "Memory: unavailable on this client")
        test.assertContains(shown, "Whole-roster reads:")
    end)

    test.test(profile .. ": /agf perf is in the command help", function()
        local world = loggedIn(profile)
        local printed = #world.messages

        fixtures.slash(world, "help")

        test.assertContains(table.concat(world.messages, "\n", printed + 1), "perf")
    end)
end

-- Counts the game's roster member calls `world` answers from now on.
local function countRosterCalls(world)
    local counted = { calls = 0 }
    local read = world.environment.GetGuildRosterInfo
    world.environment.GetGuildRosterInfo = function(...)
        counted.calls = counted.calls + 1
        return read(...)
    end
    return counted
end

for index = 1, #PROFILES do
    local profile = PROFILES[index]

    test.test(profile .. ": one roster update is read once, however many callers ask", function()
        local world, addon = loggedIn(profile)
        local controller = addon.rosterController
        local counted = countRosterCalls(world)
        local size = #world.guild.members

        -- Everything the update refreshes, and the scan's own read.
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world, 5)
        local afterUpdate = counted.calls
        test.assertTrue(afterUpdate <= 2 * size, "the shared copy and the scan's read: " .. afterUpdate)
        -- More callers read nothing more.
        local guild, _, normalizer = controller:QuietContext()
        test.assertTrue(guild ~= nil)
        local first = controller:LiveMembers(normalizer)
        local again = controller:LiveMembers(normalizer)
        controller:RosterKeyFor(world.guild.members[2].name, "Player-1-" .. world.guild.members[2].name)
        addon.mapPins:Refresh()

        test.assertEqual(afterUpdate, counted.calls)
        test.assertTrue(first == again, "the same copy")

        -- The next roster update makes the next read fresh.
        world.guild.members[2].online = not world.guild.members[2].online
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        local key = normalizer:Key(world.guild.members[2].name)
        test.assertEqual(world.guild.members[2].online, controller:LiveMembers(normalizer)[key].online)
    end)

    test.test(profile .. ": the guild context is reused, and a new guild gets its own", function()
        local world, addon = loggedIn(profile)
        local controller = addon.rosterController

        local guild, partition, normalizer = controller:QuietContext()
        local _, samePartition, sameNormalizer = controller:QuietContext()
        test.assertTrue(partition == samePartition and normalizer == sameNormalizer, "reused")
        local members = controller:LiveMembers(normalizer)

        -- The character joins another guild.
        world.guild.name = "Other Guild"
        local otherGuild, otherPartition, otherNormalizer = controller:QuietContext()

        test.assertEqual("Other Guild", otherGuild.name)
        test.assertTrue(otherPartition ~= partition, "another guild's records")
        test.assertTrue(otherPartition.key ~= partition.key)
        test.assertTrue(otherNormalizer ~= normalizer, "another guild's normalizer")
        test.assertTrue(controller:LiveMembers(otherNormalizer) ~= members, "another guild's roster copy")
        test.assertTrue(guild.name ~= otherGuild.name)
    end)
end
