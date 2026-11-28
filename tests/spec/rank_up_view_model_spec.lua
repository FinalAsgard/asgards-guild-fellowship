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
    -- Judged on the Veteran, whose rank has no requirements: no Ready or Due
    -- row, but High is brought up to match.
    local view = veteran.due()
    test.assertEqual(1, #view.rows)
    test.assertEqual("Match", view.rows[1].status)
    test.assertEqual("high", view.rows[1].promoteText)
end)

test.test("rank up view model: a snoozed player isn't due, but a ready one still shows", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 } })
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)
    world.inputs.checks:Snooze("waiting", 4, NOW + 7 * DAY, OFFICER, NOW)
    world.inputs.checks:Snooze("ready", 4, NOW + 7 * DAY, OFFICER, NOW)
    local view = world.due()

    test.assertEqual("ready Ready", names(view))
    test.assertEqual(0, view.due)
    test.assertEqual(1, view.snoozed)
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

-- Snoozes and Match -------------------------------------------------------------

test.test("rank up view model: the footer counts snoozed players", function()
    local world = newGuild({ a = { 4, 30 }, b = { 4, 30 }, c = { 4, 30 } })
    world.inputs.checks:Snooze("a", 4, NOW + 7 * DAY, OFFICER, NOW)
    world.inputs.checks:Snooze("b", 4, NOW + 7 * DAY, OFFICER, NOW)
    local view = world.due()

    test.assertEqual("c Due", names(view))
    test.assertEqual(2, view.snoozed)
    test.assertEqual("0 Ready · 1 Due · 2 snoozed · Promotion happens on the guild roster, where the Ready arrow shows.",
        view.footer)
end)

test.test("rank up view model: a snooze that ended puts the player back on Due", function()
    local world = newGuild({ a = { 4, 30 } })
    world.inputs.checks:Snooze("a", 4, NOW - 1, OFFICER, NOW - 8 * DAY)

    test.assertEqual("a Due", names(world.due()))
    test.assertEqual(0, world.due().snoozed)
end)

test.test("rank up view model: alts below their player's rank show as Match with the characters to bring up", function()
    -- Boss is a Veteran (no requirements at rank 2); Grunt and Peon, its
    -- alts, are a Member and an Initiate.
    local world = newGuild({ boss = { 2, 30 }, grunt = { 3, 1 }, peon = { 4, 1 } })
    world.inputs.partition:JoinPlayerOf("grunt", "boss", "manual")
    world.inputs.partition:JoinPlayerOf("peon", "boss", "manual")
    local view = world.due()

    test.assertEqual("boss Match", names(view))
    local row = view.rows[1]
    test.assertEqual("→ Veteran", row.rankText)
    test.assertEqual("grunt, peon", row.promoteText)
    test.assertEqual(1, view.match)
    test.assertEqual(1, view.count)
    test.assertEqual("0 Ready · 1 Match · 0 Due · Promotion happens on the guild roster, where the Ready arrow shows.",
        view.footer)
end)

test.test("rank up view model: no Match for a rank whose alts needn't match", function()
    local world = newGuild({ boss = { 2, 30 }, grunt = { 3, 1 } })
    world.inputs.partition:JoinPlayerOf("grunt", "boss", "manual")
    world.inputs.requirements:SetMatchesAlts(2, false, OFFICER, NOW)

    test.assertEqual(0, #world.due().rows)
end)

test.test("rank up view model: Match comes after Ready and before Due, and a snooze hides it", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 }, boss = { 2, 30 }, grunt = { 3, 1 } })
    world.inputs.partition:JoinPlayerOf("grunt", "boss", "manual")
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)

    test.assertEqual("ready Ready, boss Match, waiting Due", names(world.due()))
    world.inputs.checks:Snooze("boss", 2, NOW + 7 * DAY, OFFICER, NOW)
    test.assertEqual("ready Ready, waiting Due", names(world.due()))
end)

test.test("rank up view model: a player not yet due still gets a Match row for alts behind", function()
    -- Lead is a Member a day in, with an Initiate alt: not due Veteran, but
    -- the alt is brought up to Member.
    local world = newGuild({ lead = { 3, 1 }, alt = { 4, 1 } })
    world.inputs.partition:JoinPlayerOf("alt", "lead", "manual")
    local view = world.due()

    test.assertEqual("lead Match", names(view))
    test.assertEqual("→ Member", view.rows[1].rankText)
    test.assertEqual("alt", view.rows[1].promoteText)
end)

-- The rank grid ------------------------------------------------------------------

local function cellOf(row, label, view)
    local index
    for index = 1, #view.columns do
        if view.columns[index].label == label then
            return row.cells[index]
        end
    end
    return nil
end

test.test("rank up view model: the Promote to picker lists Any rank and each rank with requirements, by the rank promoted to", function()
    local world = newGuild({})
    local targets = world.addon.RankUpViewModel.Targets(world.inputs)

    test.assertEqual(3, #targets)
    test.assertEqual("Any rank", targets[1].text)
    test.assertEqual(nil, targets[1].rank)
    -- The newest members' rank first: Initiates become Members.
    test.assertEqual("→ Member", targets[2].text)
    test.assertEqual(3, targets[2].rank)
    test.assertEqual("→ Veteran", targets[3].text)
    test.assertEqual(2, targets[3].rank)
end)

test.test("rank up view model: picking a rank keeps only the players up for it, with one column per requirement in order", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 }, steady = { 3, 30 }, boss = { 2, 30 },
        grunt = { 3, 1 } })
    world.inputs.partition:JoinPlayerOf("grunt", "boss", "manual")
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)
    world.inputs.rank = 3
    local view = world.due()

    test.assertEqual("ready Ready, waiting Due", names(view))
    test.assertEqual(2, #view.columns)
    test.assertEqual("In the guild 7 days", view.columns[1].label)
    test.assertFalse(view.columns[1].check)
    test.assertEqual("Read the rules", view.columns[2].label)
    test.assertTrue(view.columns[2].check)
    test.assertEqual(2, #view.rows[1].cells)
    test.assertEqual("1 Ready · 1 Due · Promotion happens on the guild roster, where the Ready arrow shows.",
        view.footer)

    world.inputs.rank = nil
    local any = world.due()
    test.assertEqual(nil, any.columns)
    test.assertEqual(nil, any.rows[1].cells)
end)

test.test("rank up view model: grid cells for every requirement kind", function()
    local world = newGuild({ alt = { 4, 30 } })
    local addon, inputs = world.addon, world.inputs
    local requirements, partition = inputs.requirements, inputs.partition
    partition:RecordCharacter("lead", { name = "lead", rankIndex = 4, level = 66 })
    partition:JoinPlayerOf("alt", "lead", "manual")
    requirements:SetAutomated(4, "player-guild-days", true, 30, RANKS[5], OFFICER, NOW)
    requirements:SetAutomated(4, "rank-days", true, 7, RANKS[5], OFFICER, NOW)
    requirements:SetAutomated(4, "level", true, 70, RANKS[5], OFFICER, NOW)
    requirements:SetAutomated(4, "addon", true, nil, RANKS[5], OFFICER, NOW)
    requirements:SetAutomated(4, "discord", true, nil, RANKS[5], OFFICER, NOW)
    requirements:Add(4, "Interview", "check-note", RANKS[5], OFFICER, NOW)
    -- Lead's join date is approximate. (A Due player's time is always met:
    -- one not met keeps them off the list.)
    inputs.dates:Offer("lead", "joined", { time = NOW - 44 * DAY, source = "first-seen" })
    inputs.dates:Offer("lead", "rankSince", { time = NOW - 10 * DAY, rank = 4, source = "log" })
    inputs.checks:Set("lead", world.rules, true, nil, OFFICER, NOW)
    inputs.rank = 3
    local view = world.due()
    local row = view.rows[1]
    local Model = addon.RankUpViewModel

    test.assertEqual(8, #view.columns)
    local days = cellOf(row, "In the guild 7 days", view)
    test.assertEqual(Model.MET, days.state)
    test.assertEqual("≈44 d", days.text)
    local player = cellOf(row, "Player in the guild 30 days", view)
    test.assertEqual(Model.MET, player.state)
    test.assertEqual("≈44 d", player.text)
    local rank = cellOf(row, "At this rank 7 days", view)
    test.assertEqual(Model.MET, rank.state)
    test.assertEqual("10 d", rank.text)
    local level = cellOf(row, "Level 70", view)
    test.assertEqual(Model.MISSING, level.state)
    test.assertEqual("level 66", level.text)
    local seen = cellOf(row, "Has the Guild Fellowship Addon", view)
    test.assertEqual(Model.MISSING, seen.state)
    test.assertEqual("not seen", seen.text)
    local discord = cellOf(row, "Has a Discord name set", view)
    test.assertEqual(Model.MISSING, discord.state)
    test.assertEqual("not set", discord.text)
    local rules = cellOf(row, "Read the rules", view)
    test.assertTrue(rules.check)
    test.assertTrue(rules.checked)
    test.assertEqual(Model.TICKED, rules.state)
    local interview = cellOf(row, "Interview", view)
    test.assertTrue(interview.check)
    test.assertFalse(interview.checked)
    test.assertEqual(Model.UNTICKED, interview.state)

    -- Seen on sync, with a Discord name, and an officer's override on the
    -- level.
    inputs.dates:Heard("alt", NOW - 3 * DAY)
    partition:SetProfileText("lead", "discord", "lead#1234", NOW, "lead")
    inputs.checks:Set("lead", requirements:ItemOfKind(4, "level"), true, "Levels on the alt", OFFICER, NOW)
    view = world.due()
    row = view.rows[1]
    test.assertEqual("seen 3 d ago", cellOf(row, "Has the Guild Fellowship Addon", view).text)
    test.assertEqual(Model.MET, cellOf(row, "Has the Guild Fellowship Addon", view).state)
    test.assertEqual("lead#1234", cellOf(row, "Has a Discord name set", view).text)
    test.assertEqual(Model.OVERRIDDEN, cellOf(row, "Level 70", view).state)
    test.assertEqual("met by override", cellOf(row, "Level 70", view).text)
    test.assertEqual("Levels on the alt", cellOf(row, "Level 70", view).note)
    test.assertEqual("officer", cellOf(row, "Level 70", view).by)

    -- An unknown date: the time isn't met, so Lead is off the list, and
    -- the cell would say so.
    test.assertEqual("unknown", select(3, addon.PromotionPolicy.STATUS["rank-days"](
        { dates = { RankSince = function() end }, now = NOW }, "lead", { n = 7 }, { rank = 4 })))
end)

test.test("rank up view model: a kind the grid doesn't know is still a column", function()
    local world = newGuild({ waiting = { 4, 30 } })
    local addon = world.addon
    -- A kind #352 might add: automated, judged by its own rule.
    local Requirements = addon.RankRequirements
    local isAutomated = Requirements.IsAutomated
    Requirements.IsAutomated = function(kind)
        return kind == "future" or isAutomated(kind)
    end
    addon.PromotionPolicy.STATUS.future = function()
        return true, "sighted on Discord", "sighted"
    end
    local items = world.inputs.requirements:Items(4)
    local itemsOf = world.inputs.requirements.Items
    world.inputs.requirements.Items = function(self, rank)
        local list = itemsOf(self, rank)
        if rank == 4 then
            table.insert(list, { id = "future-1", label = "Seen on Discord", kind = "future" })
        end
        return list
    end
    world.inputs.rank = 3
    local view = world.due()
    Requirements.IsAutomated = isAutomated

    test.assertEqual(#items + 1, #view.columns)
    test.assertEqual("Seen on Discord", view.columns[#view.columns].label)
    local cell = view.rows[1].cells[#view.columns]
    test.assertEqual(addon.RankUpViewModel.MET, cell.state)
    test.assertEqual("sighted", cell.text)
end)

test.test("rank up view model: a ticked check shows its note, else who ticked it", function()
    local world = newGuild({ waiting = { 4, 30 } })
    local inputs = world.inputs
    local interview = inputs.requirements:Add(4, "Interview", "check-note", RANKS[5], OFFICER, NOW)[1]
    inputs.rank = 3
    local view = world.due()
    local row = view.rows[1]

    test.assertTrue(cellOf(row, "Interview", view).needsNote)
    test.assertFalse(cellOf(row, "Read the rules", view).needsNote)
    test.assertEqual("", cellOf(row, "Interview", view).text)

    inputs.checks:Set("waiting", world.rules, true, nil, OFFICER, NOW)
    inputs.checks:Set("waiting", interview, true, "Talked on Discord", OFFICER, NOW)
    view = world.due()
    row = view.rows[1]
    test.assertEqual("by officer", cellOf(row, "Read the rules", view).text)
    test.assertEqual("\"Talked on Discord\"", cellOf(row, "Interview", view).text)
    test.assertEqual("Talked on Discord", cellOf(row, "Interview", view).note)

    -- Unticked, it says nothing.
    inputs.checks:Set("waiting", world.rules, false, nil, OFFICER, NOW + 1)
    view = world.due()
    test.assertEqual("", cellOf(view.rows[1], "Read the rules", view).text)
end)

-- The Missing filter ----------------------------------------------------------------

local function choiceOf(choices, text)
    local index
    for index = 1, #choices do
        if choices[index].text == text then
            return choices[index]
        end
    end
    return nil
end

test.test("rank up view model: Missing lists the picked rank's requirements, or every rank's for Any rank", function()
    local world = newGuild({})
    world.inputs.rank = 3
    local choices = world.addon.RankUpViewModel.MissingChoices(world.inputs)

    test.assertEqual(2, #choices)
    test.assertEqual("In the guild 7 days", choices[1].text)
    test.assertEqual("Read the rules", choices[2].text)
    test.assertEqual(world.rules.id, choices[2].id)
    test.assertEqual(3, choices[2].rank)

    world.inputs.rank = nil
    choices = world.addon.RankUpViewModel.MissingChoices(world.inputs)
    test.assertEqual(3, #choices)
    -- The newest members' rank first, each named by the rank promoted to.
    test.assertEqual("In the guild 7 days (→ Member)", choices[1].text)
    test.assertEqual("Read the rules (→ Member)", choices[2].text)
    test.assertEqual("Read the rules", choices[2].label)
    test.assertEqual("In the guild 7 days (→ Veteran)", choices[3].text)
    test.assertEqual(2, choices[3].rank)
end)

test.test("rank up view model: Missing keeps the Due players missing it, counted out of everyone up for the rank", function()
    local world = newGuild({ ready = { 4, 30 }, waiting = { 4, 30 }, other = { 4, 30 }, early = { 4, 2 },
        steady = { 3, 30 }, boss = { 2, 30 }, grunt = { 3, 1 } })
    world.inputs.partition:JoinPlayerOf("grunt", "boss", "manual")
    world.inputs.checks:Set("ready", world.rules, true, nil, OFFICER, NOW)
    world.inputs.missing = choiceOf(world.addon.RankUpViewModel.MissingChoices(world.inputs),
        "Read the rules (→ Member)")
    local view = world.due()

    -- No Ready, no Match, nobody up for another rank.
    test.assertEqual("other Due, waiting Due", names(view))
    test.assertEqual(2, view.missing.count)
    test.assertEqual(3, view.missing.of)
    test.assertEqual("2 of 3 players due → Member are missing: Read the rules · Promotion happens on the guild "
        .. "roster, where the Ready arrow shows.", view.footer)

    -- The same with the rank picked, and the counts ignore the search.
    world.inputs.rank = 3
    view = world.due("oth")
    test.assertEqual("other Due", names(view))
    test.assertEqual(2, view.missing.count)
    test.assertEqual(3, view.missing.of)
end)

test.test("rank up view model: Missing for one player says is, and a met requirement leaves nobody", function()
    local world = newGuild({ waiting = { 4, 30 } })
    local choices = world.addon.RankUpViewModel.MissingChoices(world.inputs)
    world.inputs.missing = choiceOf(choices, "Read the rules (→ Member)")

    test.assertEqual("1 of 1 player due → Member is missing: Read the rules · Promotion happens on the guild "
        .. "roster, where the Ready arrow shows.", world.due().footer)

    world.inputs.missing = choiceOf(choices, "In the guild 7 days (→ Member)")
    local view = world.due()
    test.assertEqual("", names(view))
    test.assertEqual(0, view.missing.count)
    test.assertEqual(1, view.missing.of)
end)
