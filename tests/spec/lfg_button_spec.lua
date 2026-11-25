local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

-- The button on its own -------------------------------------------------------

-- An LFG button over fake frames whose shown setting is `state.shown`,
-- with `extra` options on top of the usual.
local function newButton(extra)
    local addon = test.newAddon("Adapters/Theme.lua", "Adapters/Widgets.lua", "Core/LfgDrawerModel.lua",
        "Adapters/LfgButton.lua")
    local environment = fakeFrames.install({})
    local state = { shown = true, opened = 0, hidden = 0 }
    local options = {
        frameName = "AgfTestLfgButton",
        shown = function()
            return state.shown
        end,
        onOpenBoard = function()
            state.opened = state.opened + 1
        end,
        onHide = function()
            state.hidden = state.hidden + 1
            state.shown = false
        end,
        loadPosition = function()
            return state.position
        end,
        savePosition = function(position)
            state.saved = position
        end,
    }
    local name, value
    for name, value in pairs(extra or {}) do
        options[name] = value
    end
    local button = addon.LfgButton.Create({ environment = environment }, options)
    return button, state
end

local function rightClick(button)
    button.button.scripts.OnClick(button.button, "RightButton")
end

test.test("lfg button: shows or hides as its setting says, made the first time it shows", function()
    local button, state = newButton()
    state.shown = false

    test.assertFalse(button:Refresh())
    test.assertEqual(nil, button.button)

    state.shown = true
    test.assertTrue(button:Refresh())
    test.assertTrue(button:IsShowing())
    test.assertTrue(button.button.shown)

    state.shown = false
    button:Refresh()
    test.assertFalse(button:IsShowing())
    test.assertFalse(button.button.shown)
end)

test.test("lfg button: Show Nearby opens the drawer on the guildmates nearby, each name a whisper menu", function()
    local whispered = {}
    local people = {
        { name = "Hammer", whisper = "Hammer-Camelot", level = 24, classToken = "WARRIOR" },
        { name = "Zap", whisper = "Zap-Camelot" },
    }
    local button = newButton({
        nearby = function() return { zone = "Ironforge", people = people } end,
        classColor = function(classToken) return classToken == "WARRIOR" and "ffc79c6e" or nil end,
        onWhisper = function(name) table.insert(whispered, name) end,
    })
    button:Refresh()
    button:Update({ count = 0, fresh = {}, top = { kind = "none" } })

    rightClick(button)
    button.menu.rows[2].scripts.OnClick(button.menu.rows[2])
    local drawer = button.drawer
    test.assertTrue(button:DrawerOpen())
    test.assertEqual("NEARBY IN IRONFORGE", drawer.heading.text)
    test.assertTrue(drawer.nearby.shown)
    test.assertFalse(button.startButton.shown)
    test.assertFalse(drawer.nearby.empty.shown)
    -- A guildmate per line, the level left of the name in class color.
    local rows = drawer.nearby.rows
    test.assertEqual("24", rows[1].level.text)
    test.assertEqual("|cffc79c6eHammer|r", rows[1].name.text)
    test.assertEqual("", rows[2].level.text)
    test.assertEqual("Zap", rows[2].name.text)
    -- A name opens a menu with it at the top, and Whisper.
    rows[2].scripts.OnClick(rows[2])
    test.assertTrue(button.nameMenu:IsOpen())
    test.assertEqual("Zap", button.nameMenu.titleText)
    button.nameMenu.rows[1].scripts.OnClick(button.nameMenu.rows[1])
    test.assertEqual("Zap-Camelot", whispered[1])

    -- Closed, the drawer goes back to its usual contents.
    button:CloseDrawer()
    button:OpenDrawer()
    test.assertFalse(drawer.nearby.shown)
    test.assertEqual("NEW FOR YOU", drawer.heading.text)
    test.assertTrue(button.startButton.shown)

    -- Nobody nearby: one line.
    people = {}
    button:CloseDrawer()
    button:ShowNearby()
    test.assertTrue(drawer.nearby.empty.shown)
    test.assertFalse(rows[1].shown)
end)

test.test("lfg button: right-click offers Open Guild LFG Board, Show Nearby and Hide LFG button", function()
    local button, state = newButton()
    button:Refresh()

    rightClick(button)
    local menu = button.menu
    test.assertTrue(menu:IsOpen())
    test.assertEqual("Open Guild LFG Board", menu.items[1].label)
    test.assertEqual("Show Nearby", menu.items[2].label)
    test.assertEqual("Hide LFG button", menu.items[3].label)

    menu.rows[1].scripts.OnClick(menu.rows[1])
    test.assertEqual(1, state.opened)
    test.assertFalse(menu:IsOpen())

    rightClick(button)
    menu.rows[3].scripts.OnClick(menu.rows[3])
    test.assertEqual(1, state.hidden)
    button:Refresh()
    test.assertFalse(button:IsShowing())
end)

test.test("lfg button: a left click doesn't open the menu", function()
    local button = newButton()
    button:Refresh()

    button.button.scripts.OnClick(button.button, "LeftButton")

    test.assertFalse(button.menu:IsOpen())
end)

test.test("lfg button: dragged, its place is saved", function()
    local button, state = newButton()
    button:Refresh()
    button.button.GetPoint = function()
        return "CENTER", nil, "CENTER", -300, 120
    end

    button.button.scripts.OnDragStart(button.button)
    button.button.scripts.OnDragStop(button.button)

    test.assertEqual("CENTER", state.saved.point)
    test.assertEqual(-300, state.saved.x)
    test.assertEqual(120, state.saved.y)
end)

-- The composed add-on -----------------------------------------------------------

-- Logs in, then gives the add-on frames that can draw (the fixtures' own
-- frames carry the login events) and shows or hides the button as at login:
-- login refreshes it, which `world.refreshedAtLogin` records.
local function loggedIn(profile, world)
    world = world or fixtures.newEnvironment(profile)
    local addon = fixtures.loadAddon(world)
    local refresh = addon.lfgButton.Refresh
    addon.lfgButton.Refresh = function(self)
        world.refreshedAtLogin = true
        return refresh(self)
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    addon.lfgButton.Refresh = refresh
    fakeFrames.install(world.environment)
    addon.lfgButton:Refresh()
    return world, addon
end

-- Logs in again on the same saved data (a reload or a later login).
local function relog(profile, world)
    local next = fixtures.newEnvironment(profile)
    next.database = world.database
    return loggedIn(profile, next)
end

local function registerProfileTests(profile)
    test.test(profile .. " the LFG button shows at login and its menu opens the board", function()
        local world, addon = loggedIn(profile)

        test.assertTrue(world.refreshedAtLogin)
        test.assertTrue(addon.lfgButton:IsShowing())
        addon.lfgButton:OpenMenu()
        local menu = addon.lfgButton.menu
        menu.rows[1].scripts.OnClick(menu.rows[1])

        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("lfg", addon.agfWindow:Page())
        test.assertEqual(0, #world.messages)
    end)

    test.test(profile .. " a hidden LFG button stays hidden after a reload, until /agf lfg brings it back", function()
        local world, addon = loggedIn(profile)
        addon.lfgButton:OpenMenu()
        local menu = addon.lfgButton.menu
        menu.rows[3].scripts.OnClick(menu.rows[3])

        test.assertFalse(addon.lfgButton:IsShowing())
        test.assertFalse(addon.settings:Get("lfgButton"))
        test.assertContains(world.messages[#world.messages], "/agf lfg")

        local reloaded, again = relog(profile, world)
        test.assertFalse(again.lfgButton:IsShowing())
        -- Nothing brings it back by itself: not opening the window, not a
        -- zone change.
        again.agfWindow:Open("lfg")
        fixtures.fire(reloaded, "ZONE_CHANGED_NEW_AREA")
        test.assertFalse(again.lfgButton:IsShowing())

        fixtures.slash(reloaded, "lfg")
        test.assertTrue(again.lfgButton:IsShowing())
        test.assertTrue(again.agfWindow:IsOpen())
        test.assertEqual("lfg", again.agfWindow:Page())
    end)

    test.test(profile .. " the LFG gear popup's Show LFG button switch hides and shows it", function()
        local _, addon = loggedIn(profile)
        addon.agfWindow:Open("lfg")
        addon.agfWindow:ToggleSettingsPopup()
        local switch = addon.agfWindow:Switches("lfgButton")[1]
        test.assertTrue(switch:IsOn())

        switch.scripts.OnClick(switch)
        test.assertFalse(addon.lfgButton:IsShowing())
        test.assertFalse(switch:IsOn())

        switch.scripts.OnClick(switch)
        test.assertTrue(addon.lfgButton:IsShowing())
        test.assertTrue(switch:IsOn())
    end)

    test.test(profile .. " the LFG button is hidden or shown per character", function()
        local world, addon = loggedIn(profile)
        addon.settings:Set("lfgButton", false)

        -- Another character on the same account.
        local other = fixtures.newEnvironment(profile)
        other.database = world.database
        other.environment.UnitGUID = function()
            return "Player-1-SomeoneElse"
        end
        local _, otherAddon = loggedIn(profile, other)

        test.assertTrue(otherAddon.lfgButton:IsShowing())
        test.assertTrue(otherAddon.settings:Get("lfgButton"))
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("lfg button: its place and hidden state are saved per character", function()
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua")
    local store = addon.FellowshipStore.Create({})

    test.assertTrue(store:LfgButtonShown("Player-1"))
    test.assertTrue(store:SetLfgButtonShown("Player-1", false))
    test.assertFalse(store:LfgButtonShown("Player-1"))
    test.assertTrue(store:LfgButtonShown("Player-2"))
    test.assertTrue(store:SetLfgButtonShown("Player-1", true))
    test.assertTrue(store:LfgButtonShown("Player-1"))

    test.assertTrue(store:SetLfgButtonPosition("Player-1", { point = "TOP", relativePoint = "TOP", x = 1, y = 2 }))
    test.assertEqual("TOP", store:LfgButtonPosition("Player-1").point)
    test.assertEqual(nil, store:LfgButtonPosition("Player-2"))
    -- The window's place sits beside it, untouched.
    test.assertEqual(nil, store:WindowPosition("Player-1"))
end)
