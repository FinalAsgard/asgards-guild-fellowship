local _, addon = ...

-- Draws guildmates on the game's maps with HereBeDragons-Pins-2.0: on the
-- zone map, and on the minimap for those in the player's zone, each add-on
-- guildmate is a class-colored dot at their exact position, with a tooltip naming the character, their level, and their
-- alias or main the way chat tags do. On a continent map each zone with
-- guildmates has one marker at the zone's center, and on the world map each
-- continent does: up to three class-colored dots side by side, or a count,
-- with a tooltip listing everyone there. The only code that touches the
-- HereBeDragons libraries. Without them the map simply stays empty
-- (LibraryCheck already names the missing library).
local MapPins = {
    PINS_LIBRARY = "HereBeDragons-Pins-2.0",
    MAP_LIBRARY = "HereBeDragons-2.0",
    -- The gap between a marker's dots, so they sit side by side.
    DOT_GAP = 2,
    COUNT_SIZE = 18,
    DOT_TEXTURE = "Interface\\COMMON\\Indicator-Gray",
    DOT_SIZE = 10,
    -- HBD_PINS_WORLDMAP_SHOW_CURRENT: a dot shows on its own zone's map only.
    SHOW_CURRENT_GLOBAL = "HBD_PINS_WORLDMAP_SHOW_CURRENT",
    SHOW_CURRENT = 0,
    -- Marks people a marker shows from the guild roster's zone (they don't
    -- run the add-on, or haven't shared a position).
    ROSTER_TEXT = "from the roster",
}
addon.MapPins = MapPins

local Pins = {}
Pins.__index = Pins

-- options:
--   client  the compatibility adapter
--   dots    function() -> the guildmates to draw: each { key, mapId, x, y,
--           class, name, level, label? } (label is the chat tag's text)
--   zone    function() -> the player's zone map ID, or nil (no minimap
--           dots then)
--   shown   function() -> false while guildmates are hidden from the maps
--           and minimap
--   markers function() -> the world map markers: each { area, mapId,
--           display, people } where `area` is the zone or continent map the
--           marker stands for, `mapId` the continent or world map it's
--           drawn on, `display` "dots" or "count" (see LocationBoard), and
--           `people` dots as above, those from the roster with fromRoster
--           set and no position
function MapPins.Create(options)
    return setmetatable({
        client = options.client,
        environment = options.client.environment,
        dots = options.dots or function()
            return {}
        end,
        markers = options.markers or function()
            return {}
        end,
        zone = options.zone or function()
            return nil
        end,
        shown = options.shown or function()
            return true
        end,
        icons = {},
        -- The minimap's own dots: a frame is drawn on one map only.
        minimapIcons = {},
        markerFrames = {},
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

-- A marker's tooltip lines: one per person, with their level and their
-- alias or main when they have one, and marked when only the guild roster
-- says where they are.
function MapPins.MarkerLines(marker)
    local lines = {}
    local index
    for index = 1, #(marker.people or {}) do
        local person = marker.people[index]
        local line = (person.name or person.key) .. ", level " .. tostring(person.level)
        if person.label ~= nil and person.label ~= "" then
            line = line .. " (" .. person.label .. ")"
        end
        if person.fromRoster then
            line = line .. ", " .. MapPins.ROSTER_TEXT
        end
        table.insert(lines, line)
    end
    return lines
end

-- Whether the pins library is there and can draw. Safe to call again. It
-- also redraws when the world map changes maps.
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
    local map = self.client:GetLibrary(MapPins.MAP_LIBRARY)
    if type(map) == "table" and type(map.TranslateZoneCoordinates) == "function" then
        self.map = map
    end
    local worldMap = self.environment.WorldMapFrame
    local hook = self.environment.hooksecurefunc
    if type(worldMap) == "table" and type(worldMap.OnMapChanged) == "function" and type(hook) == "function" then
        pcall(hook, worldMap, "OnMapChanged", function()
            self:Refresh()
        end)
    end
    return true
end

local function showTooltip(icon)
    local tooltip = icon.owner.environment.GameTooltip
    if type(tooltip) ~= "table" or (icon.dot == nil and icon.marker == nil) then
        return
    end
    pcall(function()
        tooltip:SetOwner(icon, "ANCHOR_RIGHT")
        local lines = icon.marker ~= nil and MapPins.MarkerLines(icon.marker) or MapPins.TooltipLines(icon.dot)
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

-- The `index`th dot frame in `pool` (the world map's by default), made the
-- first time it's needed and reused.
function Pins:Icon(index, pool)
    pool = pool or self.icons
    local icon = pool[index]
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
    pool[index] = created
    return created
end

-- The `index`th world map marker frame: DOTS_MAX dots side by side and a
-- count, made the first time it's needed and reused.
function Pins:MarkerFrame(index)
    local frame = self.markerFrames[index]
    if frame ~= nil then
        return frame
    end
    local ok, created = pcall(function()
        local size, gap = MapPins.DOT_SIZE, MapPins.DOT_GAP
        local most = addon.LocationBoard.DOTS_MAX
        local marker = self.environment.CreateFrame("Frame", nil, nil)
        marker:SetSize(most * size + (most - 1) * gap, MapPins.COUNT_SIZE)
        marker.dots = {}
        local dot
        for dot = 1, most do
            local texture = marker:CreateTexture(nil, "OVERLAY")
            texture:SetSize(size, size)
            texture:SetPoint("LEFT", marker, "LEFT", (dot - 1) * (size + gap), 0)
            texture:SetTexture(MapPins.DOT_TEXTURE)
            marker.dots[dot] = texture
        end
        marker.badge = marker:CreateTexture(nil, "ARTWORK")
        marker.badge:SetSize(MapPins.COUNT_SIZE, MapPins.COUNT_SIZE)
        marker.badge:SetPoint("CENTER", marker, "CENTER", 0, 0)
        marker.badge:SetTexture(MapPins.DOT_TEXTURE)
        marker.count = marker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        marker.count:SetPoint("CENTER", marker.badge, "CENTER", 0, 0)
        marker:EnableMouse(true)
        marker:SetScript("OnEnter", showTooltip)
        marker:SetScript("OnLeave", hideTooltip)
        marker.owner = self
        return marker
    end)
    if not ok then
        return nil
    end
    self.markerFrames[index] = created
    return created
end

-- Shows `marker`'s people on `frame`: their class-colored dots side by
-- side, or a count.
function Pins:DrawMarker(frame, marker)
    frame.marker = marker
    local dots = marker.display == "dots"
    local index
    for index = 1, #frame.dots do
        local person = dots and marker.people[index] or nil
        if person ~= nil then
            frame.dots[index]:SetVertexColor(self:ClassColor(person.class))
            frame.dots[index]:Show()
        else
            frame.dots[index]:Hide()
        end
    end
    if dots then
        frame.badge:Hide()
        frame.count:SetText("")
    else
        frame.badge:Show()
        frame.count:SetText(tostring(#marker.people))
    end
end

-- Where `area`'s center falls on map `mapId`, or nil.
function Pins:Center(area, mapId)
    if self.map == nil then
        return nil
    end
    local ok, x, y = pcall(self.map.TranslateZoneCoordinates, self.map, 0.5, 0.5, area, mapId)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    return x, y
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
    local okShown, shown = pcall(self.shown)
    if okShown and shown == false then
        if type(self.pins.RemoveAllMinimapIcons) == "function" then
            pcall(self.pins.RemoveAllMinimapIcons, self.pins, self)
        end
        return
    end
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
            pcall(icon.texture.SetVertexColor, icon.texture, self:ClassColor(dot.class))
            pcall(self.pins.AddWorldMapIconMap, self.pins, self, icon, dot.mapId, dot.x, dot.y, showFlag)
        end
    end
    self:DrawMinimap(dots)
    local okMarkers, markers = pcall(self.markers)
    if not okMarkers or type(markers) ~= "table" then
        return
    end
    for index = 1, #markers do
        local marker = markers[index]
        local x, y = self:Center(marker.area, marker.mapId)
        local frame = x ~= nil and self:MarkerFrame(index) or nil
        if frame ~= nil and pcall(self.DrawMarker, self, frame, marker) then
            pcall(self.pins.AddWorldMapIconMap, self.pins, self, frame, marker.mapId, x, y, showFlag)
        end
    end
end

-- Draws the dots in the player's zone on the minimap, replacing the ones
-- drawn before. Nothing when the pins library can't draw on the minimap.
function Pins:DrawMinimap(dots)
    if type(self.pins.AddMinimapIconMap) ~= "function" or type(self.pins.RemoveAllMinimapIcons) ~= "function" then
        return
    end
    pcall(self.pins.RemoveAllMinimapIcons, self.pins, self)
    local okZone, zone = pcall(self.zone)
    if not okZone or zone == nil then
        return
    end
    local drawn = 0
    local index
    for index = 1, #dots do
        local dot = dots[index]
        if dot.mapId == zone then
            drawn = drawn + 1
            local icon = self:Icon(drawn, self.minimapIcons)
            if icon ~= nil then
                icon.dot = dot
                pcall(icon.texture.SetVertexColor, icon.texture, self:ClassColor(dot.class))
                -- Not shown from a parent zone, and not floating on the edge.
                pcall(self.pins.AddMinimapIconMap, self.pins, self, icon, dot.mapId, dot.x, dot.y, false, false)
            end
        end
    end
end

function Pins:ClassColor(classToken)
    return rgb(self.client:GetClassColor(classToken))
end
