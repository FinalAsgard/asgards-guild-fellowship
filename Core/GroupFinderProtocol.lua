local _, addon = ...

-- The Group Finder's messages between add-on users, and their validation.
-- Every message is a table { v = VERSION, t = type, ... } sent to the guild
-- through the add-on's comm endpoint. A message with another version, a
-- type this version doesn't know, or fields of the wrong shape is ignored,
-- so mixed add-on versions in one guild never break each other. Types are
-- prefixed "gf-" so they never clash with guild sync's, Guild Greet's or
-- Guild Recruit's on the same endpoint. Pure: it never touches the game.
local GroupFinderProtocol = {
    VERSION = 1,
    -- { v, t }: who runs the add-on and is available? Sent when an
    -- organizer opens the Group Finder.
    TYPE_ASK = "gf-ask",
    -- { v, t, c = the replier's current character (key), a = whether they're
    -- available }: the reply to an ask.
    TYPE_AVAILABLE = "gf-available",
    -- Targeted messages carry `to`, the recipient's character key; every
    -- other client ignores them.
    -- { v, t, to, id = the request's id, dn = the dungeon's name, lo, hi =
    -- its level range, r = the roles still open (each once) }: an organizer
    -- asks an invitee to join.
    TYPE_REQUEST = "gf-request",
    -- { v, t, to, id, ok = accepted?, role, c = the character key chosen,
    -- n = its name, l = its level, w = nothing left to fill? }: the
    -- invitee's answer; role, c, n and l only when accepted, w only when
    -- not (the prompt closed because no option was left).
    TYPE_ANSWER = "gf-answer",
    -- { v, t, to, id }: the organizer withdrew the request.
    TYPE_CANCEL = "gf-cancel",
    -- { v, t, to, id, r }: the roles still open for that request changed.
    TYPE_SLOTS = "gf-slots",
    -- { v, t, to, id }: nothing is left to fill; the request is withdrawn.
    TYPE_WITHDRAW = "gf-withdraw",
    -- { v, t, to, id }: the invitee joined another organizer's group.
    TYPE_JOINED_ELSEWHERE = "gf-joined-elsewhere",
    -- { v, t, dn, lo, hi, s = the five slots in layout order, each { r =
    -- role, n = name?, l = level?, k = character key?, c = class token?, w =
    -- an invitee not in the party yet? } }: the organizer's group as it is
    -- now, to the whole guild. Sent whenever it changes, every
    -- GROUP_RESEND_SECONDS while it lasts, and in answer to an ask. The
    -- sender is the organizer.
    TYPE_GROUP = "gf-group",
    -- { v, t }: the sender's group ended.
    TYPE_GROUP_END = "gf-group-end",
    -- { v, t, to, id, role, c, n, l }: a guildmate offers to fill an open
    -- `role` in organizer `to`'s group with character `c` (named `n`, at
    -- level `l`).
    TYPE_OFFER = "gf-offer",
    -- { v, t, to, id, ok }: the organizer accepted the offer `id`, or not.
    TYPE_OFFER_ANSWER = "gf-offer-answer",
    -- { v, t, to, role }: a party member asks organizer `to` to put them in
    -- `role`.
    TYPE_ROLE = "gf-role",
    -- { v, t, to, role, c, n, l }: a party member will come as their alt `c`
    -- (named `n`, at level `l`) instead, in `role`.
    TYPE_ALT = "gf-alt",
    GROUP_RESEND_SECONDS = 60,
}
addon.GroupFinderProtocol = GroupFinderProtocol

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local ROLES = { tank = true, healer = true, dps = true }

local function isLevel(value)
    return type(value) == "number" and value >= 1 and value == math.floor(value)
end

-- A non-empty list of distinct roles.
local function isOpenRoles(roles)
    if type(roles) ~= "table" or #roles == 0 or #roles > 3 then
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

local function isTargeted(message)
    return isText(message.to) and isText(message.id)
end

-- A character offered: { role, c, n, l } on `message`.
local function isCharacter(message)
    return ROLES[message.role] == true and isText(message.c) and isText(message.n) and isLevel(message.l)
end

-- A broadcast group slot: a role, and who fills it when anyone does.
local function isGroupSlot(slot)
    if type(slot) ~= "table" or not ROLES[slot.r] then
        return false
    end
    if slot.n == nil then
        return slot.l == nil and slot.k == nil and slot.w == nil and slot.c == nil
    end
    return isText(slot.n) and (slot.l == nil or isLevel(slot.l)) and (slot.k == nil or isText(slot.k))
        and (slot.c == nil or isText(slot.c)) and (slot.w == nil or type(slot.w) == "boolean")
end

local function isGroupSlots(slots)
    if type(slots) ~= "table" or #slots ~= 5 then
        return false
    end
    local index
    for index = 1, #slots do
        if not isGroupSlot(slots[index]) then
            return false
        end
    end
    return true
end

-- Each type and the check its fields must pass.
local CHECKS = {
    [GroupFinderProtocol.TYPE_ASK] = function()
        return true
    end,
    [GroupFinderProtocol.TYPE_AVAILABLE] = function(message)
        return isText(message.c) and type(message.a) == "boolean"
    end,
    [GroupFinderProtocol.TYPE_REQUEST] = function(message)
        return isTargeted(message) and isText(message.dn) and isLevel(message.lo) and isLevel(message.hi)
            and message.lo <= message.hi and isOpenRoles(message.r)
    end,
    [GroupFinderProtocol.TYPE_ANSWER] = function(message)
        if not isTargeted(message) or type(message.ok) ~= "boolean" then
            return false
        end
        if message.w ~= nil and (type(message.w) ~= "boolean" or message.ok) then
            return false
        end
        return not message.ok
            or (ROLES[message.role] == true and isText(message.c) and isText(message.n) and isLevel(message.l))
    end,
    [GroupFinderProtocol.TYPE_CANCEL] = isTargeted,
    [GroupFinderProtocol.TYPE_SLOTS] = function(message)
        return isTargeted(message) and isOpenRoles(message.r)
    end,
    [GroupFinderProtocol.TYPE_WITHDRAW] = isTargeted,
    [GroupFinderProtocol.TYPE_JOINED_ELSEWHERE] = isTargeted,
    [GroupFinderProtocol.TYPE_GROUP] = function(message)
        return isText(message.dn) and isLevel(message.lo) and isLevel(message.hi) and message.lo <= message.hi
            and isGroupSlots(message.s)
    end,
    [GroupFinderProtocol.TYPE_GROUP_END] = function()
        return true
    end,
    [GroupFinderProtocol.TYPE_OFFER] = function(message)
        return isTargeted(message) and isCharacter(message)
    end,
    [GroupFinderProtocol.TYPE_OFFER_ANSWER] = function(message)
        return isTargeted(message) and type(message.ok) == "boolean"
    end,
    [GroupFinderProtocol.TYPE_ROLE] = function(message)
        return isText(message.to) and ROLES[message.role] == true
    end,
    [GroupFinderProtocol.TYPE_ALT] = function(message)
        return isText(message.to) and isCharacter(message)
    end,
}

-- Every Group Finder message type, for routing.
GroupFinderProtocol.TYPES = {}
local type_
for type_ in pairs(CHECKS) do
    GroupFinderProtocol.TYPES[type_] = true
end

function GroupFinderProtocol.Ask()
    return { v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_ASK }
end

function GroupFinderProtocol.Available(character, available)
    return {
        v = GroupFinderProtocol.VERSION,
        t = GroupFinderProtocol.TYPE_AVAILABLE,
        c = character,
        a = available == true,
    }
end

-- Asks `to` to join: request `id` for `dungeon` ({ name, minLevel,
-- maxLevel }), with `openRoles` still open.
function GroupFinderProtocol.Request(to, id, dungeon, openRoles)
    return {
        v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_REQUEST, to = to, id = id,
        dn = dungeon.name, lo = dungeon.minLevel, hi = dungeon.maxLevel, r = openRoles,
    }
end

-- Accepts request `id` from organizer `to` with `option` ({ role, key, name,
-- level }), or declines it when `option` is nil; `nothingLeft` says the
-- decline is because no option was left.
function GroupFinderProtocol.Answer(to, id, option, nothingLeft)
    local message = { v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_ANSWER, to = to, id = id }
    message.ok = option ~= nil
    if option == nil and nothingLeft then
        message.w = true
    end
    if option ~= nil then
        message.role = option.role
        message.c = option.key
        message.n = option.name
        message.l = option.level
    end
    return message
end

local function targeted(kind)
    return function(to, id)
        return { v = GroupFinderProtocol.VERSION, t = kind, to = to, id = id }
    end
end

GroupFinderProtocol.Cancel = targeted(GroupFinderProtocol.TYPE_CANCEL)
GroupFinderProtocol.Withdraw = targeted(GroupFinderProtocol.TYPE_WITHDRAW)
GroupFinderProtocol.JoinedElsewhere = targeted(GroupFinderProtocol.TYPE_JOINED_ELSEWHERE)

-- Tells invitee `to` the roles still open for request `id`.
function GroupFinderProtocol.Slots(to, id, openRoles)
    return { v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_SLOTS, to = to, id = id, r = openRoles }
end

-- The group for `dungeon` ({ name, minLevel, maxLevel }) with `slots`
-- (each { r, n?, l?, k?, c?, w? }).
function GroupFinderProtocol.Group(dungeon, slots)
    return {
        v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_GROUP,
        dn = dungeon.name, lo = dungeon.minLevel, hi = dungeon.maxLevel, s = slots,
    }
end

function GroupFinderProtocol.GroupEnd()
    return { v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_GROUP_END }
end

-- Offers organizer `to` `option` ({ role, key, name, level }) as offer `id`.
function GroupFinderProtocol.Offer(to, id, option)
    return {
        v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_OFFER, to = to, id = id,
        role = option.role, c = option.key, n = option.name, l = option.level,
    }
end

function GroupFinderProtocol.OfferAnswer(to, id, accepted)
    return { v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_OFFER_ANSWER, to = to, id = id,
        ok = accepted == true }
end

function GroupFinderProtocol.Role(to, role)
    return { v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_ROLE, to = to, role = role }
end

-- Tells organizer `to` the sender comes as `option` ({ role, key, name,
-- level }) instead.
function GroupFinderProtocol.Alt(to, option)
    return {
        v = GroupFinderProtocol.VERSION, t = GroupFinderProtocol.TYPE_ALT, to = to,
        role = option.role, c = option.key, n = option.name, l = option.level,
    }
end

-- Whether `message` is a Group Finder message this version understands.
function GroupFinderProtocol.IsValid(message)
    if type(message) ~= "table" or message.v ~= GroupFinderProtocol.VERSION then
        return false
    end
    local check = CHECKS[message.t]
    return check ~= nil and check(message) == true
end
