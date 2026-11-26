local test = require("tests.test_helper")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000

-- Group friends over an empty guild partition. `players` maps a character
-- key to its player; a key not in it is its own player.
local function newFriends(players)
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/GroupHistory.lua", "Core/GroupFriends.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    local world = { addon = addon, partition = partition, lookups = 0 }
    world.friends = addon.GroupFriends.Create({
        partition = partition,
        playerOf = function(key)
            world.lookups = world.lookups + 1
            return players and players[key] or nil
        end,
        version = function()
            return world.version
        end,
        friends = function()
            return world.pinned or {}
        end,
    })
    return world, addon.GroupFriends
end

-- Records `times` parties with `keys`, the first at `at`, a minute apart.
local function party(world, keys, times, at)
    local index
    for index = 1, times or 1 do
        world.partition:AddGroupHistory({ at = (at or NOW) + index * 60, characters = keys })
    end
end

-- Five players grouped with 10 times each, filling the Top 5.
local function fillTop(world)
    local _, key
    for _, key in ipairs({ "ace", "bard", "cleric", "druid", "elf" }) do
        party(world, { key }, 10)
    end
end

test.test("group friends: a player never grouped with has no tier", function()
    local world = newFriends()
    test.assertEqual(nil, world.friends:TierOf("hammer"))

    party(world, { "bolt" })
    test.assertEqual(nil, world.friends:TierOf("hammer"))
    test.assertEqual(nil, world.friends:TierOf(nil))
end)

test.test("group friends: 1 party is Grouped, 4 is Frequent, and the 5 grouped with most are Top 5", function()
    local world, GroupFriends = newFriends()
    fillTop(world)
    party(world, { "frank" }, 4)
    party(world, { "gus" }, 3)
    party(world, { "hal" }, 1)

    local _, key
    for _, key in ipairs({ "ace", "bard", "cleric", "druid", "elf" }) do
        -- A Top 5 player isn't also reported as Frequent.
        test.assertEqual(GroupFriends.TOP, world.friends:TierOf(key), key)
    end
    test.assertEqual(GroupFriends.FREQUENT, world.friends:TierOf("frank"))
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("gus"))
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("hal"))
    test.assertEqual(nil, world.friends:TierOf("ivy"))
    test.assertTrue(GroupFriends.HasPerks(GroupFriends.TOP))
    test.assertTrue(GroupFriends.HasPerks(GroupFriends.FREQUENT))
    test.assertFalse(GroupFriends.HasPerks(GroupFriends.GROUPED))
    test.assertFalse(GroupFriends.HasPerks(nil))
end)

test.test("group friends: the Top 5 holds the players grouped with most, even with low counts", function()
    local world, GroupFriends = newFriends()
    party(world, { "bolt" })
    party(world, { "hammer", "zap" }, 2)

    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("bolt"))
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("hammer"))
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("zap"))
end)

test.test("group friends: a tie for 5th goes to the most recent party, then to the player key", function()
    local world, GroupFriends = newFriends()
    party(world, { "ace" }, 10)
    party(world, { "bard" }, 10)
    party(world, { "cleric" }, 10)
    party(world, { "druid" }, 10)
    party(world, { "older" }, 3, NOW)
    party(world, { "newer" }, 3, NOW + 3600)

    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("newer"))
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("older"))

    -- Same count and same last party: the lower player key wins.
    world = newFriends()
    party(world, { "ace" }, 10)
    party(world, { "bard" }, 10)
    party(world, { "cleric" }, 10)
    party(world, { "druid" }, 10)
    party(world, { "zed", "yan" }, 3)
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("yan"))
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("zed"))
end)

test.test("group friends: parties with any of a player's characters count for the player, once each", function()
    local world, GroupFriends = newFriends({
        anvil = "anvil", tongs = "anvil", bishop = "bishop", rook = "bishop",
    })
    fillTop(world)
    party(world, { "anvil" })
    party(world, { "tongs" })
    party(world, { "anvil", "tongs" }, 2)
    -- Two characters in each of three parties: still 3 parties.
    party(world, { "bishop", "rook" }, 3)

    test.assertEqual(GroupFriends.FREQUENT, world.friends:TierOf("anvil"))
    test.assertEqual(GroupFriends.FREQUENT, world.friends:TierOf("tongs"))
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("rook"))
end)

test.test("group friends: tiers update after a new party, or characters joining the current one", function()
    local world, GroupFriends = newFriends()
    local history = world.addon.GroupHistory.Create(world.partition)
    fillTop(world)
    party(world, { "frank" }, 3)
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("frank"))
    test.assertEqual(nil, world.friends:TierOf("gus"))

    history:OnParty({ "frank" }, NOW + 86400)
    test.assertEqual(GroupFriends.FREQUENT, world.friends:TierOf("frank"))
    test.assertEqual(nil, world.friends:TierOf("gus"))

    history:OnParty({ "frank", "gus" }, NOW + 86460)
    test.assertEqual(GroupFriends.GROUPED, world.friends:TierOf("gus"))
end)

test.test("group friends: tiers are kept until the history or the version changes", function()
    local world, GroupFriends = newFriends({ tongs = "anvil" })
    party(world, { "anvil" })
    party(world, { "tongs" })
    world.friends:TierOf("anvil")
    local lookups = world.lookups

    world.friends:TierOf("anvil")
    world.friends:TierOf("bolt")
    -- Only the asked-for keys are looked up, not the whole history.
    test.assertEqual(lookups + 2, world.lookups)

    -- A new version (a scan linking characters) works them out again.
    world.version = 2
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("tongs"))
    test.assertTrue(world.lookups > lookups + 3)
end)

test.test("group friends: characters joining a resumed party behind an unreadable entry update the tiers", function()
    local world, GroupFriends = newFriends()
    party(world, { "frank" })
    -- A damaged last entry, which reading the history skips.
    table.insert(world.partition.data.groupHistory, { at = "soon", characters = { "zed" } })
    test.assertEqual(nil, world.friends:TierOf("gus"))

    -- After a reload, the party carries on in the last readable entry.
    world.addon.GroupHistory.Create(world.partition):OnParty({ "frank", "gus" }, NOW + 120)

    test.assertEqual(1, #world.partition:GetGroupHistory())
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("gus"))
end)

test.test("group friends: samples are the most recently grouped character of each tier, among those accepted", function()
    local world, GroupFriends = newFriends({ ace2 = "ace" })
    fillTop(world)
    party(world, { "frank" }, 4)
    party(world, { "gus" }, 1)
    party(world, { "hal" }, 1, NOW + 9999)
    party(world, { "ace2" }, 1, NOW + 99999)

    local samples = world.friends:Samples(function(key)
        return key ~= "hal"
    end)

    test.assertEqual("ace2", samples[GroupFriends.TOP])
    test.assertEqual("frank", samples[GroupFriends.FREQUENT])
    test.assertEqual("gus", samples[GroupFriends.GROUPED])
end)

test.test("group friends: a tier nobody is in has no sample", function()
    local world, GroupFriends = newFriends()
    party(world, { "bolt" })

    local samples = world.friends:Samples(function()
        return true
    end)

    test.assertEqual("bolt", samples[GroupFriends.TOP])
    test.assertEqual(nil, samples[GroupFriends.FREQUENT])
    test.assertEqual(nil, samples[GroupFriends.GROUPED])
end)

-- Friends ----------------------------------------------------------------------

test.test("group friends: a pinned player is a Friend, grouped with or not, with the perks and the star", function()
    local world, GroupFriends = newFriends()
    world.pinned = { "hammer" }

    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("hammer"))
    test.assertTrue(GroupFriends.HasPerks(GroupFriends.FRIEND))
    test.assertTrue(GroupFriends.IsStarred(GroupFriends.FRIEND))
    test.assertTrue(GroupFriends.IsStarred(GroupFriends.TOP))
    test.assertFalse(GroupFriends.IsStarred(GroupFriends.FREQUENT))
    test.assertFalse(GroupFriends.IsStarred(nil))
end)

test.test("group friends: Friend wins over Top 5 and Frequent", function()
    local world, GroupFriends = newFriends()
    fillTop(world)
    party(world, { "frank" }, 4)
    world.pinned = { "ace", "frank" }

    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("ace"))
    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("frank"))
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("bard"))
end)

test.test("group friends: a pin on any of a player's characters counts for the player, and follows merges", function()
    local players = { tongs = "anvil" }
    local world, GroupFriends = newFriends(players)
    world.pinned = { "tongs" }

    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("anvil"))
    test.assertEqual(nil, world.friends:TierOf("bellows"))

    -- A scan links bellows to the same player.
    players.bellows = "anvil"
    world.version = 2
    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("bellows"))
end)

test.test("group friends: changing the Friend slots updates the tiers", function()
    local world, GroupFriends = newFriends()
    party(world, { "bolt" })
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("bolt"))

    world.pinned = { "bolt" }
    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("bolt"))

    world.pinned = {}
    test.assertEqual(GroupFriends.TOP, world.friends:TierOf("bolt"))
    -- Unreadable slots pin nobody.
    world.pinned = { 42, "bolt" }
    test.assertEqual(GroupFriends.FRIEND, world.friends:TierOf("bolt"))
end)

test.test("group friends: a player's party count and last party, across their characters", function()
    local world = newFriends({ tongs = "anvil" })
    party(world, { "anvil" }, 2, NOW)
    party(world, { "anvil", "tongs" }, 1, NOW + 3600)

    local count, last = world.friends:StatsOf("tongs")
    test.assertEqual(3, count)
    test.assertEqual(NOW + 3660, last)
    count, last = world.friends:StatsOf("ivy")
    test.assertEqual(0, count)
    test.assertEqual(nil, last)
end)
