local test = require("tests.test_helper")

-- A stand-in for the game's frames: every method does nothing, except that
-- text set on a font string is recorded on the page it belongs to, so a spec
-- can read what each options page shows. Pages are the plain frames the
-- panel creates with no parent.
local function newEnvironment()
    local environment = { pages = {} }
    local function widget(page)
        local object = { shown = true }
        return setmetatable(object, {
            __index = function(_, method)
                if method == "SetText" then
                    return function(self, text)
                        self.text = text
                        table.insert(page.texts, text)
                    end
                elseif method == "Show" then
                    return function(self)
                        self.shown = true
                    end
                elseif method == "Hide" then
                    return function(self)
                        self.shown = false
                    end
                elseif method == "CreateFontString" or method == "CreateTexture" then
                    return function()
                        return widget(page)
                    end
                elseif method == "GetChecked" or method == "HasFocus" then
                    return function()
                        return false
                    end
                elseif method == "SetScript" then
                    return function(self, name, handler)
                        rawset(self, "scripts", rawget(self, "scripts") or {})
                        self.scripts[name] = handler
                    end
                elseif method == "GetText" then
                    -- Like a real text box, an empty one gives "".
                    return function(self)
                        return rawget(self, "text") or ""
                    end
                end
                return function() end
            end,
        })
    end
    environment.CreateFrame = function(frameType, _, parent)
        -- `environment.editBoxFails` lists methods that raise on text boxes,
        -- as on a client that lacks them.
        if frameType == "EditBox" and environment.editBoxFails ~= nil then
            local box = widget(parent)
            local name
            for name in pairs(environment.editBoxFails) do
                rawset(box, name, function()
                    error("no " .. name .. " on this client")
                end)
            end
            return box
        end
        if parent == nil then
            local page = widget(nil)
            page.texts = {}
            -- A page's own font strings record into it.
            getmetatable(page).__index = (function(original)
                return function(self, method)
                    if method == "CreateFontString" or method == "CreateTexture" then
                        return function()
                            return widget(self)
                        end
                    end
                    return original(self, method)
                end
            end)(getmetatable(page).__index)
            table.insert(environment.pages, page)
            return page
        end
        return widget(parent)
    end
    return environment
end

local function contains(list, value)
    local index
    for index = 1, #list do
        if list[index] == value then
            return true
        end
    end
    return false
end

-- A model with a main-page section and a Recruitment section on its own
-- page, holding a member toggle and, after an officer heading, an officer
-- toggle shown only while `state.officer` is true.
local function newPanel(environment)
    local addon = test.newAddon("Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local state = { officer = false }
    local model = addon.SettingsModel.Create()
    model:AddSection("general", "General")
    model:Add("general", { id = "minimap", kind = "toggle", label = "Show the minimap button",
        get = function() return true end, set = function() return true end })
    model:AddSection("recruitment", "Recruitment", { ownPage = true })
    model:Add("recruitment", { id = "optIn", kind = "toggle", label = "Opt in",
        get = function() return false end, set = function() return true end })
    test.assertTrue(model:Add("recruitment", { id = "officerHeading", kind = "heading", label = "Officer settings",
        shown = function() return state.officer end }))
    model:Add("recruitment", { id = "guildAd", kind = "toggle", label = "Guild ad on",
        shown = function() return state.officer end,
        get = function() return true end, set = function() return true end })
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    return addon, panel, model, state
end

test.test("settings panel: a section asking for its own page gets an options page under the add-on's", function()
    local environment = newEnvironment()
    local registered = {}
    environment.Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            return { ID = 1, frame = frame, name = name }
        end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name)
            table.insert(registered, { parent = parent, frame = frame, name = name })
            return { ID = 2 }
        end,
        RegisterAddOnCategory = function() end,
    }
    local _, panel = newPanel(environment)

    test.assertTrue(panel:Register())

    test.assertEqual(1, #registered)
    test.assertEqual("Recruitment", registered[1].name)
    test.assertTrue(contains(registered[1].frame.texts, "Opt in"))
    -- The main page no longer carries Recruitment.
    test.assertTrue(contains(panel.frame.texts, "General"))
    test.assertFalse(contains(panel.frame.texts, "Recruitment"))
    test.assertFalse(contains(panel.frame.texts, "Opt in"))
end)

test.test("settings panel: older clients get the page as a child of the add-on's Interface Options page", function()
    local environment = newEnvironment()
    local added = {}
    environment.InterfaceOptions_AddCategory = function(frame)
        table.insert(added, frame)
    end
    local _, panel = newPanel(environment)

    test.assertTrue(panel:Register())

    test.assertEqual(2, #added)
    test.assertEqual(nil, rawget(added[1], "parent"))
    test.assertEqual("Recruitment", added[2].name)
    test.assertEqual(added[1].name, rawget(added[2], "parent"))
end)

test.test("settings panel: without pages under the main one, every section stays on the main page", function()
    local environment = newEnvironment()
    environment.Settings = {
        RegisterCanvasLayoutCategory = function(frame)
            return { ID = 1, frame = frame }
        end,
        RegisterAddOnCategory = function() end,
    }
    local _, panel = newPanel(environment)

    test.assertTrue(panel:Register())

    test.assertTrue(contains(panel.frame.texts, "Recruitment"))
    test.assertTrue(contains(panel.frame.texts, "Opt in"))
end)

test.test("settings panel: the officer heading and settings show only for officers", function()
    local environment = newEnvironment()
    environment.InterfaceOptions_AddCategory = function() end
    local _, panel, _, state = newPanel(environment)
    panel:Register()
    local function widget(id)
        local index
        for index = 1, #panel.widgets do
            if panel.widgets[index].id == id then
                return panel.widgets[index]
            end
        end
    end

    panel:Refresh()
    test.assertFalse(widget("officerHeading").label.shown)
    test.assertFalse(widget("guildAd").label.shown)
    test.assertTrue(widget("optIn").label.shown)

    state.officer = true
    panel:Refresh()
    test.assertTrue(widget("officerHeading").label.shown)
    test.assertEqual("Officer settings", widget("officerHeading").label.text)
    test.assertTrue(widget("guildAd").label.shown)
end)

-- A model with one text setting backed by `saved.ad`, on the main page.
local function newTextPanel(environment, savedAd)
    local addon = test.newAddon("Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local saved = { ad = savedAd or "" }
    local model = addon.SettingsModel.Create()
    model:AddSection("recruitment", "Recruitment")
    model:Add("recruitment", { id = "ad", kind = "input", label = "My ad", maxLength = 255,
        get = function() return saved.ad end,
        set = function(text)
            saved.ad = text
            return true
        end })
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    environment.InterfaceOptions_AddCategory = function() end
    test.assertTrue(panel:Register())
    return panel, saved
end

local function textBox(panel)
    local index
    for index = 1, #panel.widgets do
        if panel.widgets[index].kind == "input" then
            return panel.widgets[index].frame
        end
    end
end

-- Types `text` into the box, as the player would before leaving it.
local function type_(box, text)
    box.text = text
end

test.test("settings panel: a typed ad is saved however the player leaves the box", function()
    local leaving = { "OnEnterPressed", "OnEscapePressed" }
    local index
    for index = 1, #leaving do
        local panel, saved = newTextPanel(newEnvironment())
        local box = textBox(panel)
        type_(box, "Join us! " .. index)

        box.scripts[leaving[index]](box)
        -- The game drops the box's focus, which is what saves it.
        box.scripts.OnEditFocusLost(box)

        test.assertEqual("Join us! " .. index, saved.ad, leaving[index])
    end

    local panel, saved = newTextPanel(newEnvironment())
    local box = textBox(panel)
    type_(box, "Clicked away")
    box.scripts.OnEditFocusLost(box)
    test.assertEqual("Clicked away", saved.ad)
end)

test.test("settings panel: closing the options saves an ad still being typed", function()
    local panel, saved = newTextPanel(newEnvironment())
    type_(textBox(panel), "Typed, then closed")

    panel.frame.scripts.OnHide(panel.frame)

    test.assertEqual("Typed, then closed", saved.ad)
end)

test.test("settings panel: a saved ad shows in its box even where the box can't be greyed out", function()
    local environment = newEnvironment()
    environment.editBoxFails = { Enable = true, Disable = true }

    local panel = newTextPanel(environment, "Knights recruit!")

    test.assertEqual("Knights recruit!", textBox(panel).text)
end)

test.test("settings panel: a box the panel couldn't fill in never saves over the saved ad", function()
    local environment = newEnvironment()
    environment.editBoxFails = { SetText = true }
    local panel, saved = newTextPanel(environment, "Knights recruit!")
    local box = textBox(panel)

    box.scripts.OnEditFocusLost(box)
    panel.frame.scripts.OnHide(panel.frame)

    test.assertEqual("Knights recruit!", saved.ad)
end)

test.test("settings panel: leaving a box unchanged saves nothing", function()
    local environment = newEnvironment()
    local addon = test.newAddon("Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local saves = 0
    local model = addon.SettingsModel.Create()
    model:AddSection("recruitment", "Recruitment")
    model:Add("recruitment", { id = "ad", kind = "input", label = "My ad", maxLength = 255,
        get = function() return "Knights recruit!" end,
        set = function()
            saves = saves + 1
            return true
        end })
    environment.InterfaceOptions_AddCategory = function() end
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    panel:Register()
    local box = textBox(panel)

    box.scripts.OnEditFocusLost(box)
    panel.frame.scripts.OnHide(panel.frame)

    test.assertEqual(0, saves)
end)
