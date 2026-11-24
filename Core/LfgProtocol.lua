local _, addon = ...

-- The Guild LFG Board's messages between add-on users, and their
-- validation. Every message is a table { v = VERSION, t = type, ... } sent
-- to the guild through the add-on's comm endpoint. A message with another
-- version, a type this version doesn't know, or fields of the wrong shape
-- is ignored, so mixed add-on versions in one guild never break each
-- other. Types are prefixed "lfg-"; the Group Finder's old "gf-" messages
-- are never understood here. Pure: it never touches the game.
local LfgProtocol = {
    VERSION = 1,
    PREFIX = "lfg-",
    -- { v, t, k = purpose kind, p = purpose text?, lo, hi = level range?,
    -- r = open roles (dungeon only), s = size, x = most players, no = note?,
    -- mb = the members, each { n = name, c = class token?, l = level?,
    -- r = role? }, aj = accepts Ask to join }: the sender's party listing,
    -- re-sent every HEARTBEAT_SECONDS while it lasts. The sender leads it.
    TYPE_LISTING = "lfg-listing",
    -- { v, t }: the sender's listing ended.
    TYPE_END = "lfg-end",
    HEARTBEAT_SECONDS = 60,
    -- The most characters a note or a free-text purpose holds.
    TEXT_LETTERS = 60,
    -- The largest party a listing can carry: a raid.
    MOST_PLAYERS = 40,
    KINDS = { dungeon = true, questing = true, raid = true, other = true },
}
addon.LfgProtocol = LfgProtocol

local ROLES = { tank = true, healer = true, dps = true }

-- The number of characters in `text`, counting each UTF-8 character once.
function LfgProtocol.Length(text)
    local _, count = string.gsub(text or "", "[^\128-\191]", "")
    return count
end

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isShortText(value)
    return isText(value) and LfgProtocol.Length(value) <= LfgProtocol.TEXT_LETTERS
end

local function isCount(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

local function isLevel(value)
    return type(value) == "number" and value >= 1 and value == math.floor(value)
end

-- A list of distinct roles, possibly empty.
local function isOpenRoles(roles)
    if type(roles) ~= "table" or #roles > 3 then
        return false
    end
    local seen = {}
    local index
    for index = 1, #roles do
        if not ROLES[roles[index]] or seen[roles[index]] then
            return false
        end
        seen[roles[index]] = true
    end
    return true
end

local function isMember(member)
    return type(member) == "table" and isText(member.n)
        and (member.c == nil or isText(member.c))
        and (member.l == nil or isLevel(member.l))
        and (member.r == nil or ROLES[member.r] == true)
end

local function isMembers(members, size)
    if type(members) ~= "table" or #members ~= size then
        return false
    end
    local index
    for index = 1, #members do
        if not isMember(members[index]) then
            return false
        end
    end
    return true
end

local function isRange(message)
    if message.lo == nil and message.hi == nil then
        return true
    end
    return isLevel(message.lo) and isLevel(message.hi) and message.lo <= message.hi
end

local CHECKS = {
    [LfgProtocol.TYPE_LISTING] = function(message)
        if not LfgProtocol.KINDS[message.k] or not isRange(message) then
            return false
        end
        -- Every kind but a raid names what it's for.
        if message.k ~= "raid" and not isShortText(message.p) then
            return false
        end
        if message.k == "raid" and message.p ~= nil and not isShortText(message.p) then
            return false
        end
        if message.k == "dungeon" then
            if not isOpenRoles(message.r) then
                return false
            end
        elseif message.r ~= nil then
            return false
        end
        return isCount(message.x, 1, LfgProtocol.MOST_PLAYERS) and isCount(message.s, 1, message.x)
            and isMembers(message.mb, message.s)
            and (message.no == nil or isShortText(message.no))
            and type(message.aj) == "boolean"
    end,
    [LfgProtocol.TYPE_END] = function()
        return true
    end,
}

-- Every Guild LFG Board message type, for routing.
LfgProtocol.TYPES = {}
local type_
for type_ in pairs(CHECKS) do
    LfgProtocol.TYPES[type_] = true
end

-- A listing message carrying `fields` (k, p, lo, hi, r, s, x, no, mb, aj),
-- as LfgListing's Announcement gives them.
function LfgProtocol.Listing(fields)
    local message = { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_LISTING }
    local name, value
    for name, value in pairs(fields) do
        message[name] = value
    end
    return message
end

function LfgProtocol.End()
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_END }
end

-- Whether `message` is a Guild LFG Board message this version understands.
function LfgProtocol.IsValid(message)
    if type(message) ~= "table" or message.v ~= LfgProtocol.VERSION then
        return false
    end
    local check = CHECKS[message.t]
    return check ~= nil and check(message) == true
end
