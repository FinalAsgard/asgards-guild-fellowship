local _, addon = ...

-- The add-on's page in the game's AddOns options (Esc -> Options -> AddOns),
-- drawn from the SettingsModel: a title, then one header per section with
-- its entries below it (a check box, a button, a line of text, or a number
-- with minus and plus buttons). Clients with the newer Settings API get a canvas
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

-- Fills in every widget from the model's current values.
function Panel:Refresh()
    local index
    for index = 1, #self.widgets do
        local widget = self.widgets[index]
        pcall(function()
            if widget.kind == "toggle" then
                widget.frame:SetChecked(self.model:Get(widget.id) == true)
            elseif widget.kind == "number" then
                local value = self.model:Get(widget.id)
                widget.frame:SetText(tostring(value or ""))
                if value ~= nil and value <= widget.entry.min then
                    widget.down:Disable()
                else
                    widget.down:Enable()
                end
                if value ~= nil and value >= widget.entry.max then
                    widget.up:Disable()
                else
                    widget.up:Enable()
                end
            elseif widget.kind == "text" then
                widget.frame:SetText(tostring(self.model:Get(widget.id) or ""))
            end
        end)
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
    table.insert(self.widgets, { kind = "toggle", id = entry.id, frame = check })
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
    table.insert(self.widgets, { kind = "number", id = entry.id, entry = entry, frame = value, down = down, up = up })
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
end

function Panel:addText(frame, entry, y)
    local text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", SettingsPanel.LEFT + SettingsPanel.INDENT, y - 4)
    table.insert(self.widgets, { kind = "text", id = entry.id, frame = text })
end

-- Builds the panel frame from the model. Returns the frame, or nil.
function Panel:Build()
    if type(self.environment.CreateFrame) ~= "function" then
        return nil
    end
    local ok, frame = pcall(function()
        local panel = self.environment.CreateFrame("Frame")
        panel.name = addon.Identity.displayName
        local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", SettingsPanel.LEFT, SettingsPanel.TOP)
        title:SetText(addon.Identity.displayName)
        local y = SettingsPanel.TOP - SettingsPanel.ROW - SettingsPanel.SECTION_GAP
        local sections = self.model:Sections()
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
                elseif entry.kind == "number" then
                    self:addNumber(panel, entry, y)
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
        -- However the options window closes (X, Close, Escape), the panel
        -- hides.
        panel:SetScript("OnHide", function()
            self.model:Closed()
        end)
        return panel
    end)
    if not ok then
        return nil
    end
    return frame
end

-- Adds the panel to the AddOns options. Returns true when it was added.
function Panel:Register()
    if self.registered then
        return true
    end
    local frame = self:Build()
    if frame == nil then
        return false
    end
    local settings = self.environment.Settings
    local ok = false
    if type(settings) == "table" and type(settings.RegisterCanvasLayoutCategory) == "function"
        and type(settings.RegisterAddOnCategory) == "function"
    then
        ok = pcall(function()
            local category = settings.RegisterCanvasLayoutCategory(frame, addon.Identity.displayName)
            settings.RegisterAddOnCategory(category)
            self.category = category
        end)
    elseif type(self.environment.InterfaceOptions_AddCategory) == "function" then
        ok = pcall(self.environment.InterfaceOptions_AddCategory, frame)
    end
    if not ok then
        return false
    end
    self.frame = frame
    self.registered = true
    self.model:OnChange(function()
        self:Refresh()
    end)
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
