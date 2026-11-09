local test = require("tests.test_helper")

-- The promotion rules engine's checks, judged through Evaluate and
-- ReadySet.
local NOW = 1790000000
local OFFICER = "toolbox-area52"
local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }

local function isOfficer(key)
    return key == OFFICER
end

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua",
        "Core/MembershipDates.lua",
        "Core/RankRequirements.lua",
        "Core/PromotionChecks.lua",
        "Core/PromotionPolicy.lua"
    )
end

-- A guild whose characters (key -> rank) are all in the guild, with the
-- requirements and ticks stores.
local function newGuild(characters)
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} })
        :Partition({ name = "Knights of Camelot", realm = "Area 52" })
    local key, rank
    for key, rank in pairs(characters) do
        partition:RecordCharacter(key, { name = key, rankIndex = rank })
    end
    local requirements = addon.RankRequirements.Create({}, { isOfficer = isOfficer })
    local checks = addon.PromotionChecks.Create({}, {
        isOfficer = isOfficer,
        rankOf = function(character)
            local record = partition:GetCharacter(character)
            return record and partition:IsInGuild(character) and record.rank or nil
        end,
    })
    local dates = addon.MembershipDates.Create({}, { isOfficer = isOfficer })
    return { partition = partition, requirements = requirements, checks = checks, dates = dates, now = NOW,
        rankNames = RANKS }, addon
end

local function statusOf(inputs, addon, key, id)
    local row = addon.PromotionPolicy.Evaluate(inputs, key)
    local index
    for index = 1, #row.items do
        if row.items[index].id == id then
            return row.items[index], row
        end
    end
    return nil, row
end

local function discordCheck(inputs, rank)
    return inputs.requirements:SetAutomated(rank, "discord", true, nil, RANKS[rank + 1], OFFICER, NOW)[1]
end

test.test("the Discord check passes with a name on any of the player's characters", function()
    local inputs, addon = newGuild({ main = 2, alt = 4, solo = 4 })
    local item = discordCheck(inputs, 4)
    inputs.partition:JoinPlayerOf("alt", "main", "manual")
    inputs.partition:SetProfileText("main", "discord", "bolt#1234", NOW - 60, "main")

    local alt = statusOf(inputs, addon, "alt", item.id)
    test.assertTrue(alt.met, "the alt counts the name set on its main")
    test.assertTrue(alt.automated)
    test.assertEqual("bolt#1234", alt.detail)

    local solo = statusOf(inputs, addon, "solo", item.id)
    test.assertFalse(solo.met)
    test.assertEqual("not set", solo.detail)
    inputs.partition:SetProfileText("solo", "discord", "x", NOW, "solo")
    test.assertTrue(statusOf(inputs, addon, "solo", item.id).met, "any name counts, as soon as it's saved")
end)

test.test("the Discord check fails again when the name is cleared or blank", function()
    local inputs, addon = newGuild({ main = 4, alt = 4 })
    local item = discordCheck(inputs, 4)
    inputs.partition:JoinPlayerOf("alt", "main", "manual")
    inputs.partition:SetProfileText("main", "discord", "bolt", NOW - 60, "main")
    test.assertTrue(statusOf(inputs, addon, "main", item.id).met)

    inputs.partition:SetProfileText("alt", "discord", "", NOW, "alt")
    local cleared = statusOf(inputs, addon, "main", item.id)
    test.assertFalse(cleared.met, "the newest change clears it for the whole player")
    test.assertEqual("not set", cleared.detail)
    inputs.partition:SetProfileText("alt", "discord", "   ", NOW + 1, "alt")
    test.assertFalse(statusOf(inputs, addon, "alt", item.id).met, "spaces aren't a name")
end)

test.test("an officer's override passes a failed Discord check, and it counts toward ready", function()
    local inputs, addon = newGuild({ quiet = 4, named = 4 })
    local item = discordCheck(inputs, 4)
    inputs.partition:SetProfileText("named", "discord", "named", NOW, "named")

    test.assertTrue(addon.PromotionPolicy.ReadySet(inputs).named, "met, so ready")
    test.assertEqual(nil, addon.PromotionPolicy.ReadySet(inputs).quiet)
    test.assertTrue(inputs.checks:Set("quiet", item, true, "On Discord already", OFFICER, NOW) ~= nil)
    local status, row = statusOf(inputs, addon, "quiet", item.id)
    test.assertTrue(status.met)
    test.assertTrue(status.overridden)
    test.assertEqual("not set", status.detail, "the detail still says what the data shows")
    test.assertTrue(row.ready)
    test.assertTrue(addon.PromotionPolicy.ReadySet(inputs).quiet)

    -- Turning the check off and on again starts it fresh, without the
    -- override.
    inputs.requirements:SetAutomated(4, "discord", false, nil, RANKS[5], OFFICER, NOW + 1)
    local again = inputs.requirements:SetAutomated(4, "discord", true, nil, RANKS[5], OFFICER, NOW + 2)[1]
    test.assertFalse(statusOf(inputs, addon, "quiet", again.id).met)
end)

-- Matching alts ----------------------------------------------------------------

-- A guild of players: each list's first character is the main, the rest
-- its alts (key -> rank, in `ranks`).
local function newPlayers(ranks, players)
    local inputs, addon = newGuild(ranks)
    local index
    for index = 1, #players do
        local others
        for others = 2, #players[index] do
            inputs.partition:JoinPlayerOf(players[index][others], players[index][1], "manual")
        end
    end
    return inputs, addon
end

test.test("an alt below its player's highest rank is matched to that rank", function()
    local inputs, addon = newPlayers({ main = 2, alt = 4, other = 3 }, { { "main", "alt" } })
    local Policy = addon.PromotionPolicy

    test.assertEqual(2, Policy.MatchTarget(inputs, "alt"))
    test.assertEqual(nil, Policy.MatchTarget(inputs, "main"), "the main is at the ceiling")
    test.assertEqual(nil, Policy.MatchTarget(inputs, "other"), "a player with one character")
    test.assertEqual(nil, Policy.MatchTarget(inputs, "nobody"))

    inputs.partition:RecordCharacter("alt", { rankIndex = 2 })
    test.assertEqual(nil, Policy.MatchTarget(inputs, "alt"), "the flag clears once the alt reaches the rank")
end)

test.test("the player's highest character is the one with the top rank, the main on a tie", function()
    -- The main's key sorts after its alts', so it wins a tie by being the
    -- main, not by its name.
    local inputs, addon = newPlayers({ zmain = 3, alt = 1, third = 4, solo = 2 }, { { "zmain", "alt", "third" } })
    local Policy = addon.PromotionPolicy
    local player = inputs.partition:GetCharacter("zmain").player

    local key, rank = Policy.HighestCharacter(inputs.partition, player)
    test.assertEqual("alt", key)
    test.assertEqual(1, rank)

    inputs.partition:RecordCharacter("zmain", { rankIndex = 1 })
    key = Policy.HighestCharacter(inputs.partition, player)
    test.assertEqual("zmain", key, "the main wins a tie")
    test.assertEqual(1, Policy.HighestRank(inputs.partition, player))
end)

test.test("an alt that outranks the main sets the target", function()
    local inputs, addon = newPlayers({ main = 4, alt = 1, third = 3 }, { { "main", "alt", "third" } })

    test.assertEqual(1, addon.PromotionPolicy.MatchTarget(inputs, "main"))
    test.assertEqual(1, addon.PromotionPolicy.MatchTarget(inputs, "third"))
    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "alt"))
end)

test.test("the guild master's alts are matched to the rank below the guild master's", function()
    local inputs, addon = newPlayers({ boss = 0, bank = 1, alt = 3 }, { { "boss", "bank", "alt" } })

    test.assertEqual(1, addon.PromotionPolicy.MatchTarget(inputs, "alt"))
    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "bank"), "already as high as alts go")
    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "boss"))
end)

test.test("characters out of the guild neither set the target nor get one", function()
    local inputs, addon = newPlayers({ main = 1, alt = 3, low = 4 }, { { "main", "alt", "low" } })
    inputs.partition:MarkDeparted("main", NOW)

    test.assertEqual(3, addon.PromotionPolicy.MatchTarget(inputs, "low"), "the departed main doesn't count")
    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "alt"))
    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "main"))
end)

test.test("an alt whose rank has no requirements still gets a target", function()
    local inputs, addon = newPlayers({ main = 2, alt = 4 }, { { "main", "alt" } })
    inputs.requirements:Add(3, "Read the rules", "check", RANKS[4], OFFICER, NOW)

    test.assertEqual(nil, addon.PromotionPolicy.Evaluate(inputs, "alt"), "no checklist at the alt's rank")
    test.assertEqual(2, addon.PromotionPolicy.MatchTarget(inputs, "alt"))
end)

test.test("the match set holds every in-guild character with a target", function()
    local inputs, addon = newPlayers({ main = 2, alt = 4, alt2 = 2, boss = 0, bank = 3, solo = 4, gone = 4 },
        { { "main", "alt", "alt2", "gone" }, { "boss", "bank" } })
    inputs.partition:MarkDeparted("gone", NOW)

    local set = addon.PromotionPolicy.MatchSet(inputs)
    local keys = {}
    local key
    for key in pairs(set) do
        table.insert(keys, key)
    end
    table.sort(keys)
    test.assertEqual("alt,bank", table.concat(keys, ","))
    test.assertEqual(2, set.alt)
    test.assertEqual(1, set.bank)
end)

test.test("ranks with matching off are skipped for the next one that's on", function()
    local inputs, addon = newPlayers({ main = 1, alt = 4 }, { { "main", "alt" } })
    local Policy = addon.PromotionPolicy

    inputs.requirements:SetMatchesAlts(1, false, OFFICER, NOW)
    test.assertEqual(2, Policy.MatchTarget(inputs, "alt"), "Officer is off: Veteran is next")
    inputs.requirements:SetMatchesAlts(2, false, OFFICER, NOW)
    test.assertEqual(3, Policy.MatchTarget(inputs, "alt"))
    inputs.requirements:SetMatchesAlts(1, true, OFFICER, NOW + 1)
    test.assertEqual(1, Policy.MatchTarget(inputs, "alt"), "turned back on")
end)

test.test("no flag when every rank in range has matching off", function()
    local inputs, addon = newPlayers({ main = 2, alt = 4, alt2 = 3, other = 1, low = 4 },
        { { "main", "alt", "alt2" }, { "other", "low" } })
    inputs.requirements:SetMatchesAlts(2, false, OFFICER, NOW)
    inputs.requirements:SetMatchesAlts(3, false, OFFICER, NOW)

    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "alt"))
    test.assertEqual(nil, addon.PromotionPolicy.MatchTarget(inputs, "alt2"))
    test.assertEqual(1, addon.PromotionPolicy.MatchTarget(inputs, "low"), "other players' ranks still count")

    local set = addon.PromotionPolicy.MatchSet(inputs)
    test.assertEqual(nil, set.alt)
    test.assertEqual(nil, set.alt2)
    test.assertEqual(1, set.low)
    test.assertEqual(nil, next(set, next(set)), "low is the only one")
end)
