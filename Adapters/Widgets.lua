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
    ROLE_LABELS = { tank = "Tank", healer = "Healer", dps = "DPS" },
}
addon.Widgets = Widgets

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
    if items[1] ~= nil then
        strip:Select(items[1].id)
    end
    return strip
end

-- A row of text tabs with a green underline under the selected one. Like
-- Segmented: `items` { id, label }, onSelect(id), Select(id), Selected(),
-- and SetLabel(id, text) for a tab whose label carries a count.
function UI:Tabs(parent, items, onSelect)
    local row = self:frame("Frame", parent)
    row:SetHeight(28)
    row.tabs = {}
    local ui = self
    local x = 0
    local index
    for index = 1, #items do
        local item = items[index]
        local tab = ui:frame("Button", row)
        tab.id = item.id
        tab.label = ui:Text(tab, item.label, "semibold", "body", "muted")
        tab.label:SetPoint("LEFT", tab, "LEFT", 0, 2)
        local width = (tab.label:GetStringWidth() or 0) + 4
        width = math.max(width, 48)
        tab:SetSize(width, 28)
        tab:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 0)
        tab.underline = tab:CreateTexture(nil, "ARTWORK")
        tab.underline:SetTexture(Theme.TEXTURES.white)
        tab.underline:SetVertexColor(Theme.Color("green"))
        tab.underline:SetHeight(2)
        tab.underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
        tab.underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
        tab:SetScript("OnClick", function(self)
            row:Select(self.id)
            if onSelect ~= nil then
                onSelect(self.id)
            end
        end)
        row.tabs[index] = tab
        x = x + width + Theme.SPACING.l
    end
    function row.Select(_, id)
        row.selected = id
        local position
        for position = 1, #row.tabs do
            local tab = row.tabs[position]
            local on = tab.id == id
            tab.label:SetTextColor(Theme.Color(on and "text" or "muted"))
            if on then
                tab.underline:Show()
            else
                tab.underline:Hide()
            end
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

-- A text input holding at most `maxLetters` characters, with an "n/max"
-- counter on its right. onChange(text) runs as the player types.
function UI:TextInput(parent, width, maxLetters, onChange)
    local field = self:field(parent, width, onChange)
    field.box:SetMaxLetters(maxLetters)
    field.box:SetPoint("BOTTOMRIGHT", field, "BOTTOMRIGHT", -48, 2)
    field.counter = self:Text(field, "", "regular", "small", "label")
    field.counter:SetPoint("RIGHT", field, "RIGHT", -Theme.SPACING.s, 0)
    field.onText = function(text)
        field.counter:SetText(Widgets.Length(text) .. "/" .. maxLetters)
    end
    field.onText("")
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
-- "dps", or "any" for a person of any role), grey once SetFilled(true).
function UI:RoleTile(parent, role, width, height)
    local tile = self:Panel(parent, { radius = Theme.RADIUS.small, fill = role == "any" and "green" or role,
        border = false })
    tile:SetSize(width, height or width)
    tile.role = role
    tile.label = self:Text(tile, Widgets.ROLE_LABELS[role] or "", "semibold", "small", "text")
    tile.label:SetPoint("CENTER", tile, "CENTER", 0, 0)
    -- Any role: a person instead of a role's name.
    if role == "any" then
        local inset = math.floor(math.min(width, height or width) * 0.2)
        tile.icon = tile:CreateTexture(nil, "ARTWORK")
        tile.icon:SetTexture(Theme.TEXTURES.person)
        tile.icon:SetPoint("TOPLEFT", tile, "TOPLEFT", inset, -inset)
        tile.icon:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -inset, inset)
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
        if role == "any" then
            tile.icon:SetVertexColor(Theme.Color(tile.filled and "muted" or "text"))
        end
    end
    return tile
end

-- A small menu of text items. Open(anchor, items) shows it under `anchor`
-- with one row per item ({ label, onClick }); picking one closes it and
-- runs its onClick. Close() hides it.
function UI:ContextMenu(parent)
    local menu = self:Panel(parent, { radius = Theme.RADIUS.button, fill = "raised" })
    menu:SetFrameStrata("DIALOG")
    menu:SetWidth(180)
    menu:Hide()
    menu.rows = {}
    local ui = self
    function menu.Open(_, anchor, items)
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
                    self:SetFill("hover")
                end)
                row:SetScript("OnLeave", function(self)
                    self:SetFill("raised")
                end)
                row:SetScript("OnClick", function(self)
                    menu:Close()
                    if self.onClick ~= nil then
                        self.onClick()
                    end
                end)
                row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - (index - 1) * 22)
                row:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
                menu.rows[index] = row
            end
            if row ~= nil then
                if item ~= nil then
                    row.label:SetText(item.label)
                    row.onClick = item.onClick
                    row:Show()
                else
                    row:Hide()
                end
            end
        end
        menu.items = items
        menu:SetHeight(8 + #items * 22)
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        menu.open = true
        menu:Show()
    end
    function menu.Close()
        menu.open = false
        menu:Hide()
    end
    function menu.IsOpen()
        return menu.open == true
    end
    return menu
end
