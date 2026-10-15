local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local contains = fakeFrames.contains

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
    return frame
end

-- The add-on loaded from the client's manifest and logged in, then given
-- frames that can draw and the client's options API, and its AddOns
-- options registered. Retail is given the newer Settings API, Forever the
-- older Interface Options. Returns the world, the add-on, the master frame
-- stand-in, and the options pages in order ({ name, frame, parent }).
local function withOptions(profile)
    local world = fixtures.newEnvironment(profile)
    local addon = fixtures.loadAddon(world)
    local frame = newFrame()
    addon.RosterWindow.Create = function()
        return frame
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")

    local environment = world.environment
    fakeFrames.install(environment)
    local pages = {}
    if profile == "Retail" then
        environment.Settings = {
            RegisterCanvasLayoutCategory = function(page, name)
                local category = { ID = 1 }
                table.insert(pages, { name = name, frame = page })
                return category
            end,
            RegisterCanvasLayoutSubcategory = function(parent, page, name)
                table.insert(pages, { name = name, frame = page, parent = parent })
                return { ID = #pages }
            end,
            RegisterAddOnCategory = function() end,
        }
    else
        environment.InterfaceOptions_AddCategory = function(page)
            table.insert(pages, { name = page.name, frame = page, parent = rawget(page, "parent") })
        end
    end
    test.assertTrue(addon.settingsPanel:Register(), profile .. " registers its options")
    return world, addon, frame, pages
end

local function widgetFor(panel, id)
    local index
    for index = 1, #panel.widgets do
        if panel.widgets[index].id == id then
            return panel.widgets[index]
        end
    end
    return nil
end

local function registerProfileTests(profile)
    test.test(profile .. " AddOns options: each feature has its own sub-page under the add-on's page", function()
        local _, addon, _, pages = withOptions(profile)

        test.assertEqual(6, #pages)
        test.assertEqual(addon.Identity.displayName, pages[1].name)
        test.assertEqual(nil, pages[1].parent)
        local expected = { "General", "Chat Tags", "Guild Greet", "Group Finder", "Recruitment" }
        local index
        for index = 1, #expected do
            local page = pages[index + 1]
            test.assertEqual(expected[index], page.name)
            test.assertTrue(page.parent ~= nil, expected[index] .. " sits under the add-on's page")
        end
        test.assertTrue(contains(pages[2].frame.texts, "Show the minimap button"))
        test.assertTrue(contains(pages[3].frame.texts, "Tag guild chat speakers with their alias or main"))
        test.assertTrue(contains(pages[4].frame.texts, "Offer to greet guild members as they come online"))
        test.assertTrue(contains(pages[5].frame.texts, "Do Not Disturb: no group requests, on every character"))
        -- Role preferences are changed on My Profile, not here.
        test.assertFalse(widgetFor(addon.settingsPanel, "role_tank").frame.shown)
        test.assertTrue(contains(pages[6].frame.texts, "My ad, posted exactly as written"))
        -- The add-on's own page holds the Open window button and the version,
        -- and no feature's settings.
        test.assertTrue(contains(pages[1].frame.texts, "Open window"))
        test.assertFalse(contains(pages[1].frame.texts, "Show the minimap button"))
        local version = widgetFor(addon.settingsPanel, "aboutVersion")
        test.assertContains(version.frame.text, "Version ")
    end)

    test.test(profile .. " AddOns options: Open window opens the master frame on the Roster tab", function()
        local _, addon, frame = withOptions(profile)
        addon.pages:Select("settings")
        local button = widgetFor(addon.settingsPanel, "openWindow").frame

        button.scripts.OnClick(button)

        test.assertTrue(frame.shown)
        test.assertEqual("roster", frame.pages[#frame.pages])
    end)

    test.test(profile .. " AddOns options: a setting changed there reads back on the frame's tab, and back", function()
        local world, addon = withOptions(profile)
        local tab = world.environment.CreateFrame("Frame")
        addon.frameSettings:Draw(tab, addon.settings:SectionsOn("settings"), 28)
        addon.frameSettings:Refresh()
        local inOptions = widgetFor(addon.settingsPanel, "chatTags").frame
        local onTab = widgetFor(addon.frameSettings, "chatTags").frame
        test.assertTrue(onTab.checked)

        inOptions.checked = false
        inOptions.scripts.OnClick(inOptions)
        test.assertFalse(world.database.chatTags)
        test.assertFalse(onTab.checked)

        onTab.checked = true
        onTab.scripts.OnClick(onTab)
        test.assertTrue(world.database.chatTags)
        test.assertTrue(inOptions.checked)
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("AddOns options: officer settings are hidden from members on their sub-page", function()
    local _, addon = withOptions("Retail")

    -- The fixture's logged-in character isn't an officer.
    test.assertFalse(widgetFor(addon.settingsPanel, "recruitGuildAd").row.shown)
    test.assertFalse(widgetFor(addon.settingsPanel, "recruitOfficerHeading").row.shown)
    test.assertTrue(widgetFor(addon.settingsPanel, "recruitOptIn").row.shown)
end)

test.test("AddOns options: with neither options API, nothing is registered and nothing raises", function()
    local world = fixtures.newEnvironment("Forever")
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fakeFrames.install(world.environment)

    local ok, registered = pcall(addon.settingsPanel.Register, addon.settingsPanel)

    test.assertTrue(ok)
    test.assertFalse(registered)
end)
