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
    -- r = role? }, aj = accepts Ask to join, ct = true when the sender is
    -- the contact for a party whose leader isn't in the guild }: the
    -- sender's party listing, re-sent every HEARTBEAT_SECONDS while it
    -- lasts. The sender leads it, or is its contact.
    TYPE_LISTING = "lfg-listing",
    -- { v, t, lf = true when the sender left the party }: the sender's
    -- listing ended. One that ended by leaving can be handed on. It also
    -- ends the sender's party announcement (TYPE_PARTY).
    TYPE_END = "lfg-end",
    -- { v, t, s = size, mb = the members, each { n = name, c = class
    -- token?, l = level? }, w = where it is (a dungeon or zone)? }: the
    -- party the sender leads, unlisted, with a guildmate in it: Playing on
    -- guildmates' boards, with nothing to join. Re-sent every
    -- HEARTBEAT_SECONDS while it lasts; a listing of the party replaces it.
    -- An add-on that doesn't know the type ignores it.
    TYPE_PARTY = "lfg-party",
    -- { v, t, ld = the party leader's name }: the sender claims contact for
    -- their party, whose leader isn't in the guild. The party's other
    -- guildmates stop being asked about it.
    TYPE_CONTACT = "lfg-contact",
    -- { v, t, r = the role asked for (dungeon only)?, l = level, c = class
    -- token? }: whispered to a listing's leader, asking to join it as the
    -- sender's current character.
    TYPE_ASK = "lfg-ask",
    -- { v, t, a = one of ANSWERS }: whispered back to whoever asked.
    TYPE_ANSWER = "lfg-answer",
    ANSWERS = { invited = true, declined = true, expired = true, roleFilled = true },
    -- { v, t, y = true to post the open slot, false to keep it off }: a
    -- guildmate in the sender's party answered "Someone left — fill the
    -- empty slot?". The others stop being asked.
    TYPE_SLOT = "lfg-slot",
    -- { v, t, r = a role }: whispered to the party's lister by a member
    -- choosing their own role in the party (on the board, not the game's
    -- party menu). The lister's listing then shows it.
    TYPE_ROLE = "lfg-role",
    HEARTBEAT_SECONDS = 60,
    -- Guild messages go out live and, for older add-ons, again under the
    -- sync prefix: a copy heard within this long is the same message.
    COPY_SECONDS = 10,
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
            and (message.ct == nil or message.ct == true)
    end,
    [LfgProtocol.TYPE_END] = function(message)
        return message.lf == nil or message.lf == true
    end,
    [LfgProtocol.TYPE_PARTY] = function(message)
        return isCount(message.s, 2, LfgProtocol.MOST_PLAYERS) and isMembers(message.mb, message.s)
            and (message.w == nil or isShortText(message.w))
    end,
    [LfgProtocol.TYPE_CONTACT] = function(message)
        return isShortText(message.ld)
    end,
    [LfgProtocol.TYPE_ASK] = function(message)
        return (message.r == nil or ROLES[message.r] == true) and isLevel(message.l)
            and (message.c == nil or isShortText(message.c))
    end,
    [LfgProtocol.TYPE_ANSWER] = function(message)
        return LfgProtocol.ANSWERS[message.a] == true
    end,
    [LfgProtocol.TYPE_SLOT] = function(message)
        return type(message.y) == "boolean"
    end,
    [LfgProtocol.TYPE_ROLE] = function(message)
        return ROLES[message.r] == true
    end,
}

-- Every Guild LFG Board message type, for routing.
LfgProtocol.TYPES = {}
local type_
for type_ in pairs(CHECKS) do
    LfgProtocol.TYPES[type_] = true
end

-- A listing message carrying `fields` (k, p, lo, hi, r, s, x, no, mb, aj, ct),
-- as LfgListing's Announcement gives them.
function LfgProtocol.Listing(fields)
    local message = { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_LISTING }
    local name, value
    for name, value in pairs(fields) do
        message[name] = value
    end
    return message
end

-- The listing's end; `left` when it ended because the sender left the
-- party.
function LfgProtocol.End(left)
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_END, lf = left == true or nil }
end

-- The sender's unlisted party: `members` ({ name, classToken?, level? },
-- the leader first) and where it is (`place`, a dungeon or zone, or nil).
function LfgProtocol.Party(members, place)
    local list = {}
    local index
    for index = 1, #members do
        local member = members[index]
        list[index] = { n = member.name, c = member.classToken, l = member.level }
    end
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_PARTY, s = #list, mb = list, w = place }
end

-- A contact claim for the party led by `leaderName`.
function LfgProtocol.Contact(leaderName)
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_CONTACT, ld = leaderName }
end

-- Asking to join as `role` (a dungeon's; nil otherwise), at `level`, as a
-- `classToken`.
function LfgProtocol.Ask(role, level, classToken)
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_ASK, r = role, l = level, c = classToken }
end

-- The answer `answer` (invited, declined, expired or roleFilled) to an ask.
function LfgProtocol.Answer(answer)
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_ANSWER, a = answer }
end

-- The answer to "fill the empty slot?": `yes` posts it.
function LfgProtocol.Slot(yes)
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_SLOT, y = yes == true }
end

-- A message's contents as one string, so two copies of it (the live one
-- and the one under the sync prefix) can be told for the same: its fields
-- in order, nested tables (the members, the open roles) included.
function LfgProtocol.Fingerprint(message)
    local function flat(value, depth)
        if type(value) ~= "table" then
            return type(value) .. ":" .. tostring(value)
        end
        if depth > 3 then
            return "{...}"
        end
        local keys = {}
        local key
        for key in pairs(value) do
            table.insert(keys, key)
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        local parts = {}
        local index
        for index = 1, #keys do
            parts[index] = tostring(keys[index]) .. "=" .. flat(value[keys[index]], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return flat(message, 0)
end

-- Why `message` isn't understood ("version 2", "unknown type", or for a
-- listing the first field that's wrong), or nil when it is. For /agf probe
-- lfg, so a listing that never shows can be traced.
function LfgProtocol.Problem(message)
    if type(message) ~= "table" then
        return "not a table"
    end
    if message.v ~= LfgProtocol.VERSION then
        return "version " .. tostring(message.v)
    end
    local check = CHECKS[message.t]
    if check == nil then
        return "unknown type " .. tostring(message.t)
    end
    if check(message) == true then
        return nil
    end
    if message.t ~= LfgProtocol.TYPE_LISTING then
        return "bad fields"
    end
    local checks = {
        { "kind", LfgProtocol.KINDS[message.k] == true },
        { "levels", isRange(message) },
        { "purpose", message.k == "raid" and (message.p == nil or isShortText(message.p)) or isShortText(message.p) },
        { "roles", message.k == "dungeon" and isOpenRoles(message.r) or message.k ~= "dungeon" and message.r == nil },
        { "size", isCount(message.x, 1, LfgProtocol.MOST_PLAYERS) and isCount(message.s, 1, message.x) },
        { "members", isMembers(message.mb, message.s) },
        { "note", message.no == nil or isShortText(message.no) },
        { "asks", type(message.aj) == "boolean" },
        { "contact", message.ct == nil or message.ct == true },
    }
    local index
    for index = 1, #checks do
        if not checks[index][2] then
            return "bad " .. checks[index][1]
        end
    end
    return "bad fields"
end

-- A party member's own role, `role`, for the lister.
function LfgProtocol.Role(role)
    return { v = LfgProtocol.VERSION, t = LfgProtocol.TYPE_ROLE, r = role }
end

-- Whether `message` is a Guild LFG Board message this version understands.
function LfgProtocol.IsValid(message)
    if type(message) ~= "table" or message.v ~= LfgProtocol.VERSION then
        return false
    end
    local check = CHECKS[message.t]
    return check ~= nil and check(message) == true
end
