local test = require("tests.test_helper")

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- A guild partition with Toolbox (alias "TheTool", alts Hammer and Nail),
-- Anvil, and Bolt. `live` sets roster facts by character name.
local function setup(live)
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/RosterViewModel.lua",
        "Core/PlayerPanelViewModel.lua", "Core/LfgHistoryView.lua", "Core/PlayerDetailViewModel.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local world = { addon = addon, partition = partition, keys = {}, members = {}, grouped = {} }
    local _, entry
    for _, entry in ipairs({
        { "Toolbox", "WARRIOR", 60 }, { "Hammer", "PALADIN", 40 }, { "Nail", "PRIEST", 20 }, { "Anvil", "MAGE", 52 },
        { "Bolt", "ROGUE", 60 },
    }) do
        local name = entry[1]
        local key = normalizer:Key(name .. "-Area52")
        partition:RecordCharacter(key, { name = name .. "-Area52", classToken = entry[2], level = entry[3] })
        local member = { name = name .. "-Area52", classToken = entry[2], level = entry[3], rankName = "Member" }
        local field, value
        for field, value in pairs((live or {})[name] or {}) do
            member[field] = value
        end
        world.members[key] = member
        world.keys[name] = key
    end
    partition:JoinPlayerOf(world.keys.Hammer, world.keys.Toolbox, "manual")
    partition:JoinPlayerOf(world.keys.Nail, world.keys.Toolbox, "manual")
    partition:SetAlias(partition:GetCharacter(world.keys.Toolbox).player, "TheTool", "manual")
    function world.playerOf(name)
        return partition:GetCharacter(world.keys[name]).player
    end
    function world.build(name, extra)
        local fields = {
            partition = partition,
            playerId = world.playerOf(name),
            members = world.members,
            normalizer = normalizer,
            formatDate = function(at)
                return "day " .. at
            end,
            classColor = function(classToken)
                return "ff" .. string.lower(string.sub(classToken, 1, 6))
            end,
            className = function(classToken)
                return string.upper(string.sub(classToken, 1, 1)) .. string.lower(string.sub(classToken, 2))
            end,
            friendKeys = partition:GetFriends(),
            grouped = function()
                return world.grouped[name] and world.grouped[name][1] or 0, world.grouped[name] and world.grouped[name][2]
            end,
        }
        local field, value
        for field, value in pairs(extra or {}) do
            fields[field] = value
        end
        return addon.PlayerDetailViewModel.Build(fields)
    end
    return world
end

test.test("player detail view model: the header shows the alias, the main in class color, and their facts", function()
    local world = setup({ Toolbox = { rankName = "Officer", online = true, zone = "Ironforge" } })
    local header = world.build("Hammer", {
        raceOf = function(key)
            return key == world.keys.Toolbox and "Dwarf" or nil
        end,
    }).header

    test.assertEqual("TheTool", header.name)
    test.assertEqual("TheTool", header.alias)
    test.assertEqual("Toolbox", header.mainName)
    test.assertEqual("ffwarrio", header.color)
    test.assertEqual("Level 60 Dwarf Warrior · Officer", header.facts)
    test.assertEqual("Online, Ironforge", header.status)
    test.assertTrue(header.online)
    test.assertEqual(world.keys.Toolbox, header.key)
end)

test.test("player detail view model: with no alias the main's name is big; an unknown race is left out", function()
    local world = setup()
    local header = world.build("Bolt").header

    test.assertEqual("Bolt", header.name)
    test.assertEqual(nil, header.alias)
    test.assertEqual("Level 60 Rogue · Member", header.facts)
end)

test.test("player detail view model: offline shows when they were last online, from their latest character", function()
    local world = setup({
        Toolbox = { lastOnline = { years = 0, months = 0, days = 5, hours = 0 } },
        Nail = { lastOnline = { years = 0, months = 0, days = 2, hours = 3 } },
    })
    local header = world.build("Toolbox").header

    test.assertFalse(header.online)
    test.assertEqual("Last online 2 days ago", header.status)
    test.assertEqual(nil, header.target)
end)

test.test("player detail view model: Whisper and Invite reach the online main first, else an online alt", function()
    local world = setup({ Toolbox = { online = true }, Nail = { online = true, zone = "Duskwood" } })
    test.assertEqual("Toolbox-Area52", world.build("Toolbox").header.target)

    world.members[world.keys.Toolbox].online = false
    local header = world.build("Toolbox").header
    test.assertEqual("Nail-Area52", header.target)
    test.assertEqual("Online, Duskwood", header.status)

    -- An online alt who left the guild can't be reached through the guild.
    world.partition:MarkDeparted(world.keys.Nail, 1790000000)
    test.assertEqual(nil, world.build("Toolbox").header.target)
end)

test.test("player detail view model: the badge is Friend for a pinned player, else Most grouped with its place", function()
    local world = setup()
    local mostGrouped = { { player = world.playerOf("Anvil"), count = 9 }, { player = world.playerOf("Bolt"), count = 4 } }

    local bolt = world.build("Bolt", { mostGrouped = mostGrouped }).header
    test.assertEqual("top", bolt.badge.kind)
    test.assertEqual(2, bolt.badge.rank)
    test.assertFalse(bolt.isFriend)
    test.assertTrue(bolt.canToggle)
    test.assertEqual(nil, world.build("Toolbox", { mostGrouped = mostGrouped }).header.badge)

    world.partition:AddFriend(world.keys.Hammer)
    local tool = world.build("Toolbox", { mostGrouped = mostGrouped }).header
    test.assertEqual("friend", tool.badge.kind)
    test.assertTrue(tool.isFriend)
    test.assertFalse(tool.full)
end)

test.test("player detail view model: with every slot taken, the star can remove a Friend but not add anyone", function()
    local world = setup()
    local _, name
    for _, name in ipairs({ "Toolbox", "Anvil" }) do
        world.partition:AddFriend(world.keys[name])
    end
    -- Three more players, out of this world's roster, fill the slots.
    for _, name in ipairs({ "X1", "X2", "X3" }) do
        local key = name .. "-area52"
        world.partition:RecordCharacter(key, { name = name .. "-Area52", classToken = "MAGE", level = 10 })
        world.partition:AddFriend(key)
    end

    local bolt = world.build("Bolt").header
    test.assertTrue(bolt.full)
    test.assertFalse(bolt.canToggle)
    test.assertTrue(world.build("Anvil").header.canToggle)
end)

test.test("player detail view model: the tiles, with Not set and Never when a fact is missing", function()
    local world = setup()
    local tiles = world.build("Bolt").tiles

    test.assertEqual("Discord", tiles[1].label)
    test.assertEqual("Not set", tiles[1].value)
    test.assertTrue(tiles[1].notSet)
    test.assertEqual("Never", tiles[2].value)
    test.assertTrue(tiles[2].notSet)
    test.assertEqual("Never", tiles[3].value)
    test.assertEqual("Joined guild", tiles[4].label)
    test.assertEqual("Not set", tiles[4].value)
    test.assertTrue(tiles[4].notSet)

    world.partition:SetProfileText(world.keys.Bolt, "discord", "bolt1", 1790000000, world.keys.Bolt)
    world.grouped.Bolt = { 1, 1790000000 }
    tiles = world.build("Bolt", {
        joined = function()
            return "2026-10-01"
        end,
    }).tiles
    test.assertEqual("bolt1", tiles[1].value)
    test.assertFalse(tiles[1].notSet)
    test.assertEqual("1 time", tiles[2].value)
    test.assertEqual("day 1790000000", tiles[3].value)
    test.assertFalse(tiles[3].notSet)
    test.assertEqual("2026-10-01", tiles[4].value)

    -- A join date nobody knows is not set.
    test.assertTrue(world.build("Bolt", {
        joined = function()
            return "unknown"
        end,
    }).tiles[4].notSet)
end)

test.test("player detail view model: a player who no longer exists has no view", function()
    local world = setup()
    local fields = world.build("Bolt")
    test.assertTrue(fields ~= nil)
    test.assertEqual(nil, world.addon.PlayerDetailViewModel.Build({
        partition = world.partition,
        playerId = "nobody",
        members = {},
    }))
end)

test.test("player detail view model: Characters lists in-guild characters, main first, leaving out departed ones", function()
    local world = setup({ Nail = { online = true, zone = "Duskwood" } })
    world.partition:MarkDeparted(world.keys.Hammer, 1790000000)
    local characters = world.build("Nail", {
        rolesOf = function(key)
            return key == world.keys.Toolbox and "Tank, DPS" or nil
        end,
    }).characters

    test.assertEqual(2, #characters)
    test.assertEqual("Toolbox", characters[1].name)
    test.assertTrue(characters[1].isMain)
    test.assertEqual("Warrior", characters[1].className)
    test.assertEqual(60, characters[1].level)
    test.assertEqual("Tank, DPS", characters[1].roles)
    test.assertEqual("ffwarrio", characters[1].color)
    test.assertEqual("Nail", characters[2].name)
    test.assertFalse(characters[2].isMain)
    test.assertEqual("Online, Duskwood", characters[2].status)
end)

test.test("player detail view model: Grouped shows only parties with this player, newest first, their characters marked", function()
    local world = setup()
    local entries = {
        { at = 100, characters = { world.keys.Hammer, world.keys.Anvil } },
        { at = 200, characters = { world.keys.Bolt, world.keys.Anvil } },
        { at = 300, characters = { world.keys.Nail, world.keys.Bolt }, dungeon = "Deadmines" },
    }
    local grouped = world.build("Toolbox", {
        history = function()
            return entries
        end,
        historyMember = function(key)
            local character = world.partition:GetCharacter(key)
            return { name = string.match(character.name, "^[^%-]+"), whisper = character.name }
        end,
    }).grouped

    test.assertEqual(2, grouped.total)
    test.assertFalse(grouped.more)
    test.assertEqual(300, grouped.parties[1].at)
    test.assertEqual("Deadmines", grouped.parties[1].place)
    test.assertEqual("Nail", grouped.parties[1].members[1].name)
    test.assertTrue(grouped.parties[1].members[1].theirs)
    test.assertFalse(grouped.parties[1].members[2].theirs)
    test.assertEqual(100, grouped.parties[2].at)
    test.assertEqual(nil, grouped.parties[2].place)
end)

test.test("player detail view model: Grouped is paged as the LFG History is, and says so when there's nothing", function()
    local world = setup()
    local entries = {}
    local index
    for index = 1, 25 do
        entries[index] = { at = index, characters = { world.keys.Bolt } }
    end
    local function build(shown)
        return world.build("Bolt", {
            groupedShown = shown,
            history = function()
                return entries
            end,
            historyMember = function()
                return { name = "Bolt", whisper = "Bolt-Area52" }
            end,
        }).grouped
    end

    local first = build(nil)
    test.assertEqual(20, #first.parties)
    test.assertTrue(first.more)
    test.assertEqual(25, first.total)
    local all = build(40)
    test.assertEqual(25, #all.parties)
    test.assertFalse(all.more)

    local none = world.build("Toolbox").grouped
    test.assertEqual(0, none.total)
    test.assertEqual("You haven't grouped with TheTool yet", none.empty)
end)

test.test("player detail view model: Bio and Log are the old player panel's rows, unchanged", function()
    local world = setup()
    world.partition:SetProfileText(world.keys.Bolt, "bio", "Likes boats", 1790000000, world.keys.Bolt)
    local fields = {
        adStats = function()
            return "Posted 3 ads"
        end,
    }
    local view = world.build("Bolt", fields)
    local old = world.addon.PlayerPanelViewModel.Build({
        partition = world.partition,
        playerId = world.playerOf("Bolt"),
        members = world.members,
        normalizer = world.addon.NameNormalizer.Create(RULES),
        formatDate = function(at)
            return "day " .. at
        end,
        adStats = fields.adStats,
        grouped = function()
            return 0
        end,
    })

    test.assertEqual(#old.logRows, #view.logRows)
    local index
    for index = 1, #old.logRows do
        test.assertEqual(old.logRows[index].text, view.logRows[index].text)
        test.assertEqual(old.logRows[index].kind, view.logRows[index].kind)
    end
    test.assertEqual("Posted 3 ads", view.logRows[1].text)
    test.assertEqual(#old.bioRows, #view.bioRows)
    test.assertEqual("Likes boats", view.bioRows[4].text)
end)
