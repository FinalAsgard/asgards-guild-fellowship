local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function newModel()
    local addon = test.newAddon("Core/SettingsModel.lua")
    return addon.SettingsModel.Create()
end

-- A toggle backed by a plain table, so a spec can see what was saved.
local function toggle(id, saved, extra)
    local entry = {
        id = id,
        kind = "toggle",
        label = id,
        get = function()
            return saved[id] ~= false
        end,
        set = function(enabled)
            saved[id] = enabled
            return true
        end,
    }
    local key, value
    for key, value in pairs(extra or {}) do
        entry[key] = value
    end
    return entry
end

-- The addon loaded from the client's manifest and logged in, so settings
-- reach the real saved data.
local function loggedIn(profile, options)
    local world = fixtures.newEnvironment(profile, options)
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    return world, addon
end

local function lastMessage(world)
    return world.messages[#world.messages]
end

test.test("settings are listed by section, in the order they were added", function()
    local model = newModel()
    local saved = {}

    test.assertTrue(model:AddSection("general", "General"))
    test.assertTrue(model:AddSection("chat", "Chat Tags"))
    test.assertTrue(model:Add("chat", toggle("tags", saved)))
    test.assertTrue(model:Add("general", toggle("minimap", saved)))
    test.assertTrue(model:Add("general", { id = "open", kind = "action", label = "Open", run = function() end }))

    local sections = model:Sections()
    test.assertEqual(2, #sections)
    test.assertEqual("General", sections[1].label)
    test.assertEqual("minimap", sections[1].entries[1].id)
    test.assertEqual("open", sections[1].entries[2].id)
    test.assertEqual("Chat Tags", sections[2].label)
    test.assertEqual("tags", sections[2].entries[1].id)
end)

test.test("a duplicate, incomplete, or homeless setting is refused", function()
    local model = newModel()
    local saved = {}
    model:AddSection("general", "General")

    test.assertFalse(model:AddSection("general", "Again"))
    test.assertFalse(model:Add("missing", toggle("tags", saved)))
    test.assertTrue(model:Add("general", toggle("tags", saved)))
    test.assertFalse(model:Add("general", toggle("tags", saved)))
    test.assertFalse(model:Add("general", { id = "noset", kind = "toggle", label = "x", get = function() end }))
    test.assertFalse(model:Add("general", { id = "norun", kind = "action", label = "x" }))
    test.assertFalse(model:Add("general", { id = "odd", kind = "slider", label = "x", get = function() end }))
    test.assertEqual(1, #model:Sections()[1].entries)
end)

test.test("changing a toggle saves it and tells every listener", function()
    local model = newModel()
    local saved = {}
    model:AddSection("general", "General")
    model:Add("general", toggle("tags", saved))
    local heard = {}
    model:OnChange(function(id, value)
        table.insert(heard, { id = id, value = value })
    end)

    test.assertTrue(model:Set("tags", false))
    test.assertFalse(saved.tags)
    test.assertFalse(model:Get("tags"))
    test.assertEqual(1, #heard)
    test.assertEqual("tags", heard[1].id)
    test.assertFalse(heard[1].value)

    test.assertEqual(true, model:Toggle("tags"))
    test.assertTrue(saved.tags)
    test.assertEqual(2, #heard)
end)

test.test("a refused or failing change keeps the old value and tells nobody", function()
    local model = newModel()
    local saved = {}
    model:AddSection("general", "General")
    model:Add("general", toggle("refused", saved, {
        set = function()
            return nil, "the saved setting is unreadable"
        end,
    }))
    model:Add("general", toggle("broken", saved, {
        set = function()
            error("boom")
        end,
    }))
    model:Add("general", toggle("tags", saved))
    local heard = 0
    model:OnChange(function()
        heard = heard + 1
    end)

    local changed, reason = model:Toggle("refused")
    test.assertEqual(nil, changed)
    test.assertEqual("the saved setting is unreadable", reason)
    changed, reason = model:Set("broken", false)
    test.assertEqual(nil, changed)
    test.assertEqual("it couldn't be saved", reason)
    changed, reason = model:Set("tags", "off")
    test.assertEqual(nil, changed)
    test.assertEqual("it can only be on or off", reason)
    changed, reason = model:Set("nothing", true)
    test.assertEqual(nil, changed)
    test.assertEqual("there is no such setting", reason)

    test.assertEqual(0, heard)
    test.assertTrue(model:Get("tags"))
end)

test.test("actions run, and a failing read or action never raises", function()
    local model = newModel()
    model:AddSection("general", "General")
    local runs = 0
    model:Add("general", { id = "open", kind = "action", label = "Open", run = function() runs = runs + 1 end })
    model:Add("general", { id = "bad", kind = "action", label = "Bad", run = function() error("boom") end })
    model:Add("general", { id = "version", kind = "text", get = function() error("boom") end })

    test.assertTrue(model:Run("open"))
    test.assertEqual(1, runs)
    test.assertFalse(model:Run("bad"))
    test.assertFalse(model:Run("version"))
    test.assertEqual(nil, model:Get("version"))
    test.assertEqual(nil, model:Toggle("open"))
end)

local index
for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]

    test.test(profile .. ": a fresh install has General and Chat Tags sections with defaults on", function()
        local world, addon = loggedIn(profile)
        local sections = addon.settings:Sections()

        test.assertEqual("General", sections[1].label)
        test.assertEqual("Chat Tags", sections[2].label)
        test.assertTrue(addon.settings:Get("minimap"))
        test.assertTrue(addon.settings:Get("chatTags"))
        test.assertContains(addon.settings:Get("version"), "Version ")
        test.assertEqual(nil, world.database.chatTags)
    end)

    test.test(profile .. ": /agf tags and the panel change the same saved setting", function()
        local world, addon = loggedIn(profile)

        fixtures.slash(world, "tags")
        test.assertContains(lastMessage(world), "Chat tags off.")
        test.assertFalse(world.database.chatTags)
        -- The panel reads it back.
        test.assertFalse(addon.settings:Get("chatTags"))

        -- A change from the panel shows up for the slash command.
        test.assertTrue(addon.settings:Set("chatTags", true))
        test.assertTrue(world.database.chatTags)
        fixtures.slash(world, "tags")
        test.assertContains(lastMessage(world), "Chat tags off.")
    end)

    test.test(profile .. ": an unreadable saved chat tag setting is left alone", function()
        local world, addon = loggedIn(profile)
        world.database.chatTags = "off"

        fixtures.slash(world, "tags")

        test.assertContains(lastMessage(world), "Chat tags can't be changed")
        test.assertEqual("off", world.database.chatTags)
        test.assertTrue(addon.settings:Get("chatTags"))
    end)
end

test.test("/agf minimap and the panel change the same saved setting", function()
    local world = fixtures.newEnvironment("Retail")
    local libs = world.environment.LibStub.libs
    libs["LibDataBroker-1.1"].NewDataObject = function(_, _, object)
        return object
    end
    libs["LibDBIcon-1.0"].Register = function() end
    libs["LibDBIcon-1.0"].Hide = function() end
    libs["LibDBIcon-1.0"].Show = function() end
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")

    fixtures.slash(world, "minimap")
    test.assertContains(lastMessage(world), "Minimap button hidden.")
    test.assertTrue(world.database.minimap.hide)
    test.assertFalse(addon.settings:Get("minimap"))

    test.assertTrue(addon.settings:Set("minimap", true))
    test.assertFalse(world.database.minimap.hide)
    fixtures.slash(world, "minimap")
    test.assertContains(lastMessage(world), "Minimap button hidden.")
end)

test.test("without a minimap button the setting explains why and keeps its value", function()
    local world, addon = loggedIn("Retail")

    fixtures.slash(world, "minimap")

    test.assertContains(lastMessage(world), "Can't change the minimap button")
    test.assertTrue(addon.settings:Get("minimap"))
end)

test.test("/agf options is listed in help and explains when there is no panel", function()
    local world = loggedIn("Forever")

    fixtures.slash(world, "help")
    test.assertContains(table.concat(world.messages, "\n"), "/agf options - open the settings panel")

    fixtures.slash(world, "options")
    test.assertContains(lastMessage(world), "The settings panel isn't available on this client.")
end)

test.test("/agf greet and the panel's Edit Greetings button open the Greetings window", function()
    local world, addon = loggedIn("Retail")

    fixtures.slash(world, "help")
    test.assertContains(table.concat(world.messages, "\n"), "/agf greet - edit your Guild Greet greetings")

    local entry = addon.settings:Entry("editGreetings")
    test.assertEqual("action", entry.kind)
    test.assertEqual("Edit Greetings", entry.label)
    local sections = addon.settings:Sections()
    local guildGreet = sections[#sections]
    test.assertEqual("Guild Greet", guildGreet.label)
    test.assertEqual("editGreetings", guildGreet.entries[#guildGreet.entries].id)

    -- The fixtures' stand-in framework can't build windows, so both report
    -- that instead of raising errors.
    fixtures.slash(world, "greet")
    test.assertContains(lastMessage(world), "The Greetings window can't open")
    local before = #world.messages
    test.assertTrue(addon.settings:Run("editGreetings"))
    test.assertEqual(before + 1, #world.messages)
    test.assertContains(lastMessage(world), "The Greetings window can't open")
end)

test.test("the Guild Greet section can unlock the prompts, and refuses when they can't be drawn", function()
    local _, addon = loggedIn("Forever")
    local entry = addon.settings:Entry("greetUnlock")

    test.assertEqual("toggle", entry.kind)
    test.assertFalse(addon.settings:Get("greetUnlock"))
    -- The fixtures' frames can't build prompts, so the toggle stays off.
    local ok, reason = addon.settings:Set("greetUnlock", true)
    test.assertEqual(nil, ok)
    test.assertContains(reason, "can't be drawn")
    test.assertFalse(addon.settings:Get("greetUnlock"))
end)

test.test("number settings take whole numbers within their range", function()
    local model = newModel()
    local saved = { cap = 2 }
    model:AddSection("greet", "Guild Greet")
    test.assertFalse(model:Add("greet", { id = "bad", kind = "number", label = "Bad",
        get = function() return 1 end, set = function() return true end }))
    test.assertTrue(model:Add("greet", {
        id = "cap", kind = "number", label = "Cap", min = 1, max = 10,
        get = function() return saved.cap end,
        set = function(value)
            saved.cap = value
            return true
        end,
    }))

    test.assertTrue(model:Set("cap", 10))
    test.assertEqual(10, model:Get("cap"))
    local index, value
    for index, value in ipairs({ 0, 11, 2.5, "3", true }) do
        local ok, reason = model:Set("cap", value)
        test.assertEqual(nil, ok, tostring(index))
        test.assertEqual("it must be a whole number from 1 to 10", reason)
    end
    test.assertEqual(10, saved.cap)
end)

test.test("the Guild Greet section sets the greeting cap through the saved data", function()
    local world, addon = loggedIn("Retail")
    local entry = addon.settings:Entry("greetCap")

    test.assertEqual("number", entry.kind)
    test.assertEqual(2, addon.settings:Get("greetCap"))
    test.assertTrue(addon.settings:Set("greetCap", 4))
    test.assertEqual(4, world.database.greet.cap)
    test.assertEqual(nil, addon.settings:Set("greetCap", 11))
end)

test.test("the Guild Greet section has category, threshold and this-character settings", function()
    local world, addon = loggedIn("Forever")

    test.assertTrue(addon.settings:Get("greetCategory:join"))
    test.assertTrue(addon.settings:Set("greetCategory:join", false))
    test.assertFalse(world.database.greet.categories.join)

    test.assertEqual(15, addon.settings:Get("welcomeBackMinutes"))
    test.assertTrue(addon.settings:Set("welcomeBackMinutes", 20))
    test.assertEqual(20, world.database.greet.welcomeBackMinutes)
    test.assertEqual(nil, addon.settings:Set("longAbsenceDays", 400))
    test.assertEqual(30, addon.settings:Get("longAbsenceDays"))

    -- Greet stays on for other characters.
    test.assertTrue(addon.settings:Get("greetCharacter"))
    test.assertTrue(addon.settings:Set("greetCharacter", false))
    test.assertFalse(addon.settings:Get("greetCharacter"))
    test.assertFalse(addon.guildGreet:IsEnabled())
    test.assertTrue(addon.settings:Get("guildGreet"))
    -- Saved by character key, account-wide.
    test.assertTrue(next(world.database.greet.offCharacters) ~= nil)
end)
