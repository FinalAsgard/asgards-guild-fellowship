local _, addon = ...

-- The organizer's group: the dungeon, and the fixed 5-player layout (1 tank,
-- 1 healer, 3 DPS) filled from the real party. A party member takes the
-- slot for the role the game assigned them (Retail), else the role the
-- organizer assigned them, else the first open role their class can fill
-- (tank, then healer, then DPS). Party members outside the guild take slots
-- too. The session lasts until End, or until the organizer leaves the party;
-- closing the window doesn't end it. Pure: party facts are handed in.
--
-- Requests: the organizer asks a guildmate to join. A request is pending
-- until the invitee answers, the organizer cancels it, or REQUEST_SECONDS
-- pass (expired). Accepting locks the invitee into a slot for the role
-- they chose, ahead of anyone without a role from the game or the
-- organizer; an answer for a role no longer open withdraws the request.
-- Each pending request remembers the roles it offered; when slots fill or
-- free up, SlotChanges says which invitees need the new open roles, and
-- withdraws the requests nothing is left for. An invitee who joined
-- another organizer's group leaves the request "joined-elsewhere".
--
-- Getting an accepted invitee into the party is the organizer's click:
-- InviteState says whether their chosen character is online to invite
-- ("ready") or not yet ("waiting"). Once that character is in the party
-- (matched by `rosterKey`, its key in the guild roster), it takes the
-- invitee's slot as a party member.
local GroupSession = {
    -- Every party member fills a slot as accepted.
    ACCEPTED = "accepted",
    -- How long a request waits for an answer.
    REQUEST_SECONDS = 120,
    PENDING = "pending",
    DECLINED = "declined",
    EXPIRED = "expired",
    CANCELLED = "cancelled",
    WITHDRAWN = "withdrawn",
    JOINED_ELSEWHERE = "joined-elsewhere",
}
addon.GroupSession = GroupSession

local TANK, HEALER, DPS = "tank", "healer", "dps"
GroupSession.LAYOUT = {
    { id = "tank", role = TANK },
    { id = "healer", role = HEALER },
    { id = "dps1", role = DPS },
    { id = "dps2", role = DPS },
    { id = "dps3", role = DPS },
}

local Session = {}
Session.__index = Session

-- `roles` is the client's RoleCatalog.
function GroupSession.Create(roles)
    local session = setmetatable({ roles = roles, active = false }, Session)
    session:clear()
    return session
end

function Session:clear()
    self.dungeon = nil
    self.assignments = {}
    self.members = {}
    self.grouped = false
    self.slots = {}
    self.requests = {}
    self.requestCount = 0
end

-- Starts a group for the dungeon with `dungeonId`. Starting again while one
-- is going just changes the dungeon.
function Session:Start(dungeonId)
    if dungeonId == nil then
        return false
    end
    if not self.active then
        self:clear()
        self.active = true
    end
    self.dungeon = dungeonId
    return true
end

function Session:IsActive()
    return self.active
end

-- The dungeon's id, or nil when no group is going.
function Session:Dungeon()
    return self.dungeon
end

-- Changes the dungeon, keeping every filled slot.
function Session:SetDungeon(dungeonId)
    if not self.active or dungeonId == nil then
        return false
    end
    self.dungeon = dungeonId
    return true
end

-- Ends the group: the slots empty and the dungeon is forgotten.
function Session:End()
    self.active = false
    self:clear()
end

-- Puts the party member `key` in a slot for `role`, where the game hasn't
-- assigned them one. The organizer picks their own role the same way.
function Session:Assign(key, role)
    if not self.active or key == nil or not addon.RoleCatalog.IsRole(role) then
        return false
    end
    self.assignments[key] = role
    self:place()
    return true
end

-- The party as it is now: `members` ({ key, name, classToken, level,
-- assignedRole, inGuild, isPlayer, rosterKey? } each, the organizer
-- included; rosterKey is the member's key in the guild roster) and
-- whether the organizer is in a group. Leaving the party after being in
-- one ends the session. Returns false when that happened, with the
-- requests that were still waiting (now cancelled), so their invitees can
-- be told.
function Session:UpdateParty(members, inGroup)
    if not self.active then
        return false
    end
    if self.grouped and not inGroup then
        local dropped = self:PendingRequests()
        local index
        for index = 1, #dropped do
            dropped[index].state = GroupSession.CANCELLED
        end
        self:End()
        return false, dropped
    end
    self.grouped = inGroup == true
    self.members = type(members) == "table" and members or {}
    self:place()
    return true
end

local function emptySlots()
    local slots = {}
    local index
    for index = 1, #GroupSession.LAYOUT do
        slots[index] = { id = GroupSession.LAYOUT[index].id, role = GroupSession.LAYOUT[index].role }
    end
    return slots
end

local function openSlot(slots, role)
    local index
    for index = 1, #slots do
        if slots[index].role == role and slots[index].member == nil then
            return slots[index]
        end
    end
    return nil
end

-- A character name without its realm, lowercased: "Zelwindran-Area52"
-- and "zelwindran" are the same.
local function bareName(name)
    if type(name) ~= "string" then
        return nil
    end
    return string.lower(string.match(name, "^([^%-]+)") or name)
end

-- The party member who is the character an accepted `request`'s invitee
-- chose, or nil. Matched by guild roster key; only when no member has that
-- key, by the name without its realm (the party gave a name that didn't
-- resolve to that key, a realm spelled differently, say), and then only a
-- member not already matched by key to another request (`byKey`).
local function joinedMember(members, request, byKey)
    local fallback
    local index
    for index = 1, #members do
        local member = members[index]
        if not member.isPlayer then
            if member.rosterKey ~= nil and member.rosterKey == request.character.key then
                return member
            end
            local name = bareName(member.name)
            if fallback == nil and not byKey[member.key] and name ~= nil
                and name == bareName(request.character.name)
            then
                fallback = member
            end
        end
    end
    return fallback
end

-- Fills the slots: accepted invitees first, then the party, chosen roles
-- first (the game's, then the organizer's), so a default never takes a
-- slot someone was put in.
function Session:place()
    local slots, defaults = emptySlots(), {}
    -- An invitee who joined the party keeps the role they chose.
    local joinedRole = {}
    -- Members whose roster key is an accepted invitee's: never taken by a
    -- name match for another request.
    local byKey = {}
    local index
    for index = 1, #self.requests do
        local request = self.requests[index]
        local memberIndex
        for memberIndex = 1, #self.members do
            local member = self.members[memberIndex]
            if request.state == GroupSession.ACCEPTED and member.rosterKey ~= nil
                and member.rosterKey == request.character.key
            then
                byKey[member.key] = true
            end
        end
    end
    for index = 1, #self.requests do
        local request = self.requests[index]
        request.inParty = false
        if request.state == GroupSession.ACCEPTED then
            local member = joinedMember(self.members, request, byKey)
            if member ~= nil then
                request.inParty = true
                joinedRole[member.key] = request.role
            end
        end
    end
    for index = 1, #self.requests do
        local request = self.requests[index]
        if request.state == GroupSession.ACCEPTED and not request.inParty then
            local slot = openSlot(slots, request.role)
            if slot ~= nil then
                slot.member = request.character
                slot.state = GroupSession.ACCEPTED
                slot.request = request.id
            end
        end
    end
    for index = 1, #self.members do
        local member = self.members[index]
        local role = member.assignedRole
        if not addon.RoleCatalog.IsRole(role) then
            role = joinedRole[member.key] or self.assignments[member.key]
        end
        if role ~= nil then
            local slot = openSlot(slots, role)
            if slot ~= nil then
                slot.member = member
                slot.state = GroupSession.ACCEPTED
            end
        else
            table.insert(defaults, member)
        end
    end
    for index = 1, #defaults do
        local member = defaults[index]
        local slot
        local roleIndex
        for roleIndex = 1, #addon.RoleCatalog.ROLES do
            local role = addon.RoleCatalog.ROLES[roleIndex]
            if slot == nil and self.roles:Can(member.classToken, role) then
                slot = openSlot(slots, role)
            end
        end
        if slot ~= nil then
            slot.member = member
            slot.state = GroupSession.ACCEPTED
        end
    end
    self.slots = slots
end

-- The five slots in layout order, each { id, role, member?, state? }.
function Session:Slots()
    if #self.slots == 0 then
        return emptySlots()
    end
    local copy = {}
    local index
    for index = 1, #self.slots do
        local slot = self.slots[index]
        copy[index] = { id = slot.id, role = slot.role, member = slot.member, state = slot.state, request = slot.request }
    end
    return copy
end

-- The party as last handed in.
function Session:Members()
    return self.members
end

-- Requests -------------------------------------------------------------------

-- Asks the player `target` ({ playerId, key = the character they're on,
-- label }) to join, at `now`. `owner` (the organizer's key) starts the
-- request's id, so ids from different organizers never match. Returns the
-- new pending request ({ id, playerId, to, label, state, at, roles }), or
-- nil when no group is going or that player already has one pending.
function Session:Request(target, now, owner)
    if not self.active or type(target) ~= "table" or target.key == nil or type(now) ~= "number" then
        return nil
    end
    local index
    for index = 1, #self.requests do
        local held = self.requests[index]
        if held.playerId == target.playerId and held.state == GroupSession.PENDING then
            return nil
        end
    end
    self.requestCount = self.requestCount + 1
    local request = {
        id = (owner and (owner .. ":") or "") .. tostring(now) .. "-" .. self.requestCount,
        playerId = target.playerId,
        to = target.key,
        label = target.label,
        state = GroupSession.PENDING,
        at = now,
        roles = self:OpenRoleSet(),
    }
    table.insert(self.requests, request)
    return request
end

function Session:findRequest(id)
    local index
    for index = 1, #self.requests do
        if self.requests[index].id == id then
            return self.requests[index]
        end
    end
    return nil
end

-- Every request of this group, oldest first.
function Session:Requests()
    local copy = {}
    local index
    for index = 1, #self.requests do
        copy[index] = self.requests[index]
    end
    return copy
end

-- The newest request to player `playerId`, or nil.
function Session:RequestFor(playerId)
    local index
    for index = #self.requests, 1, -1 do
        if self.requests[index].playerId == playerId then
            return self.requests[index]
        end
    end
    return nil
end

-- The requests still waiting for an answer.
function Session:PendingRequests()
    local pending = {}
    local index
    for index = 1, #self.requests do
        if self.requests[index].state == GroupSession.PENDING then
            table.insert(pending, self.requests[index])
        end
    end
    return pending
end

-- Withdraws request `id`: one still pending, or one accepted by an invitee
-- who hasn't joined the party, whose slot then opens again. Returns it, or
-- nil when it can't be withdrawn.
function Session:Cancel(id)
    local request = self:findRequest(id)
    if request == nil then
        return nil
    end
    if request.state == GroupSession.ACCEPTED and not request.inParty then
        request.state = GroupSession.CANCELLED
        self:place()
        return request
    end
    if request.state ~= GroupSession.PENDING then
        return nil
    end
    request.state = GroupSession.CANCELLED
    return request
end

-- Expires every request pending for REQUEST_SECONDS by `now`. Returns
-- those that expired.
function Session:Expire(now)
    local expired = {}
    local index
    for index = 1, #self.requests do
        local request = self.requests[index]
        if request.state == GroupSession.PENDING and now - request.at >= GroupSession.REQUEST_SECONDS then
            request.state = GroupSession.EXPIRED
            table.insert(expired, request)
        end
    end
    return expired
end

-- The invitee `from` (the character asked) answered request `id`:
-- `option` is nil for a decline, or { role, key, name, level } for the
-- slot and character they chose. A decline because nothing was left for
-- them (`nothingLeft`) withdraws the request. Returns the request's new
-- state, or nil when the answer doesn't belong to a pending request.
function Session:Answer(id, from, option, nothingLeft)
    local request = self:findRequest(id)
    if request == nil or request.state ~= GroupSession.PENDING or request.to ~= from then
        return nil
    end
    if option == nil then
        request.state = nothingLeft and GroupSession.WITHDRAWN or GroupSession.DECLINED
        return request.state
    end
    local open = false
    local roles = self:OpenRoles()
    local index
    for index = 1, #roles do
        open = open or roles[index] == option.role
    end
    if not open then
        request.state = GroupSession.WITHDRAWN
        return request.state
    end
    request.state = GroupSession.ACCEPTED
    request.role = option.role
    request.character = { key = option.key, name = option.name, level = option.level, inGuild = true, invitee = true }
    self:place()
    return request.state
end

-- Where getting the invitee in slot `slot` (from Slots) stands: "ready"
-- when their chosen character is online to invite (`isOnline(key)`),
-- "waiting" when it isn't yet, or nil for a slot without an invitee who
-- has yet to join.
function Session:InviteState(slot, isOnline)
    if slot == nil or slot.request == nil or slot.member == nil then
        return nil
    end
    local ok, online = pcall(isOnline, slot.member.key)
    if ok and online then
        return "ready"
    end
    return "waiting"
end

-- The invitee `from` joined another group instead of answering request
-- `id`. Returns whether that request was pending.
function Session:JoinedElsewhere(id, from)
    local request = self:findRequest(id)
    if request == nil or request.state ~= GroupSession.PENDING or request.to ~= from then
        return false
    end
    request.state = GroupSession.JOINED_ELSEWHERE
    return true
end

local function sameRoles(a, b)
    if #a ~= #b then
        return false
    end
    local index
    for index = 1, #a do
        if a[index] ~= b[index] then
            return false
        end
    end
    return true
end

-- After slots filled or freed up: the pending requests whose open roles
-- changed (`updates`, each now holding the new `roles`), and those nothing
-- is left for (`withdrawals`, now withdrawn).
function Session:SlotChanges()
    local updates, withdrawals = {}, {}
    local open = self:OpenRoleSet()
    local index
    for index = 1, #self.requests do
        local request = self.requests[index]
        if request.state == GroupSession.PENDING then
            if open[1] == nil then
                request.state = GroupSession.WITHDRAWN
                table.insert(withdrawals, request)
            elseif not sameRoles(open, request.roles or {}) then
                request.roles = open
                table.insert(updates, request)
            end
        end
    end
    return updates, withdrawals
end

-- The roles still open, each once, in role order.
function Session:OpenRoleSet()
    local open = {}
    local roles = self:OpenRoles()
    local index
    for index = 1, #roles do
        open[roles[index]] = true
    end
    local set = {}
    for index = 1, #addon.RoleCatalog.ROLES do
        if open[addon.RoleCatalog.ROLES[index]] then
            table.insert(set, addon.RoleCatalog.ROLES[index])
        end
    end
    return set
end

-- The roles of the slots still open, in layout order (a role once per open
-- slot).
function Session:OpenRoles()
    local open = {}
    local slots = self:Slots()
    local index
    for index = 1, #slots do
        if slots[index].member == nil then
            table.insert(open, slots[index].role)
        end
    end
    return open
end

-- The line Ask in guild posts, naming the open roles, the dungeon
-- ({ name, minLevel, maxLevel }) and its range: "LF tank, healer and 2 DPS
-- for The Deadmines (17–26), whisper me!". Nil when no role is open.
function Session:AskLine(dungeon)
    local open = self:OpenRoles()
    if open[1] == nil or type(dungeon) ~= "table" then
        return nil
    end
    local counts = { tank = 0, healer = 0, dps = 0 }
    local index
    for index = 1, #open do
        counts[open[index]] = counts[open[index]] + 1
    end
    local wanted = {}
    if counts.tank > 0 then
        table.insert(wanted, "tank")
    end
    if counts.healer > 0 then
        table.insert(wanted, "healer")
    end
    if counts.dps == 1 then
        table.insert(wanted, "DPS")
    elseif counts.dps > 1 then
        table.insert(wanted, counts.dps .. " DPS")
    end
    local roles = wanted[1]
    for index = 2, #wanted do
        roles = roles .. (index == #wanted and " and " or ", ") .. wanted[index]
    end
    return "LF " .. roles .. " for " .. dungeon.name .. " (" .. dungeon.minLevel .. "–" .. dungeon.maxLevel
        .. "), whisper me!"
end

-- Whether all five slots are filled.
function Session:IsComplete()
    if not self.active or #self.slots == 0 then
        return false
    end
    local index
    for index = 1, #self.slots do
        if self.slots[index].member == nil then
            return false
        end
    end
    return true
end
