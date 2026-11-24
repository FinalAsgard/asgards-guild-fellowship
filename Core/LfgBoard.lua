local _, addon = ...

-- The listings guildmates' add-ons announce (LfgProtocol.TYPE_LISTING): one
-- per leader, until it ends or nothing is heard of it for STALE_SECONDS (a
-- leader re-announces it every HEARTBEAT_SECONDS). It sorts them for the
-- logged-in character into Relevant, alts and Other (see Groups), and keeps
-- this player's Ask to join requests and how they stand. Pure: messages,
-- characters and times are handed in.
local LfgBoard = {
    STALE_SECONDS = 5 * 60,
    -- How often the board is looked at again with nothing new heard, so
    -- quiet listings drop.
    REFRESH_SECONDS = 30,
    -- An Ask to join nobody answers is expired after this long.
    REQUEST_SECONDS = 2 * 60,
    -- An outgoing Ask to join's states.
    PENDING = "pending",
    ACCEPTED = "accepted",
    DECLINED = "declined",
    EXPIRED = "expired",
}
addon.LfgBoard = LfgBoard

local Board = {}
Board.__index = Board

function LfgBoard.Create()
    return setmetatable({ listings = {}, ended = {}, requests = {} }, Board)
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
    self.ended[leader] = nil
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
        -- The sender is the contact, not the party's leader.
        contact = message.ct == true,
        listedAt = known ~= nil and known.listedAt or now,
        heardAt = now,
    }
end

-- Leader `leader`'s listing ended. When it ended because they `left` the
-- party (or logged off), it's kept for Ended, so a guildmate still in the
-- party can take it over. The player's request to it goes with it, so a
-- new listing of theirs can be asked again.
function Board:OnEnd(leader, left)
    if left and self.listings[leader] ~= nil then
        self.ended[leader] = self.listings[leader]
    end
    self.listings[leader] = nil
    self.requests[leader] = nil
end

-- The listing leader `id` had when they left their party, or nil.
function Board:Ended(id)
    return id ~= nil and self.ended[id] or nil
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

-- The listings at `now` sorted for the logged-in character (`current`, {
-- level, roles }) and its `alts` (a list of { name, level, roles }), each
-- by LfgRelevance and newest first:
--   relevant  those `current` could join
--   alts      of the rest, those an alt could join, each { listing, alt }
--             with the first alt that fits
--   other     the rest: full, or nothing of the player's fits
function Board:Groups(now, current, alts)
    local groups = { relevant = {}, alts = {}, other = {} }
    local listings = self:Listings(now)
    local index
    for index = 1, #listings do
        local listing = listings[index]
        if addon.LfgRelevance.Fits(listing, current) then
            table.insert(groups.relevant, listing)
        else
            local fitting
            local altIndex
            for altIndex = 1, #(alts or {}) do
                if fitting == nil and addon.LfgRelevance.Fits(listing, alts[altIndex]) then
                    fitting = alts[altIndex]
                end
            end
            if fitting ~= nil then
                table.insert(groups.alts, { listing = listing, alt = fitting })
            else
                table.insert(groups.other, listing)
            end
        end
    end
    return groups
end

-- How many listings `current` could join at `now`.
function Board:RelevantCount(now, current)
    return #self:Groups(now, current, nil).relevant
end

-- Outgoing Ask to join requests ----------------------------------------------------

-- The player asked to join leader `id`'s listing as `role` (or none) at
-- `now`. Asking again starts a new request.
function Board:Ask(id, role, now)
    self.requests[id] = { id = id, role = role, state = LfgBoard.PENDING, askedAt = now }
end

local ANSWERED = {
    invited = LfgBoard.ACCEPTED,
    declined = LfgBoard.DECLINED,
    roleFilled = LfgBoard.DECLINED,
    expired = LfgBoard.EXPIRED,
}

-- Leader `id` answered (an LfgProtocol answer). Only a pending request
-- changes; true when it did.
function Board:OnAnswer(id, answer)
    local request = id ~= nil and self.requests[id] or nil
    if request == nil or request.state ~= LfgBoard.PENDING or ANSWERED[answer] == nil then
        return false
    end
    request.state = ANSWERED[answer]
    request.roleFilled = answer == "roleFilled" or nil
    return true
end

-- The player's request to join leader `id`'s listing, or nil. One nobody
-- answered in REQUEST_SECONDS has expired by `now`.
function Board:Request(id, now)
    local request = id ~= nil and self.requests[id] or nil
    if request ~= nil and request.state == LfgBoard.PENDING and type(now) == "number"
        and type(request.askedAt) == "number" and now - request.askedAt >= LfgBoard.REQUEST_SECONDS
    then
        request.state = LfgBoard.EXPIRED
    end
    return request
end

-- What an Ask to join button reads for `request` (or none), and whether
-- it can be clicked: asking again is allowed once a request expired.
function LfgBoard.AskButton(request)
    if request == nil then
        return "Ask to join", true
    elseif request.state == LfgBoard.PENDING then
        return "Asked \194\183 pending", false
    elseif request.state == LfgBoard.ACCEPTED then
        return "Invited", false
    elseif request.state == LfgBoard.DECLINED then
        return request.roleFilled and "Declined \194\183 role filled" or "Declined", false
    end
    return "Expired \194\183 ask again", true
end
