local _, addon = ...

-- The organizer's group: the dungeon, and the fixed 5-player layout (1 tank,
-- 1 healer, 3 DPS) filled from the real party. A party member takes the
-- slot for the role the game assigned them (Retail), else the role the
-- organizer assigned them, else the first open role their class can fill
-- (tank, then healer, then DPS). Party members outside the guild take slots
-- too. The session lasts until End, or until the organizer leaves the party;
-- closing the window doesn't end it. Pure: party facts are handed in.
local GroupSession = {
    -- Every party member fills a slot as accepted.
    ACCEPTED = "accepted",
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
    self.unplaced = {}
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
-- assignedRole, inGuild, isPlayer } each, the organizer included) and
-- whether the organizer is in a group. Leaving the party after being in
-- one ends the session. Returns false when that happened.
function Session:UpdateParty(members, inGroup)
    if not self.active then
        return false
    end
    if self.grouped and not inGroup then
        self:End()
        return false
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

-- Fills the slots from the party: chosen roles first (the game's, then the
-- organizer's), so a default never takes a slot someone was put in.
function Session:place()
    local slots, unplaced, defaults = emptySlots(), {}, {}
    local index
    for index = 1, #self.members do
        local member = self.members[index]
        local role = member.assignedRole
        if not addon.RoleCatalog.IsRole(role) then
            role = self.assignments[member.key]
        end
        if role ~= nil then
            local slot = openSlot(slots, role)
            if slot ~= nil then
                slot.member = member
                slot.state = GroupSession.ACCEPTED
            else
                table.insert(unplaced, member)
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
        else
            table.insert(unplaced, member)
        end
    end
    self.slots = slots
    self.unplaced = unplaced
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
        copy[index] = { id = slot.id, role = slot.role, member = slot.member, state = slot.state }
    end
    return copy
end

-- Party members with no slot left for them.
function Session:Unplaced()
    local copy = {}
    local index
    for index = 1, #self.unplaced do
        copy[index] = self.unplaced[index]
    end
    return copy
end

-- The party as last handed in.
function Session:Members()
    return self.members
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
