local test = require("tests.test_helper")

-- The greetings editor's frames aren't unit tested (the in-game checklist
-- covers them), but how wide it's drawn, and how its category buttons
-- share that width, are worked out by plain functions.
local function load()
    return test.newAddon("Adapters/GreetingsPage.lua").GreetingsPage
end

test.test("greetings page: the editor takes the page's width, never narrower than its minimum", function()
    local page = load()

    test.assertEqual(708, page.WidthFor(724))
    test.assertEqual(page.WIDTH, page.WidthFor(300))
    test.assertEqual(page.WIDTH, page.WidthFor(nil))
end)

test.test("greetings page: at the master frame's narrowest the whole editor fits the page", function()
    local page = load()
    -- The master frame's smallest width, less the settings' scroll bar and
    -- margins, is the footer the editor is drawn in.
    local footer = 560 - 28 - 8
    local width = page.WidthFor(footer)
    test.assertTrue(width <= footer, "the editor fits its footer")

    -- The four category buttons sit side by side within it.
    local tabWidth, step = page.TabLayout(width, 4)
    test.assertTrue(12 + 3 * step + tabWidth <= width, "the last category button fits")
    -- The text box and its Save, Delete and Cancel buttons fit too.
    local input = width - 264
    test.assertTrue(20 + input + 8 + 70 + 4 + 70 + 4 + 70 <= width, "Cancel fits")
end)

test.test("greetings page: category buttons keep their full width when there's room", function()
    local page = load()

    local tabWidth, step = page.TabLayout(708, 4)

    test.assertEqual(page.TAB_WIDTH, tabWidth)
    test.assertEqual(page.TAB_WIDTH + page.TAB_GAP, step)
end)
