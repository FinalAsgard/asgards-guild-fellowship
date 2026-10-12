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
}
addon.GroupFinderProtocol = GroupFinderProtocol

local function isText(value)
    return type(value) == "string" and value ~= ""
end

-- Each type and the check its fields must pass.
local CHECKS = {
    [GroupFinderProtocol.TYPE_ASK] = function()
        return true
    end,
    [GroupFinderProtocol.TYPE_AVAILABLE] = function(message)
        return isText(message.c) and type(message.a) == "boolean"
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

-- Whether `message` is a Group Finder message this version understands.
function GroupFinderProtocol.IsValid(message)
    if type(message) ~= "table" or message.v ~= GroupFinderProtocol.VERSION then
        return false
    end
    local check = CHECKS[message.t]
    return check ~= nil and check(message) == true
end
