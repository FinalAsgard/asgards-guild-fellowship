local test = require("tests.test_helper")

local addon = test.newAddon("Core/SettingsLayout.lua")
local Layout = addon.SettingsLayout
local ROW, HEADER, GAP, TOP = Layout.ROW, Layout.HEADER, Layout.SECTION_GAP, Layout.TOP

local function section(id, entries)
    return { id = id, label = id, entries = entries }
end

local function toggle(id)
    return { id = id, kind = "toggle", label = id }
end

test.test("settings layout: headers and entries stack down from the top, each section followed by a gap", function()
    local layout = Layout.Layout({
        section("general", { toggle("minimap"), { id = "version", kind = "text" } }),
        section("chatTags", { toggle("chatTags") }),
    })

    test.assertEqual(5, #layout.items)
    test.assertEqual("header", layout.items[1].kind)
    test.assertEqual(TOP, layout.items[1].y)
    test.assertEqual(HEADER, layout.items[1].height)
    test.assertEqual(TOP + HEADER, layout.byId.minimap.y)
    test.assertEqual(ROW, layout.byId.minimap.height)
    test.assertEqual(TOP + HEADER + ROW, layout.byId.version.y)
    local second = TOP + HEADER + 2 * ROW + GAP
    test.assertEqual(second, layout.items[4].y)
    test.assertEqual("chatTags", layout.items[4].section.id)
    test.assertEqual(second + HEADER, layout.byId.chatTags.y)
    test.assertEqual(second + HEADER + ROW + GAP, layout.height)
end)

test.test("settings layout: a text box takes two rows, a taller box and a slider more", function()
    local layout = Layout.Layout({
        section("recruitment", {
            { id = "ad", kind = "input", label = "My ad", maxLength = 255 },
            { id = "guildAd", kind = "input", label = "Guild ad", maxLength = 255, lines = 3 },
            { id = "gap", kind = "number", slider = true, label = "Gap", min = 5, max = 240 },
            toggle("after"),
        }),
    })

    test.assertEqual(2 * ROW, layout.byId.ad.height)
    -- Three lines of text and the box's insets need three rows below the label.
    test.assertEqual(4 * ROW, layout.byId.guildAd.height)
    test.assertEqual(2 * ROW, layout.byId.gap.height)
    test.assertEqual(TOP + HEADER + 8 * ROW, layout.byId.after.y)
end)

test.test("settings layout: an entry that isn't shown takes no room, and a heading has a gap above it", function()
    local officer = false
    local sections = {
        section("recruitment", {
            toggle("optIn"),
            { id = "officerHeading", kind = "heading", label = "Officer settings", officerOnly = true },
            { id = "paused", kind = "toggle", label = "Paused", officerOnly = true },
            toggle("last"),
        }),
    }
    local function isShown(entry)
        return officer or not entry.officerOnly
    end

    local member = Layout.Layout(sections, isShown)
    test.assertEqual(nil, member.byId.officerHeading)
    test.assertEqual(nil, member.byId.paused)
    test.assertEqual(TOP + HEADER + ROW, member.byId.last.y)
    test.assertEqual(TOP + HEADER + 2 * ROW + GAP, member.height)

    officer = true
    local shown = Layout.Layout(sections, isShown)
    test.assertEqual(TOP + HEADER + ROW + GAP, shown.byId.officerHeading.y)
    test.assertEqual(TOP + HEADER + 3 * ROW + GAP, shown.byId.last.y)
    test.assertEqual(member.height + 2 * ROW + GAP, shown.height)
end)

test.test("settings layout: a list taller than its frame reports the height to scroll through", function()
    local entries = {}
    local index
    for index = 1, 30 do
        table.insert(entries, toggle("setting" .. index))
    end

    local layout = Layout.Layout({ section("many", entries) })

    test.assertEqual(TOP + HEADER + 30 * ROW + GAP, layout.height)
    -- Taller than the master frame's default height, so the page scrolls.
    test.assertTrue(layout.height > 560)
end)

test.test("settings layout: a color takes its label's row and a row of swatches", function()
    local layout = Layout.Layout({
        section("chatTags", {
            { id = "aliasColor", kind = "color", label = "Alias tag color", swatches = {} },
            toggle("after"),
        }),
    })

    test.assertEqual(2 * ROW, layout.byId.aliasColor.height)
    test.assertEqual(TOP + HEADER + 2 * ROW, layout.byId.after.y)
end)
