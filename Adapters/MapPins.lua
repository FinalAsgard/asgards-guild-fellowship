local _, addon = ...

-- Draws guildmates on the game's maps with HereBeDragons-Pins-2.0: on the
-- zone map, each add-on guildmate is a class-colored dot at their exact
-- position, with a tooltip naming the character, their level, and their
-- alias or main the way chat tags do. The only code that touches the pins
-- library. Without it the map simply stays empty (LibraryCheck already
-- names the missing library).
local MapPins = {
    PINS_LIBRARY = "HereBeDragons-Pins-2.0",
    DOT_TEXTURE = "Interface\\COMMON\\Indicator-Gray",
    DOT_SIZE = 10,
    -- HBD_PINS_WORLDMAP_SHOW_CURRENT: a dot shows on its own zone's map only.
    SHOW_CURRENT_GLOBAL = "HBD_PINS_WORLDMAP_SHOW_CURRENT",
    SHOW_CURRENT = 0,
}
addon.MapPins = MapPins

local Pins = {}
Pins.__index = Pins

-- options:
--   client  the compatibility adapter
--   dots    function() -> the guildmates to draw: each { key, mapId, x, y,
--           class, name, level, label? } (label is the chat tag's text)
function MapPins.Create(options)
    return setmetatable({
        client = options.client,
        environment = options.client.environment,
        dots = options.dots or function()
            return {}
        end,
        icons = {},
    }, Pins)
end

-- A dot's tooltip lines: the character's name, then its level, then its
-- alias or main when it has one.
function MapPins.TooltipLines(dot)
    local lines = { dot.name or dot.key, "Level " .. tostring(dot.level) }
    if dot.label ~= nil and dot.label ~= "" then
        table.insert(lines, dot.label)
    end
    return lines
end

-- Whether the pins library is there and can draw. Safe to call again.
function Pins:Start()
    if self.pins ~= nil then
        return true
    end
    local pins = self.client:GetLibrary(MapPins.PINS_LIBRARY)
    if type(pins) ~= "table" or type(pins.AddWorldMapIconMap) ~= "function"
        or type(pins.RemoveAllWorldMapIcons) ~= "function"
        or type(self.environment.CreateFrame) ~= "function"
    then
        return false
    end
    self.pins = pins
    return true
end

local function showTooltip(icon)
    local tooltip = icon.owner.environment.GameTooltip
    if type(tooltip) ~= "table" or icon.dot == nil then
        return
    end
    pcall(function()
        tooltip:SetOwner(icon, "ANCHOR_RIGHT")
        local lines = MapPins.TooltipLines(icon.dot)
        local index
        for index = 1, #lines do
            tooltip:AddLine(lines[index], 1, 1, 1)
        end
        tooltip:Show()
    end)
end

local function hideTooltip(icon)
    local tooltip = icon.owner.environment.GameTooltip
    if type(tooltip) == "table" then
        pcall(tooltip.Hide, tooltip)
    end
end

-- The `index`th dot frame, made the first time it's needed and reused.
function Pins:Icon(index)
    local icon = self.icons[index]
    if icon ~= nil then
        return icon
    end
    local ok, created = pcall(function()
        local frame = self.environment.CreateFrame("Frame", nil, nil)
        frame:SetSize(MapPins.DOT_SIZE, MapPins.DOT_SIZE)
        frame.texture = frame:CreateTexture(nil, "OVERLAY")
        frame.texture:SetAllPoints(frame)
        frame.texture:SetTexture(MapPins.DOT_TEXTURE)
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", showTooltip)
        frame:SetScript("OnLeave", hideTooltip)
        frame.owner = self
        return frame
    end)
    if not ok then
        return nil
    end
    self.icons[index] = created
    return created
end

-- An "ffrrggbb" color as r, g, b from 0 to 1, or white.
local function rgb(color)
    if type(color) ~= "string" or string.find(color, "^%x%x%x%x%x%x%x%x$") == nil then
        return 1, 1, 1
    end
    return tonumber(string.sub(color, 3, 4), 16) / 255, tonumber(string.sub(color, 5, 6), 16) / 255,
        tonumber(string.sub(color, 7, 8), 16) / 255
end

-- Draws the dots as they are now, replacing the ones drawn before.
function Pins:Refresh()
    if self.pins == nil then
        return
    end
    pcall(self.pins.RemoveAllWorldMapIcons, self.pins, self)
    local okDots, dots = pcall(self.dots)
    if not okDots or type(dots) ~= "table" then
        return
    end
    local showFlag = self.environment[MapPins.SHOW_CURRENT_GLOBAL]
    if type(showFlag) ~= "number" then
        showFlag = MapPins.SHOW_CURRENT
    end
    local index
    for index = 1, #dots do
        local dot = dots[index]
        local icon = self:Icon(index)
        if icon ~= nil then
            icon.dot = dot
            pcall(icon.texture.SetVertexColor, icon.texture, rgb(self.client:GetClassColor(dot.class)))
            pcall(self.pins.AddWorldMapIconMap, self.pins, self, icon, dot.mapId, dot.x, dot.y, showFlag)
        end
    end
end
