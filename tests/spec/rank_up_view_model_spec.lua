local test = require("tests.test_helper")

-- The Rank management page's Due list, from the promotion rules engine.
local NOW = 1790000000
local DAY = 24 * 60 * 60
local OFFICER = "officer"
local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }

local function isOfficer(key)
    return key == OFFICER
end

-- A guild with Initiates (rank 4) needing 7 days in the guild and Read the
-- rules to become Members, and Members (rank 3) needing 7 days to become
-- Veterans. `characters` maps key -> { rank, days in the guild }.
local function newGuild(characters)
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/NoteParser.lua", "Core/FellowshipStore.lua",
        "Core/SyncFacts.lua", "Core/MembershipDates.lua", "Core/RankRequirements.lua", "Core/PromotionChecks.lua",
        "Core/PromotionPolicy.lua", "Core/RankUpViewModel.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} })
        :Partition({ name = "Knights of Camelot", realm = "Area 52" })
    local requirements = addon.RankRequirements.Create({}, { isOfficer = isOfficer })
    local checks = addon.PromotionChecks.Create({}, {
        isOfficer = isOfficer,
        rankOf = function(character)
            local record = partition:GetCharacter(character)
            return record and partition:IsInGuild(character) and record.rank or nil
        end,
    })
    local dates = addon.MembershipDates.Create({}, { isOfficer = isOfficer })
    local key, facts
    for key, facts in pairs(characters) do
        partition:RecordCharacter(key, { name = key, rankIndex = facts[1] })
        dates:Offer(key, "joined", { time = NOW - facts[2] * DAY, source = "log" })
    end
    requirements:SetAutomated(4, "char-guild-days", true, 7, RANKS[5], OFFICER, NOW)
    local rules = requirements:Add(4, "Read the rules", "check", RANKS[5], OFFICER, NOW)
    requirements:SetAutomated(3, "char-guild-days", true, 7, RANKS[4], OFFICER, NOW)
    local world = {
        addon = addon,
        inputs = { partition = partition, requirements = requirements, checks = checks, dates = dates, now = NOW,
            rankNames = RANKS },
        rules = rules[1],
    }
    function world.due(search)
        world.inputs.search = search
        return addon.RankUpViewModel.Due(world.inputs)
    end
    return world
end

local function names(view)
    local list = {}
    local index
    for index = 1, #view.rows do
        list[index] = view.rows[index].name .. " " .. view.rows[index].status
    end
    return table.concat(list, ", ")
end

local function rowOf(view, name)
    local index
    for index = 1, #view.rows do
        if view.rows[index].name == name then
            return view.rows[index]
        end
    end
    return nil
end

test.test("rank up view model: Due lists only players whose time is met, Ready first", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 }, early = { 4, 2 }, steady = { 3, 30 } })
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)
    local view = world.due()

    test.assertEqual("ready Ready, steady Ready, waiting Due", names(view))
    test.assertEqual(2, view.ready)
    test.assertEqual(1, view.due)
    test.assertEqual(3, view.count)
end)

test.test("rank up view model: a row names the rank promoted to, never current to next", function()
    local world = newGuild({ waiting = { 4, 30 }, steady = { 3, 30 } })
    local view = world.due()

    test.assertEqual("→ Member", rowOf(view, "waiting").rankText)
    test.assertEqual("Member", rowOf(view, "waiting").rankName)
    test.assertEqual(3, rowOf(view, "waiting").rank)
    test.assertEqual("→ Veteran", rowOf(view, "steady").rankText)
end)

test.test("rank up view model: a Due row says what it's waiting on", function()
    local world = newGuild({ waiting = { 4, 30 } })
    local row = rowOf(world.due(), "waiting")

    test.assertEqual("Read the rules", row.waitingText)
    test.assertEqual(nil, row.promote)
end)

test.test("rank up view model: a Ready row lists the characters to promote", function()
    local world = newGuild({ ready = { 4, 30 } })
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)
    local row = rowOf(world.due(), "ready")

    test.assertEqual("ready", row.promoteText)
    test.assertEqual(nil, row.waiting)
end)

test.test("rank up view model: a player with characters at different ranks is judged on the highest", function()
    -- High and Mid are Members, Low an Initiate, all one player: it's
    -- judged on High, the main among its highest-ranked.
    local world = newGuild({ high = { 3, 30 }, low = { 4, 1 }, mid = { 3, 1 } })
    world.inputs.partition:JoinPlayerOf("low", "high", "manual")
    world.inputs.partition:JoinPlayerOf("mid", "high", "manual")
    local view = world.due()

    test.assertEqual(1, #view.rows)
    local row = view.rows[1]
    test.assertEqual("high", row.key)
    test.assertEqual("→ Veteran", row.rankText)
    test.assertEqual("Ready", row.status)
    -- Every character below Veteran is promoted, the low alt too.
    test.assertEqual("high, low, mid", table.concat((function()
        local sorted = {}
        local index
        for index = 1, #row.promote do
            sorted[index] = row.promote[index]
        end
        table.sort(sorted)
        return sorted
    end)(), ", "))
end)

test.test("rank up view model: an alt already at the rank promoted to isn't listed to promote", function()
    local world = newGuild({ high = { 3, 30 }, twin = { 3, 1 } })
    world.inputs.partition:JoinPlayerOf("twin", "high", "manual")
    world.inputs.partition:SetMain(world.inputs.partition:GetCharacter("high").player, "high")
    -- The Members become Veterans: both are below Veteran.
    test.assertEqual(2, #world.due().rows[1].promote)

    local veteran = newGuild({ high = { 3, 30 }, vet = { 2, 1 } })
    veteran.inputs.partition:JoinPlayerOf("high", "vet", "manual")
    -- Judged on the Veteran, whose rank has no requirements: not listed.
    test.assertEqual(0, #veteran.due().rows)
end)

test.test("rank up view model: a snoozed player isn't due, but a ready one still shows", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 } })
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)
    world.inputs.checks:Snooze("waiting", 4, NOW + 7 * DAY, OFFICER, NOW)
    world.inputs.checks:Snooze("ready", 4, NOW + 7 * DAY, OFFICER, NOW)
    local view = world.due()

    test.assertEqual("ready Ready", names(view))
    test.assertEqual(0, view.due)
end)

test.test("rank up view model: search narrows the list by alias or character name, keeping the counts", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 }, alt = { 4, 1 } })
    world.inputs.partition:JoinPlayerOf("alt", "waiting", "manual")
    world.inputs.partition:SetAlias(world.inputs.partition:GetCharacter("ready").player, "Speedy", "manual")
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)

    test.assertEqual("Speedy Ready", names(world.due("speed")))
    test.assertEqual("waiting Due", names(world.due(" ALT ")))
    local none = world.due("zzz")
    test.assertEqual(0, #none.rows)
    test.assertEqual(2, none.count)
end)

test.test("rank up view model: the footer counts Ready and Due and says where promotion happens", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 }, other = { 4, 30 } })
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)

    test.assertEqual("1 Ready · 2 Due · Promotion happens on the guild roster, where the Ready arrow shows.",
        world.due().footer)
end)

test.test("rank up view model: nobody up for a rank leaves an empty list", function()
    local world = newGuild({ early = { 4, 1 } })
    local view = world.due()

    test.assertEqual(0, #view.rows)
    test.assertEqual("0 Ready · 0 Due · Promotion happens on the guild roster, where the Ready arrow shows.",
        view.footer)
end)
