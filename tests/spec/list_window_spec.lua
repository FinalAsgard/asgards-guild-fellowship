local test = require("tests.test_helper")

local function setup()
    return test.newAddon("Core/ListWindow.lua").ListWindow
end

-- The visible rows' indexes and tops, as "index@top" in order.
local function shown(window)
    if window.first == nil then
        return ""
    end
    local parts = {}
    local index
    for index = window.first, window.last do
        if window.tops[index] ~= nil then
            table.insert(parts, index .. "@" .. window.tops[index])
        end
    end
    return table.concat(parts, " ")
end

test.test("list window: fixed rows at the top show only what fits, the last one partly", function()
    local ListWindow = setup()
    local window = ListWindow.Visible(100, 40, 100, 0)

    test.assertEqual("1@0 2@40 3@80", shown(window))
    test.assertEqual(4000, window.total)
    test.assertEqual(0, window.offset)
end)

test.test("list window: fixed rows in the middle are placed relative to the viewport", function()
    local ListWindow = setup()
    local window = ListWindow.Visible(100, 40, 100, 1010)

    test.assertEqual("26@-10 27@30 28@70", shown(window))
end)

test.test("list window: scrolling past the end stops with the last row at the bottom", function()
    local ListWindow = setup()
    local window = ListWindow.Visible(10, 40, 100, 9999)

    test.assertEqual(300, window.offset)
    -- Row 10 ends at 400, the viewport's bottom; row 8 is cut off above.
    test.assertEqual("8@-20 9@20 10@60", shown(window))
end)

test.test("list window: offsets are clamped to the top and to the end", function()
    local ListWindow = setup()

    test.assertEqual(0, ListWindow.Clamp(-50, 400, 100))
    test.assertEqual(300, ListWindow.Clamp(500, 400, 100))
    test.assertEqual(120, ListWindow.Clamp(120, 400, 100))
    -- A list shorter than the viewport never scrolls.
    test.assertEqual(0, ListWindow.Clamp(50, 60, 100))
end)

test.test("list window: mixed heights place each row after the ones above it", function()
    local ListWindow = setup()
    -- A 20px label, then cards of 48px, with a label again at row 5.
    local function height(index)
        return (index == 1 or index == 5) and 20 or 48
    end
    local window = ListWindow.Visible(8, height, 150, 0)

    test.assertEqual("1@0 2@20 3@68 4@116", shown(window))

    window = ListWindow.Visible(8, height, 100, 150)
    -- Row 4 spans 116..164, the label 164..184, row 6 184..232 and row 7
    -- 232..280, cut off at 250.
    test.assertEqual("4@-34 5@14 6@34 7@82", shown(window))
    test.assertEqual(20 + 48 * 6 + 20, window.total)
end)

test.test("list window: an empty list shows nothing", function()
    local ListWindow = setup()
    local window = ListWindow.Visible(0, 40, 100, 30)

    test.assertEqual(nil, window.first)
    test.assertEqual(0, window.offset)
    test.assertEqual(0, window.total)
end)

test.test("list window: a single row shows at the top and doesn't scroll", function()
    local ListWindow = setup()
    local window = ListWindow.Visible(1, 40, 100, 25)

    test.assertEqual("1@0", shown(window))
    test.assertEqual(0, window.offset)
end)

test.test("list window: keeping a row in view leaves the offset when it already shows", function()
    local ListWindow = setup()

    test.assertEqual(200, ListWindow.KeepInView(7, 100, 40, 100, 200))
end)

test.test("list window: keeping a row in view scrolls up to its top, or down to its bottom", function()
    local ListWindow = setup()

    -- Row 3 (80..120) is above a list scrolled to 200.
    test.assertEqual(80, ListWindow.KeepInView(3, 100, 40, 100, 200))
    -- Row 20 (760..800) is below it: it ends at the bottom.
    test.assertEqual(700, ListWindow.KeepInView(20, 100, 40, 100, 200))
end)

test.test("list window: a kept row stays in view as rows are added or removed above it", function()
    local ListWindow = setup()
    -- The selected row was 10 (360..400) at offset 320; two rows are added
    -- above it, so it's now row 12 (440..480).
    test.assertEqual(380, ListWindow.KeepInView(12, 102, 40, 100, 320))
    -- Rows removed: the list is only 5 long, so the offset falls back.
    test.assertEqual(100, ListWindow.KeepInView(5, 5, 40, 100, 320))
    -- A row that's gone keeps the offset, clamped.
    test.assertEqual(100, ListWindow.KeepInView(nil, 5, 40, 100, 320))
end)

test.test("list window: keeping a row in view works with mixed heights", function()
    local ListWindow = setup()
    local function height(index)
        return index == 1 and 20 or 48
    end
    -- Row 6 spans 20 + 4 * 48 = 212..260.
    test.assertEqual(160, ListWindow.KeepInView(6, 20, height, 100, 0))
    test.assertEqual(212, ListWindow.KeepInView(6, 20, height, 100, 400))
end)

test.test("list window: an empty viewport shows nothing but keeps the offset and total", function()
    local ListWindow = setup()
    local window = ListWindow.Visible(10, 40, 0, 10)

    test.assertEqual(nil, window.first)
    test.assertEqual(400, window.total)
    test.assertEqual(10, window.offset)
end)

test.test("list window: a row with no height doesn't show between the rows around it", function()
    local ListWindow = setup()
    local function height(index)
        return index == 2 and 0 or 40
    end
    local window = ListWindow.Visible(3, height, 80, 0)

    test.assertEqual("1@0 3@40", shown(window))
    test.assertEqual(nil, window.tops[2])
end)

test.test("list window: keeping a fractional row in view only clamps the offset", function()
    local ListWindow = setup()
    local function height(index)
        return index == 1 and 20 or 40
    end

    test.assertEqual(20, ListWindow.KeepInView(1.5, 3, height, 40, 20))
end)
