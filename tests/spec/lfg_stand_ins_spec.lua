local test = require("tests.test_helper")

local function load()
    return test.newAddon("Core/DungeonCatalog.lua", "Core/LfgProtocol.lua", "Core/LfgListing.lua",
        "Core/ZoneLevels.lua", "Core/LfgRelevance.lua", "Core/LfgBoard.lua", "Core/LfgStandIns.lua")
end

local NOW = 1790000000

-- The board as `current` (with `alts`) sees the stand-ins: the case of
-- each listing on each tab.
local function sorted(addon, facts, current, alts)
    local board = addon.LfgBoard.Create()
    local listings, why = addon.LfgStandIns.Listings(facts)
    local cases = {}
    local index
    for index = 1, #listings do
        test.assertTrue(addon.LfgProtocol.IsValid(listings[index].message), listings[index].case .. " is valid")
        test.assertTrue(addon.LfgStandIns.IsStandIn(listings[index].key))
        cases[listings[index].key] = listings[index].case
        board:OnListing(listings[index].message, listings[index].key, listings[index].sender, NOW)
    end
    local groups = board:Groups(NOW, current, alts)
    local function names(list, field)
        local result = {}
        for index = 1, #list do
            local listing = field and list[index][field] or list[index]
            table.insert(result, cases[listing.id])
        end
        table.sort(result)
        return table.concat(result, ",")
    end
    return names(groups.relevant), names(groups.alts, "listing"), names(groups.other), why
end

test.test("lfg stand-ins: every case lands where it should for the character", function()
    local addon = load()
    local current = { level = 60, roles = { "tank", "dps" } }
    local alts = { { name = "Bolt", level = 24, roles = { "healer" } } }

    local relevant, forAlts, other, why = sorted(addon, {
        level = 60, alt = alts[1], dungeons = addon.DungeonCatalog.For("forever", nil),
    }, current, alts)

    test.assertEqual("note,raid,relevant", relevant)
    test.assertEqual("alts", forAlts)
    test.assertEqual("full,greyed", other)
    test.assertEqual(nil, why)
end)

test.test("lfg stand-ins: a low character with no alts gets every case but the alts one, and is told why", function()
    local addon = load()
    local current = { level = 12, roles = { "dps" } }

    local relevant, forAlts, other, why = sorted(addon, { level = 12 }, current, {})

    test.assertEqual("note,raid,relevant", relevant)
    test.assertEqual("", forAlts)
    test.assertEqual("full,greyed", other)
    test.assertContains(why, "alt")
end)

test.test("lfg stand-ins: the greyed listing misses every alt too, or is left out with a reason", function()
    local addon = load()
    -- Level 30 would get 55-60, which a level-57 alt fits.
    local current = { level = 30, roles = { "dps" } }
    local alts = { { name = "Bolt", level = 57, roles = { "dps" } } }

    local relevant, forAlts, other, why = sorted(addon, { level = 30, alt = alts[1], alts = alts }, current, alts)

    test.assertEqual("note,raid,relevant", relevant)
    test.assertEqual("alts", forAlts)
    test.assertEqual("full,greyed", other)
    test.assertEqual(nil, why)

    -- Alts at every level: no range is clear.
    local everyLevel = {}
    local level
    for level = 1, 80 do
        everyLevel[level] = { level = level }
    end
    local listings, note = addon.LfgStandIns.Listings({ level = 30, alts = everyLevel })
    local index
    for index = 1, #listings do
        test.assertFalse(listings[index].case == "greyed")
    end
    test.assertContains(note, "greyed")
end)

test.test("lfg stand-ins: the relevant ones carry a note, and only stand-in keys count as stand-ins", function()
    local addon = load()
    local listings = addon.LfgStandIns.Listings({ level = 40 })

    test.assertEqual("3 bosses down, 2 to go", listings[2].message.no)
    test.assertFalse(addon.LfgStandIns.IsStandIn("tool box-camelot"))
    test.assertFalse(addon.LfgStandIns.IsStandIn(nil))
    test.assertTrue(addon.LfgStandIns.Request().standIn)
    test.assertEqual("healer", addon.LfgStandIns.Party().slotRole)
end)
