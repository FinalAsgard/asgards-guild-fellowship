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

test.test("view model rows show class-colored name, level, rank, and zone or last online", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    partition:RecordCharacter("tool box-camelot", { classToken = "WARRIOR", level = 60, rankIndex = 1 })
    partition:RecordCharacter("hammer smith-camelot", { classToken = "PALADIN", level = 42, rankIndex = 3 })
    local members = {
        ["tool box-camelot"] = { name = "Tool Box-Camelot", classToken = "WARRIOR", level = 60,
            rankName = "Officer", online = true, zone = "Ironforge" },
        ["hammer smith-camelot"] = { name = "Hammer Smith-Camelot", classToken = "PALADIN", level = 42,
            rankName = "Member", online = false, lastOnline = { years = 0, months = 0, days = 3, hours = 2 } },
    }

    local rows = addon.RosterViewModel.Build({
        partition = partition,
        members = members,
        normalizer = normalizer,
        classColor = function(token)
            return token == "WARRIOR" and "ffc69b6d" or nil
        end,
    })

    test.assertEqual(2, #rows)
    test.assertEqual("character", rows[1].kind)
    test.assertEqual("Tool Box", rows[1].name)
    test.assertEqual("|cffc69b6dTool Box|r", rows[1].coloredName)
    test.assertEqual(60, rows[1].level)
    test.assertEqual("Officer", rows[1].rank)
    test.assertTrue(rows[1].online)
    test.assertEqual("Ironforge", rows[1].location)
    test.assertEqual("Hammer Smith", rows[2].coloredName)
    test.assertEqual("3 days ago", rows[2].location)
end)

test.test("view model sorts online first, then by display name", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    local names = { "zed one-camelot", "anna two-camelot", "mike three-camelot" }
    local index
    for index = 1, #names do
        partition:RecordCharacter(names[index], {})
    end

    local rows = addon.RosterViewModel.Build({
        partition = partition,
        members = {
            ["zed one-camelot"] = { name = "Zed One", online = true },
            ["anna two-camelot"] = { name = "Anna Two", online = false },
            ["mike three-camelot"] = { name = "Mike Three", online = false },
        },
        normalizer = normalizer,
    })

    test.assertEqual("Zed One", rows[1].name)
    test.assertEqual("Anna Two", rows[2].name)
    test.assertEqual("Mike Three", rows[3].name)
end)

test.test("view model falls back to stored facts when live facts are missing", function()
    local addon = load()
    local partition, normalizer = setup(addon)
    partition:RecordCharacter("tool box-camelot", { classToken = "WARRIOR", level = 60, rankIndex = 2 })

    local rows = addon.RosterViewModel.Build({ partition = partition, normalizer = normalizer })

    test.assertEqual("tool box-camelot", rows[1].name)
    test.assertEqual(60, rows[1].level)
    test.assertEqual("Rank 2", rows[1].rank)
    test.assertFalse(rows[1].online)
    test.assertEqual(nil, rows[1].location)
end)

test.test("last online text uses the largest unit", function()
    local format = load().RosterViewModel.FormatLastOnline

    test.assertEqual("1 year ago", format({ years = 1, months = 3, days = 0, hours = 0 }))
    test.assertEqual("2 months ago", format({ years = 0, months = 2, days = 5, hours = 0 }))
    test.assertEqual("1 hour ago", format({ years = 0, months = 0, days = 0, hours = 1 }))
    test.assertEqual("less than an hour ago", format({ years = 0, months = 0, days = 0, hours = 0 }))
    test.assertEqual(nil, format(nil))
end)
