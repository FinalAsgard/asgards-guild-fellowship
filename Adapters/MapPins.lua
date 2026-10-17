local _, addon = ...

-- Draws guildmates on the game's maps with HereBeDragons-Pins-2.0: on the
-- zone map, and on the minimap for those in the player's zone, each add-on
-- guildmate is a class-colored dot at their exact position, with a tooltip naming the character, their alias or
-- main the way chat tags do, and their level. Dots that would overlap are
-- moved apart. On a continent map each zone with guildmates has one marker,
-- placed where those guildmates are, and on the world map each continent
-- does, at a fixed spot over its land: a class-colored dot for one, or a
-- count, with a tooltip listing everyone there. Pointing at a zone or
-- continent on the world map lists its guildmates too. The only code that
-- touches the
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
    -- HBD_PINS_WORLDMAP_SHOW_WORLD: shown on the world map too. The world
    -- map has no coordinates of its own, so a continent's world map marker
    -- is added on the continent with this flag.
    SHOW_WORLD_GLOBAL = "HBD_PINS_WORLDMAP_SHOW_WORLD",
    SHOW_WORLD = 3,
    -- While the player is in a party, guildmates outside it are drawn at
    -- this opacity, so the party stands out.
    DIM_ALPHA = 0.6,
    -- Ends the tooltip of a zone map dot placed only by the roster's zone.
    UNKNOWN_SPOT_TEXT = "(exact location unknown)",
    -- Where each continent's marker sits on the world map, over its land:
    -- Kalimdor and the Eastern Kingdoms, by their Forever and Retail map
    -- IDs. Other continents go to the middle of their guildmates.
    WORLD_SPOTS = {
        [1414] = { 0.25, 0.50 },
        [12] = { 0.25, 0.50 },
        [1415] = { 0.80, 0.44 },
        [13] = { 0.80, 0.44 },
    },
    -- A dot's width as a share of the map, when the map can't say.
    DOT_WIDTH = 0.01,
    -- Dots moved apart sit in rows of at most this many.
    SPREAD_ROW = 8,
    WORLD_MAP_TYPE = 1,
    -- The list of guildmates in the zone or continent under the cursor:
    -- under the world map's continent title, or at the right of a
    -- continent map. Checked this often, in seconds, while the map shows.
    AREA_LIST_INTERVAL = 0.1,
    AREA_LIST_TITLE_GAP = 64,
    AREA_LIST_INSET = 16,
    AREA_LIST_PADDING = 6,
}
addon.MapPins = MapPins

local Pins = {}
Pins.__index = Pins

-- options:
--   client  the compatibility adapter
--   dots    function() -> the guildmates to draw: each { key, mapId, x, y,
--           class, name, level, label?, dimmed?, fromRoster? } (label is
--           the chat tag's text; dimmed is set for those outside the
--           player's party; fromRoster for those only the roster places,
--           at their zone's center, never on the minimap)
--   zone    function() -> the player's zone map ID, or nil (no minimap
--           dots then)
--   shown   function() -> false while guildmates are hidden from the maps
--           and minimap
--   markers function() -> the map markers: each { area, mapId, display,
--           people } where `area` is the zone or continent map the marker
--           stands for, `mapId` the continent or world map it's drawn on,
--           `display` "dots" or "count"
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
        drawnMarkers = {},
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

-- A dot's tooltip lines: just the one guildmate, noting when only the
-- roster's zone places them (the dot then sits at the zone's center).
function MapPins.TooltipLines(dot)
    local line = MapPins.Describe(dot)
    if dot.fromRoster then
        line = line .. " " .. MapPins.UNKNOWN_SPOT_TEXT
    end
    return { line }
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
    -- Nothing is drawn on the world map while it's closed: draw on opening.
    if type(worldMap) == "table" and type(worldMap.HookScript) == "function" then
        pcall(worldMap.HookScript, worldMap, "OnShow", function()
            self:Refresh()
        end)
    end
    self:StartAreaList()
    return true
end

-- Builds the list of guildmates in the area under the cursor on the world
-- map's own map area, and a frame that shows whenever the map does, to
-- check the cursor (a hidden list can't check for itself).
function Pins:StartAreaList()
    local worldMap = self.environment.WorldMapFrame
    local container = type(worldMap) == "table" and worldMap.ScrollContainer or nil
    if type(container) ~= "table" then
        return
    end
    pcall(function()
        local list = self.environment.CreateFrame("Frame", nil, container)
        list.background = list:CreateTexture(nil, "BACKGROUND")
        list.background:SetAllPoints(list)
        list.background:SetColorTexture(0, 0, 0, 0.6)
        list.text = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        list.text:SetPoint("CENTER", list, "CENTER", 0, 0)
        list:Hide()
        local watcher = self.environment.CreateFrame("Frame", nil, container)
        local waited = 0
        watcher:SetScript("OnUpdate", function(_, elapsed)
            waited = waited + (elapsed or 0)
            if waited >= MapPins.AREA_LIST_INTERVAL then
                waited = 0
                self:UpdateAreaList()
            end
        end)
        self.areaList = list
        self.areaWatcher = watcher
    end)
end

-- The area under the cursor on the world map, and the map shown: the zone
-- on a continent map, the continent on the world map. Nil when the cursor
-- is off the map.
function Pins:HoveredArea()
    local worldMap = self.environment.WorldMapFrame
    local maps = self.environment.C_Map
    local container = type(worldMap) == "table" and worldMap.ScrollContainer or nil
    if type(container) ~= "table" or type(maps) ~= "table" then
        return nil
    end
    local okOver, over = pcall(container.IsMouseOver, container)
    if not okOver or not over then
        return nil
    end
    local okMap, mapId = pcall(worldMap.GetMapID, worldMap)
    local okCursor, x, y = pcall(container.GetNormalizedCursorPosition, container)
    if not okMap or type(mapId) ~= "number" or not okCursor or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    local okInfo, info = pcall(maps.GetMapInfoAtPosition, mapId, x, y)
    if not okInfo or type(info) ~= "table" or type(info.mapID) ~= "number" or info.mapID == mapId then
        return nil
    end
    return info.mapID, mapId
end

-- Shows the guildmates in the area under the cursor when they're combined
-- into a count, or hides the list. A single guildmate's dot has its own
-- tooltip instead.
function Pins:UpdateAreaList()
    local list = self.areaList
    if list == nil then
        return
    end
    local area, mapId = self:HoveredArea()
    -- Nothing to redo while the same area is under the cursor.
    if area == self.listedArea and mapId == self.listedMap and self.listedRefresh == self.refreshes then
        return
    end
    self.listedArea, self.listedMap, self.listedRefresh = area, mapId, self.refreshes
    local marker
    local index
    for index = 1, #self.drawnMarkers do
        local drawn = self.drawnMarkers[index]
        if area ~= nil and drawn.area == area and drawn.mapId == mapId and drawn.display ~= "dots" then
            marker = drawn
        end
    end
    if marker == nil then
        list:Hide()
        return
    end
    local lines = MapPins.MarkerLines(marker)
    list.text:SetText(table.concat(lines, "\n"))
    local padding = MapPins.AREA_LIST_PADDING
    local okWidth, width = pcall(list.text.GetStringWidth, list.text)
    local okHeight, height = pcall(list.text.GetStringHeight, list.text)
    width = okWidth and type(width) == "number" and width or 160
    height = okHeight and type(height) == "number" and height or 14 * #lines
    list:SetSize(width + 2 * padding, height + 2 * padding)
    local container = self.environment.WorldMapFrame.ScrollContainer
    local okInfo, info = pcall(self.environment.C_Map.GetMapInfo, mapId)
    pcall(list.ClearAllPoints, list)
    if okInfo and type(info) == "table" and info.mapType == MapPins.WORLD_MAP_TYPE then
        list.text:SetJustifyH("CENTER")
        list:SetPoint("TOP", container, "TOP", 0, -MapPins.AREA_LIST_TITLE_GAP)
    else
        list.text:SetJustifyH("LEFT")
        list:SetPoint("RIGHT", container, "RIGHT", -MapPins.AREA_LIST_INSET, 0)
    end
    list:Show()
end

-- A combined marker (a count) has no tooltip: pointing at its area lists
-- everyone there instead.
local function showTooltip(icon)
    local tooltip = icon.owner.environment.GameTooltip
    if type(tooltip) ~= "table" or (icon.dot == nil and icon.marker == nil) then
        return
    end
    if icon.marker ~= nil and icon.marker.display ~= "dots" then
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

-- Where `marker` goes on its map: a continent's fixed spot on the world
-- map, else the middle of its people, each at their position, or their
-- zone's center when only the roster places them. The area's center when
-- none of them can be placed; nil when that can't either.
function Pins:Place(marker)
    local spot = MapPins.WORLD_SPOTS[marker.area]
    if spot ~= nil then
        return spot[1], spot[2]
    end
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
    self.refreshes = (self.refreshes or 0) + 1
    local okShown, shown = pcall(self.shown)
    if okShown and shown == false then
        self.drawnMarkers = {}
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
    -- Each dot and marker shows on its own map only, so only those for the
    -- map open now are drawn, and none while the world map is closed.
    local open = self:OpenMap()
    local width = self:DotWidth()
    local placed = {}
    local drawn = 0
    local index
    for index = 1, #dots do
        local dot = dots[index]
        if open == nil or dot.mapId == open then
            drawn = drawn + 1
            local icon = self:Icon(drawn)
            if icon ~= nil then
                icon.dot = dot
                self:Color(icon, dot)
                local x, y = self:Spread(placed, dot.mapId, dot.x, dot.y, width)
                pcall(self.pins.AddWorldMapIconMap, self.pins, self, icon, dot.mapId, x, y, showFlag)
            end
        end
    end
    self:DrawMinimap(dots)
    local okMarkers, markers = pcall(self.markers)
    if not okMarkers or type(markers) ~= "table" then
        self.drawnMarkers = {}
        return
    end
    self.drawnMarkers = markers
    drawn = 0
    for index = 1, #markers do
        local marker = markers[index]
        if open == nil or marker.mapId == open then
            local x, y = self:Place(marker)
            local frame
            if x ~= nil then
                drawn = drawn + 1
                frame = self:MarkerFrame(drawn)
            end
            if frame ~= nil and pcall(self.DrawMarker, self, frame, marker) then
                self:AddMarker(frame, marker, x, y, showFlag)
            end
        end
    end
end

-- Adds `frame`, drawn for `marker`, at `x`, `y` on the marker's map. A
-- continent's marker on the world map goes on the continent itself, at the
-- point that shows at `x`, `y` on the world map (the pins library can't
-- place anything from the world map's own coordinates); only drawn while
-- the world map is open, it never shows on the continent's own map. Added
-- on the world map directly when that point can't be worked out.
function Pins:AddMarker(frame, marker, x, y, showFlag)
    if self:IsWorldMap(marker.mapId) then
        local areaX, areaY = self:Unproject(x, y, marker.area, marker.mapId)
        if areaX ~= nil then
            local worldFlag = self.environment[MapPins.SHOW_WORLD_GLOBAL]
            if type(worldFlag) ~= "number" then
                worldFlag = MapPins.SHOW_WORLD
            end
            pcall(self.pins.AddWorldMapIconMap, self.pins, self, frame, marker.area, areaX, areaY, worldFlag)
            return
        end
    end
    pcall(self.pins.AddWorldMapIconMap, self.pins, self, frame, marker.mapId, x, y, showFlag)
end

-- Whether `mapId` is a world map (the client's map type says so).
function Pins:IsWorldMap(mapId)
    local maps = self.environment.C_Map
    if type(maps) ~= "table" or type(maps.GetMapInfo) ~= "function" then
        return false
    end
    local ok, info = pcall(maps.GetMapInfo, mapId)
    return ok and type(info) == "table" and info.mapType == MapPins.WORLD_MAP_TYPE
end

-- The point on map `area` that shows at `x`, `y` on map `mapId`, or nil:
-- the pins library places a map inside another by scaling and moving it,
-- so two corners are enough to work back.
function Pins:Unproject(x, y, area, mapId)
    local leftX, topY = self:Translate(0, 0, area, mapId)
    local rightX, bottomY = self:Translate(1, 1, area, mapId)
    if leftX == nil or rightX == nil or rightX == leftX or bottomY == topY then
        return nil
    end
    return (x - leftX) / (rightX - leftX), (y - topY) / (bottomY - topY)
end

-- The map the world map shows now; false while it's closed; nil when the
-- client can't say (then everything is drawn and the pins library sorts it).
function Pins:OpenMap()
    local worldMap = self.environment.WorldMapFrame
    if type(worldMap) ~= "table" or type(worldMap.IsShown) ~= "function" or type(worldMap.GetMapID) ~= "function" then
        return nil
    end
    local okShown, shown = pcall(worldMap.IsShown, worldMap)
    if not okShown then
        return nil
    end
    if not shown then
        return false
    end
    local okMap, mapId = pcall(worldMap.GetMapID, worldMap)
    return okMap and type(mapId) == "number" and mapId or nil
end

-- A dot's width as a share of the world map's width now, so dots can be
-- kept apart.
function Pins:DotWidth()
    local worldMap = self.environment.WorldMapFrame
    if type(worldMap) == "table" and type(worldMap.GetCanvas) == "function" then
        local ok, width = pcall(function()
            return worldMap:GetCanvas():GetWidth()
        end)
        if ok and type(width) == "number" and width > 0 then
            return MapPins.DOT_SIZE / width
        end
    end
    return MapPins.DOT_WIDTH
end

-- Where a dot at `x`, `y` on map `mapId` goes so it doesn't cover one
-- already in `placed`: the first free spot moving right a dot's width at a
-- time, in rows of SPREAD_ROW going down. Records it.
function Pins:Spread(placed, mapId, x, y, width)
    -- Neighbors exactly a dot's width apart don't overlap, rounding aside.
    local apart = width * 0.999
    local function free(spotX, spotY)
        local index
        for index = 1, #placed do
            local other = placed[index]
            if other.mapId == mapId and math.abs(other.x - spotX) < apart and math.abs(other.y - spotY) < apart then
                return false
            end
        end
        return true
    end
    local row = MapPins.SPREAD_ROW
    local step = 0
    local spotX, spotY = x, y
    -- Every placed dot rules out at most a few spots, so a free one comes
    -- within this many steps.
    while not free(spotX, spotY) and step <= 4 * #placed do
        step = step + 1
        spotX = x + (step % row) * width
        spotY = y + math.floor(step / row) * width
    end
    table.insert(placed, { mapId = mapId, x = spotX, y = spotY })
    return spotX, spotY
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
        -- Those only the roster places have no real position to show.
        if dot.mapId == zone and not dot.fromRoster then
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
