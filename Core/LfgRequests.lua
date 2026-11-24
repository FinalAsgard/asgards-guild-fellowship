local _, addon = ...

-- A listing leader's incoming Ask to join requests, in the order they
-- came; several stack. One per asker: asking again replaces their last.
-- Pure: requests are handed in.
local LfgRequests = {}
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

-- A request { key, name, sender, classToken?, level, role? } came in. True
-- when it's new (not one replacing the same asker's).
function Requests:Add(request)
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
