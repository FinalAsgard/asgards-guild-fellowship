local _, addon = ...

-- Draws the SettingsModel's settings. One drawing routine, Draw, puts a list
-- of sections onto any parent frame inside a scroll area: one header per
-- section with its entries below it (a check box, a button, a line of text,
-- a number with minus and plus buttons, a slider, a labelled text box saved
-- on Enter, a row of color swatches, or a heading that sets the entries
-- after it apart). Where each
-- one goes comes from SettingsLayout, worked out again on every refresh, so
-- an entry the model reports hidden leaves no gap, and a list taller than
-- its area scrolls instead of running off the bottom. An entry the model
-- reports disabled is greyed out and can't be changed.
--
-- A panel draws for one host: "options" (the add-on's page in Esc ->
-- Options -> AddOns, see Register) or "frame" (the master frame's pages).
-- Every panel refreshes whenever any setting changes, so every drawn copy
-- agrees. Clients with the newer Settings API get a canvas category; older
-- ones get an Interface Options panel. Like the other adapters, everything
-- is optional and protected: a client with neither API, or a frame call
-- that fails, just leaves the panel out without an error.
local SettingsPanel = {
    LEFT = 16,
    TOP = -16,
    INDENT = 8,
    BUTTON_WIDTH = 140,
    INPUT_WIDTH = 520,
    SLIDER_WIDTH = 260,
    -- A color swatch's width and height.
    SWATCH_SIZE = 18,
    -- Room on the right of a scroll area for its scroll bar.
    SCROLL_BAR = 28,
    -- The info icon beside a label that shows a setting's info on
    -- mouseover; this texture is on both supported clients.
    INFO_ICON = "Interface\\FriendsFrame\\InformationIcon",
    INFO_SIZE = 16,
}
addon.SettingsPanel = SettingsPanel

local Panel = {}
Panel.__index = Panel

-- `client` is the WoW adapter; `model` the SettingsModel to draw; `host`
-- "options" (the default) or "frame".
function SettingsPanel.Create(client, model, host)
    return setmetatable({
        client = client,
        model = model,
        host = host or "options",
        environment = client.environment,
        widgets = {},
        areas = {},
    }, Panel)
end

-- The text shown beside a slider for `value`.
local function sliderText(entry, value)
    if type(value) ~= "number" then
        return ""
    end
    if type(entry.format) == "function" then
        local ok, text = pcall(entry.format, value)
        if ok and type(text) == "string" then
            return text
        end
    end
    return tostring(value)
end

-- Enables or greys out a widget's controls and label.
local function setEnabled(widget, enabled)
    -- A heading keeps its own color.
    if widget.kind == "heading" then
        return
    end
    local index
    for index = 1, #(widget.controls or {}) do
        local control = widget.controls[index]
        -- Not every client gives every kind of control Enable and Disable
        -- (text boxes in particular), so whatever it has is used.
        pcall(function()
            if type(control.Enable) == "function" and type(control.Disable) == "function" then
                if enabled then
                    control:Enable()
                else
                    control:Disable()
                end
            elseif type(control.SetEnabled) == "function" then
                control:SetEnabled(enabled)
            elseif type(control.EnableMouse) == "function" then
                control:EnableMouse(enabled)
            end
        end)
    end
    if widget.label ~= nil then
        if enabled then
            widget.label:SetTextColor(1, 1, 1)
        else
            widget.label:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

-- Shows or hides a widget's row, controls and label.
local function setShown(widget, shown)
    local parts = {}
    local index
    for index, part in ipairs({ "row", "label", "value", "info" }) do
        if widget[part] ~= nil then
            table.insert(parts, widget[part])
        end
    end
    for index = 1, #(widget.controls or {}) do
        table.insert(parts, widget.controls[index])
    end
    for index = 1, #parts do
        if parts[index] ~= nil then
            if shown then
                parts[index]:Show()
            else
                parts[index]:Hide()
            end
        end
    end
end

-- Puts each header and entry row of a drawn area where the layout says,
-- and sizes the area's scrolling content to the whole list.
function Panel:place(area)
    local layout = addon.SettingsLayout.Layout(area.sections, function(entry)
        return self.model:IsShown(entry.id)
    end)
    local index
    for index = 1, #layout.items do
        local item = layout.items[index]
        local frame
        if item.kind == "header" then
            frame = area.headers[item.section.id]
        else
            frame = area.rows[item.entry.id]
        end
        if frame ~= nil then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", area.content, "TOPLEFT", item.kind == "header" and SettingsPanel.LEFT or 0,
                -item.y)
            if item.kind == "entry" then
                frame:SetHeight(item.height)
            end
        end
    end
    local height = layout.height
    if area.footer ~= nil then
        area.footer:ClearAllPoints()
        area.footer:SetPoint("TOPLEFT", area.content, "TOPLEFT", 0, -height)
        height = height + area.footerHeight
    end
    area.content:SetHeight(height)
    area.height = height
end

-- Fills in every widget from the model's current values, then lays out
-- every drawn area again.
function Panel:Refresh()
    local index
    for index = 1, #self.widgets do
        local widget = self.widgets[index]
        local enabled = self.model:IsEnabled(widget.id) == true
        -- The value goes in first, and each step on its own, so a call the
        -- client doesn't support can't leave a setting showing blank.
        pcall(function()
            if widget.kind == "input" then
                -- Text being typed is left alone until it's saved.
                local focused = type(widget.frame.HasFocus) == "function" and widget.frame:HasFocus()
                if not focused then
                    local text = tostring(self.model:Get(widget.id) or "")
                    widget.frame:SetText(text)
                    widget.shownText = text
                    -- Filling a box puts its cursor at the end, which scrolls
                    -- a long line out of view; the start is shown instead.
                    if type(widget.frame.SetCursorPosition) == "function" then
                        widget.frame:SetCursorPosition(0)
                    end
                end
            elseif widget.kind == "toggle" then
                widget.frame:SetChecked(self.model:Get(widget.id) == true)
            elseif widget.kind == "number" then
                local value = self.model:Get(widget.id)
                widget.frame:SetText(tostring(value or ""))
                if not enabled or (value ~= nil and value <= widget.entry.min) then
                    widget.down:Disable()
                else
                    widget.down:Enable()
                end
                if not enabled or (value ~= nil and value >= widget.entry.max) then
                    widget.up:Disable()
                else
                    widget.up:Enable()
                end
            elseif widget.kind == "slider" then
                local value = self.model:Get(widget.id)
                if type(value) == "number" then
                    widget.frame:SetValue(value)
                    widget.value:SetText(sliderText(widget.entry, value))
                end
                -- Putting the saved value in isn't a change by the player.
                widget.pending = nil
            elseif widget.kind == "text" then
                widget.frame:SetText(tostring(self.model:Get(widget.id) or ""))
            elseif widget.kind == "color" then
                -- A color that can't be read shows the entry's default.
                local color = self.model:Get(widget.id) or widget.entry.default or widget.entry.swatches[1].color
                widget.value:SetText("|cff" .. tostring(color) .. (widget.entry.sample or "Sample") .. "|r")
                local swatchIndex
                for swatchIndex = 1, #widget.swatches do
                    local swatch = widget.swatches[swatchIndex]
                    if swatch.color == color then
                        swatch.selected:Show()
                    else
                        swatch.selected:Hide()
                    end
                end
            end
        end)
        pcall(setShown, widget, self.model:IsShown(widget.id))
        pcall(setEnabled, widget, enabled)
    end
    for index = 1, #self.areas do
        pcall(self.place, self, self.areas[index])
    end
end

function Panel:addToggle(frame, entry)
    local createFrame = self.environment.CreateFrame
    local check = createFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, 0)
    check:SetScript("OnClick", function(button)
        self.model:Set(entry.id, button:GetChecked() and true or false)
        -- A refused change snaps the box back to the saved value.
        self:Refresh()
    end)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    label:SetText(entry.label)
    local widget = { kind = "toggle", id = entry.id, frame = check, controls = { check }, label = label }
    self:addInfo(frame, entry, label, widget)
    return widget
end

-- An info icon just after `label`, for an entry with `info`: hovering it
-- shows the entry's label and its info text in the game's tooltip, read as
-- it is at that moment.
function Panel:addInfo(frame, entry, label, widget)
    if entry.info == nil then
        return
    end
    local icon = self.environment.CreateFrame("Frame", nil, frame)
    icon:SetWidth(SettingsPanel.INFO_SIZE)
    icon:SetHeight(SettingsPanel.INFO_SIZE)
    icon:SetPoint("LEFT", label, "RIGHT", 4, 0)
    local texture = icon:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints(icon)
    texture:SetTexture(SettingsPanel.INFO_ICON)
    icon:EnableMouse(true)
    icon:SetScript("OnEnter", function()
        self:ShowInfo(icon, entry)
    end)
    icon:SetScript("OnLeave", function()
        local tooltip = self.environment.GameTooltip
        if type(tooltip) == "table" then
            pcall(tooltip.Hide, tooltip)
        end
    end)
    widget.info = icon
end

-- Shows an entry's info in the game's tooltip beside `owner`.
function Panel:ShowInfo(owner, entry)
    local tooltip = self.environment.GameTooltip
    local text = self.model:Info(entry.id)
    if type(tooltip) ~= "table" or text == nil then
        return false
    end
    return (pcall(function()
        tooltip:SetOwner(owner, "ANCHOR_RIGHT")
        tooltip:SetText(entry.label, 1, 0.82, 0)
        tooltip:AddLine(text, 1, 1, 1, true)
        tooltip:Show()
    end))
end

-- Saves what's typed in a text box when the player changed it: it differs
-- from the text the panel last put there. A box the panel never filled in
-- saves nothing, so it can't blank out a saved value. A refused change puts
-- the saved text back.
function Panel:commitInput(widget)
    if widget.shownText == nil then
        return
    end
    local ok, text = pcall(widget.frame.GetText, widget.frame)
    if not ok or type(text) ~= "string" then
        return
    end
    text = string.gsub(text, "[\r\n]", "")
    if text ~= widget.shownText then
        self:report(widget.id, self.model:Set(widget.id, text))
    end
end

-- A line of text: its label, then a text box below it, one line tall or,
-- for an entry with `lines`, that many lines with the text wrapping. A
-- setting is one line of text, so Enter saves rather than starting a new
-- line, and line breaks are never kept. Whatever way the user leaves the
-- box saves what they typed: Enter, Escape, clicking away, or closing the
-- page.
function Panel:addInput(frame, entry)
    local row = addon.SettingsLayout.ROW
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, -4)
    label:SetText(entry.label)
    local lines = addon.SettingsLayout.InputLines(entry)
    local createFrame = self.environment.CreateFrame
    local box
    if lines == 1 then
        box = createFrame("EditBox", nil, frame, "InputBoxTemplate")
        box:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 10, -row + 2)
        box:SetWidth(SettingsPanel.INPUT_WIDTH)
        box:SetHeight(22)
    else
        -- A dark box with a thin edge, the text wrapping inside it.
        local inset = addon.SettingsLayout.INPUT_INSET
        local height = lines * addon.SettingsLayout.INPUT_LINE_HEIGHT + 2 * inset
        local holder = createFrame("Frame", nil, frame)
        holder:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, -row + 4)
        holder:SetWidth(SettingsPanel.INPUT_WIDTH + 6)
        holder:SetHeight(height)
        local edge = holder:CreateTexture(nil, "BACKGROUND")
        edge:SetAllPoints(holder)
        edge:SetColorTexture(0.5, 0.5, 0.5, 0.8)
        local fill = holder:CreateTexture(nil, "BORDER")
        fill:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(0, 0, 0, 0.75)
        box = createFrame("EditBox", nil, holder)
        box:SetMultiLine(true)
        box:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
        box:SetFontObject("ChatFontNormal")
        box:SetTextInsets(inset, inset, inset, inset)
    end
    box:SetAutoFocus(false)
    box:SetMaxLetters(entry.maxLength)
    local widget = { kind = "input", id = entry.id, frame = box, controls = { box }, label = label }
    local function leave()
        box:ClearFocus()
    end
    box:SetScript("OnEnterPressed", leave)
    box:SetScript("OnEscapePressed", leave)
    -- In a multi-line box Enter types a line break: it's taken out again,
    -- and the box is left, so Enter saves there too.
    box:SetScript("OnTextChanged", function()
        local text = box:GetText()
        if type(text) == "string" and string.find(text, "[\r\n]") then
            box:SetText((string.gsub(text, "[\r\n]", "")))
            box:ClearFocus()
        end
    end)
    box:SetScript("OnEditFocusLost", function()
        self:commitInput(widget)
        self:Refresh()
    end)
    return widget
end

-- A whole number as a slider: its label, then a slider across the entry's
-- range in the entry's steps, with the value beside it. The value shown
-- follows the slider as it's dragged; it's saved when the mouse is let go.
function Panel:addSlider(frame, entry)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, -4)
    label:SetText(entry.label)
    local slider = self.environment.CreateFrame("Slider", nil, frame)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 10, -addon.SettingsLayout.ROW + 2)
    slider:SetWidth(SettingsPanel.SLIDER_WIDTH)
    slider:SetHeight(17)
    slider:SetMinMaxValues(entry.min, entry.max)
    local step = type(entry.step) == "number" and entry.step or 1
    slider:SetValueStep(step)
    if type(slider.SetObeyStepDrag) == "function" then
        slider:SetObeyStepDrag(true)
    end
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", slider, "LEFT", 0, 0)
    track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
    track:SetHeight(6)
    track:SetColorTexture(0.25, 0.25, 0.25, 0.9)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local value = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    value:SetPoint("LEFT", slider, "RIGHT", 10, 0)
    local widget = { kind = "slider", id = entry.id, entry = entry, frame = slider, value = value, label = label,
        controls = { slider } }
    -- Snaps a dragged value to the entry's steps.
    local function snapped(raw)
        if type(raw) ~= "number" then
            return nil
        end
        return entry.min + math.floor((raw - entry.min) / step + 0.5) * step
    end
    slider:SetScript("OnValueChanged", function(_, raw)
        local current = snapped(raw)
        if current ~= nil then
            value:SetText(sliderText(entry, current))
            widget.pending = current
        end
    end)
    slider:SetScript("OnMouseUp", function()
        self:commitSlider(widget)
        self:Refresh()
    end)
    return widget
end

-- Saves a slider's value when the player moved it from the saved one.
function Panel:commitSlider(widget)
    local pending = widget.pending
    widget.pending = nil
    if type(pending) == "number" and pending ~= self.model:Get(widget.id) then
        self:report(widget.id, self.model:Set(widget.id, pending))
    end
end

-- Saves whatever is still being typed or dragged, as if the player had let
-- go of it.
function Panel:commitAll()
    local index
    for index = 1, #self.widgets do
        if self.widgets[index].kind == "input" then
            self:commitInput(self.widgets[index])
        elseif self.widgets[index].kind == "slider" then
            self:commitSlider(self.widgets[index])
        end
    end
end

-- Tells the player in chat when a change they made wasn't saved, and why,
-- since the setting then shows its saved value again.
function Panel:report(id, changed, reason)
    if changed then
        return
    end
    local entry = self.model:Entry(id)
    local name = entry and entry.label or id
    pcall(self.client.Print, self.client, addon.Identity.chatPrefix .. " Couldn't save \"" .. tostring(name) ..
        "\": " .. tostring(reason or "it couldn't be saved") .. ".")
end

-- A whole number: its label, then a minus button, the value and a plus
-- button, each press stepping it by one within the entry's range.
function Panel:addNumber(frame, entry)
    local createFrame = self.environment.CreateFrame
    local down = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    down:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, -2)
    down:SetWidth(24)
    down:SetHeight(22)
    down:SetText("-")
    local value = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    value:SetPoint("LEFT", down, "RIGHT", 4, 0)
    value:SetWidth(24)
    local up = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    up:SetPoint("LEFT", value, "RIGHT", 4, 0)
    up:SetWidth(24)
    up:SetHeight(22)
    up:SetText("+")
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", up, "RIGHT", 8, 0)
    label:SetText(entry.label)
    local function step(by)
        local current = self.model:Get(entry.id)
        if type(current) == "number" then
            self.model:Set(entry.id, current + by)
        end
        self:Refresh()
    end
    down:SetScript("OnClick", function()
        step(-1)
    end)
    up:SetScript("OnClick", function()
        step(1)
    end)
    return {
        kind = "number", id = entry.id, entry = entry, frame = value, down = down, up = up, label = label,
        value = value, controls = { down, up },
    }
end

function Panel:addAction(frame, entry)
    local button = self.environment.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, 0)
    button:SetWidth(SettingsPanel.BUTTON_WIDTH)
    button:SetHeight(22)
    button:SetText(entry.label)
    button:SetScript("OnClick", function()
        self.model:Run(entry.id)
    end)
    return { kind = "action", id = entry.id, frame = button, controls = { button } }
end

-- "rrggbb" as red, green and blue from 0 to 1, and back.
local function toRGB(color)
    return tonumber(string.sub(color, 1, 2), 16) / 255, tonumber(string.sub(color, 3, 4), 16) / 255,
        tonumber(string.sub(color, 5, 6), 16) / 255
end

local function toHex(r, g, b)
    local function byte(value)
        return math.max(0, math.min(255, math.floor(value * 255 + 0.5)))
    end
    return string.format("%02x%02x%02x", byte(r), byte(g), byte(b))
end

-- Opens the game's color picker on a color entry's current color: the
-- color picked is saved as it changes, and cancelling puts the starting
-- color back. Retail sets the picker up with one call; older clients set
-- its fields and show it. Returns false where there's no picker.
function Panel:OpenColorPicker(entry)
    local picker = self.environment.ColorPickerFrame
    if type(picker) ~= "table" then
        return false
    end
    local start = self.model:Get(entry.id) or entry.swatches[1].color
    local r, g, b = toRGB(start)
    local function picked()
        local ok, newR, newG, newB = pcall(picker.GetColorRGB, picker)
        if ok and type(newR) == "number" and type(newG) == "number" and type(newB) == "number" then
            self:report(entry.id, self.model:Set(entry.id, toHex(newR, newG, newB)))
        end
        self:Refresh()
    end
    local function cancelled()
        if self.model:Get(entry.id) ~= start then
            self.model:Set(entry.id, start)
        end
        self:Refresh()
    end
    return (pcall(function()
        if type(picker.SetupColorPickerAndShow) == "function" then
            picker:SetupColorPickerAndShow({
                r = r, g = g, b = b, hasOpacity = false, swatchFunc = picked, cancelFunc = cancelled,
            })
            return
        end
        picker.hasOpacity = false
        picker.opacityFunc = nil
        picker.func = picked
        picker.cancelFunc = cancelled
        picker.previousValues = { r, g, b }
        picker:SetColorRGB(r, g, b)
        if type(self.environment.ShowUIPanel) == "function" then
            self.environment.ShowUIPanel(picker)
        else
            picker:Show()
        end
    end))
end

-- A color: its label with a sample in the chosen color, then a row of
-- swatches to click, the chosen one outlined. Where the client has the
-- game's color picker, a Custom... button opens it for any other color.
function Panel:addColor(frame, entry)
    local createFrame = self.environment.CreateFrame
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, -4)
    label:SetText(entry.label)
    local sample = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sample:SetPoint("LEFT", label, "RIGHT", 10, 0)
    local widget = { kind = "color", id = entry.id, entry = entry, label = label, value = sample, swatches = {},
        controls = {} }
    local size = SettingsPanel.SWATCH_SIZE
    local index
    for index = 1, #entry.swatches do
        local choice = entry.swatches[index]
        local swatch = createFrame("Button", nil, frame)
        swatch:SetWidth(size)
        swatch:SetHeight(size)
        swatch:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 10 + (index - 1) * (size + 6),
            -addon.SettingsLayout.ROW + 2)
        -- A white outline behind the chosen swatch, then a dark edge and
        -- the color itself.
        local selected = swatch:CreateTexture(nil, "BACKGROUND")
        selected:SetPoint("TOPLEFT", swatch, "TOPLEFT", -2, 2)
        selected:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", 2, -2)
        selected:SetColorTexture(1, 1, 1, 1)
        local edge = swatch:CreateTexture(nil, "BORDER")
        edge:SetAllPoints(swatch)
        edge:SetColorTexture(0, 0, 0, 1)
        local fill = swatch:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", swatch, "TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(toRGB(choice.color))
        swatch:SetScript("OnClick", function()
            self:report(entry.id, self.model:Set(entry.id, choice.color))
            self:Refresh()
        end)
        swatch:SetScript("OnEnter", function()
            local tooltip = self.environment.GameTooltip
            if type(tooltip) == "table" then
                pcall(function()
                    tooltip:SetOwner(swatch, "ANCHOR_RIGHT")
                    tooltip:SetText(choice.label)
                    tooltip:Show()
                end)
            end
        end)
        swatch:SetScript("OnLeave", function()
            local tooltip = self.environment.GameTooltip
            if type(tooltip) == "table" then
                pcall(tooltip.Hide, tooltip)
            end
        end)
        table.insert(widget.swatches, { frame = swatch, color = choice.color, selected = selected })
        table.insert(widget.controls, swatch)
    end
    if type(self.environment.ColorPickerFrame) == "table" then
        local custom = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
        custom:SetWidth(80)
        custom:SetHeight(20)
        custom:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 16 + #entry.swatches * (size + 6),
            -addon.SettingsLayout.ROW + 3)
        custom:SetText("Custom...")
        custom:SetScript("OnClick", function()
            self:OpenColorPicker(entry)
        end)
        widget.custom = custom
        table.insert(widget.controls, custom)
    end
    return widget
end

function Panel:addText(frame, entry)
    local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, -4)
    return { kind = "text", id = entry.id, frame = text }
end

-- A title within a section, over a thin gold line, setting the entries
-- after it apart (e.g. officer-only settings).
function Panel:addHeading(frame, entry)
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, -2)
    line:SetWidth(SettingsPanel.INPUT_WIDTH)
    line:SetHeight(1)
    line:SetColorTexture(0.83, 0.69, 0.22, 0.6)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, -8)
    label:SetText(entry.label)
    return { kind = "heading", id = entry.id, label = label, value = line }
end

-- Draws one entry on a row of its own inside `content`; the row is placed
-- by the layout on every refresh.
function Panel:addEntry(content, entry)
    local row = self.environment.CreateFrame("Frame", nil, content)
    row:SetWidth(SettingsPanel.INPUT_WIDTH + 2 * SettingsPanel.LEFT + 40)
    local widget
    if entry.kind == "toggle" then
        widget = self:addToggle(row, entry)
    elseif entry.kind == "action" then
        widget = self:addAction(row, entry)
    elseif entry.kind == "number" and entry.slider then
        widget = self:addSlider(row, entry)
    elseif entry.kind == "number" then
        widget = self:addNumber(row, entry)
    elseif entry.kind == "input" then
        widget = self:addInput(row, entry)
    elseif entry.kind == "heading" then
        widget = self:addHeading(row, entry)
    elseif entry.kind == "color" then
        widget = self:addColor(row, entry)
    else
        widget = self:addText(row, entry)
    end
    widget.row = row
    table.insert(self.widgets, widget)
    return row
end

-- Draws `sections` onto `parent` inside a scroll area that fills it below
-- `top` (an offset down from its top edge). Only this panel's host's
-- entries are drawn. The area keeps its scroll position while it's open.
-- With `footerHeight`, the scrolling content also holds a frame that tall
-- just below the settings, for a page to draw more into, and it's
-- returned after the scroll area. Raises when a frame call fails; callers
-- run it protected.
function Panel:Draw(parent, sections, top, footerHeight)
    local createFrame = self.environment.CreateFrame
    -- Older clients' scroll frame template names its scroll bar after the
    -- frame, so every scroll area gets a name of its own.
    SettingsPanel.scrollCount = (SettingsPanel.scrollCount or 0) + 1
    local scroll = createFrame("ScrollFrame", addon.Identity.addonName .. "SettingsScroll" .. SettingsPanel.scrollCount,
        parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(top or 0))
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -SettingsPanel.SCROLL_BAR, 8)
    local content = createFrame("Frame", nil, scroll)
    content:SetWidth(SettingsPanel.INPUT_WIDTH + 2 * SettingsPanel.LEFT + 40)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    local area = { content = content, sections = {}, headers = {}, rows = {} }
    local sectionIndex, entryIndex
    for sectionIndex = 1, #sections do
        local section = sections[sectionIndex]
        local drawn = { id = section.id, label = section.label, entries = {} }
        local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        header:SetText(section.label)
        area.headers[section.id] = header
        for entryIndex = 1, #section.entries do
            local entry = section.entries[entryIndex]
            if self.model:InHost(entry.id, self.host) then
                table.insert(drawn.entries, entry)
                area.rows[entry.id] = self:addEntry(content, entry)
            end
        end
        table.insert(area.sections, drawn)
    end
    if footerHeight ~= nil then
        area.footer = createFrame("Frame", nil, content)
        area.footer:SetWidth(SettingsPanel.INPUT_WIDTH + 2 * SettingsPanel.LEFT + 40)
        area.footer:SetHeight(footerHeight)
        area.footerHeight = footerHeight
    end
    table.insert(self.areas, area)
    -- Leaving the page saves what's still being typed or dragged.
    scroll:SetScript("OnHide", function()
        self:commitAll()
    end)
    self:place(area)
    return scroll, area.footer
end

-- Listens for every setting change from now on, so this panel's drawn
-- copies always show the saved values. Safe to call more than once.
function Panel:Watch()
    if self.watching then
        return
    end
    self.watching = true
    self.model:OnChange(function()
        self:Refresh()
    end)
end

-- Builds one options page, titled `title`, from `sections`. Returns the
-- frame, or nil.
function Panel:Build(sections, title)
    if type(self.environment.CreateFrame) ~= "function" then
        return nil
    end
    local ok, frame = pcall(function()
        local panel = self.environment.CreateFrame("Frame")
        panel.name = title
        local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        heading:SetPoint("TOPLEFT", SettingsPanel.LEFT, SettingsPanel.TOP)
        heading:SetText(title)
        self:Draw(panel, sections, -SettingsPanel.TOP + addon.SettingsLayout.ROW)
        panel:SetScript("OnShow", function()
            self:Refresh()
        end)
        -- However the options window closes (X, Close, Escape), or the user
        -- moves to another page, the page hides.
        panel:SetScript("OnHide", function()
            -- Text still being typed is saved, as if the user clicked away.
            self:commitAll()
            self.model:Closed()
        end)
        return panel
    end)
    if not ok then
        return nil
    end
    return frame
end

-- The model's sections split into the add-on's own page's (home sections)
-- and the features', each of which gets a sub-page.
function Panel:pages()
    local main, own = {}, {}
    local sections = self.model:Sections()
    local index
    for index = 1, #sections do
        if sections[index].home then
            table.insert(main, sections[index])
        else
            table.insert(own, sections[index])
        end
    end
    return main, own
end

-- Adds the panel to the AddOns options: the add-on's own page with the
-- home sections, and under it a sub-page for each feature's section, so
-- each page fits the options window. A client that can't show pages under
-- the main one gets every section on the main page, scrolling.
-- Returns true when the main page was added.
function Panel:Register()
    if self.registered then
        return true
    end
    local settings = self.environment.Settings
    local modern = type(settings) == "table" and type(settings.RegisterCanvasLayoutCategory) == "function"
        and type(settings.RegisterAddOnCategory) == "function"
    local legacy = type(self.environment.InterfaceOptions_AddCategory) == "function"
    local main, own = self:pages()
    local canNest = (modern and type(settings.RegisterCanvasLayoutSubcategory) == "function") or (not modern and legacy)
    if not canNest then
        local index
        for index = 1, #own do
            table.insert(main, own[index])
        end
        own = {}
    end
    local frame = self:Build(main, addon.Identity.displayName)
    if frame == nil then
        return false
    end
    local ok = false
    if modern then
        ok = pcall(function()
            local category = settings.RegisterCanvasLayoutCategory(frame, addon.Identity.displayName)
            local index
            for index = 1, #own do
                local page = self:Build({ own[index] }, own[index].label)
                if page ~= nil then
                    settings.RegisterCanvasLayoutSubcategory(category, page, own[index].label)
                end
            end
            settings.RegisterAddOnCategory(category)
            self.category = category
        end)
    elseif legacy then
        ok = pcall(function()
            self.environment.InterfaceOptions_AddCategory(frame)
            local index
            for index = 1, #own do
                local page = self:Build({ own[index] }, own[index].label)
                if page ~= nil then
                    page.parent = frame.name
                    self.environment.InterfaceOptions_AddCategory(page)
                end
            end
        end)
    end
    if not ok then
        return false
    end
    self.frame = frame
    self.registered = true
    self:Watch()
    -- Filled in now, not only when a page is first shown.
    self:Refresh()
    return true
end
