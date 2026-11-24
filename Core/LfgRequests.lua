local _, addon = ...

-- A listing leader's incoming Ask to join requests, in the order they
-- came; several stack. One per asker: asking again replaces their last.
-- A request expires after EXPIRE_SECONDS; when a dungeon role fills, the
-- requests for it are declined ("role filled"), and when the party fills,
-- every one is. Pure: requests and times are handed in; what's dropped is
-- returned for the caller to answer.
local LfgRequests = {
    EXPIRE_SECONDS = 2 * 60,
}
addon.LfgRequests = LfgRequests

local Requests = {}
Requests.__index = Requests

function LfgRequests.Create()
    return setmetatable({ list = {} }, Requests)
end

local function indexOf(list, key)
    local index
    for index = 1, #list do
        if list[index].key == key then
            return index
        end
    end
    return nil
end

-- A request { key, name, sender, classToken?, level, role? } came in at
-- `now`. True when it's new (not one replacing the same asker's).
function Requests:Add(request, now)
    request.receivedAt = now
    local index = indexOf(self.list, request.key)
    if index ~= nil then
        self.list[index] = request
        return false
    end
    table.insert(self.list, request)
    return true
end

-- The request from `key`, now answered; it's returned, or nil.
function Requests:Remove(key)
    local index = indexOf(self.list, key)
    return index ~= nil and table.remove(self.list, index) or nil
end

function Requests:Get(key)
    local index = indexOf(self.list, key)
    return index ~= nil and self.list[index] or nil
end

-- The requests, oldest first.
function Requests:List()
    local copy = {}
    local index
    for index = 1, #self.list do
        copy[index] = self.list[index]
    end
    return copy
end

-- Every request is gone (the listing ended).
function Requests:Clear()
    self.list = {}
end

-- Removes the requests `drop(request)` picks, oldest first, and returns
-- them.
function Requests:dropWhere(drop)
    local kept, dropped = {}, {}
    local index
    for index = 1, #self.list do
        local request = self.list[index]
        table.insert(drop(request) and dropped or kept, request)
    end
    self.list = kept
    return dropped
end

-- The requests unanswered for EXPIRE_SECONDS by `now`, removed.
function Requests:Expire(now)
    if type(now) ~= "number" then
        return {}
    end
    return self:dropWhere(function(request)
        return type(request.receivedAt) == "number" and now - request.receivedAt >= LfgRequests.EXPIRE_SECONDS
    end)
end

-- The requests the party no longer has room for, removed: every one when
-- it's `full`, else those for a role not among `openRoles` (a dungeon's
-- open roles; nil for other kinds, whose requests carry no role).
function Requests:Filled(openRoles, full)
    local open = {}
    local index
    for index = 1, #(openRoles or {}) do
        open[openRoles[index]] = true
    end
    return self:dropWhere(function(request)
        return full == true or (openRoles ~= nil and request.role ~= nil and not open[request.role])
    end)
end
