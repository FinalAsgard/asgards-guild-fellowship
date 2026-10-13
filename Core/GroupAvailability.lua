local _, addon = ...

-- Who runs the add-on and is available for a group. Opening the Group
-- Finder asks the guild ("gf-ask"); every other online add-on user replies
-- ("gf-available") after a short random delay, so replies are spread out,
-- with their current character and whether they're available. A player is
-- unavailable while Do Not Disturb is on, or while they're in a group or
-- inside an instance. Nothing is sent while the player is busy (combat, a
-- boss encounter or a keystone run). "Has the add-on" means "replied";
-- there is no heartbeat.
--
-- Pure: the transport, timers and game facts are passed in.
--   send(message)            sends to the guild
--   after(seconds, callback) -> false when there are no timers
--   random(low, high)        -> a whole number from low to high
--   selfKey()                -> the logged-in character's key, or nil
--   keyOf(sender)            -> the key for a sender's name, or nil
--   doNotDisturb()           -> whether Do Not Disturb is on
--   occupied()               -> whether the player is in a group or instance
--   busy()                   -> whether the player is in combat or the like
--   onChanged()              called after the replies changed
local GroupAvailability = {
    -- A reply waits a random whole number of seconds in this range.
    REPLY_MIN = 1,
    REPLY_MAX = 5,
}
addon.GroupAvailability = GroupAvailability

local Availability = {}
Availability.__index = Availability

function GroupAvailability.Create(options)
    local function none() end
    return setmetatable({
        send = options.send,
        after = options.after or function()
            return false
        end,
        random = options.random or function(low)
            return low
        end,
        selfKey = options.selfKey,
        keyOf = options.keyOf,
        doNotDisturb = options.doNotDisturb or function()
            return false
        end,
        occupied = options.occupied or function()
            return false
        end,
        busy = options.busy or function()
            return false
        end,
        onChanged = options.onChanged or none,
        replies = {},
    }, Availability)
end

-- Whether this player would reply as available now.
function Availability:IsAvailable()
    return not self.doNotDisturb() and not self.occupied()
end

-- Asks the guild who is available. The replies from the last ask are
-- forgotten. Returns false when nothing was sent (the player is busy).
function Availability:Ask()
    self.replies = {}
    pcall(self.onChanged)
    if self.busy() then
        return false
    end
    return self.send(addon.GroupFinderProtocol.Ask()) ~= false
end

-- Replies to an ask, after a short random delay. Only one reply waits at a
-- time, whoever asked.
function Availability:OnAsk(sender)
    if self.replyPending then
        return
    end
    self.replyPending = true
    local function reply()
        self.replyPending = false
        local key = self.selfKey()
        if key == nil or self.busy() then
            return
        end
        self.send(addon.GroupFinderProtocol.Available(key, self:IsAvailable()))
    end
    if not self.after(self.random(GroupAvailability.REPLY_MIN, GroupAvailability.REPLY_MAX), reply) then
        reply()
    end
end

-- Records a reply from `sender`.
function Availability:OnAvailable(message, sender)
    local key = self.keyOf(sender)
    if key == nil then
        return
    end
    self.replies[key] = { key = key, sender = sender, character = message.c, available = message.a }
    pcall(self.onChanged)
end

-- Hands a received Group Finder message to its handler. The game echoes
-- guild messages back to their sender, so this player's own are skipped.
-- Returns false for a message it ignores.
function Availability:OnMessage(message, sender)
    local protocol = addon.GroupFinderProtocol
    if not protocol.IsValid(message) or type(sender) ~= "string" then
        return false
    end
    local senderKey = self.keyOf(sender)
    if senderKey == nil or senderKey == self.selfKey() then
        return false
    end
    if message.t == protocol.TYPE_ASK then
        self:OnAsk(sender)
    elseif message.t == protocol.TYPE_AVAILABLE then
        self:OnAvailable(message, sender)
    end
    return true
end

-- The guildmates who replied to the last ask, sorted by key, each
-- { key, sender, character, available }.
function Availability:Replies()
    local list = {}
    local _, reply
    for _, reply in pairs(self.replies) do
        table.insert(list, reply)
    end
    table.sort(list, function(a, b)
        return a.key < b.key
    end)
    return list
end
