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
    -- An open context menu's frame level (its catcher just under it).
    MENU_LEVEL = 100,
    TOGGLE_WIDTH = 34,
    TOGGLE_HEIGHT = 18,
    -- A check box, and the game's check mark drawn in it.
    CHECK_SIZE = 18,
    CHECK_TEXTURE = "Interface\\Buttons\\UI-CheckBox-Check",
    CHIP_CLEAR_TEXTURE = "Interface\\Buttons\\UI-StopButton",
    CHIP_CLEAR_SIZE = 18,
    INPUT_HEIGHT = 26,
    -- A pooled list's scroll bar, and its thumb at its shortest.
    SCROLLBAR_WIDTH = 6,
    SCROLLBAR_MIN_THUMB = 24,
    -- A text prompt, and its multiline field.
    PROMPT_WIDTH = 360,
    PROMPT_MULTILINE_HEIGHT = 96,
    DOT_SIZE = 6,
    INFO_SIZE = 16,
    -- A stepper's buttons and number, and how holding a button repeats:
    -- the wait before the first repeat, then between repeats, in seconds.
    STEPPER_BUTTON = 24,
    STEPPER_FIELD = 44,
    HOLD_DELAY = 0.4,
    HOLD_REPEAT = 0.08,
    SLIDER_HEIGHT = 16,
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
    danger = { fill = "red", hover = "redHover", text = "text", border = false },
}

-- A rounded text button. `kind`: "primary" (green), "secondary" or "danger"
-- (red); `onClick` runs on a left click while it's enabled. SetLabel
-- renames it and SetActive enables or greys it out.
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

-- A small text-only button, `label` in grey that turns white with a
-- rounded backdrop on mouseover, like IconButton, `width` wide.
function UI:TextButton(parent, label, width, onClick)
    local button = self:frame("Button", parent)
    button:SetSize(width, Widgets.BUTTON_HEIGHT - 4)
    round(button, Theme.RADIUS.small, "hover", false)
    button.fillShape:SetShown(false)
    button.edgeShape:SetShown(false)
    button.label = self:Text(button, label, "semibold", "small", "muted")
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    button:SetScript("OnEnter", function(self)
        self.hovered = true
        self.label:SetTextColor(Theme.Color("text"))
        self.fillShape:SetShown(true)
    end)
    button:SetScript("OnLeave", function(self)
        self.hovered = false
        self.label:SetTextColor(Theme.Color("muted"))
        self.fillShape:SetShown(false)
    end)
    button:SetScript("OnClick", function(self)
        if onClick ~= nil then
            onClick(self)
        end
    end)
    return button
end

-- A rounded chip naming an active filter, with an X that clears it:
-- `onClear` runs on a click of the X. SetLabel names the filter and sizes
-- the chip to fit.
function UI:Chip(parent, onClear)
    local chip = self:frame("Frame", parent)
    chip:SetHeight(Widgets.BUTTON_HEIGHT - 4)
    round(chip, Theme.RADIUS.button, "raised", "border")
    chip.label = self:Text(chip, "", "semibold", "small", "text")
    chip.label:SetPoint("LEFT", chip, "LEFT", Theme.SPACING.s, 0)
    chip.clear = self:IconButton(chip, Widgets.CHIP_CLEAR_TEXTURE, Widgets.CHIP_CLEAR_SIZE, function()
        if onClear ~= nil then
            onClear()
        end
    end)
    chip.clear:SetPoint("RIGHT", chip, "RIGHT", -Theme.SPACING.xs, 0)
    function chip.SetLabel(_, text)
        chip.label:SetText(text or "")
        chip:SetWidth((chip.label:GetStringWidth() or 0) + Widgets.CHIP_CLEAR_SIZE + 2 * Theme.SPACING.s
            + Theme.SPACING.xs)
    end
    return chip
end

-- A one-line tooltip on `frame` (a button, say) while it's hovered, kept
-- as `frame.hint` too. Hooked, so the frame's own mouseover still runs.
function UI:Hint(frame, text)
    local environment = self.environment
    frame.hint = text
    frame:HookScript("OnEnter", function(self)
        local tooltip = environment.GameTooltip
        if type(tooltip) == "table" and type(self.hint) == "string" then
            tooltip:SetOwner(self, "ANCHOR_TOP")
            tooltip:SetText(self.hint, 1, 1, 1, 1, true)
            tooltip:Show()
        end
    end)
    frame:HookScript("OnLeave", function()
        local tooltip = environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:Hide()
        end
    end)
end

-- A small round "i" that shows `text()` (a function, read on each
-- mouseover; nothing shows while it gives nil) in the game's tooltip,
-- headed `title`.
function UI:InfoIcon(parent, title, text)
    local icon = self:frame("Button", parent)
    icon:SetSize(Widgets.INFO_SIZE, Widgets.INFO_SIZE)
    round(icon, Widgets.INFO_SIZE / 2, "hover", false)
    icon.label = self:Text(icon, "i", "semibold", "small", "muted")
    icon.label:SetPoint("CENTER", icon, "CENTER", 0, 0)
    local environment = self.environment
    icon:SetScript("OnEnter", function(self)
        self.label:SetTextColor(Theme.Color("text"))
        local tooltip = environment.GameTooltip
        local ok, body = pcall(text)
        if type(tooltip) == "table" and ok and type(body) == "string" then
            tooltip:SetOwner(self, "ANCHOR_RIGHT")
            tooltip:SetText(title, 1, 1, 1)
            tooltip:AddLine(body, nil, nil, nil, true)
            tooltip:Show()
        end
    end)
    icon:SetScript("OnLeave", function(self)
        self.label:SetTextColor(Theme.Color("muted"))
        local tooltip = environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:Hide()
        end
    end)
    return icon
end

-- Numbers -------------------------------------------------------------------

local function clampWhole(value, min, max)
    return math.max(min, math.min(max, math.floor(value + 0.5)))
end

-- The value one step from `value` in `direction` (1 up, -1 down): the next
-- multiple of `step` that way, so 1 steps up to 5, then 10, in 5s, kept
-- from `min` to `max`.
function Widgets.StepValue(value, direction, step, min, max)
    step = step or 1
    local stepped
    if direction > 0 then
        stepped = (math.floor(value / step) + 1) * step
    else
        stepped = (math.ceil(value / step) - 1) * step
    end
    return clampWhole(stepped, min, max)
end

-- A number typed as `text`, rounded and kept from `min` to `max`, or nil
-- when it isn't a number.
function Widgets.TypedValue(text, min, max)
    local value = tonumber(string.match(text or "", "^%s*(.-)%s*$"))
    if value == nil or value ~= value then
        return nil
    end
    return clampWhole(value, min, max)
end

-- A − value + stepper. options: min, max, step (default 1), onChange(value)
-- when the player changes it. − and + step (StepValue), and holding one
-- repeats; the number can be clicked and typed over, kept in range on
-- Enter or leaving it. SetValue(value) shows a value without onChange;
-- GetValue() is what it shows.
function UI:Stepper(parent, options)
    local ui = self
    local stepper = self:frame("Frame", parent)
    local size = Widgets.STEPPER_BUTTON
    stepper:SetSize(2 * size + Widgets.STEPPER_FIELD + 2 * Theme.SPACING.xs, size)
    stepper.value = options.min
    local function change(value)
        if value ~= stepper.value then
            stepper:SetValue(value)
            if options.onChange ~= nil then
                options.onChange(value)
            end
        end
    end
    function stepper.Step(_, direction)
        change(Widgets.StepValue(stepper.value, direction, options.step, options.min, options.max))
    end
    local held
    local function stop()
        held = nil
        stepper:SetScript("OnUpdate", nil)
    end
    local function button(text, direction)
        local result = ui:frame("Button", stepper)
        result:SetSize(size, size)
        round(result, Theme.RADIUS.small, "raised", "border")
        result.label = ui:Text(result, text, "semibold", "body", "text")
        result.label:SetPoint("CENTER", result, "CENTER", 0, 0)
        result:SetScript("OnMouseDown", function()
            stepper:Step(direction)
            held = { direction = direction, wait = Widgets.HOLD_DELAY }
            stepper:SetScript("OnUpdate", function(_, elapsed)
                if held == nil then
                    return
                end
                held.wait = held.wait - (elapsed or 0)
                while held ~= nil and held.wait <= 0 do
                    stepper:Step(held.direction)
                    -- Stepping can hide the stepper, which ends the hold.
                    if held == nil then
                        break
                    end
                    held.wait = held.wait + Widgets.HOLD_REPEAT
                end
            end)
        end)
        result:SetScript("OnMouseUp", stop)
        result:SetScript("OnHide", stop)
        result:SetScript("OnEnter", function(self)
            self:SetFill("hover")
        end)
        result:SetScript("OnLeave", function(self)
            self:SetFill("raised")
            stop()
        end)
        return result
    end
    stepper.minus = button("−", -1)
    stepper.minus:SetPoint("LEFT", stepper, "LEFT", 0, 0)
    stepper.field = self:field(stepper, Widgets.STEPPER_FIELD)
    stepper.field:SetPoint("LEFT", stepper.minus, "RIGHT", Theme.SPACING.xs, 0)
    stepper.field:SetHeight(size)
    local box = stepper.field.box
    box:SetJustifyH("CENTER")
    local function commit()
        local typed = Widgets.TypedValue(box:GetText(), options.min, options.max)
        if typed == nil then
            box:SetText(tostring(stepper.value))
        else
            -- Shown kept in range even when it's the same value.
            box:SetText(tostring(typed))
            change(typed)
        end
    end
    box:SetScript("OnEnterPressed", function(self)
        commit()
        self:ClearFocus()
    end)
    box:HookScript("OnEditFocusLost", commit)
    stepper.plus = button("+", 1)
    stepper.plus:SetPoint("LEFT", stepper.field, "RIGHT", Theme.SPACING.xs, 0)
    stepper:SetScript("OnHide", stop)
    -- A number being typed stays until the player finishes it.
    function stepper.SetValue(_, value)
        stepper.value = value
        local ok, focused = pcall(box.HasFocus, box)
        if not (ok and focused == true) then
            box:SetText(tostring(value))
        end
    end
    function stepper.GetValue()
        return stepper.value
    end
    stepper:SetValue(options.min)
    return stepper
end

-- A horizontal slider `width` wide from options.min to options.max in
-- whole steps, its value shown beside it through options.format(value)
-- (the number itself without one). onChange(value) runs when the player
-- drags it. SetValue(value) moves it without onChange.
function UI:Slider(parent, width, options)
    local holder = self:frame("Frame", parent)
    holder:SetSize(width, Widgets.SLIDER_HEIGHT)
    local track = self:Panel(holder, { radius = Theme.RADIUS.small, fill = "surface" })
    track:SetPoint("LEFT", holder, "LEFT", 0, 0)
    track:SetSize(width - 70, 6)
    local slider = self:frame("Slider", holder)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("LEFT", holder, "LEFT", 0, 0)
    slider:SetSize(width - 70, Widgets.SLIDER_HEIGHT)
    slider:SetMinMaxValues(options.min, options.max)
    slider:SetValueStep(1)
    if type(slider.SetObeyStepOnDrag) == "function" then
        slider:SetObeyStepOnDrag(true)
    end
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(Theme.TEXTURES.rounded)
    thumb:SetVertexColor(Theme.Color("green"))
    thumb:SetSize(Widgets.SLIDER_HEIGHT, Widgets.SLIDER_HEIGHT)
    slider:SetThumbTexture(thumb)
    holder.slider = slider
    holder.text = self:Text(holder, "", "semibold", "body", "text")
    holder.text:SetPoint("LEFT", slider, "RIGHT", Theme.SPACING.m, 0)
    local function show(value)
        holder.value = value
        holder.text:SetText(options.format and options.format(value) or tostring(value))
    end
    function holder.Format(_, value)
        return options.format and options.format(value) or tostring(value)
    end
    slider:SetScript("OnValueChanged", function(_, value, userInput)
        if type(value) ~= "number" then
            return
        end
        value = clampWhole(value, options.min, options.max)
        if holder.setting then
            return
        end
        if value ~= holder.value then
            show(value)
            if userInput ~= false and options.onChange ~= nil then
                options.onChange(value)
            end
        end
    end)
    function holder.SetValue(_, value)
        holder.setting = true
        slider:SetValue(value)
        holder.setting = false
        show(value)
    end
    function holder.GetValue()
        return holder.value
    end
    function holder.SetEnabled(_, enabled)
        if enabled then
            slider:Enable()
        else
            slider:Disable()
        end
    end
    show(options.min)
    return holder
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

-- A small square check box, green with a check mark while checked.
-- `onChange(wanted)` runs on a click with the state asked for; the owner
-- calls SetChecked once it holds.
function UI:CheckBox(parent, onChange)
    local box = self:frame("Button", parent)
    box:SetSize(Widgets.CHECK_SIZE, Widgets.CHECK_SIZE)
    round(box, Theme.RADIUS.small, "raised", "border")
    box.mark = box:CreateTexture(nil, "ARTWORK")
    box.mark:SetTexture(Widgets.CHECK_TEXTURE)
    box.mark:SetPoint("TOPLEFT", box, "TOPLEFT", -2, 2)
    box.mark:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 2, -2)
    box.mark:SetVertexColor(Theme.Color("text"))
    function box.SetChecked(_, checked)
        box.checked = checked == true
        box.mark:SetShown(box.checked)
        box:SetFill(box.checked and "green" or "raised")
        box:SetBorder(not box.checked and "border" or nil)
    end
    function box.IsChecked()
        return box.checked == true
    end
    box:SetScript("OnClick", function(self)
        if onChange ~= nil then
            onChange(not self.checked)
        end
    end)
    box:SetChecked(false)
    return box
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

-- A scroll list for long lists (the roster's hundreds of players): it
-- builds only enough row frames to fill its height, never one per row,
-- places them where ListWindow says, and fills them again as it scrolls.
-- While the rows don't all fit, a slim scroll bar runs down its right edge:
-- drag its thumb, or click the track, to jump through the list.
-- options:
--   height    each row's height: a number, or function(row) -> height
--   gap       space left under each row's frame, counted in its height
--             (default 0)
--   build     function(kind, parent) -> a new frame for a row of `kind`
--             (the row's `kind` field, "row" without one)
--   fill      function(frame, row, index): shows `row` on `frame`
--   step      pixels a mouse wheel notch scrolls (default 48)
--   viewport  the height to lay out for while the frame can't say
-- SetRows(rows, keep) shows `rows`, keeping row index `keep` (optional) in
-- view; ScrollTo(offset) scrolls; Offset() and Rows() read them back, and
-- Built(kind) counts the frames made for `kind`. `list.bar` is the scroll
-- bar.
function UI:PooledList(parent, options)
    local list = self:frame("Frame", parent)
    list:SetClipsChildren(true)
    list:EnableMouseWheel(true)
    local state = { rows = {}, offset = 0, pools = {} }
    local bar = self:frame("Slider", list)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(Widgets.SCROLLBAR_WIDTH)
    bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValueStep(1)
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetTexture(Theme.TEXTURES.white)
    bar.track:SetVertexColor(Theme.Color("raised"))
    bar.track:SetAllPoints(bar)
    bar.thumb = bar:CreateTexture(nil, "ARTWORK")
    bar.thumb:SetTexture(Theme.TEXTURES.white)
    bar.thumb:SetVertexColor(Theme.Color("muted"))
    bar.thumb:SetSize(Widgets.SCROLLBAR_WIDTH, Widgets.SCROLLBAR_MIN_THUMB)
    bar:SetThumbTexture(bar.thumb)
    bar:SetScript("OnEnter", function(self)
        self.thumb:SetVertexColor(Theme.Color("text"))
    end)
    bar:SetScript("OnLeave", function(self)
        self.thumb:SetVertexColor(Theme.Color("muted"))
    end)
    bar:Hide()
    list.bar = bar
    local function rowHeight(row)
        if type(options.height) == "function" then
            return options.height(row)
        end
        return options.height
    end
    local function height()
        if type(options.height) ~= "function" then
            return options.height
        end
        return function(index)
            return rowHeight(state.rows[index])
        end
    end
    local function viewport()
        local ok, shown = pcall(list.GetHeight, list)
        if ok and type(shown) == "number" and shown > 0 then
            return shown
        end
        return options.viewport or 0
    end
    local function take(kind)
        local pool = state.pools[kind]
        if pool == nil then
            pool = { frames = {}, used = 0 }
            state.pools[kind] = pool
        end
        pool.used = pool.used + 1
        local frame = pool.frames[pool.used]
        if frame == nil then
            frame = options.build(kind, list)
            pool.frames[pool.used] = frame
        end
        return frame
    end
    function list.Layout()
        local shownHeight = viewport()
        local window = addon.ListWindow.Visible(#state.rows, height(), shownHeight, state.offset)
        state.offset = window.offset
        -- The bar, while there's more than fits; the rows stop short of it.
        local most = math.max(0, window.total - shownHeight)
        local inset = 0
        if most > 0 and shownHeight > 0 then
            inset = Widgets.SCROLLBAR_WIDTH + Theme.SPACING.xs
            -- Setting the bar runs its OnValueChanged, which mustn't scroll.
            state.syncing = true
            bar:SetMinMaxValues(0, most)
            bar:SetValue(state.offset)
            state.syncing = false
            bar.thumb:SetHeight(math.max(Widgets.SCROLLBAR_MIN_THUMB, shownHeight * shownHeight / window.total))
            bar:Show()
        else
            bar:Hide()
        end
        local kind, pool
        for kind, pool in pairs(state.pools) do
            pool.used = 0
        end
        if window.first ~= nil then
            local index
            for index = window.first, window.last do
                -- A row with no height has no top, and gets no frame.
                local top = window.tops[index]
                if top ~= nil then
                    local row = state.rows[index]
                    local frame = take(row.kind or "row")
                    options.fill(frame, row, index)
                    frame:ClearAllPoints()
                    frame:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top)
                    frame:SetPoint("RIGHT", list, "RIGHT", -inset, 0)
                    frame:SetHeight(rowHeight(row) - (options.gap or 0))
                    frame:Show()
                end
            end
        end
        for kind, pool in pairs(state.pools) do
            local index
            for index = pool.used + 1, #pool.frames do
                pool.frames[index]:Hide()
            end
        end
    end
    function list.SetRows(_, rows, keep)
        state.rows = rows or {}
        if keep ~= nil then
            state.offset = addon.ListWindow.KeepInView(keep, #state.rows, height(), viewport(), state.offset)
        end
        list.Layout()
    end
    function list.ScrollTo(_, offset)
        state.offset = offset or 0
        list.Layout()
    end
    function list.Offset()
        return state.offset
    end
    function list.Rows()
        return state.rows
    end
    function list.Built(_, kind)
        local pool = state.pools[kind or "row"]
        return pool and #pool.frames or 0
    end
    -- The frames showing rows now.
    function list.Shown()
        local shown = {}
        local _, pool
        for _, pool in pairs(state.pools) do
            local index
            for index = 1, pool.used do
                table.insert(shown, pool.frames[index])
            end
        end
        return shown
    end
    list:SetScript("OnMouseWheel", function(_, delta)
        list:ScrollTo(state.offset - delta * (options.step or 48))
    end)
    bar:SetScript("OnValueChanged", function(_, value)
        if not state.syncing and type(value) == "number" then
            list:ScrollTo(value)
        end
    end)
    list:SetScript("OnSizeChanged", function()
        list.Layout()
    end)
    return list
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

-- A small dialog over everything that asks for one piece of text: a title,
-- a field, and Save and Cancel. Open(options) shows it:
--   title      what's asked ("Alias for Toolbox")
--   text       what the field starts with
--   maxLetters the most characters it holds
--   maxBytes   the most bytes, for a multiline field (an accented letter
--              takes two)
--   multiline  true for a taller field that keeps line breaks (a bio)
--   onSave     function(text): Save, or Enter in a one-line field
-- A click outside it, Cancel or Escape closes it without saving. Close(),
-- IsOpen() and Save() (as the button does) are there for its owner.
function UI:TextPrompt(parent)
    local screen = self.environment.UIParent or parent
    local pad = Theme.SPACING.l
    local width = Widgets.PROMPT_WIDTH
    local prompt = self:Panel(screen, { fill = "raised" })
    prompt:SetFrameStrata("FULLSCREEN_DIALOG")
    prompt:SetWidth(width)
    prompt:SetPoint("CENTER", screen, "CENTER", 0, 80)
    prompt:EnableMouse(true)
    prompt:Hide()
    local catcher = self:frame("Button", screen)
    catcher:SetAllPoints(screen)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:RegisterForClicks("AnyDown")
    catcher:SetScript("OnClick", function()
        prompt:Close()
    end)
    catcher:Hide()
    prompt.catcher = catcher
    prompt:SetScript("OnHide", function()
        prompt.open = false
        catcher:Hide()
    end)
    if parent ~= screen and type(parent.HookScript) == "function" then
        parent:HookScript("OnHide", function()
            prompt:Hide()
        end)
    end
    prompt.title = self:Text(prompt, "", "semibold", "title", "text")
    prompt.title:SetPoint("TOPLEFT", prompt, "TOPLEFT", pad, -pad)
    prompt.title:SetPoint("RIGHT", prompt, "RIGHT", -pad, 0)
    prompt.title:SetJustifyH("LEFT")
    prompt.single = self:field(prompt, width - 2 * pad)
    prompt.multi = self:field(prompt, width - 2 * pad)
    prompt.multi:SetHeight(Widgets.PROMPT_MULTILINE_HEIGHT)
    prompt.multi.box:SetMultiLine(true)
    prompt.multi.box:ClearAllPoints()
    prompt.multi.box:SetPoint("TOPLEFT", prompt.multi, "TOPLEFT", Theme.SPACING.s, -5)
    prompt.multi.box:SetPoint("BOTTOMRIGHT", prompt.multi, "BOTTOMRIGHT", -Theme.SPACING.s, 5)
    local _, field
    for _, field in ipairs({ prompt.single, prompt.multi }) do
        field:SetPoint("TOPLEFT", prompt.title, "BOTTOMLEFT", 0, -Theme.SPACING.m)
        field.box:SetScript("OnEscapePressed", function()
            prompt:Close()
        end)
    end
    prompt.single.box:SetScript("OnEnterPressed", function()
        prompt:Save()
    end)
    prompt.save = self:Button(prompt, "Save", "primary", function()
        prompt:Save()
    end)
    prompt.save:SetWidth(90)
    prompt.save:SetPoint("BOTTOMRIGHT", prompt, "BOTTOMRIGHT", -pad, pad)
    prompt.cancel = self:Button(prompt, "Cancel", "secondary", function()
        prompt:Close()
    end)
    prompt.cancel:SetWidth(90)
    prompt.cancel:SetPoint("RIGHT", prompt.save, "LEFT", -Theme.SPACING.s, 0)

    function prompt.Open(_, options)
        prompt.options = options
        prompt.title:SetText(options.title or "")
        local shown = options.multiline and prompt.multi or prompt.single
        local hidden = options.multiline and prompt.single or prompt.multi
        hidden:Hide()
        shown:Show()
        prompt.field = shown
        shown.box:SetMaxLetters(options.maxLetters or 0)
        if options.maxBytes ~= nil then
            -- The game's cap counts the terminating zero.
            shown.box:SetMaxBytes(options.maxBytes + 1)
        end
        shown:SetValue(options.text or "")
        local fieldHeight = options.multiline and Widgets.PROMPT_MULTILINE_HEIGHT or Widgets.INPUT_HEIGHT
        prompt:SetHeight(2 * pad + 22 + Theme.SPACING.m + fieldHeight + Theme.SPACING.l + Widgets.BUTTON_HEIGHT)
        prompt.open = true
        catcher:SetFrameLevel(Widgets.MENU_LEVEL - 1)
        prompt:SetFrameLevel(Widgets.MENU_LEVEL)
        catcher:Show()
        prompt:Show()
        if type(prompt.Raise) == "function" then
            prompt:Raise()
        end
        shown.box:SetFocus()
        if type(shown.box.HighlightText) == "function" then
            shown.box:HighlightText()
        end
    end
    function prompt.Save()
        -- A closed prompt (cancelled, or already saved) saves nothing.
        if not prompt.open then
            return
        end
        local options, field = prompt.options, prompt.field
        prompt:Close()
        if options ~= nil and field ~= nil and options.onSave ~= nil then
            options.onSave(field:GetValue())
        end
    end
    function prompt.Close()
        prompt.open = false
        catcher:Hide()
        prompt:Hide()
    end
    function prompt.IsOpen()
        return prompt.open == true
    end
    return prompt
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
    -- It lives on the screen itself, over everything, rather than inside
    -- `parent`: inside the window it showed but couldn't be clicked in some
    -- places (the listing editor). It closes when `parent` hides.
    local screen = self.environment.UIParent or parent
    local menu = self:Panel(screen, { radius = Theme.RADIUS.button, fill = "raised" })
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
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
    local host = screen
    local catcher = self:frame("Button", host)
    catcher:SetAllPoints(host)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
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
    if parent ~= screen and type(parent.HookScript) == "function" then
        parent:HookScript("OnHide", function()
            menu:Hide()
        end)
    end
    local ui = self
    -- The width it was made, read on first open.
    local baseWidth
    -- Opens under `anchor` with `items`; `title` (text, may carry color
    -- codes) heads them when given. It widens to fit its longest line.
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
        -- As wide as it was made, or wider when a line needs it, so no text
        -- runs past its edge.
        local function number(value)
            return type(value) == "number" and value or nil
        end
        if baseWidth == nil then
            baseWidth = number(menu:GetWidth()) or 180
        end
        local widest = hasTitle and (number(menu.title:GetStringWidth()) or 0) or 0
        for index = 1, #items do
            widest = math.max(widest, number(menu.rows[index].label:GetStringWidth()) or 0)
        end
        menu:SetWidth(math.max(baseWidth, math.ceil(widest) + 2 * (4 + Theme.SPACING.s)))
        menu:SetHeight(8 + first + #items * 22)
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        menu.open = true
        -- The catcher just under the menu, the menu (and its rows) on top.
        catcher:SetFrameLevel(Widgets.MENU_LEVEL - 1)
        menu:SetFrameLevel(Widgets.MENU_LEVEL)
        catcher:Show()
        menu:Show()
        if type(menu.Raise) == "function" then
            menu:Raise()
        end
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
