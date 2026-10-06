local _, addon = ...

-- The operations that organize players, used by conflict resolution (and,
-- in later slices, the right-click menu and edit panel). Pure: it works on a
-- FellowshipStore partition and never touches the game, and it never writes
-- guild notes.
local PlayerService = {
    -- Kinds whose suggestion can be applied (an unresolved marker records
    -- its name as an out-of-guild main; a promotion confirms the new acting
    -- main). The others (ambiguous, cycle, self reference, chain too long,
    -- competing aliases) have nothing to apply and can only be dismissed.
    ACCEPTABLE = { main = true, alias = true, unresolved = true, promotion = true },
}
addon.PlayerService = PlayerService

local Service = {}
Service.__index = Service

-- options.now: function() -> timestamp, used for history dates.
function PlayerService.Create(partition, options)
    options = options or {}
    return setmetatable({
        partition = partition,
        now = options.now or function()
            return 0
        end,
    }, Service)
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
    elseif kind == "alias" then
        local record = self.partition:GetCharacter(character)
        if record == nil or not self.partition:SetAlias(record.player, conflict.suggestion.alias, source) then
            return false, "the alias could not be set"
        end
    elseif kind == "unresolved" then
        local record = self.partition:GetCharacter(character)
        if record == nil or type(conflict.suggestion.outOfGuild) ~= "string" then
            return false, "there is nothing to apply; dismiss it instead"
        end
        self.partition:AddHistory(record.player, {
            name = conflict.suggestion.outOfGuild,
            role = "main",
            since = self.now(),
            reason = "out of guild",
        })
    end
    -- A promotion needs no change: accepting confirms the new acting main.
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
    -- A rejected promotion keeps the acting main; choose another with
    -- MakeMain. It isn't remembered, since it doesn't come from a note.
    if conflict.fingerprint ~= nil and kind ~= "promotion" then
        self.partition:SetRejected(character, kind, conflict.fingerprint)
    end
    return true
end

-- Makes `key` its player's main ("Make this the main"; also how an automatic
-- promotion is reassigned). The character must be in the guild, so the
-- acting main always is. Any pending promotion for the player is resolved.
function Service:MakeMain(key)
    local character = self.partition:GetCharacter(key)
    if character == nil then
        return false, "that character is not known"
    end
    if not self.partition:IsInGuild(key) then
        return false, "only a character in the guild can be the main"
    end
    local playerId = character.player
    local player = self.partition:GetPlayer(playerId)
    local former = player.main
    if former == key then
        return true
    end
    self.partition:SetMain(playerId, key)
    local conflicts = self.partition:GetConflicts() or {}
    local index = #conflicts
    while index >= 1 do
        local entry = conflicts[index]
        if entry.kind == "promotion" and self.partition:GetCharacter(entry.character) ~= nil
            and self.partition:GetCharacter(entry.character).player == playerId
        then
            table.remove(conflicts, index)
        end
        index = index - 1
    end
    return true
end

-- Removes one departed character for good, keeping its history entry.
function Service:Purge(key)
    if not self.partition:Purge(key) then
        return false, "only characters who left the guild can be purged"
    end
    return true
end

-- Removes every departed character. Returns how many were purged.
function Service:PurgeAllDeparted()
    local departed = {}
    self.partition:EachCharacter(function(key, character)
        if character.departed ~= nil then
            table.insert(departed, key)
        end
    end)
    local purged = 0
    local index
    for index = 1, #departed do
        if self.partition:Purge(departed[index]) then
            purged = purged + 1
        end
    end
    return purged
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
