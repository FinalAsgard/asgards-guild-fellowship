local _, addon = ...

-- The listings guildmates' add-ons announce (LfgProtocol.TYPE_LISTING): one
-- per leader, until it ends or nothing is heard of it for STALE_SECONDS (a
-- leader re-announces it every HEARTBEAT_SECONDS). Pure: messages and times
-- are handed in.
local LfgBoard = {
    STALE_SECONDS = 5 * 60,
}
addon.LfgBoard = LfgBoard

local Board = {}
Board.__index = Board

function LfgBoard.Create()
    return setmetatable({ listings = {} }, Board)
end

local function bareName(name)
    return string.match(name or "", "^([^%-]+)") or name
end

-- Leader `leader` (their character key, named `sender`) announced listing
-- `message` at `now`. A listing heard again keeps when it was first heard.
function Board:OnListing(message, leader, sender, now)
    local known = self.listings[leader]
    local members = {}
    local index
    for index = 1, #message.mb do
        local member = message.mb[index]
        members[index] = { name = member.n, classToken = member.c, level = member.l, role = member.r }
    end
    local openRoles = {}
    for index = 1, #(message.r or {}) do
        openRoles[index] = message.r[index]
    end
    self.listings[leader] = {
        id = leader,
        leader = bareName(sender) or leader,
        sender = sender,
        kind = message.k,
        purpose = message.p,
        minLevel = message.lo,
        maxLevel = message.hi,
        openRoles = message.k == "dungeon" and openRoles or nil,
        size = message.s,
        maxSize = message.x,
        note = message.no,
        members = members,
        acceptsAsk = message.aj == true,
        listedAt = known ~= nil and known.listedAt or now,
        heardAt = now,
    }
end

-- Leader `leader`'s listing ended.
function Board:OnEnd(leader)
    self.listings[leader] = nil
end

local function isStale(listing, now)
    return type(now) == "number" and now - listing.heardAt >= LfgBoard.STALE_SECONDS
end

-- Leader `id`'s listing, unless it's gone stale by `now`.
function Board:Get(id, now)
    local listing = id ~= nil and self.listings[id] or nil
    if listing == nil or isStale(listing, now) then
        return nil
    end
    return listing
end

-- The listings at `now`, newest first; stale ones are dropped.
function Board:Listings(now)
    local list = {}
    local id, listing
    for id, listing in pairs(self.listings) do
        if isStale(listing, now) then
            self.listings[id] = nil
        else
            table.insert(list, listing)
        end
    end
    table.sort(list, function(a, b)
        if a.listedAt ~= b.listedAt then
            return a.listedAt > b.listedAt
        end
        return a.id < b.id
    end)
    return list
end
