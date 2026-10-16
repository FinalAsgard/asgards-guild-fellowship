local _, addon = ...

-- Draws guildmates on the game's maps with HereBeDragons-Pins-2.0: on the
-- zone map, and on the minimap for those in the player's zone, each add-on
-- guildmate is a class-colored dot at their exact position, with a tooltip naming the character, their alias or
-- main the way chat tags do, and their level. On a continent map each zone
-- with guildmates has one marker, and on the world map each continent does,
-- placed where those guildmates are: a class-colored dot for one, or a
-- count, with a tooltip listing everyone there. Guildmates only the roster
-- places get the same kind of marker at their zone's center on the zone
-- map. The only code that touches the
-- HereBeDragons libraries. Without them the map simply stays empty
-- (LibraryCheck already names the missing library).
local MapPins = {
    PINS_LIBRARY = "HereBeDragons-Pins-2.0",
    MAP_LIBRARY = "HereBeDragons-2.0",
    -- The gap between a marker's dots, so they sit side by side.
    DOT_GAP = 2,
    COUNT_SIZE = 18,
    -- A plain white circle, so the class color tints it.
    DOT_TEXTURE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",
    DOT_SIZE = 10,
    -- A count's badge: a dark circle under the white number.
    BADGE_COLOR = { 0.1, 0.1, 0.1 },
    -- HBD_PINS_WORLDMAP_SHOW_CURRENT: a dot shows on its own zone's map only.
    SHOW_CURRENT_GLOBAL = "HBD_PINS_WORLDMAP_SHOW_CURRENT",
    SHOW_CURRENT = 0,
    -- While the player is in a party, guildmates outside it are drawn at
    -- this opacity, so the party stands out.
    DIM_ALPHA = 0.35,
}
addon.MapPins = MapPins

local Pins = {}
Pins.__index = Pins

-- options:
--   client  the compatibility adapter
--   dots    function() -> the guildmates to draw: each { key, mapId, x, y,
--           class, name, level, label?, dimmed? } (label is the chat tag's
--           text; dimmed is set for those outside the player's party)
--   zone    function() -> the player's zone map ID, or nil (no minimap
--           dots then)
--   shown   function() -> false while guildmates are hidden from the maps
--           and minimap
--   markers function() -> the map markers: each { area, mapId, display,
--           people } where `area` is the zone or continent map the marker
--           stands for, `mapId` the map it's drawn on (the zone's own map
--           for those only the roster places), `display` "dots" or "count"
--           (see LocationBoard), and `people` dots as above, those from the
--           roster with fromRoster set and no position
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

-- How a guildmate reads on the map: "Name (alias or main) (level)", each
-- part in parentheses only when known.
function MapPins.Describe(person)
    local line = person.name or person.key
    if person.label ~= nil and person.label ~= "" then
        line = line .. " (" .. person.label .. ")"
    end
    if person.level ~= nil then
        line = line .. " (" .. tostring(person.level) .. ")"
    end
    return line
end

-- A dot's tooltip lines: just the one guildmate.
function MapPins.TooltipLines(dot)
    return { MapPins.Describe(dot) }
end

-- A marker's tooltip lines: one per person.
function MapPins.MarkerLines(marker)
    local lines = {}
    local index
    for index = 1, #(marker.people or {}) do
        table.insert(lines, MapPins.Describe(marker.people[index]))
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

-- The `index`th map marker frame: DOTS_MAX dots side by side and a
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
        marker.badge:SetVertexColor(MapPins.BADGE_COLOR[1], MapPins.BADGE_COLOR[2], MapPins.BADGE_COLOR[3])
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
            frame.dots[index]:SetAlpha(person.dimmed and MapPins.DIM_ALPHA or 1)
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
    -- A marker with nobody from the player's party is dimmed as a whole.
    local anyoneUndimmed = false
    for index = 1, #marker.people do
        if not marker.people[index].dimmed then
            anyoneUndimmed = true
        end
    end
    frame.badge:SetAlpha(anyoneUndimmed and 1 or MapPins.DIM_ALPHA)
    frame.count:SetAlpha(anyoneUndimmed and 1 or MapPins.DIM_ALPHA)
end

-- Draws a dot frame in `dot`'s class color, dimmed when it's outside the
-- player's party.
function Pins:Color(icon, dot)
    pcall(icon.texture.SetVertexColor, icon.texture, self:ClassColor(dot.class))
    pcall(icon.SetAlpha, icon, dot.dimmed and MapPins.DIM_ALPHA or 1)
end

-- Where point `x`, `y` on map `from` falls on map `to`, or nil.
function Pins:Translate(x, y, from, to)
    if from == to then
        return x, y
    end
    if self.map == nil then
        return nil
    end
    local ok, toX, toY = pcall(self.map.TranslateZoneCoordinates, self.map, x, y, from, to)
    if not ok or type(toX) ~= "number" or type(toY) ~= "number" then
        return nil
    end
    return toX, toY
end

-- Where `marker` goes on its map: the middle of its people, each at their
-- position, or their zone's center when only the roster places them. The
-- area's center when none of them can be placed; nil when that can't either.
function Pins:Place(marker)
    local sumX, sumY, placed = 0, 0, 0
    local index
    for index = 1, #marker.people do
        local person = marker.people[index]
        local x, y
        if type(person.mapId) == "number" then
            x, y = self:Translate(person.x or 0.5, person.y or 0.5, person.mapId, marker.mapId)
        end
        if x ~= nil then
            sumX, sumY, placed = sumX + x, sumY + y, placed + 1
        end
    end
    if placed > 0 then
        return sumX / placed, sumY / placed
    end
    return self:Translate(0.5, 0.5, marker.area, marker.mapId)
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
            self:Color(icon, dot)
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
        local x, y = self:Place(marker)
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
                self:Color(icon, dot)
                -- Not shown from a parent zone, and not floating on the edge.
                pcall(self.pins.AddMinimapIconMap, self.pins, self, icon, dot.mapId, dot.x, dot.y, false, false)
            end
        end
    end
end

function Pins:ClassColor(classToken)
    return rgb(self.client:GetClassColor(classToken))
end
