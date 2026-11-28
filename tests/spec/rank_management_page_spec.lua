local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- The Rank management page on fake frames, over a Due list held here.
local function setup()
    local addon = test.newAddon("Core/ListWindow.lua", "Core/RankUpViewModel.lua", "Adapters/Theme.lua",
        "Adapters/Widgets.lua", "Adapters/RankManagementPage.lua")
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local content = environment.CreateFrame("Frame")
    local world = { addon = addon, searches = {}, snoozed = {}, ranks = {}, ticks = {} }
    world.rows = {
        { playerId = 1, key = "toolbox", name = "TheTool", status = "Ready", rankText = "→ Member",
            promoteText = "Toolbox, Hammer" },
        { playerId = 2, key = "bolt", name = "Bolt", status = "Due", rankText = "→ Veteran",
            waitingText = "Discord name · Interview" },
    }
    world.page = addon.RankManagementPage.Create(content, ui, {
        model = function(search, rank)
            table.insert(world.searches, search)
            table.insert(world.ranks, rank or "any")
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
            local index
            for index = #world.rows, 1, -1 do
                if world.rows[index].key == key then
                    table.remove(world.rows, index)
                end
            end
            return world.refuse == nil, world.refuse
        end,
        onError = function(text)
            world.error = text
        end,
        targets = function()
            return { { text = "Any rank" }, { rank = 3, text = "→ Member" }, { rank = 2, text = "→ Veteran" } }
        end,
        onTick = function(key, item, ticked)
            table.insert(world.ticks, { key = key, item = item, ticked = ticked })
            if world.refuse ~= nil then
                return false, world.refuse
            end
            world.checked = ticked
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
            },
            rows = { { playerId = 2, key = "bolt", name = "Bolt", status = "Due", rankText = "→ Member",
                waitingText = "Level 70 · Read the rules",
                cells = {
                    { id = "days", state = "met", text = "≈44 d" },
                    { id = "level", state = "missing", text = "level 66" },
                    { id = "rules", check = true, checked = world.checked == true,
                        state = world.checked and "ticked" or "unticked", text = "" },
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
    test.assertFalse(row.cells[3].text.shown)
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
