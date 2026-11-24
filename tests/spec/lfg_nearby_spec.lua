local test = require("tests.test_helper")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }

-- A guild:
--   Thunderer (alias): Bolt, a shaman (22, online in Ironforge), with
--     alts Hammer, a paladin (24, offline), and Oldbolt, a warrior (60)
--   Cleric, a priest (20, online in Stormwind)
--   Zap, a mage (22, online in Westfall)
--   Busy, a warrior (25, online in Westfall)
--   Me, a warrior (24, online in Westfall): the player
local function newGuild()
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/LfgNearby.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    local function add(key, class, level)
        partition:RecordCharacter(key, { name = key:gsub("^%l", string.upper), classToken = class, level = level })
    end
    add("bolt", "SHAMAN", 22)
    add("hammer", "PALADIN", 24)
    add("oldbolt", "WARRIOR", 60)
    partition:JoinPlayerOf("hammer", "bolt", "manual")
    partition:JoinPlayerOf("oldbolt", "bolt", "manual")
    partition:SetAlias(partition:GetCharacter("bolt").player, "Thunderer", "manual")
    add("cleric", "PRIEST", 20)
    add("zap", "MAGE", 22)
    add("busy", "WARRIOR", 25)
    add("me", "WARRIOR", 24)
    local world = {
        addon = addon,
        partition = partition,
        members = {
            bolt = { online = true, zone = "Ironforge", level = 22, name = "Bolt" },
            hammer = { online = false, name = "Hammer" },
            oldbolt = { online = false, name = "Oldbolt" },
            cleric = { online = true, zone = "Stormwind", level = 20, name = "Cleric" },
            zap = { online = true, zone = "Westfall", level = 22, name = "Zap" },
            busy = { online = true, zone = "Westfall", level = 25, name = "Busy" },
            me = { online = true, zone = "Westfall", level = 24, name = "Me" },
        },
    }
    function world.nearby(zone)
        return addon.LfgNearby.List({ partition = partition, members = world.members }, zone, "me")
    end
    return world
end

local function labels(list)
    local result = {}
    local index
    for index = 1, #list do
        result[index] = list[index].label
    end
    return table.concat(result, ", ")
end

local function names(characters)
    local result = {}
    local index
    for index = 1, #characters do
        result[index] = characters[index].name .. " " .. characters[index].level
    end
    return table.concat(result, ", ")
end

test.test("lfg nearby: online guildmates in the zone, at any level, without the player", function()
    local world = newGuild()
    world.members.oldbolt = { online = true, zone = "Westfall", level = 60, name = "Oldbolt" }

    local nearby = world.nearby("Westfall")

    test.assertEqual("Busy, Thunderer, Zap", labels(nearby))
    test.assertEqual("Oldbolt 60", names(nearby[2].characters))
    test.assertEqual(0, #world.nearby("Moonglade"))
    test.assertEqual(0, #world.nearby(nil))
end)

test.test("lfg nearby: one entry per player, with each of their characters there", function()
    local world = newGuild()
    world.members.hammer = { online = true, zone = "Ironforge", level = 24, name = "Hammer" }

    local nearby = world.nearby("Ironforge")

    test.assertEqual("Thunderer", labels(nearby))
    test.assertEqual("Bolt 22, Hammer 24", names(nearby[1].characters))
end)
