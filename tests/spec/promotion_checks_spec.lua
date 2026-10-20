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
        "Core/MembershipDates.lua",
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
    local dates = addon.MembershipDates.Create({}, { isOfficer = isOfficer })
    local inputs = { partition = partition, requirements = requirements, checks = checks, dates = dates, now = NOW,
        rankNames = RANKS }
    return inputs, addon
end

local function addItem(inputs, rank, label, kind, n)
    local records = inputs.requirements:Add(rank, label, kind or "check", RANKS[rank + 1], OFFICER, NOW, n)
    return records[1]
end

local DAY = 24 * 60 * 60

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

-- Automated items -------------------------------------------------------------------

local function itemOf(row, id)
    local index
    for index = 1, #row.items do
        if row.items[index].id == id then
            return row.items[index]
        end
    end
end

test.test("character days in guild count from the join, with before tracking passing and first-seen approximate",
    function()
    local inputs, addon = newGuild({ bolt = 4, nail = 4, rivet = 4, screw = 4 })
    local item = addItem(inputs, 4, "", "char-guild-days", 7)
    test.assertEqual("In the guild 7 days", item.label, "a blank label says what the check is")
    inputs.dates:Offer("bolt", "joined", { time = NOW - 5 * DAY - 60, source = "log" })
    inputs.dates:Offer("nail", "joined", { time = NOW - 9 * DAY, source = "log" })
    inputs.dates:Offer("rivet", "joined", { time = NOW - 2 * DAY, source = "before-tracking" })

    local bolt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id)
    test.assertFalse(bolt.met)
    test.assertTrue(bolt.automated)
    test.assertEqual("5 of 7 days", bolt.detail)
    local nail = itemOf(addon.PromotionPolicy.Evaluate(inputs, "nail"), item.id)
    test.assertTrue(nail.met)
    test.assertEqual("9 days (needs 7)", nail.detail)
    local rivet = itemOf(addon.PromotionPolicy.Evaluate(inputs, "rivet"), item.id)
    test.assertTrue(rivet.met)
    test.assertEqual("before tracking", rivet.detail)
    local screw = itemOf(addon.PromotionPolicy.Evaluate(inputs, "screw"), item.id)
    test.assertFalse(screw.met)
    test.assertEqual("join date unknown", screw.detail)
    inputs.dates:Offer("screw", "joined", { time = NOW - 3 * DAY, source = "first-seen" })
    test.assertEqual("3 of 7 days (approx.)", itemOf(addon.PromotionPolicy.Evaluate(inputs, "screw"), item.id).detail)
end)

test.test("player days in guild count from the earliest join among the player's characters still in the guild",
    function()
    local inputs, addon = newGuild({ main = 2, alt = 4, gone = 4 })
    local item = addItem(inputs, 4, "", "player-guild-days", 30)
    inputs.partition:JoinPlayerOf("alt", "main", "manual")
    inputs.partition:JoinPlayerOf("gone", "main", "manual")
    inputs.dates:Offer("alt", "joined", { time = NOW - 1 * DAY, source = "live" })
    inputs.dates:Offer("main", "joined", { time = NOW - 40 * DAY, source = "log" })
    inputs.dates:Offer("gone", "joined", { time = NOW - 400 * DAY, source = "log" })
    inputs.partition:MarkDeparted("gone", NOW)

    local alt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "alt"), item.id)
    test.assertTrue(alt.met)
    test.assertEqual("40 days (needs 30)", alt.detail, "the main's join, not the departed character's")
    inputs.partition:MarkDeparted("main", NOW)
    alt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "alt"), item.id)
    test.assertFalse(alt.met)
    test.assertEqual("1 of 30 days", alt.detail)
    inputs.dates:Offer("alt", "joined", { time = NOW - 1 * DAY, source = "before-tracking" })
    test.assertEqual("1 of 30 days", itemOf(addon.PromotionPolicy.Evaluate(inputs, "alt"), item.id).detail,
        "a before-tracking mark doesn't replace a real join")
end)

test.test("days at rank count only the record for the character's current rank", function()
    local inputs, addon = newGuild({ bolt = 4, nail = 4 })
    local item = addItem(inputs, 4, "", "rank-days", 14)
    inputs.dates:Offer("bolt", "rankSince", { time = NOW - 3 * DAY, rank = 4, source = "log" })
    inputs.dates:Offer("nail", "rankSince", { time = NOW - 30 * DAY, rank = 3, source = "log" })

    local bolt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id)
    test.assertFalse(bolt.met)
    test.assertEqual("3 of 14 days", bolt.detail)
    local nail = itemOf(addon.PromotionPolicy.Evaluate(inputs, "nail"), item.id)
    test.assertFalse(nail.met, "a date for another rank doesn't count")
    test.assertEqual("rank date unknown", nail.detail)
    inputs.dates:Offer("nail", "rankSince", { time = NOW - 2 * DAY, rank = 4, source = "seen" })
    test.assertEqual("2 of 14 days (approx.)", itemOf(addon.PromotionPolicy.Evaluate(inputs, "nail"), item.id).detail)
    inputs.dates = addon.MembershipDates.Create({}, {})
    inputs.dates:Offer("bolt", "rankSince", { time = NOW, rank = 4, source = "before-tracking" })
    bolt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id)
    test.assertTrue(bolt.met)
    test.assertEqual("before tracking", bolt.detail)
end)

test.test("a level item compares the character's level", function()
    local inputs, addon = newGuild({ bolt = 4, nail = 4, rivet = 4 })
    local item = addItem(inputs, 4, "", "level", 50)
    test.assertEqual("Level 50", item.label)
    inputs.partition:RecordCharacter("bolt", { level = 42 })
    inputs.partition:RecordCharacter("nail", { level = 60 })

    local bolt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id)
    test.assertFalse(bolt.met)
    test.assertEqual("level 42 of 50", bolt.detail)
    test.assertEqual("level 60 (needs 50)", itemOf(addon.PromotionPolicy.Evaluate(inputs, "nail"), item.id).detail)
    test.assertEqual("level unknown", itemOf(addon.PromotionPolicy.Evaluate(inputs, "rivet"), item.id).detail)
end)

test.test("an officer overrides a failed automated item with an optional reason, and can remove it", function()
    local inputs, addon = newGuild({ bolt = 4 })
    local item = addItem(inputs, 4, "", "level", 50)
    inputs.partition:RecordCharacter("bolt", { level = 42 })
    local checks = inputs.checks

    test.assertEqual(nil, (checks:Set("bolt", item, true, "Old friend", MEMBER, NOW)), "officers only")
    test.assertTrue(checks:Set("bolt", item, true, "  Old friend ", OFFICER, NOW) ~= nil)
    local row = addon.PromotionPolicy.Evaluate(inputs, "bolt")
    local status = itemOf(row, item.id)
    test.assertTrue(status.met)
    test.assertTrue(status.overridden)
    test.assertEqual("level 42 of 50", status.detail, "the detail still says what the data shows")
    test.assertTrue(row.ready)

    local Model = addon.PromotionsViewModel
    local rows = Model.List({ row }, {
        expanded = { bolt = true },
        nameOf = function(key)
            return key == OFFICER and "Toolbox" or key
        end,
        formatDate = function()
            return "2026-10-20"
        end,
    })
    test.assertEqual("level 42 of 50", rows[3].ranks)
    test.assertEqual("overridden", rows[3].progress)
    test.assertEqual("Undo override", rows[3].action)
    test.assertEqual("Overridden by Toolbox on 2026-10-20", rows[3].tooltip[1])
    test.assertEqual("Reason: Old friend", rows[3].tooltip[2])

    test.assertTrue(checks:Set("bolt", item, false, nil, OTHER_OFFICER, NOW) ~= nil)
    row = addon.PromotionPolicy.Evaluate(inputs, "bolt")
    test.assertFalse(itemOf(row, item.id).met)
    rows = Model.List({ row }, { expanded = { bolt = true } })
    test.assertEqual("Override", rows[3].action)
    test.assertTrue(rows[3].askReason)
    test.assertContains(rows[3].tooltip[1], "Override removed by")

    -- No reason is needed, and a met item offers no override.
    test.assertTrue(checks:Set("bolt", item, true, nil, OFFICER, NOW) ~= nil)
    test.assertTrue(itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id).overridden)
    checks:Set("bolt", item, false, nil, OFFICER, NOW)
    inputs.partition:RecordCharacter("bolt", { level = 55 })
    rows = Model.List({ addon.PromotionPolicy.Evaluate(inputs, "bolt") }, { expanded = { bolt = true } })
    test.assertEqual(nil, rows[3].action)
end)

test.test("the add-on check passes when any of the player's characters was heard within N days", function()
    local inputs, addon = newGuild({ main = 2, alt = 4, solo = 4, quiet = 4 })
    local records = inputs.requirements:Add(4, "", "addon", RANKS[5], OFFICER, NOW)
    local item = records[1]
    test.assertEqual(30, item.n, "the window defaults to 30 days")
    test.assertEqual("Has the add-on (seen in 30 days)", item.label)
    inputs.partition:JoinPlayerOf("alt", "main", "manual")
    inputs.dates:Heard("main", NOW - 3 * DAY - 60)
    inputs.dates:Heard("solo", NOW - 45 * DAY)

    local alt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "alt"), item.id)
    test.assertTrue(alt.met, "the alt counts its main's add-on")
    test.assertEqual("seen 3 days ago", alt.detail)
    local solo = itemOf(addon.PromotionPolicy.Evaluate(inputs, "solo"), item.id)
    test.assertFalse(solo.met)
    test.assertEqual("seen 45 days ago", solo.detail)
    local quiet = itemOf(addon.PromotionPolicy.Evaluate(inputs, "quiet"), item.id)
    test.assertFalse(quiet.met)
    test.assertEqual("add-on not seen", quiet.detail)
    inputs.dates:Heard("quiet", NOW)
    test.assertEqual("seen today", itemOf(addon.PromotionPolicy.Evaluate(inputs, "quiet"), item.id).detail)
    inputs.dates:Heard("solo", NOW - DAY)
    test.assertEqual("seen 1 day ago", itemOf(addon.PromotionPolicy.Evaluate(inputs, "solo"), item.id).detail)
end)

-- The list at scale ------------------------------------------------------------------

local function keysOf(rows)
    local keys = {}
    local index
    for index = 1, #rows do
        table.insert(keys, rows[index].key)
    end
    return table.concat(keys, ",")
end

test.test("the list shows ready characters at first, and in progress and each rank only when ticked", function()
    local inputs, addon = newGuild({ bolt = 4, nail = 4, rivet = 3, screw = 3, vet = 2 })
    local initiate = addItem(inputs, 4, "Read the rules")
    local member = addItem(inputs, 3, "Attend an event")
    inputs.checks:Set("nail", initiate, true, nil, OFFICER, NOW)
    inputs.checks:Set("screw", member, true, nil, OFFICER, NOW)
    local Query = addon.PromotionPolicy.Query

    local result = Query(inputs)
    test.assertEqual("screw,nail", keysOf(result.rows), "ready only, the higher rank first")
    test.assertEqual(2, result.ready)
    test.assertEqual(4, result.all)
    test.assertEqual("3,4", table.concat(result.ranks, ","), "ranks with requirements, highest first")

    result = Query(inputs, { filters = { ready = true, progress = true } })
    test.assertEqual("screw,nail,rivet,bolt", keysOf(result.rows), "ready first, then rank, then name")
    result = Query(inputs, { filters = { progress = true } })
    test.assertEqual("rivet,bolt", keysOf(result.rows))
    result = Query(inputs, { filters = { ready = true, progress = true, hiddenRanks = { [3] = true } } })
    test.assertEqual("nail,bolt", keysOf(result.rows))
    test.assertEqual(2, result.ready, "the ready count ignores the filters")
    result = Query(inputs, { filters = {} })
    test.assertEqual(0, #result.rows)
    test.assertEqual(1, result.pages)
end)

test.test("a search matches a character's name, its player's alias, or any of the player's characters", function()
    local inputs, addon = newGuild({ main = 1, bolt = 4, nail = 4, solo = 4 })
    addItem(inputs, 4, "Read the rules")
    inputs.partition:JoinPlayerOf("bolt", "main", "manual")
    inputs.partition:SetAlias(inputs.partition:GetCharacter("main").player, "Sparky", "manual")
    local Matches = addon.PromotionPolicy.Matches
    local all = { filters = { ready = true, progress = true } }

    test.assertEqual(nil, Matches(inputs.partition, "  "))
    local function search(text)
        all.matches = Matches(inputs.partition, text)
        return keysOf(addon.PromotionPolicy.Query(inputs, all).rows)
    end
    test.assertEqual("bolt", search("BOL"))
    test.assertEqual("bolt", search("spark"), "the alias")
    test.assertEqual("bolt", search("main"), "the main's name")
    test.assertEqual("solo", search("sol"), "a character with no player")
    test.assertEqual("", search("nobody"))
end)

test.test("the list comes a page at a time, kept within the pages there are", function()
    local characters = {}
    local index
    for index = 1, 7 do
        characters["char" .. index] = 4
    end
    local inputs, addon = newGuild(characters)
    addItem(inputs, 4, "Read the rules")
    local options = { filters = { progress = true }, pageSize = 3, page = 2 }

    local result = addon.PromotionPolicy.Query(inputs, options)
    test.assertEqual(3, result.pages)
    test.assertEqual(2, result.page)
    test.assertEqual(7, result.total)
    test.assertEqual("char4,char5,char6", keysOf(result.rows))
    test.assertEqual(1, #result.rows[1].items, "each row on the page is evaluated in full")
    options.page = 9
    result = addon.PromotionPolicy.Query(inputs, options)
    test.assertEqual(3, result.page)
    test.assertEqual("char7", keysOf(result.rows))
    options.page = 0
    test.assertEqual(1, addon.PromotionPolicy.Query(inputs, options).page)
end)

test.test("a 1,000-character guild lists within its time budget, evaluating only the page in full", function()
    local characters = {}
    local index
    for index = 1, 1000 do
        characters[string.format("char%04d", index)] = 2 + index % 3
    end
    local inputs, addon = newGuild(characters)
    local rank
    for rank = 2, 4 do
        local check = addItem(inputs, rank, "Read the rules")
        addItem(inputs, rank, "", "char-guild-days", 7)
        addItem(inputs, rank, "", "level", 10)
        local key
        for key in pairs(characters) do
            if characters[key] == rank and tonumber(string.sub(key, 5)) % 4 == 0 then
                inputs.checks:Set(key, check, true, nil, OFFICER, NOW)
            end
        end
    end
    local full = 0
    local evaluate = addon.PromotionPolicy.Evaluate
    addon.PromotionPolicy.Evaluate = function(...)
        full = full + 1
        return evaluate(...)
    end

    local started = os.clock()
    local result = addon.PromotionPolicy.Query(inputs, { filters = { ready = true, progress = true } })
    local elapsed = os.clock() - started
    test.assertEqual(1000, result.total)
    test.assertEqual(addon.PromotionPolicy.PAGE_SIZE, #result.rows)
    test.assertEqual(addon.PromotionPolicy.PAGE_SIZE, full, "only the page shown is evaluated in full")
    test.assertTrue(elapsed < 1, "took " .. elapsed .. " seconds")
end)

test.test("the controls show the page, the filters, a box per rank, and the ready count for the tab", function()
    local _, addon = newGuild({})
    local Model = addon.PromotionsViewModel
    local controls = Model.Controls({ page = 2, pages = 3, total = 120, ready = 4, ranks = { 3, 4 } },
        { ready = true, hiddenRanks = { [4] = true } }, RANKS)

    test.assertEqual("Page 2 of 3 (120 characters)", controls.pageText)
    test.assertTrue(controls.ready)
    test.assertFalse(controls.progress)
    test.assertEqual("Member", controls.ranks[1].name)
    test.assertTrue(controls.ranks[1].shown)
    test.assertFalse(controls.ranks[2].shown)
    test.assertEqual("Promotions (4)", controls.tabLabel)
    test.assertEqual("4", controls.badge)
    test.assertEqual("Promotions", Model.TabLabel(0))
    local rows = Model.List({}, { anyRequirements = true, filtered = true })
    test.assertEqual(Model.NO_MATCH, rows[2].character)
end)

-- The player panel and the roster -------------------------------------------------------

local function panelFor(inputs, addon, keys, options)
    local characters = {}
    local index
    for index = 1, #keys do
        local character = inputs.partition:GetCharacter(keys[index])
        table.insert(characters, {
            key = keys[index],
            name = keys[index],
            rankName = RANKS[character.rank + 1],
            evaluated = addon.PromotionPolicy.Evaluate(inputs, keys[index]),
            lastPromotion = options.lastPromotion,
            promoteAction = options.promoteAction,
        })
    end
    return addon.PromotionsViewModel.PanelRows(characters, options)
end

local function rowWith(rows, text)
    local index
    for index = 1, #rows do
        if rows[index].text ~= nil and string.find(rows[index].text, text, 1, true) then
            return rows[index]
        end
    end
    return nil
end

test.test("an officer's panel shows each character's checklist with its buttons, who ticked, and Promote", function()
    local inputs, addon = newGuild({ main = 2, bolt = 4 })
    local noted = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 4, "", "level", 10)
    inputs.checks:Set("bolt", noted, true, "Raid night", OFFICER, NOW)

    local rows = panelFor(inputs, addon, { "main", "bolt" }, {
        officer = true,
        highestRankName = "Veteran",
        promoteAction = "Promote",
        lastPromotion = { time = NOW, rank = 4, promoter = OFFICER },
        nameOf = function(key)
            return key == OFFICER and "Toolbox" or key
        end,
        formatDate = function()
            return "2026-10-20"
        end,
    })
    test.assertEqual("Promotion", rows[1].text)
    test.assertEqual("Highest rank: Veteran", rows[2].text)
    test.assertContains(rowWith(rows, "main: Veteran").text, "no requirements")
    test.assertContains(rowWith(rows, "bolt: Initiate -> Member, 1 of 2").text, "1 of 2")
    test.assertContains(rowWith(rows, "Promoted on 2026-10-20").text, "by Toolbox")
    local ticked = rowWith(rows, "Attend an event")
    test.assertEqual("Untick", ticked.action)
    test.assertContains(ticked.text, "Raid night")
    test.assertContains(ticked.tooltip[1], "Ticked by Toolbox")
    local level = rowWith(rows, "Level 10")
    test.assertEqual("Override", level.action)
    test.assertTrue(level.askReason)
    test.assertContains(level.text, "level unknown")
    local promote = rowWith(rows, "Promote to Member")
    test.assertTrue(promote.promote)
    test.assertEqual("Promote...", promote.action, "unmet items ask first, on the Promotions tab")
    test.assertContains(promote.confirm, "Not met: Level 10")
end)

test.test("a member's own panel shows progress and details read-only, without notes, names, or Promote", function()
    local inputs, addon = newGuild({ bolt = 4 })
    local noted = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 4, "", "level", 10)
    inputs.checks:Set("bolt", noted, true, "Raid night", OFFICER, NOW)

    local rows = panelFor(inputs, addon, { "bolt" }, {
        officer = false,
        highestRankName = "Veteran",
        promoteAction = "Promote",
        lastPromotion = { time = NOW, rank = 4, promoter = OFFICER },
    })
    test.assertEqual(nil, rowWith(rows, "Highest rank"))
    test.assertEqual(nil, rowWith(rows, "Promoted on"))
    test.assertEqual(nil, rowWith(rows, "Promote to"))
    local ticked = rowWith(rows, "Attend an event")
    test.assertContains(ticked.text, "[x]")
    test.assertFalse(string.find(ticked.text, "Raid night", 1, true) ~= nil, "no notes")
    test.assertEqual(nil, ticked.action)
    test.assertEqual(nil, ticked.tooltip)
    test.assertContains(rowWith(rows, "Level 10").text, "level unknown")
    local index
    for index = 1, #rows do
        test.assertEqual(nil, rows[index].action)
    end
end)

test.test("the roster marks ready characters' rows, and clears marks that no longer apply", function()
    local inputs, addon = newGuild({ bolt = 4, nail = 4 })
    local item = addItem(inputs, 4, "Read the rules")
    inputs.checks:Set("bolt", item, true, nil, OFFICER, NOW)
    local Roster = test.newAddon("Core/RosterViewModel.lua").RosterViewModel
    local ready = addon.PromotionPolicy.ReadySet(inputs)
    test.assertTrue(ready.bolt)
    test.assertEqual(nil, ready.nail)

    local rows = { { kind = "player" }, { kind = "character", key = "bolt" }, { kind = "character", key = "nail" } }
    test.assertTrue(Roster.MarkReady(rows, ready))
    test.assertTrue(rows[2].ready)
    test.assertEqual(nil, rows[3].ready)
    test.assertEqual(nil, rows[1].ready)
    test.assertFalse(Roster.MarkReady(rows, ready), "nothing changed")
    test.assertTrue(Roster.MarkReady(rows, nil))
    test.assertEqual(nil, rows[2].ready)
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
    -- The list shows only ready characters at first; these tests follow
    -- everyone's progress.
    world.addon.promotions.filter("progress", true)
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
        test.assertEqual(nil, next(partition:GetPromotionChecks().records or {}), "the stale ticks were pruned")
    end)

    test.test(profile .. " an officer adds a level item, overrides it for a low character, then lowers its level",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel, 5)
        local promotions = tool.addon.promotions

        local ok, reason = promotions.add("", "level", "")
        test.assertFalse(ok)
        test.assertEqual("a level needs to be 1 to 100", reason)
        test.assertTrue(promotions.add("", "level", "50"))
        local itemId = promotions.view().items[1].id
        test.assertEqual("Level 50", promotions.view().items[1].label)
        local bolt = characterRow(promotions.listRows(), "Bolt")
        test.assertEqual("0 of 1", bolt.progress)
        promotions.expand(bolt.key)
        local rows = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        test.assertEqual("level 12 of 50", rows[at + 1].ranks)
        test.assertEqual("Override", rows[at + 1].action)

        test.assertTrue(promotions.tick(bolt.key, itemId, true, "Raid leader on another server"))
        settle(channel, 5)
        local memberBolt = characterRow(hammer.addon.promotions.listRows(), "Bolt")
        test.assertEqual("1 of 1", memberBolt.progress, "the override reaches members")
        test.assertContains(memberBolt.character, "Ready")

        test.assertTrue(promotions.tick(bolt.key, itemId, false))
        test.assertEqual("0 of 1", characterRow(promotions.listRows(), "Bolt").progress)
        test.assertTrue(promotions.rename(itemId, "Level 50", "10"))
        test.assertEqual("Level 10", promotions.view().items[1].label)
        test.assertEqual("1 of 1", characterRow(promotions.listRows(), "Bolt").progress)
        settle(channel, 5)
        test.assertEqual("Level 10", hammer.addon.promotions.view().items[1].label)
        test.assertEqual("1 of 1", characterRow(hammer.addon.promotions.listRows(), "Bolt").progress)
    end)

    test.test(profile .. " adapter: the promote permission check and call, and a client without them", function()
        local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = names[1] })
        local client = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua").Compatibility
            .Create(world.environment)

        test.assertTrue(client:CanUsePromote())
        test.assertTrue(client:PromoteCalls().GuildPromote)
        -- The officer is rank 1: they may promote rank 4 and 3, not rank 2
        -- (that would make it their own rank).
        test.assertTrue(client:CanPromoteMember(4))
        test.assertTrue(client:CanPromoteMember(3))
        test.assertFalse(client:CanPromoteMember(2))
        test.assertEqual(nil, client:CanPromoteMember(nil))
        world.canPromote = false
        test.assertFalse(client:CanPromoteMember(4))
        test.assertTrue(client:PromoteMember(names[3]))
        test.assertEqual(names[3], world.promoted[1])
        test.assertEqual(3, world.guild.members[3].rank)
        test.assertFalse(client:PromoteMember(""))

        world.environment.CanGuildPromote = function()
            error("not allowed")
        end
        test.assertEqual(nil, client:CanPromoteMember(4))
        world.environment.GuildPromote = function()
            error("protected")
        end
        test.assertFalse(client:PromoteMember(names[3]))
        world.environment.CanGuildPromote = nil
        world.environment.GuildPromote = nil
        test.assertFalse(client:CanUsePromote())
        test.assertFalse(client:PromoteCalls().CanGuildPromote)
        test.assertEqual(nil, client:CanPromoteMember(4))
        test.assertFalse(client:PromoteMember(names[3]))
    end)

    test.test(profile .. " an officer promotes with a confirmation, the date and promoter are kept, the checklist goes",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel, 5)
        local promotions = tool.addon.promotions
        test.assertTrue(promotions.add("Read the rules", false))
        test.assertTrue(promotions.add("Attend an event", false))
        local bolt = characterRow(promotions.listRows(), "Bolt")
        promotions.expand(bolt.key)
        local rows = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        test.assertTrue(promotions.tick(bolt.key, rows[at + 1].item, true))
        rows = promotions.listRows()
        local promote = rows[at + 3]
        test.assertEqual("promote", promote.kind)
        test.assertEqual("Promote", promote.action)
        test.assertEqual("    Promote to Member", promote.character)
        test.assertContains(promote.confirm, "Not met: Attend an event")
        -- Members never get a Promote row.
        hammer.addon.promotions.expand(bolt.key)
        settle(channel, 5)
        local memberRows = hammer.addon.promotions.listRows()
        local _, memberAt = characterRow(memberRows, "Bolt")
        test.assertEqual("item", memberRows[memberAt + 2].kind)
        test.assertEqual(nil, memberRows[memberAt + 3])

        test.assertTrue(promotions.promote(bolt.key))
        test.assertEqual(names[3], tool.promoted[1])
        fixtures.fire(tool, "GUILD_ROSTER_UPDATE")
        settle(channel, 10)
        local toolKey = tool.addon.rosterController:SelfKey()
        local _, partition = tool.addon.rosterController:QuietContext()
        local dates = tool.addon.MembershipDates.Create(partition:GetMembershipDates())
        local last = dates:LastPromotion(bolt.key)
        test.assertEqual(toolKey, last.promoter)
        test.assertEqual(3, last.rank)
        test.assertEqual(3, partition:GetCharacter(bolt.key).rank, "the roster has the new rank at once")
        test.assertEqual(nil, next(partition:GetPromotionChecks().records or {}), "only the date and promoter stay")
        local _, memberPartition = hammer.addon.rosterController:QuietContext()
        test.assertEqual(toolKey, memberPartition:GetMembershipDates().characters[bolt.key].lastPromotion.promoter)
    end)

    test.test(profile .. " without the game's promote calls, Mark as promoted records the rank change once seen",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        settle(channel, 5)
        tool.environment.CanGuildPromote = nil
        tool.environment.GuildPromote = nil
        local promotions = tool.addon.promotions
        test.assertTrue(promotions.add("Read the rules", false))
        local bolt = characterRow(promotions.listRows(), "Bolt")
        promotions.expand(bolt.key)
        local rows = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        test.assertEqual("Mark as promoted", rows[at + 2].action)

        tool.messages = {}
        test.assertTrue(promotions.promote(bolt.key))
        test.assertContains(table.concat(tool.messages, "\n"), "in the game's guild window")
        local _, partition = tool.addon.rosterController:QuietContext()
        local dates = tool.addon.MembershipDates.Create(partition:GetMembershipDates())
        test.assertEqual(nil, dates:LastPromotion(bolt.key), "nothing is recorded before the rank changes")

        -- The officer changes the rank in the game's guild window.
        tool.guild.members[3].rank = 3
        tool.guild.members[3].rankName = "Member"
        tool.addon.rosterController:Rescan()
        fixtures.fire(tool, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(tool, 5)
        local last = dates:LastPromotion(bolt.key)
        test.assertEqual(tool.addon.rosterController:SelfKey(), last.promoter)
        test.assertEqual("addon", last.source)
    end)

    test.test(profile .. " /agf probe promote is a dry run naming the calls and whether this officer may promote",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        tool.messages = {}
        fixtures.slash(tool, "probe promote " .. names[3])
        local printed = table.concat(tool.messages, "\n")
        test.assertContains(printed, "dry run")
        test.assertContains(printed, "GuildPromote: present")
        test.assertContains(printed, "May promote: yes")
        test.assertContains(printed, "The button would be: Promote")
        test.assertEqual(0, #tool.promoted, "no rank changed")
        tool.messages = {}
        fixtures.slash(tool, "probe promote " .. names[1])
        test.assertContains(table.concat(tool.messages, "\n"), "May promote: no")
        hammer.messages = {}
        fixtures.slash(hammer, "probe promote " .. names[3])
        test.assertContains(table.concat(hammer.messages, "\n"), "Only officers")
    end)

    test.test(profile .. " the add-on check passes for a member whose add-on was heard, and the officer shares it",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        -- Long enough for both add-ons' login sync to go out.
        settle(channel, 70)
        local promotions = tool.addon.promotions

        test.assertTrue(promotions.rank(-1))
        test.assertTrue(promotions.add("", "addon", ""))
        test.assertEqual("Has the add-on (seen in 30 days)", promotions.view().items[1].label)
        local hammerRow = characterRow(promotions.listRows(), "Hammer")
        test.assertEqual("1 of 1", hammerRow.progress, "the officer heard Hammer's add-on")

        -- Bolt, at another rank, has never been heard.
        promotions.rank(1)
        test.assertTrue(promotions.add("", "addon", "7"))
        promotions.expand(characterRow(promotions.listRows(), "Bolt").key)
        local rows = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        test.assertEqual("add-on not seen", rows[at + 1].ranks)

        -- The officer's add-on shares what it heard a few minutes later.
        settle(channel, 310)
        local toolKey = tool.addon.rosterController:SelfKey()
        local hammerKey = hammer.addon.rosterController:SelfKey()
        local _, partition = hammer.addon.rosterController:QuietContext()
        local seen = partition:GetMembershipDates().characters[hammerKey].addonSeen
        test.assertEqual(toolKey, seen.by)
        test.assertEqual("1 of 1", characterRow(hammer.addon.promotions.listRows(), "Hammer").progress)
    end)

    test.test(profile .. " the list shows ready characters at first, filters and searches, and counts the ready",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local promotions = tool.addon.promotions
        local Model = tool.addon.PromotionsViewModel
        test.assertTrue(promotions.filter("progress", false))
        test.assertTrue(promotions.add("Read the rules", false))

        local rows, controls = promotions.listRows()
        test.assertEqual(nil, characterRow(rows, "Bolt"), "in progress is hidden at first")
        test.assertEqual(Model.NO_MATCH, rows[2].character)
        test.assertEqual("Promotions", controls.tabLabel)
        test.assertEqual("Initiate", controls.ranks[1].name)

        test.assertTrue(promotions.filter("progress", true))
        local bolt = characterRow(promotions.listRows(), "Bolt")
        promotions.expand(bolt.key)
        rows = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        test.assertTrue(promotions.tick(bolt.key, rows[at + 1].item, true))
        test.assertTrue(promotions.filter("progress", false))
        rows, controls = promotions.listRows()
        test.assertContains(characterRow(rows, "Bolt").character, "Ready")
        test.assertEqual("Promotions (1)", controls.tabLabel)
        test.assertEqual("Page 1 of 1 (1 character)", controls.pageText)

        promotions.search("nobody")
        test.assertEqual(nil, characterRow(promotions.listRows(), "Bolt"))
        promotions.search("bol")
        test.assertTrue(characterRow(promotions.listRows(), "Bolt") ~= nil)
        promotions.filter(4, false)
        rows, controls = promotions.listRows()
        test.assertEqual(nil, characterRow(rows, "Bolt"))
        test.assertFalse(controls.ranks[1].shown)
        test.assertEqual("Promotions (1)", controls.tabLabel, "the count ignores the filters")
        test.assertFalse(promotions.filter("junk", true))
    end)

    test.test(profile .. " the open Promotions page redraws now and every few minutes, and stops once closed",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local drawn = {}
        tool.addon.rosterController.window = {
            IsShown = function()
                return true
            end,
            ShowPage = function() end,
            SetPromotions = function(_, model, rows, controls)
                table.insert(drawn, controls)
            end,
        }
        tool.addon.pages:Select("promotions")
        tool.addon.promotions.shown()
        test.assertEqual(1, #drawn)
        test.assertEqual("Promotions", drawn[1].tabLabel)
        fixtures.runTimers(tool, 301)
        test.assertEqual(2, #drawn, "day-based checks catch up while it's open")
        tool.addon.pages:Select("roster")
        fixtures.runTimers(tool, 301)
        tool.addon.pages:Select("promotions")
        fixtures.runTimers(tool, 601)
        test.assertEqual(2, #drawn, "closed, it stops")
    end)

    test.test(profile .. " the player panel works promotions for officers, agrees with the tab, and only a member's own",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel, 5)
        local promotions = tool.addon.promotions
        test.assertTrue(promotions.add("Read the rules", false))
        test.assertTrue(promotions.rank(-1))
        test.assertTrue(promotions.add("Help a new member", false))
        settle(channel, 10)
        local bolt = characterRow(promotions.listRows(), "Bolt")
        local _, partition = tool.addon.rosterController:QuietContext()
        local boltPlayer = partition:GetCharacter(bolt.key).player
        local boltKeys = partition:CharactersOf(boltPlayer)

        local panel = promotions.panelRows(boltKeys, boltPlayer)
        local item = rowWith(panel, "Read the rules")
        test.assertEqual("Tick", item.action)
        test.assertTrue(rowWith(panel, "Promote to Member") ~= nil)
        test.assertTrue(promotions.tick(item.key, item.item, true))
        panel = promotions.panelRows(boltKeys, boltPlayer)
        test.assertEqual("Untick", rowWith(panel, "Read the rules").action)
        test.assertContains(rowWith(panel, "Initiate -> Member").text, "1 of 1")
        test.assertEqual("1 of 1", characterRow(promotions.listRows(), "Bolt").progress, "the tab agrees")
        test.assertTrue(promotions.readyKeys()[bolt.key])

        -- The roster marks Bolt's row once the window redraws.
        local controller = tool.addon.rosterController
        local drawnRows
        controller.window = {
            IsShown = function()
                return true
            end,
            ShowPage = function() end,
            SetRows = function(_, rows)
                drawnRows = rows
            end,
            SetPromotions = function() end,
        }
        controller.rosterRows = { { kind = "character", key = bolt.key } }
        controller:RefreshPromotions()
        test.assertTrue(drawnRows[1].ready)

        -- Members: nothing about others, nor a ready marker; their own,
        -- read-only.
        settle(channel, 10)
        test.assertEqual(nil, hammer.addon.promotions.readyKeys())
        test.assertEqual(nil, hammer.addon.promotions.panelRows(boltKeys, boltPlayer))
        local hammerKey = hammer.addon.rosterController:SelfKey()
        local _, memberPartition = hammer.addon.rosterController:QuietContext()
        local hammerPlayer = memberPartition:GetCharacter(hammerKey).player
        local own = hammer.addon.promotions.panelRows(memberPartition:CharactersOf(hammerPlayer), hammerPlayer)
        local help = rowWith(own, "Help a new member")
        test.assertContains(help.text, "[ ]")
        test.assertEqual(nil, help.action)
        test.assertFalse(hammer.addon.promotions.focus(hammerKey))

        -- A note or a confirmation opens the character on the tab.
        test.assertTrue(promotions.focus(bolt.key))
        test.assertEqual("promotions", tool.addon.pages:Current())
        local rows, controls = promotions.listRows()
        local _, at = characterRow(rows, "Bolt")
        test.assertEqual("item", rows[at + 1].kind, "its checklist is open")
        test.assertEqual("Page 1 of 1 (1 character)", controls.pageText, "searched by its name")
    end)
end
