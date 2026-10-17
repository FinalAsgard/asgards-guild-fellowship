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

        -- After the add-on's own page in the AddOns options.
        test.assertTrue(sections[1].home)
        test.assertEqual("General", sections[2].label)
        test.assertEqual("Chat Tags", sections[3].label)
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

test.test("each section names its master frame page, Settings unless it says otherwise", function()
    local model = newModel()

    test.assertTrue(model:AddSection("general", "General"))
    test.assertTrue(model:AddSection("greet", "Guild Greet", { page = "greetings" }))
    test.assertTrue(model:AddSection("chat", "Chat Tags", { page = "settings" }))
    test.assertTrue(model:AddSection("recruit", "Recruitment", { page = "recruitment" }))
    test.assertTrue(model:AddSection("about", "Asgard's Guild Fellowship", { home = true }))
    test.assertFalse(model:AddSection("odd", "Odd", { page = "nowhere" }))

    local onSettings = model:SectionsOn("settings")
    test.assertEqual(2, #onSettings)
    test.assertEqual("general", onSettings[1].id)
    test.assertEqual("chat", onSettings[2].id)
    test.assertEqual("greet", model:SectionsOn("greetings")[1].id)
    test.assertEqual("recruit", model:SectionsOn("recruitment")[1].id)
    test.assertEqual(0, #model:SectionsOn("nowhere"))
    -- A home section belongs to the AddOns options' own page, on no tab.
    local sections = model:Sections()
    test.assertTrue(sections[5].home)
    test.assertEqual(nil, sections[5].page)
end)

test.test("an entry kept to one host is drawn only there; others are drawn in both", function()
    local model = newModel()
    model:AddSection("general", "General")
    local saved = {}
    test.assertTrue(model:Add("general", toggle("minimap", saved)))
    test.assertTrue(model:Add("general", { id = "openRoster", kind = "action", label = "Open Roster", host = "options",
        run = function() end }))
    test.assertFalse(model:Add("general", toggle("odd", saved, { host = "elsewhere" })))

    test.assertTrue(model:InHost("minimap", "frame"))
    test.assertTrue(model:InHost("minimap", "options"))
    test.assertTrue(model:InHost("openRoster", "options"))
    test.assertFalse(model:InHost("openRoster", "frame"))
    test.assertFalse(model:InHost("missing", "options"))
end)

test.test("the composed add-on puts each section on its page and the Open window button on no tab", function()
    local _, addon = loggedIn("Retail")
    local settings = addon.settings

    local onSettings = settings:SectionsOn("settings")
    test.assertEqual(4, #onSettings)
    test.assertEqual("general", onSettings[1].id)
    test.assertEqual("chatTags", onSettings[2].id)
    test.assertEqual("groupFinder", onSettings[3].id)
    test.assertEqual("guildMap", onSettings[4].id)
    test.assertEqual("guildGreet", settings:SectionsOn("greetings")[1].id)
    test.assertEqual("recruitment", settings:SectionsOn("recruitment")[1].id)
    test.assertTrue(settings:Sections()[1].home)
    test.assertEqual("openWindow", settings:Sections()[1].entries[1].id)
    test.assertTrue(settings:InHost("version", "frame"))
    test.assertTrue(settings:InHost("minimap", "frame"))
end)

test.test("guild map settings are on by default and saved account-wide", function()
    local world, addon = loggedIn("Retail")
    local settings = addon.settings

    test.assertEqual("Share my location with the guild", settings:Entry("shareLocation").label)
    test.assertEqual("Show guildmates on the map and minimap", settings:Entry("showGuildMap").label)
    test.assertTrue(settings:Get("shareLocation"))
    test.assertTrue(settings:Get("showGuildMap"))
    test.assertEqual(nil, world.database.guildMap)

    test.assertTrue(settings:Set("shareLocation", false))
    test.assertTrue(settings:Set("showGuildMap", false))
    -- Saved for the account, not per guild or character.
    test.assertFalse(world.database.guildMap.share)
    test.assertFalse(world.database.guildMap.show)
    test.assertFalse(settings:Get("shareLocation"))

    test.assertTrue(settings:Set("shareLocation", true))
    test.assertEqual(nil, world.database.guildMap.share)
    test.assertTrue(settings:Get("shareLocation"))

    -- An unusable saved value counts as on and is never written over.
    world.database.guildMap = "broken"
    test.assertTrue(settings:Get("showGuildMap"))
    test.assertEqual(nil, settings:Set("showGuildMap", false))
    test.assertEqual("broken", world.database.guildMap)
end)

test.test("/agf options is listed in help and explains when the window can't open", function()
    local world = loggedIn("Forever")

    fixtures.slash(world, "help")
    test.assertContains(table.concat(world.messages, "\n"), "/agf options - open the add-on's settings")

    fixtures.slash(world, "options")
    test.assertContains(lastMessage(world), "can't open")
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

test.test("closing the panel turns off modes marked to end on close, and nothing else", function()
    local model = newModel()
    local saved = { unlock = true, minimap = true }
    model:AddSection("general", "General")
    model:Add("general", toggle("unlock", saved, { offOnClose = true }))
    model:Add("general", toggle("minimap", saved))
    local changes = {}
    model:OnChange(function(id, value)
        table.insert(changes, id .. "=" .. tostring(value))
    end)

    model:Closed()

    test.assertFalse(saved.unlock)
    test.assertTrue(saved.minimap)
    test.assertEqual("unlock=false", table.concat(changes, ","))
    -- Already off: closing again changes nothing.
    model:Closed()
    test.assertEqual(1, #changes)
end)

test.test("the prompt unlock is a mode that ends when the panel closes", function()
    local _, addon = loggedIn("Retail")

    test.assertTrue(addon.settings:Entry("greetUnlock").offOnClose)
end)

test.test("a text setting saves text up to its length and refuses anything else", function()
    local model = newModel()
    local saved = { ad = "" }
    model:AddSection("general", "General")
    test.assertFalse(model:Add("general", {
        id = "nolimit", kind = "input", label = "x", get = function() end, set = function() end,
    }))
    test.assertTrue(model:Add("general", {
        id = "ad",
        kind = "input",
        label = "My ad",
        maxLength = 5,
        get = function()
            return saved.ad
        end,
        set = function(text)
            saved.ad = text
            return true
        end,
    }))

    test.assertTrue(model:Set("ad", "Hello"))
    test.assertEqual("Hello", model:Get("ad"))
    local changed, reason = model:Set("ad", "Hello!")
    test.assertEqual(nil, changed)
    test.assertEqual("it can be at most 5 characters", reason)
    changed, reason = model:Set("ad", 5)
    test.assertEqual(nil, changed)
    test.assertEqual("it must be text", reason)
    test.assertEqual("Hello", saved.ad)
end)

test.test("a disabled setting can't be changed or run, and says why", function()
    local model = newModel()
    local saved = {}
    local available = false
    local runs = 0
    local function enabled()
        if not available then
            return false, "not now"
        end
        return true
    end
    model:AddSection("general", "General")
    model:Add("general", toggle("tags", saved, { enabled = enabled }))
    model:Add("general", { id = "open", kind = "action", label = "Open", enabled = enabled, run = function()
        runs = runs + 1
    end })
    model:Add("general", toggle("broken", saved, { enabled = function() error("boom") end }))
    test.assertFalse(model:Add("general", toggle("odd", saved, { enabled = true })))

    test.assertFalse(model:IsEnabled("tags"))
    local changed, reason = model:Set("tags", false)
    test.assertEqual(nil, changed)
    test.assertEqual("not now", reason)
    test.assertEqual(nil, saved.tags)
    test.assertFalse(model:Run("open"))
    test.assertEqual(0, runs)
    test.assertFalse(model:IsEnabled("broken"))

    available = true
    test.assertTrue(model:IsEnabled("tags"))
    test.assertTrue(model:Set("tags", false))
    test.assertTrue(model:Run("open"))
    test.assertEqual(1, runs)
end)

test.test("a number with a step only takes values on its steps", function()
    local model = newModel()
    local saved = {}
    model:AddSection("general", "General")
    model:Add("general", { id = "gap", kind = "number", slider = true, label = "Gap", min = 5, max = 240, step = 5,
        get = function() return saved.gap end,
        set = function(value)
            saved.gap = value
            return true
        end })

    local changed, reason = model:Set("gap", 12)
    test.assertEqual(nil, changed)
    test.assertEqual("it must go in steps of 5", reason)
    test.assertTrue(model:Set("gap", 15))
    test.assertEqual(15, saved.gap)
end)

test.test("a setting's info text is read when asked, and a failing or missing one gives nothing", function()
    local model = newModel()
    local saved = {}
    local ad = "Knights recruit!"
    model:AddSection("general", "General")
    model:Add("general", toggle("useAd", saved, { info = function() return ad end }))
    model:Add("general", toggle("plain", saved))
    model:Add("general", toggle("broken", saved, { info = function() error("boom") end }))
    test.assertFalse(model:Add("general", toggle("odd", saved, { info = "text" })))

    test.assertEqual("Knights recruit!", model:Info("useAd"))
    ad = "New ad"
    test.assertEqual("New ad", model:Info("useAd"))
    test.assertEqual(nil, model:Info("plain"))
    test.assertEqual(nil, model:Info("broken"))
    test.assertEqual(nil, model:Info("nothing"))
end)

test.test("a color setting takes only six hex digits, saved in lower case", function()
    local model = newModel()
    model:AddSection("chatTags", "Chat Tags")
    local saved = {}
    local swatches = { { label = "Gold", color = "ffd100" } }
    test.assertFalse(model:Add("chatTags", { id = "bare", kind = "color", label = "Bare",
        get = function() return "ffffff" end, set = function() return true end }))
    test.assertTrue(model:Add("chatTags", { id = "aliasColor", kind = "color", label = "Alias tag color",
        swatches = swatches,
        get = function() return saved.color or "4a90ff" end,
        set = function(color)
            saved.color = color
            return true
        end }))

    test.assertTrue(model:Set("aliasColor", "FFD100"))
    test.assertEqual("ffd100", saved.color)
    local changed, reason = model:Set("aliasColor", "gold")
    test.assertEqual(nil, changed)
    test.assertContains(reason, "six hex digits")
    test.assertEqual(nil, (model:Set("aliasColor", "#ffd100")))
    test.assertEqual(nil, (model:Set("aliasColor", 16766976)))
    test.assertEqual("ffd100", model:Get("aliasColor"))
end)

local function registerTagColorTest(profile)
    test.test(profile .. ": choosing a tag color in the settings recolors chat tags", function()
        local world, addon = loggedIn(profile)
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)
        local speaker = profile == "Forever" and "Hammer Smith" or "Hammer-Area52"
        local before = addon.chatAnnotator:Annotate("CHAT_MSG_GUILD", "hi", speaker)
        test.assertContains(before, "|cff4a90ff[")
        test.assertEqual("4a90ff", addon.settings:Get("chatTagColor:alias"))

        test.assertTrue(addon.settings:Set("chatTagColor:alias", "ffd100"))

        test.assertContains(addon.chatAnnotator:Annotate("CHAT_MSG_GUILD", "hi", speaker), "|cffffd100[")
        test.assertEqual("ffd100", world.database.chatTagColors.alias)
        test.assertEqual("7fd4ff", addon.settings:Get("chatTagColor:main"))
    end)
end

registerTagColorTest("Forever")
registerTagColorTest("Retail")

test.test("the Guild Greet settings open with the main switches, then headed groups for prompts and timing", function()
    local _, addon = loggedIn("Retail")
    local section = addon.settings:SectionsOn("greetings")[1]
    local ids = {}
    local index
    for index = 1, #section.entries do
        if addon.settings:InHost(section.entries[index].id, "frame") then
            table.insert(ids, section.entries[index].id)
        end
    end

    test.assertEqual("guildGreet", ids[1])
    test.assertEqual("greetCharacter", ids[2])
    test.assertEqual("greetInInstances", ids[3])
    test.assertEqual("greetUnlock", ids[4])
    test.assertEqual("greetPromptsHeading", ids[5])
    test.assertEqual("greetCategory:join", ids[6])
    test.assertEqual("greetTimingHeading", ids[10])
    test.assertEqual("welcomeBackMinutes", ids[11])
    test.assertEqual("greetCap", ids[13])
    test.assertEqual(13, #ids)
    -- "This character" explains how it differs from the main switch.
    test.assertContains(addon.settings:Info("greetCharacter"), "every character on this account")
end)
