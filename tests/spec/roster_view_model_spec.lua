local test = require("tests.test_helper")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/RosterViewModel.lua"
    )
end

local function setup(addon)
    local store = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
    local partition = store:Partition({ name = "Knights", realm = "Camelot" })
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = true, homeRealm = "Camelot" })
    return partition, normalizer
end

-- Tool Box (alias TheTool) with alt Hammer Smith, plus single-character
-- player Zélie Rune.
local function seedGuild(partition)
    partition:RecordCharacter("tool box-camelot", { name = "Tool Box", classToken = "WARRIOR", level = 60, rankIndex = 1 })
    partition:RecordCharacter("hammer smith-camelot", { name = "Hammer Smith", classToken = "PALADIN", level = 42 })
    partition:RecordCharacter("zélie rune-camelot", { name = "Zélie Rune", classToken = "MAGE", level = 12 })
    partition:JoinPlayerOf("hammer smith-camelot", "tool box-camelot", "note")
    partition:SetAlias(partition:GetCharacter("tool box-camelot").player, "TheTool", "note")
end

local LIVE = {
    ["tool box-camelot"] = { name = "Tool Box", classToken = "WARRIOR", level = 60, rankName = "Officer",
        online = false, lastOnline = { years = 0, months = 0, days = 3, hours = 2 } },
    ["hammer smith-camelot"] = { name = "Hammer Smith", classToken = "PALADIN", level = 42,
        rankName = "Member", online = true, zone = "Ironforge" },
    ["zélie rune-camelot"] = { name = "Zélie Rune", classToken = "MAGE", level = 12, rankName = "Initiate",
        online = false },
}

local function build(addon, partition, normalizer, collapsed)
    return addon.RosterViewModel.Build({
        partition = partition,
        members = LIVE,
        normalizer = normalizer,
        classColor = function(token)
            return token == "WARRIOR" and "ffc69b6d" or nil
        end,
        collapsed = collapsed,
    })
end

test.test("view model groups characters under a header per player, main first and marked", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    seedGuild(partition)

    local rows = build(addon, partition, normalizer)

    test.assertEqual(5, #rows)
    test.assertEqual("player", rows[1].kind)
    test.assertEqual("TheTool (Tool Box)", rows[1].label)
    test.assertEqual(2, rows[1].count)
    test.assertEqual("Tool Box", rows[2].name)
    test.assertTrue(rows[2].isMain)
    test.assertEqual("Hammer Smith", rows[3].name)
    test.assertFalse(rows[3].isMain)
    test.assertEqual(rows[1].id, rows[3].player)
    test.assertEqual("player", rows[4].kind)
    test.assertEqual("Zélie Rune", rows[4].label)
    test.assertEqual("Zélie Rune", rows[5].name)
    test.assertTrue(rows[5].isMain)
end)

test.test("a player is online when any of its characters is", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    seedGuild(partition)

    local rows = build(addon, partition, normalizer)

    -- Only the alt Hammer Smith is online, which puts the player first.
    test.assertTrue(rows[1].online)
    test.assertFalse(rows[4].online)
end)

test.test("character rows show class-colored name, level, rank, and zone or last online", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    seedGuild(partition)

    local rows = build(addon, partition, normalizer)

    test.assertEqual("|cffc69b6dTool Box|r", rows[2].coloredName)
    test.assertEqual(60, rows[2].level)
    test.assertEqual("Officer", rows[2].rank)
    test.assertEqual("3 days ago", rows[2].location)
    test.assertEqual("Hammer Smith", rows[3].coloredName)
    test.assertEqual("Ironforge", rows[3].location)
end)

test.test("collapsed groups keep their header and hide their characters", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    seedGuild(partition)
    local toolPlayer = partition:GetCharacter("tool box-camelot").player

    local rows = build(addon, partition, normalizer, { [toolPlayer] = true })

    test.assertEqual(3, #rows)
    test.assertTrue(rows[1].collapsed)
    test.assertEqual("player", rows[2].kind)
end)

test.test("players without an alias are labeled by the main's name and sorted by label", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    partition:RecordCharacter("zed one-camelot", { name = "Zed One" })
    partition:RecordCharacter("anna two-camelot", { name = "Anna Two" })

    local rows = addon.RosterViewModel.Build({ partition = partition, normalizer = normalizer })

    test.assertEqual("Anna Two", rows[1].label)
    test.assertEqual("Zed One", rows[3].label)
end)

test.test("view model falls back to stored facts when live facts are missing", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    partition:RecordCharacter("tool box-camelot", { name = "Tool Box-Camelot", classToken = "WARRIOR",
        level = 60, rankIndex = 2 })

    local rows = addon.RosterViewModel.Build({ partition = partition, normalizer = normalizer })

    test.assertEqual("Tool Box", rows[2].name)
    test.assertEqual(60, rows[2].level)
    test.assertEqual("Rank 2", rows[2].rank)
    test.assertFalse(rows[2].online)
    test.assertEqual(nil, rows[2].location)
end)

test.test("last online text uses the largest unit", function()
    local format = load().RosterViewModel.FormatLastOnline

    test.assertEqual("1 year ago", format({ years = 1, months = 3, days = 0, hours = 0 }))
    test.assertEqual("2 months ago", format({ years = 0, months = 2, days = 5, hours = 0 }))
    test.assertEqual("1 hour ago", format({ years = 0, months = 0, days = 0, hours = 1 }))
    test.assertEqual("less than an hour ago", format({ years = 0, months = 0, days = 0, hours = 0 }))
    test.assertEqual(nil, format(nil))
end)
