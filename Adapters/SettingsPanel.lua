local _, addon = ...

-- The add-on's page in the game's AddOns options (Esc -> Options -> AddOns),
-- drawn from the SettingsModel: a title, then one header per section with
-- its entries below it. A section that asks for a page of its own gets one
-- under the add-on's entry. Within a section, a heading sets the entries
-- after it apart (a check box, a button, a line of text, a number
-- with minus and plus buttons, or a labelled text box saved on Enter). An
-- entry the model reports disabled is greyed out and can't be changed, and
-- one it reports hidden isn't shown. Clients with the newer Settings API get a canvas
-- category; older ones get an Interface Options panel. Like the other
-- adapters, everything is optional and protected: a client with neither API,
-- or a frame call that fails, just leaves the panel out without an error.
local SettingsPanel = {
    LEFT = 16,
    TOP = -16,
    ROW = 26,
    SECTION_GAP = 12,
    INDENT = 8,
    BUTTON_WIDTH = 140,
    INPUT_WIDTH = 520,
    SLIDER_WIDTH = 260,
    -- The info icon beside a label that shows a setting's info on
    -- mouseover; this texture is on both supported clients.
    INFO_ICON = "Interface\\FriendsFrame\\InformationIcon",
    INFO_SIZE = 16,
    -- A text line's height in a multi-line box, and the room around the
    -- text inside the box.
    INPUT_LINE_HEIGHT = 14,
    INPUT_INSET = 6,
}
addon.SettingsPanel = SettingsPanel

local Panel = {}
Panel.__index = Panel

-- `client` is the WoW adapter; `model` the SettingsModel to draw.
function SettingsPanel.Create(client, model)
    return setmetatable({
        client = client,
        model = model,
        environment = client.environment,
        widgets = {},
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

-- Shows or hides a widget's controls and label.
local function setShown(widget, shown)
    local parts = {}
    local index
    for index, part in ipairs({ "label", "value", "info" }) do
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

-- Fills in every widget from the model's current values.
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
            end
        end)
        pcall(setShown, widget, self.model:IsShown(widget.id))
        pcall(setEnabled, widget, enabled)
    end
end

function Panel:addToggle(frame, entry, y)
    local createFrame = self.environment.CreateFrame
    local check = createFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, y)
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
    table.insert(self.widgets, widget)
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
        self.model:Set(widget.id, text)
    end
end

-- The text box's height for an entry: one line, or `entry.lines` lines.
local function inputLines(entry)
    if type(entry.lines) == "number" and entry.lines > 1 then
        return math.floor(entry.lines)
    end
    return 1
end

-- How many panel rows an entry's text box takes below its label.
function SettingsPanel.InputRows(entry)
    local lines = inputLines(entry)
    if lines == 1 then
        return 1
    end
    local height = lines * SettingsPanel.INPUT_LINE_HEIGHT + 2 * SettingsPanel.INPUT_INSET
    return math.ceil(height / SettingsPanel.ROW)
end

-- A line of text: its label, then a text box below it, one line tall or,
-- for an entry with `lines`, that many lines with the text wrapping. A
-- setting is one line of text, so Enter saves rather than starting a new
-- line, and line breaks are never kept. Whatever way the user leaves the
-- box saves what they typed: Enter, Escape, clicking away, or closing the
-- options.
function Panel:addInput(frame, entry, y)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, y - 4)
    label:SetText(entry.label)
    local lines = inputLines(entry)
    local createFrame = self.environment.CreateFrame
    local box
    if lines == 1 then
        box = createFrame("EditBox", nil, frame, "InputBoxTemplate")
        box:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 10, y - SettingsPanel.ROW + 2)
        box:SetWidth(SettingsPanel.INPUT_WIDTH)
        box:SetHeight(22)
    else
        -- A dark box with a thin edge, the text wrapping inside it.
        local height = lines * SettingsPanel.INPUT_LINE_HEIGHT + 2 * SettingsPanel.INPUT_INSET
        local holder = createFrame("Frame", nil, frame)
        holder:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, y - SettingsPanel.ROW + 4)
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
        box:SetTextInsets(SettingsPanel.INPUT_INSET, SettingsPanel.INPUT_INSET,
            SettingsPanel.INPUT_INSET, SettingsPanel.INPUT_INSET)
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
    table.insert(self.widgets, widget)
end

-- A whole number as a slider: its label, then a slider across the entry's
-- range in the entry's steps, with the value beside it. The value shown
-- follows the slider as it's dragged; it's saved when the mouse is let go.
function Panel:addSlider(frame, entry, y)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, y - 4)
    label:SetText(entry.label)
    local slider = self.environment.CreateFrame("Slider", nil, frame)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 10, y - SettingsPanel.ROW + 2)
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
    table.insert(self.widgets, widget)
end

-- Saves a slider's value when the player moved it from the saved one.
function Panel:commitSlider(widget)
    local pending = widget.pending
    widget.pending = nil
    if type(pending) == "number" and pending ~= self.model:Get(widget.id) then
        self.model:Set(widget.id, pending)
    end
end

-- A whole number: its label, then a minus button, the value and a plus
-- button, each press stepping it by one within the entry's range.
function Panel:addNumber(frame, entry, y)
    local createFrame = self.environment.CreateFrame
    local down = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    down:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT + 4, y - 2)
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
    table.insert(self.widgets, {
        kind = "number", id = entry.id, entry = entry, frame = value, down = down, up = up, label = label,
        value = value, controls = { down, up },
    })
end

function Panel:addAction(frame, entry, y)
    local button = self.environment.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, y)
    button:SetWidth(SettingsPanel.BUTTON_WIDTH)
    button:SetHeight(22)
    button:SetText(entry.label)
    button:SetScript("OnClick", function()
        self.model:Run(entry.id)
    end)
    table.insert(self.widgets, { kind = "action", id = entry.id, frame = button, controls = { button } })
end

function Panel:addText(frame, entry, y)
    local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, y - 4)
    table.insert(self.widgets, { kind = "text", id = entry.id, frame = text })
end

-- A title within a section, over a thin gold line, setting the entries
-- after it apart (e.g. officer-only settings).
function Panel:addHeading(frame, entry, y)
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, y - 2)
    line:SetWidth(SettingsPanel.INPUT_WIDTH)
    line:SetHeight(1)
    line:SetColorTexture(0.83, 0.69, 0.22, 0.6)
    local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, y - 8)
    label:SetText(entry.label)
    table.insert(self.widgets, { kind = "heading", id = entry.id, label = label, value = line })
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
        local y = SettingsPanel.TOP - SettingsPanel.ROW - SettingsPanel.SECTION_GAP
        local sectionIndex, entryIndex
        for sectionIndex = 1, #sections do
            local section = sections[sectionIndex]
            local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            header:SetPoint("TOPLEFT", SettingsPanel.LEFT, y)
            header:SetText(section.label)
            y = y - SettingsPanel.ROW + 6
            for entryIndex = 1, #section.entries do
                local entry = section.entries[entryIndex]
                if entry.kind == "toggle" then
                    self:addToggle(panel, entry, y)
                elseif entry.kind == "action" then
                    self:addAction(panel, entry, y)
                elseif entry.kind == "number" and entry.slider then
                    self:addSlider(panel, entry, y)
                    -- The slider sits on a row of its own below the label.
                    y = y - SettingsPanel.ROW
                elseif entry.kind == "number" then
                    self:addNumber(panel, entry, y)
                elseif entry.kind == "input" then
                    self:addInput(panel, entry, y)
                    -- The text box sits on rows of its own below the label.
                    y = y - SettingsPanel.InputRows(entry) * SettingsPanel.ROW
                elseif entry.kind == "heading" then
                    -- A gap above it sets it apart from the entries before.
                    y = y - SettingsPanel.SECTION_GAP
                    self:addHeading(panel, entry, y)
                else
                    self:addText(panel, entry, y)
                end
                y = y - SettingsPanel.ROW
            end
            y = y - SettingsPanel.SECTION_GAP
        end
        panel:SetScript("OnShow", function()
            self:Refresh()
        end)
        -- However the options window closes (X, Close, Escape), or the user
        -- moves to another page, the page hides.
        panel:SetScript("OnHide", function()
            -- Text still being typed is saved, as if the user clicked away.
            local index
            for index = 1, #self.widgets do
                if self.widgets[index].kind == "input" then
                    self:commitInput(self.widgets[index])
                elseif self.widgets[index].kind == "slider" then
                    self:commitSlider(self.widgets[index])
                end
            end
            self.model:Closed()
        end)
        return panel
    end)
    if not ok then
        return nil
    end
    return frame
end

-- The model's sections split into the main page's and those that ask for a
-- page of their own.
function Panel:pages()
    local main, own = {}, {}
    local sections = self.model:Sections()
    local index
    for index = 1, #sections do
        if sections[index].ownPage then
            table.insert(own, sections[index])
        else
            table.insert(main, sections[index])
        end
    end
    return main, own
end

-- Adds the panel to the AddOns options: the main page, with a page of its
-- own under it for each section that asks for one. A client that can't
-- show pages under the main one gets those sections on the main page.
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
    self.model:OnChange(function()
        self:Refresh()
    end)
    -- Filled in now, not only when a page is first shown.
    self:Refresh()
    return true
end

-- `/agf options`: opens the AddOns options at this panel. Returns true when
-- the client opened it.
function Panel:Open()
    if not self.registered then
        return false
    end
    local environment = self.environment
    local settings = environment.Settings
    if self.category ~= nil and type(settings.OpenToCategory) == "function" then
        return (pcall(function()
            local id = self.category.ID
            if type(self.category.GetID) == "function" then
                id = self.category:GetID()
            end
            settings.OpenToCategory(id)
        end))
    end
    if type(environment.InterfaceOptionsFrame_OpenToCategory) == "function" then
        -- The old options frame often opens on the wrong page the first
        -- time, so it's asked twice.
        return (pcall(function()
            environment.InterfaceOptionsFrame_OpenToCategory(self.frame)
            environment.InterfaceOptionsFrame_OpenToCategory(self.frame)
        end))
    end
    return false
end
