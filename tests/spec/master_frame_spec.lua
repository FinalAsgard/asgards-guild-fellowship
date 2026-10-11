local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

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
    function frame:SetStatus() end
    function frame:SetRows() return true end
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
    addon.RosterWindow.Create = function()
        return frame
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    return world, addon, frame, broker.objects[world.addonName]
end

local function registerProfileTests(profile)
    test.test(profile .. " /agf and /agf roster open the frame on the Roster tab", function()
        local world, addon, frame = loggedIn(profile)

        fixtures.slash(world, "")
        test.assertTrue(frame.shown)
        test.assertEqual("roster", frame:LastPage())

        fixtures.slash(world, "")
        test.assertFalse(frame.shown)

        fixtures.slash(world, "roster")
        test.assertTrue(frame.shown)
        test.assertEqual("roster", addon.pages:Current())
    end)

    test.test(profile .. " the minimap button opens the frame on the Roster tab, whatever tab showed last", function()
        local _, addon, frame, launcher = loggedIn(profile)
        addon.pages:Add("other", "Other", "other.blp")

        launcher.OnClick()
        test.assertTrue(frame.shown)
        test.assertEqual("roster", frame:LastPage())

        -- Another tab is showing: the button brings the Roster tab back
        -- instead of closing the frame.
        addon.pages:Select("other")
        launcher.OnClick()
        test.assertTrue(frame.shown)
        test.assertEqual("roster", frame:LastPage())
        test.assertEqual("roster", addon.pages:Current())

        -- Closed on another tab, it reopens on Roster.
        addon.pages:Select("other")
        frame:Hide()
        launcher.OnClick()
        test.assertTrue(frame.shown)
        test.assertEqual("roster", addon.pages:Current())
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

        -- /agf brings the Roster tab back.
        fixtures.slash(world, "")
        test.assertTrue(frame.shown)
        test.assertEqual("roster", frame:LastPage())
    end)

    test.test(profile .. " the guild window's button opens the frame on the Roster tab", function()
        local world, addon, frame = loggedIn(profile)
        addon.pages:Add("other", "Other", "other.blp")
        addon.pages:Select("other")

        addon.entryPoints.toggle()

        test.assertTrue(frame.shown)
        test.assertEqual("roster", addon.pages:Current())
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

test.test("the add-on compartment opens the frame on the Roster tab", function()
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

    entry.func()

    test.assertTrue(frame.shown)
    test.assertEqual("roster", frame:LastPage())
end)
