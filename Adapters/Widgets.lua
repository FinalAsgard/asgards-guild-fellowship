local _, addon = ...

-- The new UI's building blocks, drawn from the Theme with plain game frames
-- (no Details! Framework): rounded panels and cards, buttons, a segmented
-- control, tabs, a toggle switch, a search box, a text input with a
-- character counter, a count badge, a glow, a role tile and a context menu.
-- Later features moved into the new window reuse them.
--
-- Rounded shapes are drawn from one white disc (Theme.TEXTURES.rounded):
-- its quarters are the four corners, and three flat bands fill between
-- them, so a shape of any size and color takes seven tinted textures. A
-- 1px border is a second shape just behind, 1px larger.
local Theme = addon.Theme

local Widgets = {
    BUTTON_HEIGHT = 26,
    TOGGLE_WIDTH = 34,
    TOGGLE_HEIGHT = 18,
    INPUT_HEIGHT = 26,
    DOT_SIZE = 6,
    ROLE_LABELS = { tank = "Tank", healer = "Healer", dps = "DPS" },
    -- Each role's icon (a Theme.TEXTURES name); "any" is a person.
    ROLE_ICONS = { tank = "shield", healer = "cross", dps = "sword", any = "person" },
}
addon.Widgets = Widgets

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

-- Opens the game's color picker on `start` ("rrggbb"), for both windows'
-- color settings: `onColor(color)` gets each color picked as it changes,
-- and `onColor(start, true)` on cancel. Retail sets the picker up with one
-- call; older clients set its fields and show it. False where there's no
-- picker.
function Widgets.OpenColorPicker(environment, start, onColor)
    local picker = environment.ColorPickerFrame
    if type(picker) ~= "table" then
        return false
    end
    local r, g, b = toRGB(start)
    local function picked()
        local ok, newR, newG, newB = pcall(picker.GetColorRGB, picker)
        if ok and type(newR) == "number" and type(newG) == "number" and type(newB) == "number" then
            onColor(toHex(newR, newG, newB))
        end
    end
    local function cancelled()
        onColor(start, true)
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
        if type(environment.ShowUIPanel) == "function" then
            environment.ShowUIPanel(picker)
        else
            picker:Show()
        end
    end))
end

local UI = {}
UI.__index = UI

-- A widget factory drawing with `environment`'s CreateFrame (the game's
-- globals, or a spec's fake frames).
function Widgets.Create(environment)
    return setmetatable({ environment = environment }, UI)
end

function UI:frame(frameType, parent, template)
    return self.environment.CreateFrame(frameType, nil, parent, template)
end

-- Shapes --------------------------------------------------------------------

local Shape = {}
Shape.__index = Shape

-- The disc's quarters, as texture coordinates, by corner.
local CORNERS = {
    TOPLEFT = { 0, 0.5, 0, 0.5 },
    TOPRIGHT = { 0.5, 1, 0, 0.5 },
    BOTTOMLEFT = { 0, 0.5, 0.5, 1 },
    BOTTOMRIGHT = { 0.5, 1, 0.5, 1 },
}
local CORNER_ORDER = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

-- A rounded rectangle drawn on `frame` in draw layer `layer` at `sublevel`.
local function newShape(frame, layer, sublevel)
    local shape = setmetatable({ frame = frame, corners = {}, bands = {} }, Shape)
    local index
    for index = 1, #CORNER_ORDER do
        local corner = frame:CreateTexture(nil, layer, nil, sublevel)
        corner:SetTexture(Theme.TEXTURES.rounded)
        corner:SetTexCoord(unpack(CORNERS[CORNER_ORDER[index]]))
        shape.corners[CORNER_ORDER[index]] = corner
    end
    for index = 1, 3 do
        local band = frame:CreateTexture(nil, layer, nil, sublevel)
        band:SetTexture(Theme.TEXTURES.white)
        shape.bands[index] = band
    end
    return shape
end

-- Fits the shape inside its frame, `inset` pixels in, with corner `radius`.
function Shape:Place(inset, radius)
    local frame = self.frame
    local corner, point
    for point, corner in pairs(self.corners) do
        local x = string.find(point, "LEFT") and inset or -inset
        local y = string.find(point, "TOP") and -inset or inset
        corner:ClearAllPoints()
        corner:SetPoint(point, frame, point, x, y)
        corner:SetSize(radius, radius)
    end
    local middle, left, right = self.bands[1], self.bands[2], self.bands[3]
    middle:ClearAllPoints()
    middle:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + radius, -inset)
    middle:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset - radius, inset)
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset - radius)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", inset + radius, inset + radius)
    right:ClearAllPoints()
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset - radius)
    right:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", -inset - radius, inset + radius)
    return self
end

function Shape:each(callback)
    local point
    for point in pairs(self.corners) do
        callback(self.corners[point])
    end
    local index
    for index = 1, #self.bands do
        callback(self.bands[index])
    end
end

-- Tints the shape r, g, b, a.
function Shape:SetColor(r, g, b, a)
    self:each(function(texture)
        texture:SetVertexColor(r, g, b, a or 1)
    end)
end

function Shape:SetShown(shown)
    self:each(function(texture)
        if shown then
            texture:Show()
        else
            texture:Hide()
        end
    end)
end

-- Gives `frame` a rounded fill and a 1px edge behind it, with SetFill and
-- SetBorder to recolor them.
local function round(frame, radius, fill, border)
    frame.edgeShape = newShape(frame, "BACKGROUND", 1):Place(0, radius)
    frame.fillShape = newShape(frame, "BACKGROUND", 2):Place(1, math.max(radius - 1, 1))
    function frame.SetFill(_, color)
        frame.fillColor = color
        frame.fillShape:SetColor(Theme.Color(color))
        if frame.borderColor == nil then
            frame.edgeShape:SetColor(Theme.Color(color))
        end
    end
    -- `color`: a COLORS name ("border" for the faint edge, "gold",
    -- "green"), or nil for no visible edge.
    function frame.SetBorder(_, color)
        frame.borderColor = color
        frame.edgeShape:SetColor(Theme.Color(color or frame.fillColor))
    end
    frame:SetFill(fill)
    frame:SetBorder(border)
    return frame
end

-- Panels and cards ----------------------------------------------------------

-- Gives an existing `frame` a rounded fill (a COLORS name) and an optional
-- 1px border, with SetFill and SetBorder, as a panel has.
function UI:Round(frame, radius, fill, border)
    return round(frame, radius, fill, border)
end

-- A rounded panel or card. options: radius (default the card's), fill (a
-- COLORS name, default "surface"), border ("border" for the faint edge,
-- "gold", "green", or false for none; default "border").
function UI:Panel(parent, options)
    options = options or {}
    local panel = self:frame("Frame", parent)
    local border = options.border
    if border == nil then
        border = "border"
    end
    return round(panel, options.radius or Theme.RADIUS.card, options.fill or "surface", border or nil)
end

-- A font string on `parent` in Inter. `style`, `size` and `color` as for
-- Theme.Font.
function UI:Text(parent, text, style, size, color, layer)
    local label = parent:CreateFontString(nil, layer or "OVERLAY")
    Theme.Font(label, style, size, color or "text")
    label:SetText(text or "")
    return label
end

-- A small uppercase grey section label.
function UI:SectionLabel(parent, text)
    return self:Text(parent, Theme.Label(text), "semibold", "small", "label")
end

-- Buttons -------------------------------------------------------------------

local BUTTON_COLORS = {
    primary = { fill = "green", hover = "greenHover", text = "text", border = false },
    secondary = { fill = "raised", hover = "hover", text = "text", border = "border" },
}

-- A rounded text button. `kind`: "primary" (green) or "secondary"; `onClick`
-- runs on a left click while it's enabled. SetLabel renames it and
-- SetActive enables or greys it out.
function UI:Button(parent, label, kind, onClick)
    local button = self:frame("Button", parent)
    local colors = BUTTON_COLORS[kind] or BUTTON_COLORS.secondary
    button:SetHeight(Widgets.BUTTON_HEIGHT)
    round(button, Theme.RADIUS.button, colors.fill, colors.border or nil)
    button.label = self:Text(button, label, "semibold", "body", colors.text)
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.active = true
    button:SetScript("OnEnter", function(self)
        if self.active then
            self:SetFill(colors.hover)
        end
    end)
    button:SetScript("OnLeave", function(self)
        self:SetFill(colors.fill)
    end)
    button:SetScript("OnClick", function(self)
        if self.active and onClick ~= nil then
            onClick(self)
        end
    end)
    function button.SetLabel(_, text)
        button.label:SetText(text or "")
    end
    function button.SetActive(_, active)
        button.active = active == true
        button.label:SetTextColor(Theme.Color(button.active and colors.text or "disabled"))
    end
    return button
end

-- A square button showing `texture` tinted grey, white on mouseover, with
-- a rounded backdrop that shows while hovered or `selected`.
function UI:IconButton(parent, texture, size, onClick)
    local button = self:frame("Button", parent)
    button:SetSize(size, size)
    round(button, Theme.RADIUS.small, "hover", false)
    button.fillShape:SetShown(false)
    button.edgeShape:SetShown(false)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(texture)
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 5, -5)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -5, 5)
    button.icon:SetVertexColor(Theme.Color("muted"))
    local function backdrop(shown)
        button.fillShape:SetShown(shown)
        button.edgeShape:SetShown(shown)
    end
    button:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(Theme.Color("text"))
        backdrop(true)
    end)
    button:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(Theme.Color("muted"))
        backdrop(self.selected == true)
    end)
    button:SetScript("OnClick", function(self)
        if onClick ~= nil then
            onClick(self)
        end
    end)
    function button.SetSelected(_, selected)
        button.selected = selected == true
        backdrop(button.selected)
    end
    return button
end

-- Choices -------------------------------------------------------------------

-- Buttons side by side in one rounded strip, one selected (green). `items`
-- is a list of { id, label }; `onSelect(id)` runs when the player picks
-- one. Select(id) picks one without calling onSelect; Selected() says
-- which is picked.
function UI:Segmented(parent, items, width, onSelect)
    local strip = self:Panel(parent, { radius = Theme.RADIUS.button, fill = "surface" })
    strip:SetSize(width, Widgets.BUTTON_HEIGHT)
    strip.buttons = {}
    local count = math.max(#items, 1)
    local segment = (width - 4) / count
    local ui = self
    local index
    for index = 1, #items do
        local item = items[index]
        local button = ui:frame("Button", strip)
        button:SetSize(segment, Widgets.BUTTON_HEIGHT - 4)
        button:SetPoint("TOPLEFT", strip, "TOPLEFT", 2 + (index - 1) * segment, -2)
        round(button, Theme.RADIUS.small, "surface", false)
        button.id = item.id
        button.label = ui:Text(button, item.label, "semibold", "body", "muted")
        button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.dot = button:CreateTexture(nil, "OVERLAY")
        button.dot:SetTexture(Theme.TEXTURES.rounded)
        button.dot:SetVertexColor(Theme.Color("disabled"))
        button.dot:SetSize(Widgets.DOT_SIZE, Widgets.DOT_SIZE)
        button.dot:SetPoint("LEFT", button.label, "RIGHT", Theme.SPACING.xs, 0)
        button.dot:Hide()
        button:SetScript("OnClick", function(self)
            strip:Select(self.id)
            if onSelect ~= nil then
                onSelect(self.id)
            end
        end)
        strip.buttons[index] = button
    end
    function strip.Select(_, id)
        strip.selected = id
        local position
        for position = 1, #strip.buttons do
            local button = strip.buttons[position]
            local on = button.id == id
            button:SetFill(on and "green" or "surface")
            button.label:SetTextColor(Theme.Color(on and "text" or "muted"))
        end
    end
    function strip.Selected()
        return strip.selected
    end
    -- A small grey dot beside one's label, e.g. for a choice that's off.
    function strip.SetDot(_, id, shown)
        local position
        for position = 1, #strip.buttons do
            local button = strip.buttons[position]
            if button.id == id then
                button.dotShown = shown == true
                if button.dotShown then
                    button.dot:Show()
                else
                    button.dot:Hide()
                end
            end
        end
    end
    if items[1] ~= nil then
        strip:Select(items[1].id)
    end
    return strip
end

-- A row of tabs drawn as rounded buttons, the selected one green, as the
-- window's sidebar buttons are. Like Segmented: `items` { id, label },
-- onSelect(id), Select(id), Selected(), and SetLabel(id, text) for a tab
-- whose label carries a count.
function UI:Tabs(parent, items, onSelect)
    local row = self:frame("Frame", parent)
    row:SetHeight(28)
    row.tabs = {}
    local ui = self
    -- Each tab as wide as its label and its padding, one after another.
    local function layout()
        local x = 0
        local position
        for position = 1, #row.tabs do
            local tab = row.tabs[position]
            local width = math.max((tab.label:GetStringWidth() or 0) + 2 * Theme.SPACING.m, 48)
            tab:SetSize(width, 28)
            tab:ClearAllPoints()
            tab:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
            x = x + width + Theme.SPACING.xs
        end
    end
    local index
    for index = 1, #items do
        local item = items[index]
        local tab = ui:frame("Button", row)
        tab.id = item.id
        round(tab, Theme.RADIUS.button, "surface", false)
        tab.label = ui:Text(tab, item.label, "semibold", "body", "muted")
        tab.label:SetPoint("CENTER", tab, "CENTER", 0, 0)
        tab:SetScript("OnEnter", function(self)
            if self.id ~= row.selected then
                self:SetFill("hover")
            end
        end)
        tab:SetScript("OnLeave", function(self)
            if self.id ~= row.selected then
                self:SetFill("surface")
            end
        end)
        tab:SetScript("OnClick", function(self)
            row:Select(self.id)
            if onSelect ~= nil then
                onSelect(self.id)
            end
        end)
        row.tabs[index] = tab
    end
    layout()
    function row.Select(_, id)
        row.selected = id
        local position
        for position = 1, #row.tabs do
            local tab = row.tabs[position]
            local on = tab.id == id
            tab:SetFill(on and "green" or "surface")
            tab.label:SetTextColor(Theme.Color(on and "text" or "muted"))
        end
    end
    function row.Selected()
        return row.selected
    end
    function row.SetLabel(_, id, text)
        local position
        for position = 1, #row.tabs do
            if row.tabs[position].id == id then
                row.tabs[position].label:SetText(text)
            end
        end
        -- A longer label (a count added) widens its tab and moves the rest.
        layout()
    end
    if items[1] ~= nil then
        row:Select(items[1].id)
    end
    return row
end

-- An on/off switch: a pill, green while on, with a round knob. A click
-- calls onChange(wanted); the owner saves it and calls SetOn with what was
-- saved, so the switch always shows the real setting. IsOn() reads it.
function UI:Toggle(parent, onChange)
    local switch = self:frame("Button", parent)
    switch:SetSize(Widgets.TOGGLE_WIDTH, Widgets.TOGGLE_HEIGHT)
    round(switch, Widgets.TOGGLE_HEIGHT / 2, "raised", "border")
    switch.knob = switch:CreateTexture(nil, "ARTWORK")
    switch.knob:SetTexture(Theme.TEXTURES.rounded)
    switch.knob:SetSize(Widgets.TOGGLE_HEIGHT - 4, Widgets.TOGGLE_HEIGHT - 4)
    switch.knob:SetVertexColor(Theme.Color("text"))
    function switch.SetOn(_, on)
        switch.on = on == true
        switch.knob:ClearAllPoints()
        if switch.on then
            switch.knob:SetPoint("RIGHT", switch, "RIGHT", -2, 0)
            switch:SetFill("green")
            switch:SetBorder(nil)
        else
            switch.knob:SetPoint("LEFT", switch, "LEFT", 2, 0)
            switch:SetFill("raised")
            switch:SetBorder("border")
        end
    end
    function switch.IsOn()
        return switch.on == true
    end
    switch:SetScript("OnClick", function(self)
        if onChange ~= nil then
            onChange(not self.on)
        end
    end)
    switch:SetOn(false)
    return switch
end

-- Scrolling -----------------------------------------------------------------

-- A list that scrolls with the mouse wheel, `step` pixels a notch: a scroll
-- frame on `parent` and, inside it, the list frame to lay rows out on, top
-- to bottom, `width` wide until the scroll frame is sized. Returns both.
function UI:ScrollList(parent, step, width)
    local area = self:frame("ScrollFrame", parent)
    local list = self:frame("Frame", area)
    list:SetSize(width or 400, 1)
    area:SetScrollChild(list)
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(self, delta)
        local most = self:GetVerticalScrollRange() or 0
        local scroll = (self:GetVerticalScroll() or 0) - delta * step
        self:SetVerticalScroll(math.max(0, math.min(most, scroll)))
    end)
    area:SetScript("OnSizeChanged", function(_, areaWidth)
        if type(areaWidth) == "number" and areaWidth > 0 then
            list:SetWidth(areaWidth)
        end
    end)
    return area, list
end

-- Text entry ----------------------------------------------------------------

-- A text box in a rounded field. Shared by SearchBox and TextInput.
function UI:field(parent, width, onChange)
    local field = self:Panel(parent, { radius = Theme.RADIUS.button, fill = "surface" })
    field:SetSize(width, Widgets.INPUT_HEIGHT)
    local box = self:frame("EditBox", field)
    box:SetPoint("TOPLEFT", field, "TOPLEFT", Theme.SPACING.s, -2)
    box:SetPoint("BOTTOMRIGHT", field, "BOTTOMRIGHT", -Theme.SPACING.s, 2)
    box:SetAutoFocus(false)
    Theme.Font(box, "regular", "body", "text")
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEditFocusGained", function()
        field:SetBorder("green")
    end)
    box:SetScript("OnEditFocusLost", function()
        field:SetBorder("border")
    end)
    field.box = box
    function field.GetValue()
        return box:GetText() or ""
    end
    function field.SetValue(_, text)
        box:SetText(text or "")
    end
    box:SetScript("OnTextChanged", function(self, userInput)
        if field.onText ~= nil then
            field.onText(self:GetText() or "")
        end
        if userInput and onChange ~= nil then
            onChange(self:GetText() or "")
        end
    end)
    return field
end

-- A search box: a text field with grey `placeholder` text while it's empty.
-- onChange(text) runs as the player types.
function UI:SearchBox(parent, width, placeholder, onChange)
    local field = self:field(parent, width, onChange)
    field.placeholder = self:Text(field, placeholder, "regular", "body", "label")
    field.placeholder:SetPoint("LEFT", field, "LEFT", Theme.SPACING.s, 0)
    field.onText = function(text)
        if text == "" then
            field.placeholder:Show()
        else
            field.placeholder:Hide()
        end
    end
    return field
end

-- The number of characters in `text`, counting each UTF-8 character once.
function Widgets.Length(text)
    local _, count = string.gsub(text or "", "[^\128-\191]", "")
    return count
end

-- The first `limit` bytes of `text`, backed off to the start of a whole
-- UTF-8 character so a letter like é is never cut in half.
function Widgets.CutBytes(text, limit)
    if #text <= limit then
        return text
    end
    local length = limit
    -- Bytes 0x80-0xBF continue a character started earlier.
    while length > 0 do
        local nextByte = string.byte(text, length + 1)
        if nextByte < 0x80 or nextByte >= 0xC0 then
            break
        end
        length = length - 1
    end
    return string.sub(text, 1, length)
end

-- How many lines a multiline input shows for text `stringHeight` tall, at
-- `lineHeight` a line: at least one, at most `maxLines`.
function Widgets.LinesFor(stringHeight, lineHeight, maxLines)
    if type(stringHeight) ~= "number" or type(lineHeight) ~= "number" or lineHeight <= 0 then
        return 1
    end
    return math.max(1, math.min(maxLines, math.ceil(stringHeight / lineHeight - 0.01)))
end

-- A text input holding at most `maxLetters` characters, with an "n/max"
-- counter on its right. onChange(text) runs as the player types.
--
-- options (optional), for a multiline input:
--   multiline  true: the text wraps, and the field grows from one line to
--              `maxLines` (default 4) as it's typed, calling onResize(height)
--   maxBytes   the most bytes it holds, cut at a whole character (a chat
--              message's limit counts bytes, so é takes two)
--   onEnter    function(): Enter (it never adds a line break)
--   onEscape   function(): Escape
-- Line breaks, typed or pasted, fold into spaces.
function UI:TextInput(parent, width, maxLetters, onChange, options)
    options = options or {}
    local field = self:field(parent, width, onChange)
    local box = field.box
    box:SetMaxLetters(maxLetters)
    field.counter = self:Text(field, "", "regular", "small", "label")
    if not options.multiline then
        box:SetPoint("BOTTOMRIGHT", field, "BOTTOMRIGHT", -48, 2)
        field.counter:SetPoint("RIGHT", field, "RIGHT", -Theme.SPACING.s, 0)
        field.onText = function(text)
            field.counter:SetText(Widgets.Length(text) .. "/" .. maxLetters)
        end
        field.onText("")
        return field
    end

    local maxLines = options.maxLines or 4
    local lineHeight = Theme.FONT_SIZE.body + 4
    field.lines = 1
    box:SetMultiLine(true)
    if options.maxBytes ~= nil then
        -- The game's cap counts the terminating zero.
        box:SetMaxBytes(options.maxBytes + 1)
    end
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", field, "TOPLEFT", Theme.SPACING.s, -5)
    box:SetPoint("BOTTOMRIGHT", field, "BOTTOMRIGHT", -56, 5)
    field.counter:SetPoint("BOTTOMRIGHT", field, "BOTTOMRIGHT", -Theme.SPACING.s, 6)
    -- Measures the text at the box's width, to know how many lines it takes.
    field.measure = self:Text(field, "", "regular", "body", "text")
    field.measure:SetWordWrap(true)
    field.measure:Hide()
    local function resize(text)
        local boxWidth = box:GetWidth()
        if type(boxWidth) == "number" and boxWidth > 0 then
            field.measure:SetWidth(boxWidth)
        end
        field.measure:SetText(text)
        local lines = Widgets.LinesFor(field.measure:GetStringHeight(), lineHeight, maxLines)
        local height = lines * lineHeight + 10
        field:SetHeight(math.max(Widgets.INPUT_HEIGHT, height))
        if lines ~= field.lines then
            field.lines = lines
            if options.onResize ~= nil then
                options.onResize(height)
            end
        end
    end
    box:SetScript("OnTextChanged", function(self, userInput)
        local text = self:GetText() or ""
        local tidied = string.gsub(text, "[\r\n]+", " ")
        if options.maxBytes ~= nil then
            tidied = Widgets.CutBytes(tidied, options.maxBytes)
        end
        if tidied ~= text then
            -- The game runs this again for the new text, not as typing.
            self:SetText(tidied)
            text = tidied
        end
        field.counter:SetText(Widgets.Length(text) .. "/" .. maxLetters)
        resize(text)
        if userInput and onChange ~= nil then
            onChange(text)
        end
    end)
    box:SetScript("OnEnterPressed", function()
        if options.onEnter ~= nil then
            options.onEnter()
        end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        if options.onEscape ~= nil then
            options.onEscape()
        end
    end)
    field.counter:SetText("0/" .. maxLetters)
    return field
end

-- Signals -------------------------------------------------------------------

-- A gold count for a corner, hidden at zero. SetCount(n).
function UI:CountBadge(parent)
    local badge = self:frame("Frame", parent)
    badge:SetSize(18, 14)
    badge.text = self:Text(badge, "", "semibold", "small", "gold")
    badge.text:SetPoint("CENTER", badge, "CENTER", 0, 0)
    function badge.SetCount(_, count)
        badge.count = type(count) == "number" and count or 0
        badge.text:SetText(tostring(badge.count))
        if badge.count > 0 then
            badge:Show()
        else
            badge:Hide()
        end
    end
    badge:SetCount(0)
    return badge
end

-- A soft glow around `parent`, hidden until SetGlow(color) (a COLORS name:
-- "gold" or "orange"); SetGlow(nil) hides it. Pulse() flashes it once,
-- where the client can animate.
function UI:Glow(parent, spread)
    spread = spread or 10
    local glow = parent:CreateTexture(nil, "BACKGROUND", nil, -8)
    glow:SetTexture(Theme.TEXTURES.glow)
    glow:SetBlendMode("ADD")
    glow:SetPoint("TOPLEFT", parent, "TOPLEFT", -spread, spread)
    glow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", spread, -spread)
    glow:Hide()
    local pulse
    if type(glow.CreateAnimationGroup) == "function" then
        local ok, group = pcall(glow.CreateAnimationGroup, glow)
        if ok and type(group) == "table" and type(group.CreateAnimation) == "function" then
            -- One pulse: dim, then back to full.
            local dim = group:CreateAnimation("Alpha")
            local back = group:CreateAnimation("Alpha")
            if type(dim) == "table" and type(back) == "table" then
                dim:SetFromAlpha(1)
                dim:SetToAlpha(0.3)
                dim:SetDuration(0.35)
                dim:SetOrder(1)
                back:SetFromAlpha(0.3)
                back:SetToAlpha(1)
                back:SetDuration(0.35)
                back:SetOrder(2)
                pulse = group
            end
        end
    end
    local holder = { texture = glow }
    function holder.SetGlow(_, color)
        holder.color = color
        if color == nil then
            glow:Hide()
            if pulse ~= nil then
                pulse:Stop()
            end
            return
        end
        glow:SetVertexColor(Theme.Color(color))
        glow:Show()
    end
    function holder.Pulse()
        if pulse ~= nil and holder.color ~= nil then
            pulse:Stop()
            pulse:Play()
        end
    end
    return holder
end

-- A role tile: a rounded square in the role's color ("tank", "healer",
-- "dps", or "any" for a person of any role), grey once SetFilled(true). It
-- shows the role's name; ShowIcon() swaps that for the role's icon, for a
-- tile too small for the name. "any" always shows its person.
function UI:RoleTile(parent, role, width, height)
    local tile = self:Panel(parent, { radius = Theme.RADIUS.small, fill = role == "any" and "green" or role,
        border = false })
    tile:SetSize(width, height or width)
    tile.role = role
    tile.label = self:Text(tile, Widgets.ROLE_LABELS[role] or "", "semibold", "small", "text")
    tile.label:SetPoint("CENTER", tile, "CENTER", 0, 0)
    -- A square in the middle, so the icon keeps its shape on a wide tile.
    local side = math.min(width, height or width)
    local size = side - 2 * math.max(math.floor(side * 0.15), 1)
    tile.icon = tile:CreateTexture(nil, "ARTWORK")
    tile.icon:SetTexture(Theme.TEXTURES[Widgets.ROLE_ICONS[role]])
    tile.icon:SetSize(size, size)
    tile.icon:SetPoint("CENTER", tile, "CENTER", 0, 0)
    if role ~= "any" then
        tile.icon:Hide()
    end
    function tile.ShowIcon()
        tile.label:SetText("")
        tile.icon:Show()
    end
    function tile.SetFilled(_, filled)
        tile.filled = filled == true
        if tile.filled then
            tile:SetFill("filled")
            tile.label:SetTextColor(Theme.Color("muted"))
        else
            tile:SetFill(role == "any" and "green" or role)
            tile.label:SetTextColor(Theme.Color("text"))
        end
        tile.icon:SetVertexColor(Theme.Color(tile.filled and "muted" or "text"))
    end
    return tile
end

-- A dungeon party's five role tiles in a row, with their icons: Tank,
-- Healer and three DPS, `size` square and 4 apart. Placed by the first.
function UI:RoleRow(parent, size)
    local tiles = {}
    local roles = { "tank", "healer", "dps", "dps", "dps" }
    local index
    for index = 1, #roles do
        tiles[index] = self:RoleTile(parent, roles[index], size, size)
        tiles[index]:ShowIcon()
        if index > 1 then
            tiles[index]:SetPoint("LEFT", tiles[index - 1], "RIGHT", 4, 0)
        end
    end
    return tiles
end

-- Shows role `tiles` for a dungeon party's `members` (each { role }): a
-- member's role is filled (grey), the rest open, except roles missing from
-- `openRoles` (what the listing asks for, when given), which aren't.
function Widgets.ShowRoles(tiles, members, openRoles)
    local taken = {}
    local index
    for index = 1, #(members or {}) do
        local role = members[index].role
        if role ~= nil then
            taken[role] = (taken[role] or 0) + 1
        end
    end
    local wanted
    if openRoles ~= nil then
        wanted = {}
        for index = 1, #openRoles do
            wanted[openRoles[index]] = true
        end
    end
    local seen = {}
    for index = 1, #tiles do
        local role = tiles[index].role
        seen[role] = (seen[role] or 0) + 1
        tiles[index]:SetFilled(seen[role] <= (taken[role] or 0) or (wanted ~= nil and not wanted[role]))
        tiles[index]:Show()
    end
end

-- A small menu of text items. Open(anchor, items, title?) shows it under
-- `anchor` with one row per item ({ label, onClick, disabled? }); picking
-- one closes it and runs its onClick, and a click anywhere outside it
-- closes it. A disabled item is greyed out and does nothing.
-- Close() hides it.
function UI:ContextMenu(parent)
    local menu = self:Panel(parent, { radius = Theme.RADIUS.button, fill = "raised" })
    menu:SetFrameStrata("DIALOG")
    menu:SetWidth(180)
    menu:Hide()
    menu.rows = {}
    -- An optional title over the items, with a line under it.
    menu.title = self:Text(menu, "", "semibold", "body", "text")
    menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 4 + Theme.SPACING.s, -4)
    menu.title:SetHeight(22)
    menu.divider = menu:CreateTexture(nil, "ARTWORK")
    menu.divider:SetTexture(Theme.TEXTURES.white)
    menu.divider:SetVertexColor(Theme.Color("border"))
    menu.divider:SetHeight(1)
    menu.divider:SetPoint("TOPLEFT", menu, "TOPLEFT", Theme.SPACING.s, -4 - 22 - 2)
    menu.divider:SetPoint("RIGHT", menu, "RIGHT", -Theme.SPACING.s, 0)
    -- A click anywhere outside the open menu closes it: a catcher covering
    -- the screen sits just under it.
    local host = self.environment.UIParent or parent
    local catcher = self:frame("Button", host)
    catcher:SetAllPoints(host)
    catcher:SetFrameStrata("DIALOG")
    catcher:RegisterForClicks("AnyDown")
    catcher:SetScript("OnClick", function()
        menu:Close()
    end)
    catcher:Hide()
    menu.catcher = catcher
    -- However the menu goes (closed, or hidden with its window), its
    -- catcher goes with it, so it never eats the next click.
    menu:SetScript("OnHide", function()
        menu.open = false
        catcher:Hide()
    end)
    local ui = self
    -- Opens under `anchor` with `items`; `title` (text, may carry color
    -- codes) heads them when given.
    function menu.Open(_, anchor, items, title)
        local hasTitle = title ~= nil and title ~= ""
        menu.titleText = hasTitle and title or nil
        menu.title:SetText(hasTitle and title or "")
        if hasTitle then
            menu.title:Show()
            menu.divider:Show()
        else
            menu.title:Hide()
            menu.divider:Hide()
        end
        local first = hasTitle and (22 + 5) or 0
        local index
        for index = 1, math.max(#items, #menu.rows) do
            local item = items[index]
            local row = menu.rows[index]
            if item ~= nil and row == nil then
                row = ui:frame("Button", menu)
                row:SetHeight(22)
                round(row, Theme.RADIUS.small, "raised", false)
                row.label = ui:Text(row, "", "regular", "body", "text")
                row.label:SetPoint("LEFT", row, "LEFT", Theme.SPACING.s, 0)
                row:SetScript("OnEnter", function(self)
                    if not self.disabled then
                        self:SetFill("hover")
                    end
                end)
                row:SetScript("OnLeave", function(self)
                    self:SetFill("raised")
                end)
                row:SetScript("OnClick", function(self)
                    if self.disabled then
                        return
                    end
                    menu:Close()
                    if self.onClick ~= nil then
                        self.onClick()
                    end
                end)
                menu.rows[index] = row
            end
            if row ~= nil then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - first - (index - 1) * 22)
                row:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
                if item ~= nil then
                    row.label:SetText(item.label)
                    row.onClick = item.onClick
                    row.disabled = item.disabled == true
                    row.label:SetTextColor(Theme.Color(row.disabled and "disabled" or "text"))
                    row:Show()
                else
                    row:Hide()
                end
            end
        end
        menu.items = items
        menu.anchor = anchor
        menu:SetHeight(8 + first + #items * 22)
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        menu.open = true
        local level = type(menu.GetFrameLevel) == "function" and menu:GetFrameLevel() or nil
        catcher:SetFrameLevel(math.max((tonumber(level) or 2) - 1, 1))
        catcher:Show()
        menu:Show()
    end
    function menu.Close()
        menu.open = false
        catcher:Hide()
        menu:Hide()
    end
    function menu.IsOpen()
        return menu.open == true
    end
    return menu
end
