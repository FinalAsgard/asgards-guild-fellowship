local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

local function newEnvironment()
    return fakeFrames.install({})
end

local contains = fakeFrames.contains

-- A model with a home section (an Open window button) for the add-on's own
-- page, a General section, and a Recruitment section holding a member toggle
-- and, after an officer heading, an officer toggle shown only while
-- `state.officer` is true.
local function newPanel(environment)
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local state = { officer = false, opened = 0 }
    local model = addon.SettingsModel.Create()
    model:AddSection("about", "Asgard's Guild Fellowship", { home = true })
    model:Add("about", { id = "openWindow", kind = "action", label = "Open window",
        run = function() state.opened = state.opened + 1 end })
    model:AddSection("general", "General")
    model:Add("general", { id = "minimap", kind = "toggle", label = "Show the minimap button",
        get = function() return true end, set = function() return true end })
    model:AddSection("recruitment", "Recruitment", { page = "recruitment" })
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

test.test("settings panel: each feature's section gets a sub-page under the add-on's page", function()
    local environment = newEnvironment()
    local registered = {}
    environment.Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            return { ID = 1, frame = frame, name = name }
        end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name)
            table.insert(registered, { parent = parent, frame = frame, name = name })
            return { ID = #registered + 1 }
        end,
        RegisterAddOnCategory = function() end,
    }
    local _, panel = newPanel(environment)

    test.assertTrue(panel:Register())

    test.assertEqual(2, #registered)
    test.assertEqual("General", registered[1].name)
    test.assertEqual(panel.category, registered[1].parent)
    test.assertTrue(contains(registered[1].frame.texts, "Show the minimap button"))
    test.assertEqual("Recruitment", registered[2].name)
    test.assertTrue(contains(registered[2].frame.texts, "Opt in"))
    -- The add-on's own page carries only its home section.
    test.assertTrue(contains(panel.frame.texts, "Open window"))
    test.assertFalse(contains(panel.frame.texts, "General"))
    test.assertFalse(contains(panel.frame.texts, "Opt in"))
end)

test.test("settings panel: older clients get each sub-page as a child of the add-on's Interface Options page", function()
    local environment = newEnvironment()
    local added = {}
    environment.InterfaceOptions_AddCategory = function(frame)
        table.insert(added, frame)
    end
    local _, panel = newPanel(environment)

    test.assertTrue(panel:Register())

    test.assertEqual(3, #added)
    test.assertEqual(nil, rawget(added[1], "parent"))
    test.assertEqual("General", added[2].name)
    test.assertEqual("Recruitment", added[3].name)
    test.assertEqual(added[1].name, rawget(added[2], "parent"))
    test.assertEqual(added[1].name, rawget(added[3], "parent"))
end)

test.test("settings panel: the add-on page's Open window button runs its action", function()
    local environment = newEnvironment()
    environment.InterfaceOptions_AddCategory = function() end
    local _, panel, _, state = newPanel(environment)
    panel:Register()
    local button
    local index
    for index = 1, #panel.widgets do
        if panel.widgets[index].id == "openWindow" then
            button = panel.widgets[index].frame
        end
    end

    button.scripts.OnClick(button)

    test.assertEqual(1, state.opened)
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
    -- The Recruitment sub-page's area (after the home and General pages).
    local area = panel.areas[3]
    local Layout = addon.SettingsLayout

    test.assertEqual(Layout.TOP + Layout.HEADER + Layout.ROW + Layout.SECTION_GAP, area.content.height)

    state.officer = true
    panel:Refresh()

    test.assertEqual(Layout.TOP + Layout.HEADER + 3 * Layout.ROW + 2 * Layout.SECTION_GAP, area.content.height)
    test.assertEqual(Layout.ROW, area.rows.guildAd.height)
end)

-- A model with one color setting backed by `saved.color`.
local function newColorPanel(environment)
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local saved = { color = "4a90ff" }
    local model = addon.SettingsModel.Create()
    model:AddSection("chatTags", "Chat Tags")
    model:Add("chatTags", { id = "aliasColor", kind = "color", label = "Alias tag color", sample = "[TheTool]",
        swatches = { { label = "Blue", color = "4a90ff" }, { label = "Gold", color = "ffd100" } },
        get = function() return saved.color end,
        set = function(color)
            saved.color = color
            return true
        end })
    environment.InterfaceOptions_AddCategory = function() end
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    panel:Register()
    return panel, saved, widgetFor(panel, "aliasColor")
end

test.test("settings panel: clicking a color swatch saves it, outlines it, and shows the sample in it", function()
    local panel, saved, widget = newColorPanel(newEnvironment())

    test.assertEqual(2, #widget.swatches)
    test.assertTrue(widget.swatches[1].selected.shown)
    test.assertFalse(widget.swatches[2].selected.shown)
    test.assertEqual("|cff4a90ff[TheTool]|r", widget.value.text)

    local gold = widget.swatches[2].frame
    gold.scripts.OnClick(gold)

    test.assertEqual("ffd100", saved.color)
    test.assertFalse(widget.swatches[1].selected.shown)
    test.assertTrue(widget.swatches[2].selected.shown)
    test.assertEqual("|cffffd100[TheTool]|r", widget.value.text)
    test.assertEqual(nil, panel.environment.ColorPickerFrame)
    -- Without the game's color picker there's no Custom... button.
    test.assertEqual(nil, widget.custom)
end)

test.test("settings panel: Custom... opens the game's color picker and saves the color picked", function()
    -- Retail's picker is set up with one call; older clients' by its fields.
    local styles = { "setup", "fields" }
    local index
    for index = 1, #styles do
        local environment = newEnvironment()
        local picker = { color = { 0, 0, 0 } }
        function picker:GetColorRGB() return self.color[1], self.color[2], self.color[3] end
        if styles[index] == "setup" then
            function picker:SetupColorPickerAndShow(info)
                self.info = info
                self.color = { info.r, info.g, info.b }
                self.shown = true
            end
        else
            function picker:SetColorRGB(r, g, b) self.color = { r, g, b } end
            function picker:Show() self.shown = true end
        end
        environment.ColorPickerFrame = picker
        local _, saved, widget = newColorPanel(environment)
        test.assertTrue(widget.custom ~= nil, styles[index])

        widget.custom.scripts.OnClick(widget.custom)
        test.assertTrue(picker.shown, styles[index])
        test.assertEqual(0x4a / 255, picker.color[1], styles[index])

        picker.color = { 1, 0x80 / 255, 0 }
        local picked = picker.info and picker.info.swatchFunc or picker.func
        picked()
        test.assertEqual("ff8000", saved.color, styles[index])
        test.assertEqual("|cffff8000[TheTool]|r", widget.value.text, styles[index])

        -- Cancelling puts the color it started on back.
        local cancel = picker.info and picker.info.cancelFunc or picker.cancelFunc
        cancel()
        test.assertEqual("4a90ff", saved.color, styles[index])
    end
end)

test.test("settings panel: a color that can't be read shows its entry's default, not the first swatch", function()
    local environment = newEnvironment()
    environment.InterfaceOptions_AddCategory = function() end
    local addon = test.newAddon("Core/SettingsLayout.lua", "Core/SettingsModel.lua", "Adapters/SettingsPanel.lua")
    local model = addon.SettingsModel.Create()
    model:AddSection("chatTags", "Chat Tags")
    model:Add("chatTags", { id = "mainColor", kind = "color", label = "Main's name tag color", sample = "[Hammer]",
        default = "7fd4ff",
        swatches = { { label = "Blue", color = "4a90ff" }, { label = "Light blue", color = "7fd4ff" } },
        get = function() error("saved data exploded") end,
        set = function() return true end })
    local panel = addon.SettingsPanel.Create({ environment = environment }, model)
    panel:Register()
    local widget = widgetFor(panel, "mainColor")

    test.assertEqual("|cff7fd4ff[Hammer]|r", widget.value.text)
    test.assertFalse(widget.swatches[1].selected.shown)
    test.assertTrue(widget.swatches[2].selected.shown)
end)
