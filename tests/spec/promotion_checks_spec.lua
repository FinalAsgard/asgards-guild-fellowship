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

local function itemOf(row, id)
    local index
    for index = 1, #row.items do
        if row.items[index].id == id then
            return row.items[index]
        end
    end
end

test.test("each character at a rank with requirements gets its next rank, progress, and ready", function()
    local inputs, addon = newGuild({ boss = 0, officer = 1, vet = 2, bolt = 4, nail = 4, rivet = 3 })
    local first = addItem(inputs, 4, "Read the rules")
    local second = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 0, "Nothing above the top")
    inputs.checks:Set("bolt", first, true, nil, OFFICER, NOW)
    inputs.checks:Set("bolt", second, true, "Raid", OFFICER, NOW)
    inputs.checks:Set("nail", first, true, nil, OFFICER, NOW)

    local bolt = addon.PromotionPolicy.Evaluate(inputs, "bolt")
    test.assertTrue(bolt.ready)
    test.assertEqual("Initiate", bolt.rankName)
    test.assertEqual("Member", bolt.nextRankName)
    test.assertEqual(2, bolt.met)
    local nail = addon.PromotionPolicy.Evaluate(inputs, "nail")
    test.assertEqual(1, nail.met)
    test.assertEqual(2, nail.total)
    test.assertFalse(nail.ready)
    local ready = addon.PromotionPolicy.ReadySet(inputs)
    test.assertTrue(ready.bolt)
    test.assertEqual(nil, ready.nail)
    test.assertEqual(nil, ready.boss, "the top rank is never ready")
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

test.test("an item's tooltip says who ticked it, when, and its note", function()
    local inputs, addon = newGuild({ bolt = 4 })
    local item = addItem(inputs, 4, "Attend an event", "check-note")
    local plain = addItem(inputs, 4, "Read the rules")
    inputs.checks:Set("bolt", item, true, "Raid night", OFFICER, NOW)
    local evaluated = addon.PromotionPolicy.Evaluate(inputs, "bolt")
    local function nameOf(key)
        return key == OFFICER and "Toolbox" or key
    end
    local function formatDate()
        return "2026-10-20"
    end

    local ticked = addon.PromotionsViewModel.ItemRow("bolt", itemOf(evaluated, item.id), nameOf, formatDate)
    test.assertTrue(ticked.ticked)
    test.assertTrue(ticked.needsNote)
    test.assertEqual("Ticked by Toolbox on 2026-10-20", ticked.tooltip[1])
    test.assertEqual("Note: Raid night", ticked.tooltip[2])
    local open = addon.PromotionsViewModel.ItemRow("bolt", itemOf(evaluated, plain.id), nameOf, formatDate)
    test.assertFalse(open.ticked)
    test.assertEqual(nil, open.tooltip)
end)

-- Automated items -------------------------------------------------------------------


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
    local function nameOf(key)
        return key == OFFICER and "Toolbox" or key
    end
    local function formatDate()
        return "2026-10-20"
    end
    local function itemRow()
        return Model.ItemRow("bolt", itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id), nameOf,
            formatDate)
    end
    local shown = itemRow()
    test.assertEqual("level 42 of 50", shown.ranks)
    test.assertEqual("overridden", shown.progress)
    test.assertEqual("Undo override", shown.action)
    test.assertEqual("Overridden by Toolbox on 2026-10-20", shown.tooltip[1])
    test.assertEqual("Reason: Old friend", shown.tooltip[2])

    test.assertTrue(checks:Set("bolt", item, false, nil, OTHER_OFFICER, NOW) ~= nil)
    test.assertFalse(itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id).met)
    shown = itemRow()
    test.assertEqual("Override", shown.action)
    test.assertContains(shown.tooltip[1], "Override removed by")

    -- No reason is needed, and a met item offers no override.
    test.assertTrue(checks:Set("bolt", item, true, nil, OFFICER, NOW) ~= nil)
    test.assertTrue(itemOf(addon.PromotionPolicy.Evaluate(inputs, "bolt"), item.id).overridden)
    checks:Set("bolt", item, false, nil, OFFICER, NOW)
    inputs.partition:RecordCharacter("bolt", { level = 55 })
    test.assertEqual(nil, itemRow().action)
end)

test.test("the add-on check passes when any of the player's characters was ever heard", function()
    local inputs, addon = newGuild({ main = 2, alt = 4, solo = 4, quiet = 4 })
    local records = inputs.requirements:Add(4, "", "addon", RANKS[5], OFFICER, NOW)
    local item = records[1]
    test.assertEqual(nil, item.n, "a yes or no check, with no number")
    test.assertEqual("Has the Guild Fellowship Addon", item.label)
    inputs.partition:JoinPlayerOf("alt", "main", "manual")
    inputs.dates:Heard("main", NOW - 3 * DAY - 60)
    inputs.dates:Heard("solo", NOW - 45 * DAY)

    local alt = itemOf(addon.PromotionPolicy.Evaluate(inputs, "alt"), item.id)
    test.assertTrue(alt.met, "the alt counts its main's add-on")
    test.assertEqual("seen 3 days ago", alt.detail)
    local solo = itemOf(addon.PromotionPolicy.Evaluate(inputs, "solo"), item.id)
    test.assertTrue(solo.met, "however long ago")
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

test.test("a 1,000-character guild's ready flags are worked out within their time budget", function()
    local characters = {}
    local index
    for index = 1, 1000 do
        characters[string.format("char%04d", index)] = 2 + index % 3
    end
    local inputs, addon = newGuild(characters)
    local rank
    for rank = 2, 4 do
        local check = addItem(inputs, rank, "Read the rules")
        addItem(inputs, rank, "", "level", 1)
        local key
        for key in pairs(characters) do
            if characters[key] == rank and tonumber(string.sub(key, 5)) % 4 == 0 then
                inputs.checks:Set(key, check, true, nil, OFFICER, NOW)
            end
        end
    end
    for index = 1, 1000 do
        inputs.partition:RecordCharacter(string.format("char%04d", index), { level = 10 })
    end

    local started = os.clock()
    local ready = addon.PromotionPolicy.ReadySet(inputs)
    local elapsed = os.clock() - started
    local count = 0
    local key
    for key in pairs(ready) do
        count = count + 1
    end
    test.assertEqual(250, count, "every fourth character ticked its item")
    test.assertTrue(elapsed < 1, "took " .. elapsed .. " seconds")
end)

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

test.test("an officer's panel shows each character's checklist with its check boxes, Override and who ticked",
    function()
    local inputs, addon = newGuild({ main = 2, bolt = 4 })
    local noted = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 4, "", "level", 10)
    inputs.checks:Set("bolt", noted, true, "Raid night", OFFICER, NOW)

    local rows = panelFor(inputs, addon, { "main", "bolt" }, {
        officer = true,
        highestRankName = "Veteran",
        lastPromotion = { time = NOW, rank = 4, promoter = OFFICER },
        expanded = { main = true, bolt = true },
        nameOf = function(key)
            return key == OFFICER and "Toolbox" or key
        end,
        formatDate = function()
            return "2026-10-20"
        end,
    })
    test.assertEqual("Highest rank: Veteran", rows[1].text)
    test.assertContains(rowWith(rows, "bolt: Initiate").text, "[-] ", "an open checklist")
    test.assertContains(rowWith(rows, "main: Veteran").text, "no requirements")
    test.assertContains(rowWith(rows, "bolt: Initiate -> Member, 1 of 2").text, "1 of 2")
    test.assertContains(rowWith(rows, "Promoted on 2026-10-20").text, "by Toolbox")
    local ticked = rowWith(rows, "Attend an event")
    test.assertEqual(nil, ticked.action, "a check box, not a button")
    test.assertTrue(ticked.check)
    test.assertTrue(ticked.checked)
    test.assertTrue(ticked.canCheck)
    test.assertEqual("Raid night", ticked.note)
    test.assertFalse(string.find(ticked.text, "Raid night", 1, true) ~= nil, "the note is on its own line")
    local noteLine
    local index
    for index = 1, #rows do
        if rows[index].noteInput and rows[index].item == noted.id then
            noteLine = rows[index]
        end
    end
    test.assertEqual("Raid night", noteLine.note, "a ticked item's note shows on its line")
    test.assertTrue(noteLine.ticked)
    test.assertContains(ticked.tooltip[1], "Ticked by Toolbox")
    local level = rowWith(rows, "Level 10")
    test.assertEqual("Override", level.action)
    test.assertFalse(level.checked)
    test.assertEqual(nil, level.canCheck, "an automated item's box only shows whether it's met")
    test.assertContains(level.text, "level unknown")
    local reason
    for index = 1, #rows do
        if rows[index].noteInput and rows[index].item == level.item then
            reason = rows[index]
        end
    end
    test.assertTrue(reason.reason, "a failed check has a line for the override's optional reason")
    test.assertEqual(nil, rowWith(rows, "Promote to"), "add-ons can't promote: no Promote button")
end)

test.test("a member's own panel shows progress and details read-only, without notes or names", function()
    local inputs, addon = newGuild({ bolt = 4 })
    local noted = addItem(inputs, 4, "Attend an event", "check-note")
    addItem(inputs, 4, "", "level", 10)
    inputs.checks:Set("bolt", noted, true, "Raid night", OFFICER, NOW)

    local rows = panelFor(inputs, addon, { "bolt" }, {
        officer = false,
        highestRankName = "Veteran",
        lastPromotion = { time = NOW, rank = 4, promoter = OFFICER },
        expanded = { bolt = true },
    })
    test.assertEqual(nil, rowWith(rows, "Highest rank"))
    test.assertEqual(nil, rowWith(rows, "Promoted on"))
    test.assertEqual(nil, rowWith(rows, "Promote to"))
    local ticked = rowWith(rows, "Attend an event")
    test.assertTrue(ticked.check)
    test.assertTrue(ticked.checked)
    test.assertEqual(nil, ticked.canCheck, "read-only")
    test.assertFalse(string.find(ticked.text, "Raid night", 1, true) ~= nil, "no notes")
    test.assertEqual(nil, ticked.action)
    test.assertEqual(nil, ticked.tooltip)
    test.assertContains(rowWith(rows, "Level 10").text, "level unknown")
    local index
    for index = 1, #rows do
        test.assertEqual(nil, rows[index].action)
    end
end)

test.test("the panel's Promotion tab shows one line per character, each opening to its checklist", function()
    local inputs, addon = newGuild({ main = 2, bolt = 4 })
    addItem(inputs, 4, "Attend an event")

    local rows = panelFor(inputs, addon, { "main", "bolt" }, { officer = true })
    test.assertEqual(2, #rows, "closed, just the characters")
    local bolt = rowWith(rows, "bolt: Initiate")
    test.assertTrue(bolt.toggle)
    test.assertFalse(bolt.expanded)
    test.assertContains(bolt.text, "[+] ")
    test.assertEqual(nil, rowWith(rows, "main: Veteran").toggle, "nothing to open without requirements")
    test.assertEqual(nil, rowWith(rows, "Attend an event"))

    local noted = addItem(inputs, 4, "Write a guide", "check-note")
    rows = panelFor(inputs, addon, { "main", "bolt" }, { officer = true,
        expanded = { bolt = true } })
    local at
    local index
    for index = 1, #rows do
        if rows[index].item == noted.id and not rows[index].noteInput then
            at = index
        end
    end
    test.assertTrue(rows[at].needsNote)
    test.assertTrue(rows[at + 1].noteInput, "the note is typed on the line under the item")
    test.assertEqual(noted.id, rows[at + 1].item)
    inputs.checks:Set("bolt", noted, true, "The raid guide", OFFICER, NOW)
    rows = panelFor(inputs, addon, { "bolt" }, { officer = true, expanded = { bolt = true } })
    local saved
    for index = 1, #rows do
        if rows[index].noteInput then
            saved = rows[index]
        end
    end
    test.assertEqual("The raid guide", saved.note, "once ticked, the line shows the note")
    test.assertTrue(saved.ticked)
    inputs.checks:Set("bolt", noted, false, nil, OFFICER, NOW + 1)
    rows = panelFor(inputs, addon, { "bolt" }, { officer = true, expanded = { bolt = true } })
    for index = 1, #rows do
        if rows[index].noteInput then
            saved = rows[index]
        end
    end
    test.assertFalse(saved.ticked)
    test.assertEqual(nil, saved.note, "unticked, the window keeps what was typed")
    local member = panelFor(inputs, addon, { "bolt" }, { officer = false, expanded = { bolt = true } })
    for index = 1, #member do
        test.assertEqual(nil, member[index].noteInput, "members get no note line")
    end
    rows = panelFor(inputs, addon, { "main", "bolt" }, { officer = true,
        expanded = { bolt = true } })
    test.assertTrue(rowWith(rows, "bolt: Initiate").expanded)
    local item = rowWith(rows, "Attend an event")
    test.assertTrue(item.canCheck)
    test.assertFalse(item.checked)

    -- Every item met: the character is flagged ready for promotion.
    test.assertFalse(string.find(rowWith(rows, "bolt: Initiate").text, "Ready for promotion", 1, true) ~= nil)
    inputs.checks:Set("bolt", inputs.requirements:Item(item.item), true, nil, OFFICER, NOW + 2)
    inputs.checks:Set("bolt", noted, true, "The raid guide", OFFICER, NOW + 3)
    rows = panelFor(inputs, addon, { "bolt" }, { officer = true })
    test.assertContains(rowWith(rows, "bolt: Initiate").text, "Ready for promotion")
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

-- The key of the character named `name` in `world`'s roster.
local function keyOf(world, name)
    local _, _, normalizer = world.addon.rosterController:QuietContext()
    return normalizer:Key(name)
end

-- The player panel's Promotion tab for the player of the character named
-- `name`, that character's checklist open, and its line (the first of its
-- rows): its rank, progress and Ready flag.
local function panelOf(world, name)
    local _, partition = world.addon.rosterController:QuietContext()
    local key = keyOf(world, name)
    local player = partition:GetCharacter(key).player
    local function draw()
        local rows = world.addon.promotions.panelRows(partition:CharactersOf(player), player)
        local index
        for index = 1, #(rows or {}) do
            if rows[index].key == key then
                return rows, rows[index]
            end
        end
        return rows, nil
    end
    local rows, header = draw()
    if header ~= nil and header.toggle and not header.expanded then
        world.addon.promotions.togglePanel(key)
        rows, header = draw()
    end
    return rows, header, key
end

-- The checklist row of item `id` in panel `rows`.
local function itemRowOf(rows, id)
    local index
    for index = 1, #rows do
        if rows[index].item == id and not rows[index].noteInput then
            return rows[index]
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

        local _, header = panelOf(tool, names[3])
        test.assertContains(header.text, "no requirements")
        test.assertTrue(promotions.add("Attend an event", true))
        local rows, bolt, boltKey = panelOf(tool, names[3])
        test.assertContains(bolt.text, "0 of 1")
        local item = itemRowOf(rows, promotions.view().items[1].id)
        local ok, reason = promotions.tick(boltKey, item.item, true, "")
        test.assertFalse(ok)
        test.assertEqual("this item needs a note", reason)
        test.assertTrue(promotions.tick(boltKey, item.item, true, "Raid night"))
        _, bolt = panelOf(tool, names[3])
        test.assertContains(bolt.text, "1 of 1")
        test.assertContains(bolt.text, "Ready for promotion")
        test.assertTrue(promotions.readyKeys()[boltKey])
        settle(channel, 5)

        local _, memberPartition = hammer.addon.rosterController:QuietContext()
        local _, tick = next(memberPartition:GetPromotionChecks().records)
        test.assertEqual(boltKey, tick.character, "the tick reaches a member's add-on")
        local refused, why = hammer.addon.promotions.tick(boltKey, item.item, false)
        test.assertFalse(refused)
        test.assertEqual("only officers can tick promotion requirements", why)

        -- Bolt is promoted in the game's own guild window: the next scan
        -- finds the new rank, and its ticks are gone.
        tool.guild.members[3].rank = 3
        tool.guild.members[3].rankName = "Member"
        tool.addon.rosterController:Rescan()
        fixtures.fire(tool, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(tool, 5)
        _, bolt = panelOf(tool, names[3])
        test.assertContains(bolt.text, "no requirements")
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

        local ok, reason = promotions.automated("level", true, "")
        test.assertFalse(ok)
        test.assertEqual("a level needs to be 1 to 100", reason)
        test.assertTrue(promotions.automated("level", true, "50"))
        local level = promotions.view().automated[4]
        test.assertTrue(level.enabled)
        test.assertEqual(50, level.n)
        local itemId = level.id
        local rows, bolt, boltKey = panelOf(tool, names[3])
        test.assertContains(bolt.text, "0 of 1")
        local item = itemRowOf(rows, itemId)
        test.assertContains(item.text, "level 12 of 50")
        test.assertEqual("Override", item.action)

        test.assertTrue(promotions.tick(boltKey, itemId, true, "Raid leader on another server"))
        settle(channel, 5)
        test.assertContains(select(2, panelOf(tool, names[3])).text, "1 of 1")
        local _, memberPartition = hammer.addon.rosterController:QuietContext()
        local _, override = next(memberPartition:GetPromotionChecks().records)
        test.assertEqual("Raid leader on another server", override.note, "the override reaches members")

        test.assertTrue(promotions.tick(boltKey, itemId, false))
        test.assertContains(select(2, panelOf(tool, names[3])).text, "0 of 1")
        test.assertTrue(promotions.automated("level", true, "10"))
        test.assertEqual(10, promotions.view().automated[4].n)
        test.assertContains(select(2, panelOf(tool, names[3])).text, "1 of 1")
        settle(channel, 5)
        test.assertEqual(10, hammer.addon.promotions.view().automated[4].n)
    end)

    test.test(profile .. " /agf probe ready counts the ready and says whether the game's roster is followed",
        function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel, 5)
        test.assertTrue(tool.addon.promotions.add("Read the rules", false))
        local boltKey = keyOf(tool, names[3])
        test.assertTrue(tool.addon.promotions.tick(boltKey, tool.addon.promotions.view().items[1].id, true))
        tool.messages = {}
        fixtures.slash(tool, "probe ready")
        local printed = table.concat(tool.messages, "\n")
        test.assertContains(printed, "Ready flag probe:")
        test.assertContains(printed, "Ready for promotion: 1")
        test.assertContains(printed, "Guild roster rows followed: no")
        hammer.messages = {}
        fixtures.slash(hammer, "probe ready")
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
        test.assertTrue(promotions.automated("addon", true))
        test.assertTrue(promotions.view().automated[5].enabled)
        test.assertContains(select(2, panelOf(tool, names[2])).text, "1 of 1", "the officer heard Hammer's add-on")

        -- Bolt, at another rank, has never been heard.
        promotions.rank(1)
        test.assertTrue(promotions.automated("addon", true))
        local rows = panelOf(tool, names[3])
        test.assertContains(itemRowOf(rows, promotions.view().automated[5].id).text, "add-on not seen")

        -- The officer's add-on shares what it heard a few minutes later.
        settle(channel, 310)
        local toolKey = tool.addon.rosterController:SelfKey()
        local hammerKey = hammer.addon.rosterController:SelfKey()
        local _, partition = hammer.addon.rosterController:QuietContext()
        local seen = partition:GetMembershipDates().characters[hammerKey].addonSeen
        test.assertEqual(toolKey, seen.by)
        test.assertContains(select(2, panelOf(hammer, names[2])).text, "1 of 1", "the member's own view agrees")
    end)

    test.test(profile .. " the player panel works promotions for officers, marks the roster, and only a member's own",
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
        local _, partition = tool.addon.rosterController:QuietContext()
        local boltKey = keyOf(tool, names[3])
        local boltPlayer = partition:GetCharacter(boltKey).player
        local boltKeys = partition:CharactersOf(boltPlayer)

        local panel = promotions.panelRows(boltKeys, boltPlayer)
        test.assertEqual(nil, rowWith(panel, "Read the rules"), "a checklist starts closed")
        test.assertTrue(rowWith(panel, "Initiate -> Member").toggle)
        test.assertTrue(promotions.togglePanel(boltKey))
        panel = promotions.panelRows(boltKeys, boltPlayer)
        local item = rowWith(panel, "Read the rules")
        test.assertTrue(item.canCheck)
        test.assertFalse(item.checked)
        test.assertEqual(nil, rowWith(panel, "Promote to"), "add-ons can't promote")
        test.assertTrue(promotions.tick(item.key, item.item, true))
        panel = promotions.panelRows(boltKeys, boltPlayer)
        test.assertTrue(rowWith(panel, "Read the rules").checked)
        test.assertContains(rowWith(panel, "Initiate -> Member").text, "Ready for promotion")
        test.assertTrue(promotions.readyKeys()[boltKey])

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
        controller.rosterRows = { { kind = "character", key = boltKey } }
        controller:RefreshPromotions()
        test.assertTrue(drawnRows[1].ready)

        -- Members: nothing about others, nor a ready marker; their own,
        -- read-only.
        settle(channel, 10)
        test.assertEqual(nil, hammer.addon.promotions.readyKeys())
        test.assertEqual(nil, hammer.addon.promotions.panelRows(boltKeys, boltPlayer))
        local own = panelOf(hammer, names[2])
        local help = rowWith(own, "Help a new member")
        test.assertFalse(help.checked)
        test.assertEqual(nil, help.canCheck)
        test.assertEqual(nil, help.action)
    end)
end
