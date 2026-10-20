local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Officers' ticks on promotion checklists, and the rules engine that turns
-- requirements and ticks into each character's progress.
local NOW = 1790000000
local OFFICER = "toolbox-area52"
local OTHER_OFFICER = "gm-area52"
local MEMBER = "hammer-area52"
local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }

local function isOfficer(key)
    return key == OFFICER or key == OTHER_OFFICER
end

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua",
        "Core/RankRequirements.lua",
        "Core/PromotionChecks.lua",
        "Core/PromotionPolicy.lua",
        "Core/PromotionsViewModel.lua"
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
    local inputs = { partition = partition, requirements = requirements, checks = checks, rankNames = RANKS }
    return inputs, addon
end

local function addItem(inputs, rank, label, kind)
    local records = inputs.requirements:Add(rank, label, kind or "check", RANKS[rank + 1], OFFICER, NOW)
    return records[1]
end

-- Ticks -------------------------------------------------------------------------

test.test("an officer ticks and unticks a character's item, and a needs-a-note item needs its note", function()
    local inputs = newGuild({ bolt = 4 })
    local plain = addItem(inputs, 4, "Read the rules")
    local noted = addItem(inputs, 4, "Attend an event", "check-note")
    local checks = inputs.checks

    test.assertTrue(checks:Set("bolt", plain, true, nil, OFFICER, NOW) ~= nil)
    test.assertTrue(checks:IsTicked("bolt", plain.id))
    test.assertTrue(checks:Set("bolt", plain, false, nil, OFFICER, NOW) ~= nil)
    test.assertFalse(checks:IsTicked("bolt", plain.id))
    test.assertEqual(NOW + 1, checks:Record("bolt", plain.id).at, "an untick in the same second still wins")

    local records, reason = checks:Set("bolt", noted, true, "  ", OFFICER, NOW)
    test.assertEqual(nil, records)
    test.assertEqual("this item needs a note", reason)
    test.assertEqual(nil, (checks:Set("bolt", noted, true, string.rep("x", 101), OFFICER, NOW)))
    test.assertTrue(checks:Set("bolt", noted, true, "Raid night, Oct 3", OFFICER, NOW) ~= nil)
    test.assertEqual("Raid night, Oct 3", checks:Record("bolt", noted.id).note)
    test.assertEqual(OFFICER, checks:Record("bolt", noted.id).by)
end)

test.test("only officers' ticks are accepted, and the newest wins", function()
    local inputs = newGuild({ bolt = 4 })
    local item = addItem(inputs, 4, "Read the rules")
    local checks = inputs.checks

    local _, reason = checks:Set("bolt", item, true, nil, MEMBER, NOW)
    test.assertEqual("only officers can tick promotion requirements", reason)
    local function record(ticked, at, by)
        return { t = "tick", character = "bolt", rank = 4, item = item.id, ticked = ticked, at = at, by = by }
    end
    test.assertFalse(checks:Apply(record(true, NOW, MEMBER)))
    test.assertTrue(checks:Apply(record(true, NOW + 5, OFFICER)))
    test.assertFalse(checks:Apply(record(false, NOW + 2, OTHER_OFFICER)), "older")
    test.assertTrue(checks:IsTicked("bolt", item.id))
    test.assertTrue(checks:Apply(record(false, NOW + 6, OTHER_OFFICER)))
    test.assertFalse(checks:IsTicked("bolt", item.id))
    test.assertFalse(checks:Apply("junk"))
end)

test.test("any rank change makes a character's ticks stale: ignored, pruned, and never sent", function()
    local inputs = newGuild({ bolt = 4, nail = 4 })
    local item = addItem(inputs, 4, "Read the rules")
    local checks = inputs.checks
    checks:Set("bolt", item, true, nil, OFFICER, NOW)
    checks:Set("nail", item, true, nil, OFFICER, NOW)
    test.assertEqual(2, #checks:Snapshot())

    -- Bolt is promoted (by the add-on or in the game's own UI).
    inputs.partition:RecordCharacter("bolt", { rankIndex = 3 })
    test.assertFalse(checks:IsTicked("bolt", item.id))
    test.assertEqual(1, #checks:Snapshot())
    test.assertFalse(checks:Apply({ t = "tick", character = "bolt", rank = 4, item = item.id, ticked = true,
        at = NOW + 10, by = OFFICER }), "a tick for the old rank arriving late")
    test.assertEqual(1, checks:Prune())
    -- Demoted back: the old ticks don't come back.
    inputs.partition:RecordCharacter("bolt", { rankIndex = 4 })
    test.assertFalse(checks:IsTicked("bolt", item.id))
    test.assertTrue(checks:IsTicked("nail", item.id))
end)

test.test("a snapshot covers what's held only with every current tick, as new or newer", function()
    local inputs = newGuild({ bolt = 4 })
    local other = newGuild({ bolt = 4 })
    local item = addItem(inputs, 4, "Read the rules")
    inputs.checks:Set("bolt", item, true, nil, OFFICER, NOW)

    test.assertTrue(inputs.checks:CoveredBy(inputs.checks:Snapshot()))
    test.assertFalse(inputs.checks:CoveredBy(other.checks:Snapshot()))
    test.assertTrue(other.checks:CoveredBy(inputs.checks:Snapshot()))
    test.assertFalse(inputs.checks:CoveredBy("junk"))
end)

-- The rules engine ----------------------------------------------------------------

test.test("each character at a rank with requirements gets its next rank, progress, and ready", function()
    local inputs, addon = newGuild({ boss = 0, officer = 1, vet = 2, bolt = 4, nail = 4, rivet = 3 })
    local first = addItem(inputs, 4, "Read the rules")
    local second = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 0, "Nothing above the top")
    inputs.checks:Set("bolt", first, true, nil, OFFICER, NOW)
    inputs.checks:Set("bolt", second, true, "Raid", OFFICER, NOW)
    inputs.checks:Set("nail", first, true, nil, OFFICER, NOW)

    local rows = addon.PromotionPolicy.List(inputs)
    test.assertEqual(2, #rows, "ranks without requirements, and the top rank, produce no rows")
    test.assertEqual("bolt", rows[1].key, "ready first")
    test.assertTrue(rows[1].ready)
    test.assertEqual("Initiate", rows[1].rankName)
    test.assertEqual("Member", rows[1].nextRankName)
    test.assertEqual(2, rows[1].met)
    test.assertEqual("nail", rows[2].key)
    test.assertEqual(1, rows[2].met)
    test.assertEqual(2, rows[2].total)
    test.assertFalse(rows[2].ready)
    test.assertEqual(nil, addon.PromotionPolicy.Evaluate(inputs, "boss"))
    test.assertEqual(nil, addon.PromotionPolicy.Evaluate(inputs, "rivet"))
end)

test.test("a character shows its player's highest rank when another character holds a higher one", function()
    local inputs, addon = newGuild({ main = 1, alt = 4, solo = 4 })
    addItem(inputs, 4, "Read the rules")
    inputs.partition:JoinPlayerOf("alt", "main", "manual")

    local alt = addon.PromotionPolicy.Evaluate(inputs, "alt")
    test.assertEqual(1, alt.highestRank)
    test.assertEqual("Officer", alt.highestRankName)
    test.assertEqual(nil, addon.PromotionPolicy.Evaluate(inputs, "solo").highestRank)
    -- A character who left doesn't count.
    inputs.partition:MarkDeparted("main", NOW)
    test.assertEqual(nil, addon.PromotionPolicy.Evaluate(inputs, "alt").highestRank)
end)

test.test("the list rows show each character, its checklist when open, and who ticked each item", function()
    local inputs, addon = newGuild({ bolt = 4 })
    local item = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 4, "Read the rules")
    inputs.checks:Set("bolt", item, true, "Raid night", OFFICER, NOW)
    local Model = addon.PromotionsViewModel
    local evaluated = addon.PromotionPolicy.List(inputs)

    local rows = Model.List(evaluated, { anyRequirements = true })
    test.assertEqual("heading", rows[1].kind)
    test.assertEqual("Initiate -> Member", rows[2].ranks)
    test.assertEqual("1 of 2", rows[2].progress)
    test.assertEqual("Open", rows[2].action)
    test.assertEqual(2, #rows)

    rows = Model.List(evaluated, {
        expanded = { bolt = true },
        nameOf = function(key)
            return key == OFFICER and "Toolbox" or key
        end,
        formatDate = function()
            return "2026-10-20"
        end,
    })
    test.assertEqual("Close", rows[2].action)
    test.assertEqual("item", rows[3].kind)
    test.assertTrue(rows[3].ticked)
    test.assertEqual("Untick", rows[3].action)
    test.assertEqual("Ticked by Toolbox on 2026-10-20", rows[3].tooltip[1])
    test.assertEqual("Note: Raid night", rows[3].tooltip[2])
    test.assertEqual("Tick", rows[4].action)
    test.assertEqual(nil, rows[4].tooltip)

    test.assertEqual(Model.NO_REQUIREMENTS, Model.List({}, {})[2].character)
    test.assertEqual(Model.NOBODY, Model.List({}, { anyRequirements = true })[2].character)
end)

-- In the composed add-on -----------------------------------------------------------

local NAMES = {
    Forever = { "Tool Box", "Hammer Smith", "Bolt Nut" },
    Retail = { "Toolbox-Area52", "Hammer-Area52", "Bolt-Area52" },
}

local function guild(profile)
    local names = NAMES[profile]
    return {
        name = "Knights of Camelot",
        realm = profile == "Retail" and "Area 52" or "Camelot",
        members = {
            { name = names[1], class = "WARRIOR", level = 60, rank = 1, rankName = "Officer", online = true,
                zone = "Ironforge" },
            { name = names[2], class = "MAGE", level = 42, rank = 3, rankName = "Member", online = true,
                zone = "Ironforge" },
            { name = names[3], class = "ROGUE", level = 12, rank = 4, rankName = "Initiate", online = false,
                zone = "Ironforge" },
        },
    }
end

local function login(profile, channel, playerName)
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = playerName })
    world.time = channel.time or world.time
    channel.time = world.time
    fixtures.joinChannel(channel, world)
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

local function settle(channel, seconds)
    local step
    for step = 1, seconds do
        local index
        for index = 1, #channel.worlds do
            fixtures.runTimers(channel.worlds[index], 1)
        end
        fixtures.deliver(channel)
    end
end

local function characterRow(rows, prefix)
    local index
    for index = 1, #rows do
        if rows[index].kind == "character" and string.find(rows[index].character, prefix, 1, true) then
            return rows[index], index
        end
    end
    return nil
end

for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]
    local names = NAMES[profile]

    test.test(profile .. " an officer ticks a checklist item with a note, and it reaches a member's add-on", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel, 5)
        local promotions = tool.addon.promotions

        local empty = promotions.listRows()
        test.assertEqual(tool.addon.PromotionsViewModel.NO_REQUIREMENTS, empty[2].character)
        test.assertTrue(promotions.add("Attend an event", true))
        local rows = promotions.listRows()
        local bolt = characterRow(rows, "Bolt")
        test.assertEqual("0 of 1", bolt.progress)
        test.assertTrue(promotions.expand(bolt.key))
        rows = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        local item = rows[at + 1]
        local ok, reason = promotions.tick(item.key, item.item, true, "")
        test.assertFalse(ok)
        test.assertEqual("this item needs a note", reason)
        test.assertTrue(promotions.tick(item.key, item.item, true, "Raid night"))
        test.assertEqual("1 of 1", characterRow(promotions.listRows(), "Bolt").progress)
        settle(channel, 5)

        local memberRows = hammer.addon.promotions.listRows()
        test.assertEqual("1 of 1", characterRow(memberRows, "Bolt").progress)
        test.assertContains(characterRow(memberRows, "Bolt").character, "Ready")
        local refused, why = hammer.addon.promotions.tick(item.key, item.item, false)
        test.assertFalse(refused)
        test.assertEqual("only officers can tick promotion requirements", why)

        -- Bolt is promoted in the game's own guild UI: the next scan finds
        -- the new rank, and its ticks are gone.
        tool.guild.members[3].rank = 3
        tool.guild.members[3].rankName = "Member"
        tool.addon.rosterController:Rescan()
        fixtures.fire(tool, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(tool, 5)
        test.assertEqual(nil, characterRow(promotions.listRows(), "Bolt"))
        local _, partition = tool.addon.rosterController:QuietContext()
        test.assertEqual(0, #tool.addon.PromotionChecks.Create(partition:GetPromotionChecks(), {}):Snapshot())
    end)
end
