local test = require("tests.test_helper")

-- A stand-in for the game's frames: every method does nothing, except that
-- text set on a font string is recorded on the page it belongs to, so a spec
-- can read what each options page shows. Pages are the plain frames the
-- panel creates with no parent; a frame made inside a page (a scroll area,
-- a row) records into that same page.
local function newEnvironment()
    local environment = { pages = {} }
    local function widget(page)
        local object = { shown = true, page = page }
        return setmetatable(object, {
            __index = function(_, method)
                if method == "SetText" then
                    return function(self, text)
                        self.text = text
                        local texts = type(page) == "table" and rawget(page, "texts")
                        if texts then
                            table.insert(texts, text)
                        end
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
                elseif method == "HasFocus" then
                    return function()
                        return false
                    end
                elseif method == "SetChecked" then
                    return function(self, checked)
                        rawset(self, "checked", checked)
                    end
                elseif method == "GetChecked" then
                    return function(self)
                        return rawget(self, "checked") == true
                    end
                elseif method == "SetHeight" then
                    return function(self, height)
                        rawset(self, "height", height)
                    end
                elseif method == "SetScript" then
                    return function(self, name, handler)
                        rawset(self, "scripts", rawget(self, "scripts") or {})
                        self.scripts[name] = handler
                    end
                elseif method == "SetCursorPosition" then
                    return function(self, position)
                        rawset(self, "cursor", position)
                    end
                elseif method == "SetMultiLine" then
                    return function(self, multiLine)
                        rawset(self, "multiLine", multiLine)
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
        local owner = parent and (rawget(parent, "texts") ~= nil and parent or rawget(parent, "page"))
        if frameType == "EditBox" and environment.editBoxFails ~= nil then
            local box = widget(owner)
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
        return widget(owner)
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
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
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
local function newTextPanel(environment, savedAd, lines)
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local saved = { ad = savedAd or "" }
    local model = addon.SettingsModel.Create()
    model:AddSection("recruitment", "Recruitment")
    model:Add("recruitment", { id = "ad", kind = "input", label = "My ad", maxLength = 255, lines = lines,
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
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
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

test.test("settings panel: a filled-in box shows the start of its text", function()
    local panel = newTextPanel(newEnvironment(), string.rep("Knights of Camelot recruit! ", 8))

    test.assertEqual(0, textBox(panel).cursor)
end)

test.test("settings panel: an entry with lines gets a multi-line box, and others one line", function()
    local tall = newTextPanel(newEnvironment(), "", 3)
    local short = newTextPanel(newEnvironment(), "")

    test.assertTrue(textBox(tall).multiLine)
    test.assertEqual(nil, rawget(textBox(short), "multiLine"))
end)

test.test("settings panel: Enter in a multi-line box saves, and line breaks are never kept", function()
    local panel, saved = newTextPanel(newEnvironment(), "", 3)
    local box = textBox(panel)

    -- Enter types a line break into a multi-line box.
    type_(box, "Join us\n")
    box.scripts.OnTextChanged(box)
    test.assertEqual("Join us", box.text)
    box.scripts.OnEditFocusLost(box)
    test.assertEqual("Join us", saved.ad)

    type_(box, "Raids on\r\nFriday")
    box.scripts.OnEditFocusLost(box)
    test.assertEqual("Raids onFriday", saved.ad)
end)

test.test("settings panel: a slider shows its value as it's dragged and saves it on release", function()
    local environment = newEnvironment()
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local saved = { gap = 60 }
    local saves = 0
    local model = addon.SettingsModel.Create()
    model:AddSection("recruitment", "Recruitment")
    model:Add("recruitment", { id = "gap", kind = "number", slider = true, label = "Gap", min = 5, max = 240, step = 5,
        format = function(value) return value .. " min" end,
        get = function() return saved.gap end,
        set = function(value)
            saves = saves + 1
            saved.gap = value
            return true
        end })
    environment.InterfaceOptions_AddCategory = function() end
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    panel:Register()
    local widget
    local index
    for index = 1, #panel.widgets do
        if panel.widgets[index].kind == "slider" then
            widget = panel.widgets[index]
        end
    end

    test.assertEqual("60 min", widget.value.text)
    -- Dragging: the value shown follows, snapped to the steps, unsaved.
    widget.frame.scripts.OnValueChanged(widget.frame, 87.2)
    test.assertEqual("85 min", widget.value.text)
    test.assertEqual(0, saves)
    -- Letting go saves it.
    widget.frame.scripts.OnMouseUp(widget.frame)
    test.assertEqual(85, saved.gap)
    test.assertEqual(1, saves)
    -- Releasing again without moving saves nothing.
    widget.frame.scripts.OnMouseUp(widget.frame)
    test.assertEqual(1, saves)
end)

test.test("settings panel: a setting with info gets an icon that shows it in the tooltip on mouseover", function()
    local environment = newEnvironment()
    local tooltip = { lines = {}, shown = false }
    function tooltip:SetOwner(owner) self.owner = owner end
    function tooltip:SetText(text) self.lines = { text } end
    function tooltip:AddLine(text) table.insert(self.lines, text) end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    environment.GameTooltip = tooltip
    environment.InterfaceOptions_AddCategory = function() end
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local ad = "Knights recruit!"
    local model = addon.SettingsModel.Create()
    model:AddSection("recruitment", "Recruitment")
    model:Add("recruitment", { id = "useAd", kind = "toggle", label = "Also post the officers' guild ad",
        info = function() return ad end,
        get = function() return true end, set = function() return true end })
    model:Add("recruitment", { id = "plain", kind = "toggle", label = "Plain",
        get = function() return true end, set = function() return true end })
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    panel:Register()
    local widgets = {}
    local index
    for index = 1, #panel.widgets do
        widgets[panel.widgets[index].id] = panel.widgets[index]
    end

    test.assertEqual(nil, widgets.plain.info)
    local icon = widgets.useAd.info
    test.assertTrue(icon ~= nil)

    icon.scripts.OnEnter(icon)
    test.assertTrue(tooltip.shown)
    test.assertEqual(icon, tooltip.owner)
    test.assertEqual("Also post the officers' guild ad", tooltip.lines[1])
    test.assertEqual("Knights recruit!", tooltip.lines[2])
    icon.scripts.OnLeave(icon)
    test.assertFalse(tooltip.shown)

    -- It's read again each time, so a changed ad shows.
    ad = "Raiding Fridays"
    icon.scripts.OnEnter(icon)
    test.assertEqual("Raiding Fridays", tooltip.lines[2])
end)

test.test("settings panel: a change that isn't saved says why in chat", function()
    local environment = newEnvironment()
    local printed = {}
    environment.InterfaceOptions_AddCategory = function() end
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local model = addon.SettingsModel.Create()
    model:AddSection("recruitment", "Recruitment")
    model:Add("recruitment", { id = "ad", kind = "input", label = "My ad", maxLength = 255,
        get = function() return "" end,
        set = function() return nil, "saved data is unavailable" end })
    local panel = addon.SettingsPanel.Create({
        environment = environment,
        Print = function(_, message) table.insert(printed, message) end,
    }, model)
    panel:Register()
    local box = textBox(panel)

    type_(box, "Join us")
    box.scripts.OnEditFocusLost(box)

    test.assertEqual(1, #printed)
    test.assertContains(printed[1], "Couldn't save \"My ad\": saved data is unavailable.")
end)

local function widgetFor(panel, id)
    local index
    for index = 1, #panel.widgets do
        if panel.widgets[index].id == id then
            return panel.widgets[index]
        end
    end
    return nil
end

test.test("settings panel: a setting changed in one host reads back in the other", function()
    local environment = newEnvironment()
    environment.InterfaceOptions_AddCategory = function() end
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local saved = { minimap = true }
    local model = addon.SettingsModel.Create()
    model:AddSection("general", "General")
    model:Add("general", { id = "minimap", kind = "toggle", label = "Show the minimap button",
        get = function() return saved.minimap end,
        set = function(shown)
            saved.minimap = shown
            return true
        end })
    model:Add("general", { id = "openRoster", kind = "action", label = "Open Roster", host = "options",
        run = function() end })
    local options = addon.SettingsPanel.Create({ environment = environment }, model)
    options:Register()
    local frame = addon.SettingsPanel.Create({ environment = environment }, model, "frame")
    local page = environment.CreateFrame("Frame")
    frame:Draw(page, model:SectionsOn("settings"), 28)
    frame:Watch()
    frame:Refresh()

    local inOptions = widgetFor(options, "minimap").frame
    local inFrame = widgetFor(frame, "minimap").frame
    test.assertTrue(inFrame.checked)

    -- Unticked in the AddOns options: the frame's copy follows.
    inOptions.checked = false
    inOptions.scripts.OnClick(inOptions)
    test.assertFalse(saved.minimap)
    test.assertFalse(inFrame.checked)

    -- Ticked again on the frame's Settings tab: the options follow.
    inFrame.checked = true
    inFrame.scripts.OnClick(inFrame)
    test.assertTrue(saved.minimap)
    test.assertTrue(inOptions.checked)

    -- The Open Roster button is only drawn in the options.
    test.assertTrue(widgetFor(options, "openRoster") ~= nil)
    test.assertEqual(nil, widgetFor(frame, "openRoster"))
    test.assertTrue(contains(page.texts, "Show the minimap button"))
    test.assertFalse(contains(page.texts, "Open Roster"))
end)

test.test("settings panel: hidden settings leave no gap and the scroll area grows when they show", function()
    local environment = newEnvironment()
    environment.InterfaceOptions_AddCategory = function() end
    local addon, panel, _, state = newPanel(environment)
    panel:Register()
    -- The Recruitment page's area: its own page under the add-on's.
    local area = panel.areas[2]
    local Layout = addon.SettingsLayout

    test.assertEqual(Layout.TOP + Layout.HEADER + Layout.ROW + Layout.SECTION_GAP, area.content.height)

    state.officer = true
    panel:Refresh()

    test.assertEqual(Layout.TOP + Layout.HEADER + 3 * Layout.ROW + 2 * Layout.SECTION_GAP, area.content.height)
    test.assertEqual(Layout.ROW, area.rows.guildAd.height)
end)
