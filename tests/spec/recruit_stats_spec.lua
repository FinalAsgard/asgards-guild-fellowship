local test = require("tests.test_helper")

local START = 1790000000
local DAY = 24 * 60 * 60

local function load()
    return test.newAddon("Core/RecruitStats.lua")
end

test.test("recruit stats: a report replaces the held record only when its total is higher", function()
    local addon = load()
    local saved = {}
    local stats = addon.RecruitStats.Create(saved)

    test.assertTrue(stats:File("anvil-area52", { n = 5, t = { START } }))
    test.assertFalse(stats:File("anvil-area52", { n = 4, t = { START, START + 1 } }))
    test.assertFalse(stats:File("anvil-area52", { n = 5, t = {} }))
    test.assertEqual(5, saved["anvil-area52"].n)
    test.assertTrue(stats:File("anvil-area52", { n = 6, t = { START, START + 60 } }))
    test.assertEqual(6, saved["anvil-area52"].n)
    test.assertEqual(2, #saved["anvil-area52"].t)
end)

test.test("recruit stats: malformed reports are ignored", function()
    local addon = load()
    local stats = addon.RecruitStats.Create({})

    test.assertFalse(stats:File("anvil-area52", "lots"))
    test.assertFalse(stats:File("anvil-area52", { n = -1, t = {} }))
    test.assertFalse(stats:File("anvil-area52", { n = 1.5, t = {} }))
    test.assertFalse(stats:File("anvil-area52", { n = 2, t = { "yesterday" } }))
    test.assertFalse(stats:File("anvil-area52", { n = 2 }))
    test.assertFalse(stats:File(nil, { n = 2, t = {} }))
end)

test.test("recruit stats: a player's characters add up to their highest record", function()
    local addon = load()
    local stats = addon.RecruitStats.Create({})
    -- The same account's record, heard from its main and later its alt.
    stats:File("anvil-area52", { n = 3, t = { START } })
    stats:File("tongs-area52", { n = 7, t = { START, START + 1 } })

    test.assertEqual(7, stats:Best({ "anvil-area52", "tongs-area52" }).n)
    test.assertEqual(nil, stats:Best({ "bolt-area52" }))
end)

test.test("recruit stats: the 30-day count falls as ads age out, with no new report", function()
    local addon = load()
    local record = { n = 9, t = { START, START + 10 * DAY, START + 20 * DAY } }

    test.assertEqual("Advertised: 9 (3 in last 30 days)", addon.RecruitStats.Line(record, START + 20 * DAY))
    test.assertEqual("Advertised: 9 (2 in last 30 days)", addon.RecruitStats.Line(record, START + 30 * DAY))
    test.assertEqual("Advertised: 9 (0 in last 30 days)", addon.RecruitStats.Line(record, START + 60 * DAY))
    test.assertEqual(nil, addon.RecruitStats.Line(nil, START))
end)

test.test("recruit stats: the user's own record counts each ad and drops old times", function()
    local addon = load()
    local record = { n = 0, t = {} }

    local report = addon.RecruitStats.AddOwn(record, START)
    test.assertEqual(1, record.n)
    test.assertEqual(1, report.n)
    addon.RecruitStats.AddOwn(record, START + 31 * DAY)
    test.assertEqual(2, record.n)
    test.assertEqual(1, #record.t)
    test.assertEqual(START + 31 * DAY, record.t[1])
    -- The report sent is a copy.
    test.assertEqual(1, #report.t)

    local broken = { n = "lots" }
    addon.RecruitStats.AddOwn(broken, START)
    test.assertEqual(1, broken.n)
end)

-- A partition with just the parts the Recruiters view reads: players (id ->
-- { main, alias }) and their characters (key -> { name }).
local function fakePartition(players, characters, owners)
    local partition = {}
    function partition:EachPlayer(callback)
        local ids = {}
        local id
        for id in pairs(players) do
            table.insert(ids, id)
        end
        table.sort(ids)
        local index
        for index = 1, #ids do
            callback(ids[index], players[ids[index]])
        end
    end
    function partition:CharactersOf(id)
        return owners[id]
    end
    function partition:GetCharacter(key)
        return characters[key]
    end
    return partition
end

test.test("recruiters: players are ranked by 30-day count, then all time, labelled by alias or main", function()
    local addon = load()
    local partition = fakePartition({
        [1] = { main = "anvil-area52", alias = "Rip" },
        [2] = { main = "bolt-area52" },
        [3] = { main = "cog-area52" },
        [4] = { main = "dent-area52" },
        [5] = { main = "quiet-area52" },
    }, {
        ["anvil-area52"] = { name = "Anvil-Area52" },
        ["bolt-area52"] = { name = "Bolt-Area52" },
        ["cog-area52"] = { name = "Cog-Area52" },
        ["dent-area52"] = { name = "Dent-Area52" },
        ["quiet-area52"] = { name = "Quiet-Area52" },
    }, {
        [1] = { "anvil-area52", "tongs-area52" },
        [2] = { "bolt-area52" },
        [3] = { "cog-area52" },
        [4] = { "dent-area52" },
        [5] = { "quiet-area52" },
    })
    local records = {
        ["anvil-area52"] = { n = 4, t = { START, START + 1 } },
        ["bolt-area52"] = { n = 9, t = { START } },
        ["cog-area52"] = { n = 20, t = { START, START + 1 } },
        -- All of Dent's ads are older than 30 days.
        ["dent-area52"] = { n = 50, t = {} },
    }
    local normalizer = {
        Display = function(_, name)
            return (string.gsub(name, "%-Area52$", ""))
        end,
    }

    local rows = addon.RecruitStats.Recruiters({
        partition = partition,
        normalizer = normalizer,
        recordOf = function(keys)
            return records[keys[1]]
        end,
        now = START + 2,
    })

    test.assertEqual(4, #rows)
    test.assertEqual("Cog", rows[1].label)
    test.assertEqual(2, rows[1].recent)
    test.assertEqual(20, rows[1].total)
    test.assertEqual("Rip", rows[2].label)
    test.assertEqual(2, rows[2].recent)
    test.assertEqual("Bolt", rows[3].label)
    test.assertEqual("Dent", rows[4].label)
    test.assertEqual(0, rows[4].recent)
    test.assertEqual(50, rows[4].total)
end)

test.test("recruit stats: a report can't claim more recent ads than its total, or future ones", function()
    local addon = load()
    local stats = addon.RecruitStats.Create({})

    test.assertFalse(stats:File("anvil-area52", { n = 1, t = { START, START, START } }))
    test.assertTrue(stats:File("anvil-area52", { n = 3, t = { START, START + 60, START + 10 * DAY } }))
    -- The ad dated ten days ahead doesn't count as recent.
    test.assertEqual("Advertised: 3 (2 in last 30 days)",
        addon.RecruitStats.Line(stats:Best({ "anvil-area52" }), START + 120))
end)

test.test("recruit stats: the user's own summary counts all ads and those of the last 30 days", function()
    local stats = load().RecruitStats
    local now = 1790000000
    local day = 24 * 60 * 60

    test.assertEqual("You haven't posted a guild ad yet.", stats.OwnSummary(nil, now))
    test.assertEqual("You haven't posted a guild ad yet.", stats.OwnSummary({ n = 0, t = {} }, now))
    test.assertEqual("You haven't posted a guild ad yet.", stats.OwnSummary({ n = "lots", t = {} }, now))
    test.assertEqual("You've posted 1 guild ad (1 in the last 30 days).",
        stats.OwnSummary({ n = 1, t = { now - day } }, now))
    test.assertEqual("You've posted 12 guild ads (2 in the last 30 days).",
        stats.OwnSummary({ n = 12, t = { now - 40 * day, now - 2 * day, now } }, now))
end)
