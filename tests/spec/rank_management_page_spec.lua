local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- The Rank management page on fake frames, over a Due list held here.
local function setup()
    local addon = test.newAddon("Core/ListWindow.lua", "Core/RankUpViewModel.lua", "Adapters/Theme.lua",
        "Adapters/Widgets.lua", "Core/RankRequirements.lua", "Adapters/RequirementsEditor.lua",
        "Adapters/RankManagementPage.lua")
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local content = environment.CreateFrame("Frame")
    local world = { addon = addon, searches = {}, snoozed = {}, ranks = {}, ticks = {}, missings = {},
        missingRanks = {}, filters = {}, edits = {} }
    -- All players, soonest first.
    world.players = {
        { playerId = 1, key = "toolbox", name = "TheTool", status = "Ready", statusText = "Ready",
            rankText = "→ Member" },
        { playerId = 3, key = "nap", name = "Nap", status = "Snoozed", rankText = "→ Member",
            statusText = "Snoozed until 2026-12-04 by Toolbox" },
        { playerId = 4, key = "fresh", name = "Fresh", status = "Not yet", rankText = "→ Member",
            statusText = "Not yet: 5 days" },
        { playerId = 5, key = "boss", name = "Boss", status = "No requirements", statusText = "No requirements" },
    }
    world.rows = {
        { playerId = 1, key = "toolbox", name = "TheTool", status = "Ready", rankText = "→ Member",
            promoteText = "Toolbox, Hammer" },
        { playerId = 2, key = "bolt", name = "Bolt", status = "Due", rankText = "→ Veteran",
            waitingText = "Discord name · Interview" },
    }
    world.page = addon.RankManagementPage.Create(content, ui, {
        model = function(search, rank, missing)
            table.insert(world.searches, search)
            table.insert(world.ranks, rank or "any")
            table.insert(world.missings, missing or "none")
            if rank ~= nil then
                return world.grid(rank)
            end
            local rows = {}
            local _, row
            for _, row in ipairs(world.rows) do
                if string.find(string.lower(row.name), string.lower(search), 1, true) then
                    table.insert(rows, row)
                end
            end
            return { rows = rows, count = #world.rows, footer = "1 Ready · 1 Due · Promotion happens on the guild roster." }
        end,
        onSnooze = function(key)
            table.insert(world.snoozed, key)
            if world.refuse ~= nil then
                return false, world.refuse
            end
            local index
            for index = #world.rows, 1, -1 do
                if world.rows[index].key == key then
                    table.remove(world.rows, index)
                end
            end
            return true
        end,
        onError = function(text)
            world.error = text
        end,
        targets = function()
            return { { text = "Any rank" }, { rank = 3, text = "→ Member" }, { rank = 2, text = "→ Veteran" } }
        end,
        players = function(search, filter)
            table.insert(world.filters, filter)
            local rows = {}
            local _, row
            for _, row in ipairs(world.players) do
                local kept = filter == "all" or (filter == "snoozed" and row.status == "Snoozed")
                    or (filter == "notyet" and row.status == "Not yet")
                if kept and string.find(string.lower(row.name), string.lower(search), 1, true) then
                    table.insert(rows, row)
                end
            end
            return { rows = rows, count = #world.players, snoozed = 1, notYet = 1 }
        end,
        requirements = {
            ranks = function()
                return {
                    { rank = 4, text = "→ Member", count = 0, countText = "None" },
                    { rank = 3, text = "→ Veteran", count = 2, countText = "2 requirements" },
                }
            end,
            view = function(rank)
                table.insert(world.edits, "view " .. rank)
                local automated = {
                    { kind = "char-guild-days", text = "Character days in guild", enabled = rank == 3,
                        n = rank == 3 and 14 or nil, numberText = "Days" },
                    { kind = "addon", text = "Has the Guild Fellowship Addon", enabled = false },
                }
                local items = {}
                if rank == 3 then
                    items = {
                        { id = "rules", label = "Read the rules", kindText = "Checkbox", canUp = false, canDown = true },
                        { id = "interview", label = "Interview", kindText = "Checkbox, needs a note", canUp = true,
                            canDown = false },
                    }
                end
                return { rank = rank, rankText = "Member (rank " .. rank .. ")", nextText = "Promotes to Veteran",
                    automated = automated, items = items, empty = items[1] == nil and "No custom requirements." or nil,
                    matchAlts = rank == 3, snoozeDays = 7 }
            end,
            add = function(rank, label, needsNote)
                table.insert(world.edits, "add " .. rank .. " " .. label .. " " .. tostring(needsNote))
                return true
            end,
            rename = function(rank, id, label)
                table.insert(world.edits, "rename " .. rank .. " " .. id .. " " .. label)
                return true
            end,
            automated = function(rank, kind, enabled, n)
                table.insert(world.edits, "automated " .. rank .. " " .. kind .. " " .. tostring(enabled) .. " "
                    .. tostring(n))
                return world.refuse == nil, world.refuse
            end,
            matchAlts = function(rank, on)
                table.insert(world.edits, "matchAlts " .. rank .. " " .. tostring(on))
                return true
            end,
            snoozeDays = function(rank, days)
                table.insert(world.edits, "snoozeDays " .. rank .. " " .. days)
                return true
            end,
            move = function(rank, id, step)
                table.insert(world.edits, "move " .. rank .. " " .. id .. " " .. step)
                return true
            end,
            delete = function(rank, id)
                table.insert(world.edits, "delete " .. rank .. " " .. id)
                return true
            end,
            onError = function(text)
                world.error = text
            end,
        },
        missing = function(rank)
            table.insert(world.missingRanks, rank or "any")
            if rank == 3 then
                return { { rank = 3, id = "level", label = "Level 70", text = "Level 70" },
                    { rank = 3, id = "rules", label = "Read the rules", text = "Read the rules" } }
            end
            return { { rank = 3, id = "level", label = "Level 70", text = "Level 70 (→ Member)" },
                { rank = 2, id = "raids", label = "Raid ready", text = "Raid ready (→ Veteran)" } }
        end,
        onTick = function(key, item, ticked, note)
            table.insert(world.ticks, { key = key, item = item, ticked = ticked, note = note })
            if world.refuse ~= nil then
                return false, world.refuse
            end
            if item == "interview" then
                world.note = ticked and note or nil
            elseif item == "level" then
                world.overridden = ticked
            else
                world.checked = ticked
            end
            return true
        end,
    })
    -- The grid for → Member: an automated column and an officer check.
    function world.grid(rank)
        if rank ~= 3 then
            return { rows = {}, count = 0, footer = "", columns = {} }
        end
        return {
            count = 1,
            footer = "0 Ready · 1 Due",
            columns = {
                { id = "days", label = "In the guild 7 days", check = false },
                { id = "level", label = "Level 70", check = false },
                { id = "rules", label = "Read the rules", check = true },
                { id = "interview", label = "Interview", check = true },
            },
            rows = { { playerId = 2, key = "bolt", name = "Bolt", status = "Due", rankText = "→ Member",
                waitingText = "Level 70 · Read the rules",
                cells = {
                    { id = "days", state = "met", text = "≈44 d" },
                    world.overridden and { id = "level", state = "overridden", text = "met by override" }
                        or { id = "level", state = "missing", text = "level 66" },
                    { id = "rules", check = true, checked = world.checked == true,
                        state = world.checked and "ticked" or "unticked", text = world.checked and "by Toolbox" or "" },
                    { id = "interview", check = true, needsNote = true, checked = world.note ~= nil,
                        state = world.note and "ticked" or "unticked",
                        text = world.note and ("\"" .. world.note .. "\"") or "" },
                } } },
        }
    end
    world.page:Refresh()
    return world
end

-- The shown rows, by player id.
local function shown(world)
    local rows = {}
    local _, frame
    for _, frame in ipairs(world.page.list:Shown()) do
        if frame.shown then
            table.insert(rows, frame)
        end
    end
    table.sort(rows, function(a, b)
        return a.entry.playerId < b.entry.playerId
    end)
    return rows
end

test.test("rank management page: opens on Due, a row per player with the rank promoted to", function()
    local world = setup()
    local rows = shown(world)

    test.assertEqual("due", world.page.tabs:Selected())
    test.assertEqual(2, #rows)
    test.assertEqual("TheTool  |cff9d9d9d→ Member|r", rows[1].name.text)
    test.assertEqual("Ready", rows[1].status.text)
    test.assertEqual("Promote: Toolbox, Hammer", rows[1].sub.text)
    test.assertEqual("Bolt  |cff9d9d9d→ Veteran|r", rows[2].name.text)
    test.assertEqual("Due", rows[2].status.text)
    test.assertEqual("Waiting on: Discord name · Interview", rows[2].sub.text)
    test.assertEqual("1 Ready · 1 Due · Promotion happens on the guild roster.", world.page.footer.text)
    test.assertFalse(world.page.empty.shown)
end)

test.test("rank management page: search narrows the list", function()
    local world = setup()
    local box = world.page.search.box
    box:SetText("bol")
    box.scripts.OnTextChanged(box, true)

    test.assertEqual("bol", world.searches[#world.searches])
    local rows = shown(world)
    test.assertEqual(1, #rows)
    test.assertEqual("Due", rows[1].status.text)

    box:SetText("zzz")
    box.scripts.OnTextChanged(box, true)
    test.assertTrue(world.page.empty.shown)
    test.assertEqual(world.addon.RankManagementPage.NO_MATCHES, world.page.empty.text)
end)

test.test("rank management page: with nobody due, it says so", function()
    local world = setup()
    world.rows = {}
    world.page:Refresh()

    test.assertTrue(world.page.empty.shown)
    test.assertEqual(world.addon.RankManagementPage.EMPTY, world.page.empty.text)
end)

test.test("rank management page: Snooze shows only on Due rows, and one click snoozes the player", function()
    local world = setup()
    local rows = shown(world)

    test.assertFalse(rows[1].snooze.shown)
    test.assertTrue(rows[2].snooze.shown)
    rows[2].snooze.scripts.OnClick(rows[2].snooze)
    test.assertEqual("bolt", world.snoozed[1])
    -- The list is built again without them.
    test.assertEqual(1, #shown(world))
end)

test.test("rank management page: a refused snooze says why", function()
    local world = setup()
    world.refuse = "only officers can snooze a promotion check"
    local row = shown(world)[2]
    row.snooze.scripts.OnClick(row.snooze)

    test.assertEqual("Bolt wasn't snoozed: only officers can snooze a promotion check.", world.error)
    test.assertEqual("Bolt", shown(world)[2].entry.name, "still on Due")
end)

test.test("rank management page: an update keeps All players' count current from Due", function()
    local world = setup()
    test.assertEqual("All players (4)", world.page.tabs.tabs[2].label.text)
    table.insert(world.players, { playerId = 6, key = "newbie", name = "Newbie", status = "Not yet",
        statusText = "Not yet: 7 days" })

    world.page:Update()
    test.assertEqual("due", world.page.tabs:Selected())
    test.assertEqual("All players (5)", world.page.tabs.tabs[2].label.text)
end)

test.test("rank management page: a Match row lists the characters to bring up, with no Snooze", function()
    local world = setup()
    world.rows = { { playerId = 3, key = "boss", name = "Boss", status = "Match", rankText = "→ Veteran",
        promoteText = "Grunt, Peon" } }
    world.page:Refresh()
    local row = shown(world)[1]

    test.assertEqual("Match", row.status.text)
    test.assertEqual("Boss  |cff9d9d9d→ Veteran|r", row.name.text)
    test.assertEqual("Promote: Grunt, Peon", row.sub.text)
    test.assertFalse(row.snooze.shown)
end)

-- Promote to and the grid -----------------------------------------------------------

local function click(button)
    button.scripts.OnClick(button, "LeftButton")
end

local function pick(world, row)
    click(world.page.picker)
    click(world.page.menu.rows[row])
end

test.test("rank management page: Promote to lists Any rank and the ranks, and picking one asks for that rank", function()
    local world = setup()
    test.assertEqual("Promote to: Any rank", world.page.picker.label.text)
    test.assertFalse(world.page.header.shown)

    click(world.page.picker)
    local menu = world.page.menu
    test.assertEqual("Any rank", menu.rows[1].label.text)
    test.assertEqual("→ Member", menu.rows[2].label.text)
    test.assertEqual("→ Veteran", menu.rows[3].label.text)
    click(menu.rows[2])

    test.assertEqual(3, world.ranks[#world.ranks])
    test.assertEqual("Promote to: → Member", world.page.picker.label.text)
    test.assertTrue(world.page.header.shown)

    pick(world, 1)
    test.assertEqual("any", world.ranks[#world.ranks])
    test.assertFalse(world.page.header.shown)
    test.assertEqual(2, #shown(world))
end)

test.test("rank management page: a picked rank shows a column per requirement, headed by its label", function()
    local world = setup()
    pick(world, 2)
    local labels = world.page.header.labels

    test.assertEqual("In the guild 7 days", labels[1].text)
    test.assertEqual("Level 70", labels[2].text)
    test.assertEqual("Read the rules", labels[3].text)
    local row = shown(world)[1]
    test.assertEqual("≈44 d", row.cells[1].text.text)
    test.assertTrue(row.cells[1].text.shown)
    test.assertFalse(row.cells[1].box.shown)
    test.assertEqual("level 66", row.cells[2].text.text)
    test.assertTrue(row.cells[3].box.shown)
    test.assertEqual("", row.cells[3].text.text)
    test.assertFalse(row.cells[3].box:IsChecked())
end)

test.test("rank management page: met and missing cells are colored apart", function()
    local world = setup()
    pick(world, 2)
    local row = shown(world)[1]

    test.assertEqual("green", row.cells[1].color)
    test.assertEqual("red", row.cells[2].color)
end)

test.test("rank management page: an officer check ticks and unticks at once, with no confirm", function()
    local world = setup()
    pick(world, 2)
    local box = shown(world)[1].cells[3].box
    click(box)

    test.assertEqual(1, #world.ticks)
    test.assertEqual("bolt", world.ticks[1].key)
    test.assertEqual("rules", world.ticks[1].item)
    test.assertTrue(world.ticks[1].ticked)
    -- Built again from the saved tick.
    box = shown(world)[1].cells[3].box
    test.assertTrue(box:IsChecked())

    click(box)
    test.assertFalse(world.ticks[2].ticked)
    test.assertFalse(shown(world)[1].cells[3].box:IsChecked())
end)

test.test("rank management page: a refused tick says why and leaves the box as it was", function()
    local world = setup()
    pick(world, 2)
    world.refuse = "only officers can tick promotion requirements"
    click(shown(world)[1].cells[3].box)

    test.assertEqual("Bolt's Read the rules wasn't ticked: only officers can tick promotion requirements.",
        world.error)
    test.assertFalse(shown(world)[1].cells[3].box:IsChecked())
end)

test.test("rank management page: a rank nobody is up for says so", function()
    local world = setup()
    pick(world, 3)

    test.assertTrue(world.page.empty.shown)
    test.assertEqual("Nobody is up for → Veteran right now.", world.page.empty.text)
end)

test.test("rank management page: leaving the grid hides the cells", function()
    local world = setup()
    pick(world, 2)
    pick(world, 1)
    local _, row
    for _, row in ipairs(shown(world)) do
        local _, cell
        for _, cell in ipairs(row.cells) do
            test.assertFalse(cell.shown)
        end
    end
end)

-- Notes and overrides ---------------------------------------------------------------

test.test("rank management page: a ticked check shows who ticked it beside the box", function()
    local world = setup()
    pick(world, 2)
    click(shown(world)[1].cells[3].box)
    local cell = shown(world)[1].cells[3]

    test.assertTrue(cell.text.shown)
    test.assertEqual("by Toolbox", cell.text.text)
end)

test.test("rank management page: ticking a check that needs a note asks for it, and Save ticks it with the note", function()
    local world = setup()
    pick(world, 2)
    click(shown(world)[1].cells[4].box)
    local prompt = world.page.prompt

    test.assertTrue(prompt:IsOpen())
    test.assertEqual("Interview for Bolt", prompt.title.text)
    test.assertEqual(0, #world.ticks)
    prompt.single:SetValue("Talked on Discord")
    click(prompt.save)

    test.assertEqual("interview", world.ticks[1].item)
    test.assertTrue(world.ticks[1].ticked)
    test.assertEqual("Talked on Discord", world.ticks[1].note)
    local cell = shown(world)[1].cells[4]
    test.assertTrue(cell.box:IsChecked())
    test.assertEqual("\"Talked on Discord\"", cell.text.text)

    -- Unticking it needs no note.
    click(cell.box)
    test.assertFalse(prompt:IsOpen())
    test.assertFalse(world.ticks[2].ticked)
end)

test.test("rank management page: Cancel on the note leaves the check unticked", function()
    local world = setup()
    pick(world, 2)
    click(shown(world)[1].cells[4].box)
    click(world.page.prompt.cancel)

    test.assertEqual(0, #world.ticks)
    test.assertFalse(shown(world)[1].cells[4].box:IsChecked())
end)

test.test("rank management page: right-clicking a failed automated cell overrides it, with an optional reason", function()
    local world = setup()
    pick(world, 2)
    local cell = shown(world)[1].cells[2]
    cell.scripts.OnClick(cell, "RightButton")
    local menu = world.page.menu

    test.assertTrue(menu:IsOpen())
    test.assertEqual("Override as met...", menu.rows[1].label.text)
    click(menu.rows[1])
    test.assertTrue(world.page.prompt:IsOpen())
    world.page.prompt.single:SetValue("Levels on an alt")
    click(world.page.prompt.save)

    test.assertEqual("level", world.ticks[1].item)
    test.assertTrue(world.ticks[1].ticked)
    test.assertEqual("Levels on an alt", world.ticks[1].note)
    cell = shown(world)[1].cells[2]
    test.assertEqual("met by override", cell.text.text)
    test.assertEqual("gold", cell.color)
end)

test.test("rank management page: Remove override takes the override back", function()
    local world = setup()
    world.overridden = true
    pick(world, 2)
    local cell = shown(world)[1].cells[2]
    cell.scripts.OnClick(cell, "RightButton")

    test.assertEqual("Remove override", world.page.menu.rows[1].label.text)
    click(world.page.menu.rows[1])
    test.assertFalse(world.ticks[1].ticked)
    test.assertEqual("level 66", shown(world)[1].cells[2].text.text)
end)

test.test("rank management page: a met automated cell and a check box have no right-click menu", function()
    local world = setup()
    pick(world, 2)
    local row = shown(world)[1]
    row.cells[1].scripts.OnClick(row.cells[1], "RightButton")
    test.assertFalse(world.page.menu:IsOpen())
    row.cells[3].scripts.OnClick(row.cells[3], "RightButton")
    test.assertFalse(world.page.menu:IsOpen())
end)

-- The Missing filter ----------------------------------------------------------------

local function filter(world, row)
    click(world.page.missingPicker)
    click(world.page.menu.rows[row])
end

test.test("rank management page: Missing lists the picked rank's requirements, or every rank's for Any rank", function()
    local world = setup()
    click(world.page.missingPicker)
    test.assertEqual("any", world.missingRanks[1])
    test.assertEqual("Level 70 (→ Member)", world.page.menu.rows[1].label.text)
    test.assertEqual("Raid ready (→ Veteran)", world.page.menu.rows[2].label.text)

    pick(world, 2)
    click(world.page.missingPicker)
    test.assertEqual(3, world.missingRanks[2])
    test.assertEqual("Level 70", world.page.menu.rows[1].label.text)
    test.assertEqual("Read the rules", world.page.menu.rows[2].label.text)
end)

test.test("rank management page: choosing a Missing requirement filters the list and shows a chip that clears it", function()
    local world = setup()
    test.assertFalse(world.page.chip.shown)
    filter(world, 1)

    test.assertEqual("level", world.missings[#world.missings].id)
    test.assertEqual(3, world.missings[#world.missings].rank)
    test.assertTrue(world.page.chip.shown)
    test.assertEqual("Missing: Level 70 (→ Member)", world.page.chip.label.text)

    click(world.page.chip.clear)
    test.assertEqual("none", world.missings[#world.missings])
    test.assertFalse(world.page.chip.shown)
end)

test.test("rank management page: in the grid the filtered requirement's header is highlighted", function()
    local world = setup()
    pick(world, 2)
    filter(world, 1)
    local labels = world.page.header.labels

    test.assertTrue(labels[2].highlighted)
    test.assertFalse(labels[1].highlighted)
    test.assertFalse(labels[3].highlighted)

    click(world.page.chip.clear)
    test.assertFalse(labels[2].highlighted)
end)

test.test("rank management page: picking another rank drops a filter of a different rank, Any rank keeps it", function()
    local world = setup()
    pick(world, 2)
    filter(world, 2)
    pick(world, 1)
    test.assertEqual("rules", world.missings[#world.missings].id)
    test.assertTrue(world.page.chip.shown)

    pick(world, 3)
    test.assertEqual("none", world.missings[#world.missings])
    test.assertFalse(world.page.chip.shown)
end)

test.test("rank management page: nobody missing the filtered requirement says so", function()
    local world = setup()
    pick(world, 3)
    filter(world, 2)

    test.assertTrue(world.page.empty.shown)
    test.assertEqual("Nobody due is missing that.", world.page.empty.text)
end)

-- All players -----------------------------------------------------------------------

local function allTab(world)
    local tab = world.page.tabs.tabs[2]
    click(tab)
end

local function shownInOrder(world)
    local rows = {}
    local _, frame
    for _, frame in ipairs(world.page.list:Shown()) do
        if frame.shown then
            table.insert(rows, frame)
        end
    end
    return rows
end

test.test("rank management page: the All players tab is labelled with the player count", function()
    local world = setup()
    test.assertEqual("All players (4)", world.page.tabs.tabs[2].label.text)
    test.assertTrue(world.page.picker.shown)
    test.assertFalse(world.page.filterBar.shown)
end)

test.test("rank management page: All players lists every player with its status in words", function()
    local world = setup()
    allTab(world)
    local rows = shownInOrder(world)

    test.assertEqual("all", world.page.tabs:Selected())
    test.assertEqual(4, #rows)
    test.assertEqual("TheTool  |cff9d9d9d→ Member|r", rows[1].name.text)
    test.assertEqual("Ready", rows[1].status.text)
    test.assertEqual("Snoozed", rows[2].status.text)
    test.assertEqual("Snoozed until 2026-12-04 by Toolbox", rows[2].sub.text)
    test.assertEqual("Not yet: 5 days", rows[3].sub.text)
    test.assertEqual("Boss", rows[4].name.text)
    test.assertEqual("No requirements", rows[4].sub.text)
    test.assertEqual("4 players · 1 snoozed · 1 not yet", world.page.footer.text)
    -- Due's controls give way to the status filter.
    test.assertFalse(world.page.picker.shown)
    test.assertFalse(world.page.missingPicker.shown)
    test.assertTrue(world.page.filterBar.shown)
end)

test.test("rank management page: All players' filter offers All, Snoozed and Not yet", function()
    local world = setup()
    allTab(world)
    local buttons = world.page.filterBar.buttons

    test.assertEqual("All", buttons[1].label.text)
    test.assertEqual("Snoozed", buttons[2].label.text)
    test.assertEqual("Not yet", buttons[3].label.text)
    click(buttons[2])
    test.assertEqual("snoozed", world.filters[#world.filters])
    local rows = shownInOrder(world)
    test.assertEqual(1, #rows)
    test.assertEqual("Nap  |cff9d9d9d→ Member|r", rows[1].name.text)

    click(buttons[3])
    test.assertEqual("Fresh  |cff9d9d9d→ Member|r", shownInOrder(world)[1].name.text)
end)

test.test("rank management page: back on Due, the list is Due's again", function()
    local world = setup()
    allTab(world)
    click(world.page.tabs.tabs[1])

    test.assertEqual(2, #shown(world))
    test.assertTrue(world.page.picker.shown)
    test.assertFalse(world.page.filterBar.shown)
    test.assertEqual("1 Ready · 1 Due · Promotion happens on the guild roster.", world.page.footer.text)
end)

-- Requirements ----------------------------------------------------------------------

local function requirementsTab(world)
    click(world.page.tabs.tabs[3])
    return world.page.editor
end

-- The last change asked for (or "view <rank>" when it's only been shown).
local function lastEdit(world)
    local index
    for index = #world.edits, 1, -1 do
        if string.find(world.edits[index], "view ", 1, true) ~= 1 then
            return world.edits[index]
        end
    end
    return world.edits[#world.edits]
end

test.test("rank management page: Requirements lists the ranks by the rank promoted to, with their counts", function()
    local world = setup()
    local editor = requirementsTab(world)

    test.assertEqual("Requirements", world.page.tabs.tabs[3].label.text)
    test.assertFalse(world.page.search.shown)
    test.assertFalse(world.page.list.shown)
    test.assertEqual("→ Member", editor.rankRows[1].label.text)
    test.assertEqual("None", editor.rankRows[1].count.text)
    test.assertEqual("→ Veteran", editor.rankRows[2].label.text)
    test.assertEqual("2 requirements", editor.rankRows[2].count.text)
    -- It opens on the first rank that has requirements.
    test.assertTrue(editor.rankRows[2].selected)
    test.assertEqual("→ Veteran", editor.title.text)

    click(editor.rankRows[1])
    test.assertTrue(editor.rankRows[1].selected)
    test.assertEqual("view 4", lastEdit(world))
    test.assertEqual("No custom requirements.", editor.noChecks.text)

    -- Back on Due, the list is back.
    click(world.page.tabs.tabs[1])
    test.assertTrue(world.page.search.shown)
    test.assertTrue(world.page.list.shown)
end)

test.test("rank management page: an automated check is a switch with its number", function()
    local world = setup()
    local editor = requirementsTab(world)
    local days, addonCheck = editor.automatedRows[1], editor.automatedRows[2]

    test.assertTrue(days.toggle:IsOn())
    test.assertEqual("Days", days.number.text)
    test.assertEqual(14, days.stepper:GetValue())
    test.assertFalse(addonCheck.stepper.shown, "the add-on check takes no number")

    days.stepper:Step(1)
    test.assertEqual("automated 3 char-guild-days true 15", lastEdit(world))
    click(days.toggle)
    test.assertEqual("automated 3 char-guild-days false 14", lastEdit(world))
    click(addonCheck.toggle)
    test.assertEqual("automated 3 addon true nil", lastEdit(world))

    world.refuse = "only officers can change promotion requirements"
    click(addonCheck.toggle)
    test.assertEqual("The requirements weren't changed: only officers can change promotion requirements.",
        world.error)
end)

test.test("rank management page: a number set while its check is off waits through a refresh for the switch", function()
    local world = setup()
    local editor = requirementsTab(world)
    click(editor.rankRows[1])
    local days = editor.automatedRows[1]
    test.assertFalse(days.toggle:IsOn())
    local start = days.stepper:GetValue()

    days.stepper:Step(1)
    test.assertEqual("view 4", lastEdit(world), "nothing saved while it's off")
    editor:Refresh()
    test.assertEqual(start + 1, days.stepper:GetValue())

    click(days.toggle)
    test.assertEqual("automated 4 char-guild-days true " .. (start + 1), lastEdit(world))
end)

test.test("rank management page: Add saves to the rank shown when it was clicked", function()
    local world = setup()
    local editor = requirementsTab(world)
    click(editor.add)
    editor.rank = 4
    editor.prompt.single:SetValue("Attend an event")
    click(editor.prompt.save)

    test.assertEqual("add 3 Attend an event false", lastEdit(world))
end)

test.test("rank management page: officer checks are added, renamed and reordered", function()
    local world = setup()
    local editor = requirementsTab(world)
    local prompt = editor.prompt

    click(editor.add)
    prompt.single:SetValue("Attend an event")
    prompt.save.scripts.OnClick(prompt.save, "LeftButton")
    test.assertEqual("add 3 Attend an event false", lastEdit(world))
    click(editor.addNote)
    prompt.single:SetValue("Interview")
    prompt.save.scripts.OnClick(prompt.save, "LeftButton")
    test.assertEqual("add 3 Interview true", lastEdit(world))

    local rules = editor.itemRows[1]
    test.assertEqual("Read the rules", rules.label.text)
    test.assertEqual("Checkbox", rules.kind.text)
    test.assertFalse(rules.up.shown, "the first can't go up")
    click(rules.down)
    test.assertEqual("move 3 rules 1", lastEdit(world))
    click(editor.itemRows[2].up)
    test.assertEqual("move 3 interview -1", lastEdit(world))

    click(editor.itemRows[1].rename)
    test.assertEqual("Read the rules", prompt.single:GetValue())
    prompt.single:SetValue("Read the guild rules")
    prompt.save.scripts.OnClick(prompt.save, "LeftButton")
    test.assertEqual("rename 3 rules Read the guild rules", lastEdit(world))
end)

test.test("rank management page: Delete warns that the check's ticks go too, and asks first", function()
    local world = setup()
    local editor = requirementsTab(world)
    local row = editor.itemRows[1]
    local before = #world.edits

    click(row.delete)
    test.assertTrue(row.warning.shown)
    test.assertEqual("Delete \"Read the rules\"? Every tick and note on it is dropped too.", row.warning.text)
    test.assertFalse(row.rename.shown)
    click(row.cancel)
    test.assertFalse(row.warning.shown)
    test.assertFalse(string.find(lastEdit(world), "delete", 1, true) ~= nil)

    click(row.delete)
    click(row.confirm)
    test.assertEqual("delete 3 rules", lastEdit(world))
    test.assertFalse(row.warning.shown)
    test.assertTrue(#world.edits > before)
end)

test.test("rank management page: each rank has its alts switch and its snooze length", function()
    local world = setup()
    local editor = requirementsTab(world)

    test.assertTrue(editor.matchAlts:IsOn())
    test.assertEqual("Alts should match this rank", editor.matchAltsText.text)
    click(editor.matchAlts)
    test.assertEqual("matchAlts 3 false", lastEdit(world))
    test.assertEqual(7, editor.snooze:GetValue())
    editor.snooze:Step(1)
    test.assertEqual("snoozeDays 3 8", lastEdit(world))
end)
