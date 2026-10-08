local _, addon = ...

-- Guild sync's conversation between add-on users. For now it has one
-- message: an officer's edit, broadcast to the guild as it happens and
-- applied by everyone who receives it.
--
-- Every message is a table { v = PROTOCOL, t = type, ... }. A message with
-- another protocol version, or a type this version doesn't know, is ignored,
-- so mixed add-on versions in one guild never break each other.
--
-- Pure: the transport and the game's facts are passed in.
--   comm         { Broadcast(message) } sending to the guild
--   context()    -> partition, normalizer for the current guild, or nil
--   selfKey()    -> the logged-in character's key, or nil
--   isOfficer(key) -> boolean
--   now()        -> server time in seconds, or nil
--   onApplied(count) called after received facts changed the roster
local SyncSession = {
    PROTOCOL = 1,
    TYPE_FACTS = "facts",
}
addon.SyncSession = SyncSession

local Session = {}
Session.__index = Session

function SyncSession.Create(options)
    return setmetatable({
        comm = options.comm,
        context = options.context,
        selfKey = options.selfKey,
        isOfficer = options.isOfficer,
        now = options.now,
        onApplied = options.onApplied or function() end,
    }, Session)
end

function Session:Facts(partition)
    return addon.SyncFacts.Create(partition, {
        isOfficer = self.isOfficer,
        now = function()
            return self.now() or 0
        end,
    })
end

-- After this user changed main links by hand: stamps the main link of every
-- character in `keys` (a set) as theirs, now, and broadcasts them when this
-- user is an officer. Returns the facts sent, or nil when nothing was sent.
function Session:LocalEdit(keys)
    return self:StampAndSend(function(facts, author, now)
        return facts:Stamp(keys, author, now)
    end)
end

-- After this user set or cleared the alias of `key`'s player by hand: the
-- same, for that player's alias.
function Session:LocalAliasEdit(key)
    return self:StampAndSend(function(facts, author, now)
        return { facts:StampAlias(key, author, now) }
    end)
end

-- Stamps with `stamp(facts, author, now)` -> list of facts, and broadcasts
-- them when this user is an officer.
function Session:StampAndSend(stamp)
    local partition = self.context()
    local author = self.selfKey()
    local now = self.now()
    if partition == nil or author == nil or now == nil then
        return nil
    end
    local facts = stamp(self:Facts(partition), author, now)
    if facts[1] == nil or not self.isOfficer(author) then
        return nil
    end
    self.comm:Broadcast({ v = SyncSession.PROTOCOL, t = SyncSession.TYPE_FACTS, facts = facts })
    return facts
end

-- A message from `sender` (a name as the game reports it). Returns how many
-- facts it applied.
function Session:Receive(message, sender)
    if type(message) ~= "table" or message.v ~= SyncSession.PROTOCOL
        or message.t ~= SyncSession.TYPE_FACTS
    then
        return 0
    end
    local partition, normalizer = self.context()
    if partition == nil then
        return 0
    end
    local senderKey = normalizer:Key(sender)
    -- The game echoes guild messages back to their sender.
    if senderKey == nil or senderKey == self.selfKey() then
        return 0
    end
    local applied = self:Facts(partition):ApplyAll(message.facts, senderKey)
    if applied > 0 then
        self.onApplied(applied)
    end
    return applied
end
