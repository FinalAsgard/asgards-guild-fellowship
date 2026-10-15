local _, addon = ...

-- Guildmates' latest positions, as their add-ons report them (see
-- LocationProtocol). Pure: the caller checks that the sender is in the
-- guild and passes the clock.
local LocationBoard = {}
addon.LocationBoard = LocationBoard

local Board = {}
Board.__index = Board

-- options.isOwn: function(key) -> true for the player's own characters,
-- which are never held (the player isn't shown twice).
function LocationBoard.Create(options)
    options = options or {}
    return setmetatable({
        entries = {},
        isOwn = options.isOwn or function()
            return false
        end,
    }, Board)
end

-- A valid `gm-loc` or `gm-near` from character `senderKey`, heard at `now`.
-- Returns true when the board changed.
function Board:OnLocation(message, senderKey, now)
    if message.c ~= senderKey or self.isOwn(senderKey) then
        return false
    end
    self.entries[senderKey] = {
        key = senderKey,
        mapId = message.m,
        x = message.x,
        y = message.y,
        class = message.cl,
        level = message.l,
        heard = now,
    }
    return true
end

-- Every guildmate on the board, sorted by key: each { key, mapId, x, y,
-- class, level, heard }.
function Board:All()
    local found = {}
    local key, entry
    for key, entry in pairs(self.entries) do
        if not self.isOwn(key) then
            table.insert(found, entry)
        end
    end
    table.sort(found, function(left, right)
        return left.key < right.key
    end)
    return found
end

-- At most this many people show as dots side by side on a world map
-- marker; more show as a count.
LocationBoard.DOTS_MAX = 3

-- Guildmates grouped into one marker per area, for the world map: `areaOf`
-- gives the area an entry's zone map belongs to (the zone itself for a
-- continent map, its continent for the world map), or nil to leave it out.
-- Returns markers sorted by area: { area, people (sorted by key), display }
-- with display "dots" for 1 to DOTS_MAX people and "count" for more.
function Board:Markers(areaOf)
    local byArea, areas = {}, {}
    local entries = self:All()
    local index
    for index = 1, #entries do
        local area = areaOf(entries[index].mapId)
        if area ~= nil then
            if byArea[area] == nil then
                byArea[area] = { area = area, people = {} }
                table.insert(areas, area)
            end
            table.insert(byArea[area].people, entries[index])
        end
    end
    table.sort(areas)
    local markers = {}
    for index = 1, #areas do
        local marker = byArea[areas[index]]
        marker.display = #marker.people <= LocationBoard.DOTS_MAX and "dots" or "count"
        table.insert(markers, marker)
    end
    return markers
end
