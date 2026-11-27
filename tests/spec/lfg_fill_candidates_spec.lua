local test = require("tests.test_helper")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }

-- A guild:
--   Thunderer (alias): Bolt, a shaman (22, online), with alts Hammer, a
--     paladin (24, online), and Boltalt, a priest (23, offline)
--   Cleric, a priest (20, online), heals
--   Zap, a mage (22, online)
--   Busy, a warrior (25, online), in a listed group on the board
--   Sleepy, a rogue (22, offline), with alt Sleepier (23, offline)
--   Pal, a priest (22, online), in the player's party, with alt Palalt (22,
--     online)
--   Me, a warrior (24, online): the player, with alt Mealt (22, online)
local function newGuild()
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/GroupFriends.lua", "Core/LfgRelevance.lua",
        "Core/LfgFillCandidates.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    local function add(key, class, level)
        partition:RecordCharacter(key, { name = key:gsub("^%l", string.upper) .. "-Camelot", classToken = class,
            level = level })
    end
    add("bolt", "SHAMAN", 22)
    add("hammer", "PALADIN", 24)
    partition:JoinPlayerOf("hammer", "bolt", "manual")
    add("boltalt", "PRIEST", 23)
    partition:JoinPlayerOf("boltalt", "bolt", "manual")
    partition:SetAlias(partition:GetCharacter("bolt").player, "Thunderer", "manual")
    add("cleric", "PRIEST", 20)
    add("zap", "MAGE", 22)
    add("busy", "WARRIOR", 25)
    add("sleepy", "ROGUE", 22)
    add("sleepier", "MAGE", 23)
    partition:JoinPlayerOf("sleepier", "sleepy", "manual")
    add("pal", "PRIEST", 22)
    add("palalt", "MAGE", 22)
    partition:JoinPlayerOf("palalt", "pal", "manual")
    add("me", "WARRIOR", 24)
    add("mealt", "MAGE", 22)
    partition:JoinPlayerOf("mealt", "me", "manual")
    local members = {}
    local key
    for _, key in ipairs({ "bolt", "hammer", "cleric", "zap", "busy", "pal", "palalt", "me", "mealt" }) do
        members[key] = { online = true, level = partition:GetCharacter(key).level, name = key:gsub("^%l", string.upper) }
    end
    members.sleepy = { online = false, level = 22, name = "Sleepy" }
    members.sleepier = { online = false, level = 23, name = "Sleepier" }
    members.boltalt = { online = false, level = 23, name = "Boltalt" }
    local roles = { cleric = { "healer" }, bolt = { "healer", "dps" }, hammer = { "tank" }, busy = { "tank" } }
    return function(listing, grouped, tiers)
        return addon.LfgFillCandidates.List({
            partition = partition,
            members = members,
            rolesOf = function(key)
                return roles[key] or { "dps" }
            end,
            listing = listing,
            selfKey = "me",
            partyKeys = { "pal" },
            grouped = grouped or { busy = true },
            className = function(classToken)
                return classToken:sub(1, 1) .. classToken:sub(2):lower()
            end,
            tierOf = tiers and function(key)
                return tiers[key]
            end or nil,
        })
    end
end

local function names(rows)
    local result = {}
    local index
    for index = 1, #rows do
        result[index] = rows[index].name .. (rows[index].starred and "*" or "")
            .. (rows[index].kind == "alt" and " (alt)" or "")
            .. (rows[index].inGroup and " (in a group)" or "")
    end
    return table.concat(result, ", ")
end

test.test("lfg fill: a dungeon wants the level and an open role", function()
    local list = newGuild()
    local rows = list({ kind = "dungeon", minLevel = 20, maxLevel = 24, openRoles = { "healer" }, size = 2,
        maxSize = 5 })
    test.assertEqual("Bolt, Cleric", names(rows))
    rows = list({ kind = "dungeon", minLevel = 22, maxLevel = 26, openRoles = { "tank" }, size = 2, maxSize = 5 })
    test.assertEqual("Hammer, Busy (in a group)", names(rows))
    test.assertEqual("Thunderer", rows[1].label)
    test.assertEqual("Hammer-Camelot", rows[1].whisper)
    test.assertEqual("PALADIN", rows[1].class)
    test.assertEqual(24, rows[1].level)
end)

test.test("lfg fill: questing, raid and other match any role in the range", function()
    local list = newGuild()
    test.assertEqual("Bolt, Hammer, Zap, Boltalt (alt), Busy (in a group)",
        names(list({ kind = "questing", minLevel = 21, maxLevel = 25, size = 2, maxSize = 5 })))
    test.assertEqual("Bolt, Cleric, Hammer, Zap, Boltalt (alt), Busy (in a group)",
        names(list({ kind = "raid", size = 10, maxSize = 40 })))
    test.assertEqual("Cleric", names(list({ kind = "other", minLevel = 18, maxLevel = 20, size = 1, maxSize = 5 })))
    -- Other with no range fits nobody, and a full party has no room.
    test.assertEqual("", names(list({ kind = "other", size = 1, maxSize = 5 })))
    test.assertEqual("", names(list({ kind = "questing", minLevel = 1, maxLevel = 60, size = 5, maxSize = 5 })))
end)

test.test("lfg fill: the player's characters, the party's players and players with nothing online are left out", function()
    local list = newGuild()
    local rows = list({ kind = "questing", minLevel = 1, maxLevel = 60, size = 2, maxSize = 5 })
    -- No Me or Mealt (the player), no Pal or Palalt (in the party), no
    -- Sleepy or Sleepier (nothing online); Busy, in a listed group, last.
    test.assertEqual("Bolt, Cleric, Hammer, Zap, Boltalt (alt), Busy (in a group)", names(rows))
end)

test.test("lfg fill: offline alts that fit, of players online on another character, come after online rows", function()
    local list = newGuild()
    local listing = { kind = "dungeon", minLevel = 22, maxLevel = 24, openRoles = { "dps" }, size = 2, maxSize = 5,
        label = "The Deadmines" }
    local rows = list(listing)
    -- Boltalt is Thunderer's, online as Bolt, and comes after Zap; Sleepier's
    -- player has nothing online, so it's left out.
    test.assertEqual("Bolt, Zap, Boltalt (alt)", names(rows))
    local alt = rows[3]
    test.assertEqual("bolt", alt.onlineKey)
    test.assertEqual("Bolt", alt.onlineName)
    test.assertEqual("Bolt-Camelot", alt.whisper)
    test.assertEqual("Thunderer", alt.label)
    test.assertEqual(23, alt.level)
    test.assertEqual("Priest", alt.className)
    test.assertEqual("Could you log over to Boltalt? We have a spot for them in The Deadmines.", alt.message)

    -- An alt whose player is online in a listed group goes last, marked.
    rows = list(listing, { bolt = true })
    test.assertEqual("Zap, Bolt (in a group), Boltalt (alt) (in a group)", names(rows))
end)

test.test("lfg fill: starred friends are marked and go first among the online rows, and among the alts", function()
    local addon = test.newAddon("Core/GroupFriends.lua")
    local GroupFriends = addon.GroupFriends
    local list = newGuild()
    local listing = { kind = "questing", minLevel = 1, maxLevel = 60, size = 2, maxSize = 5 }

    local rows = list(listing, {}, { zap = GroupFriends.FRIEND, boltalt = GroupFriends.TOP,
        cleric = GroupFriends.GROUPED })
    -- A Friend or Top 5 is starred; a Grouped friend isn't.
    test.assertEqual("Zap*, Bolt, Busy, Cleric, Hammer, Boltalt* (alt)", names(rows))
    test.assertTrue(rows[1].starred)
    test.assertFalse(rows[4].starred)
    -- Without tiers, nobody is.
    test.assertEqual("Bolt, Busy, Cleric, Hammer, Zap, Boltalt (alt)", names(list(listing, {})))
end)
