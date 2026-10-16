local _, addon = ...

-- Guildmates' locations between add-on users, and their validation. Every
-- message is a table { v = VERSION, t = type, ... } sent through the
-- add-on's comm endpoint. A message with another version, a type this
-- version doesn't know, or fields of the wrong shape is ignored, so mixed
-- add-on versions in one guild never break each other. Types are prefixed
-- "gm-" so they never clash with guild sync's, Guild Greet's, Guild
-- Recruit's or the Group Finder's on the same endpoint. Pure: it never
-- touches the game.
local LocationProtocol = {
    VERSION = 1,
    -- { v, t, c = the sender's character (key), m = its zone's map id,
    -- x, y = its position on that map (0-1, 3 decimals), cl = its class
    -- token, l = its level }: where the sender is. Sent to the guild.
    TYPE_LOCATION = "gm-loc",
    -- The same fields, whispered to one guildmate in the same zone.
    TYPE_NEAR = "gm-near",
    -- { v, t, c }: the sender's character is off the map (sharing turned
    -- off, or inside an instance). Sent to the guild.
    TYPE_HIDE = "gm-hide",
}
addon.LocationProtocol = LocationProtocol

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isWhole(value)
    return type(value) == "number" and value >= 1 and value == math.floor(value)
end

local function isCoordinate(value)
    return type(value) == "number" and value >= 0 and value <= 1
end

local function isPosition(message)
    return isText(message.c) and isWhole(message.m) and isCoordinate(message.x) and isCoordinate(message.y)
        and isText(message.cl) and isWhole(message.l)
end

-- Each type and the check its fields must pass.
local CHECKS = {
    [LocationProtocol.TYPE_LOCATION] = isPosition,
    [LocationProtocol.TYPE_NEAR] = isPosition,
    [LocationProtocol.TYPE_HIDE] = function(message)
        return isText(message.c)
    end,
}

-- Every location message type, for routing.
LocationProtocol.TYPES = {}
local type_
for type_ in pairs(CHECKS) do
    LocationProtocol.TYPES[type_] = true
end

-- A coordinate rounded to 3 decimals, kept within 0-1.
local function round(value)
    local rounded = math.floor(value * 1000 + 0.5) / 1000
    return math.max(0, math.min(1, rounded))
end

local function position(kind, character, spot)
    return {
        v = LocationProtocol.VERSION,
        t = kind,
        c = character,
        m = spot.mapId,
        x = round(spot.x),
        y = round(spot.y),
        cl = spot.class,
        l = spot.level,
    }
end

-- Where `character` is: `spot` is { mapId, x, y, class, level }.
function LocationProtocol.Location(character, spot)
    return position(LocationProtocol.TYPE_LOCATION, character, spot)
end

function LocationProtocol.Near(character, spot)
    return position(LocationProtocol.TYPE_NEAR, character, spot)
end

function LocationProtocol.Hide(character)
    return { v = LocationProtocol.VERSION, t = LocationProtocol.TYPE_HIDE, c = character }
end

-- Whether `message` is a location message this version understands.
function LocationProtocol.IsValid(message)
    if type(message) ~= "table" or message.v ~= LocationProtocol.VERSION then
        return false
    end
    local check = CHECKS[message.t]
    return check ~= nil and check(message) == true
end
