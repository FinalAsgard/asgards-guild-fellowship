local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local function newNavigator()
    local addon = test.newAddon("Core/PageNavigator.lua")
    return addon.PageNavigator.Create()
end

test.test("pages are listed as tabs in the order they were added", function()
    local pages = newNavigator()

    test.assertTrue(pages:Add("roster", "Roster", "roster.blp"))
    test.assertTrue(pages:Add("settings", "Settings", "settings.blp"))
    test.assertFalse(pages:Add("roster", "Again", "again.blp"))

    local tabs = pages:Tabs()
    test.assertEqual(2, #tabs)
    test.assertEqual("roster", tabs[1].id)
    test.assertEqual("Roster", tabs[1].label)
    test.assertEqual("roster.blp", tabs[1].icon)
    test.assertTrue(tabs[1].selected)
    test.assertEqual("settings", tabs[2].id)
    test.assertFalse(tabs[2].selected)
end)

test.test("the first page added is current until another is selected", function()
    local pages = newNavigator()
    test.assertEqual(nil, pages:Current())
    pages:Add("roster", "Roster", "roster.blp")
    pages:Add("settings", "Settings", "settings.blp")

    test.assertEqual("roster", pages:Current())
    test.assertTrue(pages:Select("settings"))
    test.assertEqual("settings", pages:Current())
    test.assertTrue(pages:Tabs()[2].selected)
    test.assertFalse(pages:Tabs()[1].selected)
end)

test.test("selecting an unknown page leaves the current page as it is", function()
    local pages = newNavigator()
    pages:Add("roster", "Roster", "roster.blp")
    pages:Add("settings", "Settings", "settings.blp")
    pages:Select("settings")

    test.assertFalse(pages:Select("missing"))
    test.assertFalse(pages:Select(nil))
    test.assertEqual("settings", pages:Current())
end)

test.test("general entry points open the Roster page and a page command opens its page", function()
    local pages = newNavigator()
    pages:Add("roster", "Roster", "roster.blp")
    pages:Add("settings", "Settings", "settings.blp")
    pages:Select("settings")

    test.assertEqual("roster", pages:PageFor(nil))
    test.assertEqual("roster", pages:PageFor("minimap"))
    test.assertEqual("roster", pages:PageFor("compartment"))
    test.assertEqual("roster", pages:PageFor("guildButton"))
    test.assertEqual("settings", pages:PageFor("settings"))
end)

-- The composed add-on ------------------------------------------------------

-- A master frame that records what it was asked to show.
local function newFrame()
    local frame = { shown = false, pages = {} }
    function frame:IsShown() return self.shown end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:SetTitle() end
    function frame:SetConflicts() return true end
    function frame:SetRecruiters() return true end
    function frame:ShowPage(id)
        table.insert(self.pages, id)
        return true
    end
    function frame:LastPage() return self.pages[#self.pages] end
    return frame
end

-- Fake LibDataBroker and LibDBIcon, so the minimap button registers.
local function installMinimapLibraries(environment)
    local broker = { objects = {} }
    function broker:NewDataObject(name, object)
        self.objects[name] = object
        return object
    end
    local icon = {}
    function icon:Register() end
    environment.LibStub.libs["LibDataBroker-1.1"] = broker
    environment.LibStub.libs["LibDBIcon-1.0"] = icon
    return broker
end

-- The add-on loaded from the client's manifest and logged in, with its
-- frame replaced by a recording one (the fixtures' framework can't build
-- frames).
local function loggedIn(profile)
    local world = fixtures.newEnvironment(profile)
    local broker = installMinimapLibraries(world.environment)
    local addon = fixtures.loadAddon(world)
    local frame = newFrame()
    -- The options the add-on built the frame with, kept for the specs.
    addon.RosterWindow.Create = function(_, options)
        frame.options = options
        return frame
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    return world, addon, frame, broker.objects[world.addonName]
end

local function registerProfileTests(profile)
    test.test(profile .. " /agf and /agf roster open the new window on the Guild Roster", function()
        local world, addon, frame = loggedIn(profile)
        fakeFrames.install(world.environment)

        fixtures.slash(world, "")
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())
        test.assertFalse(frame.shown, "the old window stays shut")

        fixtures.slash(world, "")
        test.assertFalse(addon.agfWindow:IsOpen())

        fixtures.slash(world, "roster")
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())
    end)

    test.test(profile .. " the minimap button opens the Guild Roster, whatever page showed last", function()
        local world, addon, _, launcher = loggedIn(profile)
        fakeFrames.install(world.environment)

        launcher.OnClick()
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())

        -- Another page is showing: the button brings the Roster back
        -- instead of closing the window.
        addon.agfWindow:ShowPage("friends")
        launcher.OnClick()
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())

        -- Closed on another page, it reopens on the Roster.
        addon.agfWindow:ShowPage("friends")
        addon.agfWindow:Close()
        launcher.OnClick()
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())
    end)

    test.test(profile .. " /agf options opens the frame on the Settings tab", function()
        local world, addon, frame = loggedIn(profile)

        fixtures.slash(world, "options")
        test.assertTrue(frame.shown)
        test.assertEqual("settings", frame:LastPage())
        test.assertEqual("settings", addon.pages:Current())

        -- Already open: it stays open on Settings.
        fixtures.slash(world, "options")
        test.assertTrue(frame.shown)
        test.assertEqual("settings", frame:LastPage())

        -- /agf opens the Guild Roster in the new window.
        fakeFrames.install(world.environment)
        fixtures.slash(world, "")
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())
    end)

    test.test(profile .. " /agf greet and the options' Edit Greetings button open the new window on Greetings", function()
        local world, addon, frame = loggedIn(profile)
        fakeFrames.install(world.environment)

        fixtures.slash(world, "help")
        test.assertContains(table.concat(world.messages, "\n"), "/agf greet - edit your Guild Greet greetings")

        fixtures.slash(world, "greet")
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("greetings", addon.agfWindow:Page())

        addon.agfWindow:Close()
        test.assertTrue(addon.settings:Run("editGreetings"))
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("greetings", addon.agfWindow:Page())
        -- The button belongs to the options; the window has the page itself.
        test.assertFalse(addon.settings:InHost("editGreetings", "frame"))
        test.assertTrue(addon.settings:InHost("editGreetings", "options"))
    end)

    test.test(profile .. " the old window has no Greetings or Roster tab; it opens on My Profile", function()
        local world, addon, frame = loggedIn(profile)

        fixtures.slash(world, "profile")
        test.assertTrue(frame.shown)
        test.assertEqual("profile", frame:LastPage())
        local ids = {}
        local _, page
        for _, page in ipairs(addon.pages:Pages()) do
            table.insert(ids, page.id)
        end
        test.assertFalse(string.find(table.concat(ids, ","), "greetings", 1, true) ~= nil)
        test.assertFalse(string.find(table.concat(ids, ","), "roster", 1, true) ~= nil)
        test.assertContains(table.concat(ids, ","), "profile,recruitment,ads")
        test.assertEqual(nil, addon.GreetingsPage)
    end)

    test.test(profile .. " unlocked greet prompts stay unlocked on any tab and lock when the frame closes", function()
        local world, addon, frame = loggedIn(profile)
        -- Frames that can draw, so the prompts can be unlocked.
        fakeFrames.install(world.environment)
        fixtures.slash(world, "greet")
        test.assertTrue(addon.settings:Run("greetMove"))
        test.assertEqual("Done moving", addon.settings:Label("greetMove"))

        -- Moving between tabs keeps the mode on.
        fixtures.slash(world, "options")
        fixtures.slash(world, "recruit")
        test.assertTrue(addon.settings:IsActive("greetMove"))

        -- Pressing Done moving locks them again.
        test.assertTrue(addon.settings:Run("greetMove"))
        test.assertFalse(addon.settings:IsActive("greetMove"))

        -- The frame closing (Escape, its close button, or /agf) ends it.
        test.assertTrue(addon.settings:Run("greetMove"))
        frame:Hide()
        frame.options.onHide()
        test.assertFalse(addon.settings:IsActive("greetMove"))
        test.assertEqual("Move greeting pop-ups", addon.settings:Label("greetMove"))
    end)

    test.test(profile .. " the guild window's button opens the Guild Roster", function()
        local world, addon = loggedIn(profile)
        fakeFrames.install(world.environment)

        addon.entryPoints.toggle()

        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("roster", addon.agfWindow:Page())
        test.assertEqual(0, #world.messages)
    end)

    test.test(profile .. " a frame that can't be built prints a message instead of raising", function()
        local world = fixtures.newEnvironment(profile)
        fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")

        local ok = pcall(fixtures.slash, world, "")

        test.assertTrue(ok)
        test.assertContains(world.messages[#world.messages], "can't open")
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("the add-on compartment opens the Guild Roster", function()
    local world = fixtures.newEnvironment("Retail")
    local entry
    world.environment.AddonCompartmentFrame = {
        RegisterAddon = function(_, info)
            entry = info
        end,
    }
    local addon = fixtures.loadAddon(world)
    local frame = newFrame()
    addon.RosterWindow.Create = function()
        return frame
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")

    fakeFrames.install(world.environment)
    entry.func()

    test.assertTrue(addon.agfWindow:IsOpen())
    test.assertEqual("roster", addon.agfWindow:Page())
    test.assertFalse(frame.shown, "not the old window")
end)

test.test("no window closes on a right-click: every framework panel turns that off", function()
    local listing = io.popen("ls Adapters")
    local checked = 0
    local name
    for name in listing:lines() do
        if string.match(name, "%.lua$") then
            local handle = assert(io.open("Adapters/" .. name, "r"))
            local source = handle:read("*a")
            handle:close()
            local _, made = string.gsub(source, ":CreateSimplePanel%(", "")
            local _, guarded = string.gsub(source, "panel%.DontRightClickClose = true", "")
            test.assertEqual(made, guarded, name .. " makes " .. made .. " panels, " .. guarded .. " kept open on right-click")
            checked = checked + made
        end
    end
    listing:close()
    test.assertTrue(checked >= 3, "found the panels")
end)

-- The specs stand in for RosterWindow.Create, so the real window's parts are
-- checked in its source: every part Create keeps must come back from build.
-- The patterns read RosterWindow.lua's layout: build's one-line
-- "    return host, conflicts, ..." and Create's "local ok, host, ... = pcall(build,".
-- A failure on "found build's return" means that layout changed, not a part.
test.test("the roster window keeps every part build makes, the Guild Log page included", function()
    local handle = assert(io.open("Adapters/RosterWindow.lua", "r"))
    local source = handle:read("*a")
    handle:close()
    local function names(list)
        local set = {}
        local name
        for name in string.gmatch(list, "[%a_][%w_]*") do
            set[name] = true
        end
        return set
    end
    local returned = string.match(source, "\n    return (host, conflicts, [^\n]+)\nend\n")
    local captured = string.match(source, "local ok, (host, [^=]+)=%s*pcall%(build,")
    test.assertTrue(returned ~= nil and captured ~= nil, "found build's return and Create's call")
    returned, captured = names(returned), names(captured)
    local create = string.match(source, "function RosterWindow%.Create%(.-\nend\n")
    local kept = 0
    local field, value
    for field, value in string.gmatch(create, "\n%s+([%a_][%w_]*) = ([%a_][%w_]*),") do
        if field == value then
            test.assertTrue(captured[field], "Create keeps " .. field .. " without taking it from build")
            test.assertTrue(returned[field], "build doesn't return " .. field)
            kept = kept + 1
        end
    end
    test.assertTrue(kept >= 5, "found the window's parts")
    test.assertTrue(returned.guildLog, "build returns the Guild Log page")
end)

-- A frame that remembers its one point, as the game reports it back.
local function pointFrame()
    local frame = {}
    function frame:ClearAllPoints()
        self.point = nil
    end
    function frame:SetPoint(point, relativeTo, relativePoint, x, y)
        if type(x) ~= "number" then
            error("bad offset")
        end
        self.point = { point, relativeTo, relativePoint, x, y }
    end
    function frame:GetPoint()
        if self.point == nil then
            return nil
        end
        return unpack(self.point)
    end
    return frame
end

test.test("a pop-out panel opens where it was left, else beside the master frame", function()
    local addon = test.newAddon("Adapters/MasterFrame.lua")
    local screen, master = {}, {}

    local panel = pointFrame()
    addon.MasterFrame.PlacePopOut(panel, master, nil, screen)
    test.assertEqual("TOPLEFT", panel.point[1])
    test.assertEqual(master, panel.point[2])
    test.assertEqual("TOPRIGHT", panel.point[3])
    test.assertEqual(addon.MasterFrame.SIDE_OFFSET, panel.point[4])
    -- Still beside the frame: nothing to save, so it keeps following it.
    test.assertEqual(nil, addon.MasterFrame.PopOutPosition(panel, screen))

    -- Dragged: the game re-anchors it to the screen.
    panel:SetPoint("TOPLEFT", nil, "BOTTOMLEFT", 900, 700)
    local position = addon.MasterFrame.PopOutPosition(panel, screen)
    test.assertEqual("TOPLEFT", position.point)
    test.assertEqual("BOTTOMLEFT", position.relativePoint)
    test.assertEqual(900, position.x)
    test.assertEqual(700, position.y)

    -- After a reload it opens there.
    local reopened = pointFrame()
    addon.MasterFrame.PlacePopOut(reopened, master, position, screen)
    test.assertEqual(screen, reopened.point[2])
    test.assertEqual(900, reopened.point[4])
    test.assertEqual(700, reopened.point[5])
    test.assertEqual(900, addon.MasterFrame.PopOutPosition(reopened, screen).x)

    -- Something unusable saved: beside the frame again.
    local fallback = pointFrame()
    addon.MasterFrame.PlacePopOut(fallback, master, { point = "TOPLEFT", relativePoint = "TOPLEFT", x = "far",
        y = 1 }, screen)
    test.assertEqual(master, fallback.point[2])
end)

-- The old window draws no roster; its Settings page holds the guild note
-- Conflicts button (see RosterWindow's build), until conflicts are retired.
test.test("the old window has no roster, and its Settings page holds the Conflicts button", function()
    local handle = assert(io.open("Adapters/RosterWindow.lua", "r"))
    local source = handle:read("*a")
    handle:close()
    test.assertFalse(string.find(source, "host:Content(\"roster\")", 1, true) ~= nil, "no Roster page")
    test.assertTrue(string.find(source, "local settingsPage = host:Content(\"settings\")", 1, true) ~= nil)
    test.assertTrue(string.find(source, "CreateFrame(\"Button\", nil, settingsPage, \"UIPanelButtonTemplate\")", 1,
        true) ~= nil, "the Conflicts button is made on the Settings page")
end)
