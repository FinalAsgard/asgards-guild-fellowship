local _, addon = ...

-- The operations that organize players, used by conflict resolution (and,
-- in later slices, the right-click menu and edit panel). Pure: it works on a
-- FellowshipStore partition and never touches the game, and it never writes
-- guild notes.
local PlayerService = {
    -- Kinds whose suggestion can be applied. The others (unresolved,
    -- ambiguous, cycle, self reference, chain too long, competing aliases)
    -- have nothing to apply and can only be dismissed.
    ACCEPTABLE = { main = true, alias = true },
}
addon.PlayerService = PlayerService

local Service = {}
Service.__index = Service

function PlayerService.Create(partition)
    return setmetatable({ partition = partition }, Service)
end

local function findConflict(partition, character, kind)
    local conflicts = partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        if conflicts[index].character == character and conflicts[index].kind == kind then
            return conflicts[index]
        end
    end
    return nil
end

-- Applies a conflict's suggestion. Accepted suggestions are marked as coming
-- from a note, since that's where they came from. Returns false and a reason
-- when nothing can be applied (the conflict is then left in the queue).
function Service:AcceptConflict(character, kind)
    local conflict = findConflict(self.partition, character, kind)
    if conflict == nil then
        return false, "that conflict is no longer pending"
    end
    if not PlayerService.ACCEPTABLE[kind] or type(conflict.suggestion) ~= "table" then
        return false, "there is nothing to apply; dismiss it instead"
    end

    local source = addon.FellowshipStore.SOURCE_NOTE
    if kind == "main" then
        if self.partition:GetCharacter(conflict.suggestion.main) == nil then
            return false, "the suggested main is no longer known"
        end
        if not self.partition:JoinPlayerOf(character, conflict.suggestion.main, source) then
            return false, "the character could not be moved"
        end
    else
        local record = self.partition:GetCharacter(character)
        if record == nil or not self.partition:SetAlias(record.player, conflict.suggestion.alias, source) then
            return false, "the alias could not be set"
        end
    end
    self.partition:RemoveConflict(character, kind)
    self.partition:ClearRejected(character, kind)
    return true
end

-- Keeps the database as it is and remembers the note's fingerprint, so the
-- same suggestion isn't queued again until the note changes.
function Service:RejectConflict(character, kind)
    local conflict = self.partition:RemoveConflict(character, kind)
    if conflict == nil then
        return false, "that conflict is no longer pending"
    end
    if conflict.fingerprint ~= nil then
        self.partition:SetRejected(character, kind, conflict.fingerprint)
    end
    return true
end

-- Resolves every pending conflict. Accept all applies every suggestion it
-- can and dismisses the rest, so the queue always ends up empty.
function Service:AcceptAll()
    local pending = {}
    local conflicts = self.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        table.insert(pending, conflicts[index])
    end
    local accepted, dismissed = 0, 0
    for index = 1, #pending do
        local conflict = pending[index]
        if self:AcceptConflict(conflict.character, conflict.kind) then
            accepted = accepted + 1
        elseif self:RejectConflict(conflict.character, conflict.kind) then
            dismissed = dismissed + 1
        end
    end
    return accepted, dismissed
end

function Service:RejectAll()
    local pending = {}
    local conflicts = self.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        table.insert(pending, conflicts[index])
    end
    local rejected = 0
    for index = 1, #pending do
        if self:RejectConflict(pending[index].character, pending[index].kind) then
            rejected = rejected + 1
        end
    end
    return rejected
end
