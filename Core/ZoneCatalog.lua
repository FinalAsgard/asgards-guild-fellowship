local _, addon = ...

-- The zones a questing listing can be in, each { id, mapId?, name,
-- minLevel?, maxLevel? }, for the listing editor's zone list. The WoW
-- adapter reads them from the client's map tree, with the game's level
-- ranges where it has them; where it reads none, the player's current zone
-- is the only one. It answers which zones fit a level, and searches them by
-- name. Pure: it never touches the game.
local ZoneCatalog = {}
addon.ZoneCatalog = ZoneCatalog

local Catalog = {}
Catalog.__index = Catalog

local function isLevel(value)
    return type(value) == "number" and value >= 1 and value == math.floor(value)
end

-- A zone entry, or nil when `entry` isn't one. A range that isn't whole is
-- left out, so the zone goes under Other levels.
local function zoneOf(entry)
    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
        return nil
    end
    local zone = { name = entry.name }
    if type(entry.mapId) == "number" then
        zone.mapId = entry.mapId
    end
    zone.id = zone.mapId or entry.name
    if isLevel(entry.minLevel) and isLevel(entry.maxLevel) and entry.minLevel <= entry.maxLevel then
        zone.minLevel, zone.maxLevel = entry.minLevel, entry.maxLevel
    end
    return zone
end

local function byName(a, b)
    if a.name ~= b.name then
        return a.name < b.name
    end
    return tostring(a.id) < tostring(b.id)
end

-- A catalog of `entries` ({ mapId?, name, minLevel?, maxLevel? }), and of
-- `current` (the player's zone, the same shape) when the entries don't
-- name it. Unusable entries, and a name already given, are left out.
function ZoneCatalog.Create(entries, current)
    local zones, byName_ = {}, {}
    local function add(entry)
        local zone = zoneOf(entry)
        if zone ~= nil and byName_[zone.name] == nil then
            table.insert(zones, zone)
            byName_[zone.name] = zone
        end
    end
    local index
    for index = 1, #(type(entries) == "table" and entries or {}) do
        add(entries[index])
    end
    add(current)
    table.sort(zones, byName)
    return setmetatable({ zones = zones, byName = byName_ }, Catalog)
end

-- The zone named `name`, or nil.
function Catalog:Named(name)
    return self.byName[name]
end

-- Whether `level` is within `zone`'s range. A zone without one fits no
-- level.
function ZoneCatalog.Fits(zone, level)
    return zone.minLevel ~= nil and type(level) == "number"
        and level >= zone.minLevel and level <= zone.maxLevel
end

-- The listing editor's zone search: every zone whose name holds `text`
-- (ignoring case; all of them with no text), split into those `level`
-- fits and the rest, each by name. Zones without a range are among the
-- rest.
function Catalog:Search(text, level)
    local wanted = string.lower(string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
    local fitting, others = {}, {}
    local index
    for index = 1, #self.zones do
        local zone = self.zones[index]
        if wanted == "" or string.find(string.lower(zone.name), wanted, 1, true) ~= nil then
            table.insert(ZoneCatalog.Fits(zone, level) and fitting or others, zone)
        end
    end
    return fitting, others
end
