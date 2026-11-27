local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- The Rank management page on fake frames, over a Due list held here.
local function setup()
    local addon = test.newAddon("Core/ListWindow.lua", "Core/RankUpViewModel.lua", "Adapters/Theme.lua",
        "Adapters/Widgets.lua", "Adapters/RankManagementPage.lua")
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local content = environment.CreateFrame("Frame")
    local world = { addon = addon, searches = {} }
    world.rows = {
        { playerId = 1, name = "TheTool", status = "Ready", rankText = "→ Member", promoteText = "Toolbox, Hammer" },
        { playerId = 2, name = "Bolt", status = "Due", rankText = "→ Veteran", waitingText = "Discord name · Interview" },
    }
    world.page = addon.RankManagementPage.Create(content, ui, {
        model = function(search)
            table.insert(world.searches, search)
            local rows = {}
            local _, row
            for _, row in ipairs(world.rows) do
                if string.find(string.lower(row.name), string.lower(search), 1, true) then
                    table.insert(rows, row)
                end
            end
            return { rows = rows, count = #world.rows, footer = "1 Ready · 1 Due · Promotion happens on the guild roster." }
        end,
    })
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
