local _, addon = ...

-- The operations that organize players, used by conflict resolution, the
-- right-click menu, and (later) the edit panel, plus lookups for other
-- features. Pure: it works on a FellowshipStore partition and never touches
-- the game, and it never writes guild notes.
--
-- Operations the player performs by hand mark what they change as manual,
-- and every one leaves the acting-main invariant intact: a player with any
-- in-guild character has an in-guild main.
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

PlayerService.MAX_ALIAS_LENGTH = 48

-- options.now: function() -> timestamp, used for history dates.
-- options.normalizer: a NameNormalizer, for display names in lookups.
function PlayerService.Create(partition, options)
    options = options or {}
    return setmetatable({
        partition = partition,
        normalizer = options.normalizer,
        now = options.now or function()
            return 0
        end,
    }, Service)
end

-- Restores the acting-main invariant after a manual change. Manual changes
-- don't queue promotion conflicts: the player made them on purpose.
function Service:KeepActingMains()
    addon.ReconcileEngine.EnsureActingMains(self.partition, {}, self.now())
end

-- Records in `playerId`'s history that `key` left it ("detached", "moved
-- to …"), so the player panel shows former characters. Nothing is recorded
-- when the old player is gone (it had no other characters).
function Service:RecordLeaving(playerId, key, wasMain, reason)
    local character = self.partition:GetCharacter(key)
    if character == nil or self.partition:GetPlayer(playerId) == nil then
        return
    end
    self.partition:AddHistory(playerId, {
        name = character.name or key,
        character = key,
        role = wasMain and "main" or "alt",
        ["until"] = self.now(),
        reason = reason,
    })
end

-- The player `key` belongs to, and whether it is that player's main.
function Service:Membership(key)
    local character = self.partition:GetCharacter(key)
    local player = character and self.partition:GetPlayer(character.player)
    return character and character.player, player ~= nil and player.main == key
end

-- Drops pending note conflicts that a manual change has settled.
function Service:SettleConflicts(keys, kinds)
    local conflicts = self.partition:GetConflicts() or {}
    local index = #conflicts
    while index >= 1 do
        local entry = conflicts[index]
        if keys[entry.character] and kinds[entry.kind] then
            table.remove(conflicts, index)
        end
        index = index - 1
    end
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
        local formerPlayer, wasMain = self:Membership(character)
        if not self.partition:JoinPlayerOf(character, conflict.suggestion.main, source) then
            return false, "the character could not be moved"
        end
        self:KeepActingMains()
        self:RecordLeaving(formerPlayer, character, wasMain, "moved to " ..
            tostring(self:PlayerNameOf(character)) .. " by a guild note")
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
    character.source = addon.FellowshipStore.SOURCE_MANUAL
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

-- Manual organizing (the right-click menu) ---------------------------------

-- "Set main…": links `key` as an alt of `playerId`.
function Service:SetMainPlayer(key, playerId)
    local character = self.partition:GetCharacter(key)
    local player = self.partition:GetPlayer(playerId)
    if character == nil then
        return false, "that character is not known"
    end
    if player == nil then
        return false, "that player is not known"
    end
    if character.player == playerId then
        return true
    end
    local formerPlayer, wasMain = self:Membership(key)
    if not self.partition:JoinPlayerOf(key, player.main, addon.FellowshipStore.SOURCE_MANUAL) then
        return false, "the character could not be moved"
    end
    self:SettleConflicts({ [key] = true }, { main = true })
    self:KeepActingMains()
    self:RecordLeaving(formerPlayer, key, wasMain, "moved to " .. tostring(self:PlayerName(playerId)))
    return true
end

-- "Set alias…": sets the player's alias, or clears it when `alias` is
-- empty. Multi-word aliases are allowed here (notes only take one word).
function Service:SetAlias(key, alias)
    local character = self.partition:GetCharacter(key)
    if character == nil then
        return false, "that character is not known"
    end
    local playerId = character.player
    local trimmed = type(alias) == "string" and string.gsub(alias, "^%s*(.-)%s*$", "%1") or ""
    trimmed = string.gsub(trimmed, "%s+", " ")
    if #trimmed > PlayerService.MAX_ALIAS_LENGTH then
        return false, "aliases can be at most " .. PlayerService.MAX_ALIAS_LENGTH .. " characters"
    end
    if trimmed == "" then
        self.partition:ClearAlias(playerId, addon.FellowshipStore.SOURCE_MANUAL)
    else
        self.partition:SetAlias(playerId, trimmed, addon.FellowshipStore.SOURCE_MANUAL)
    end
    local keys = {}
    local members = self.partition:CharactersOf(playerId)
    local index
    for index = 1, #members do
        keys[members[index]] = true
    end
    self:SettleConflicts(keys, { alias = true, ["competing aliases"] = true })
    return true
end

-- "Detach as own player": moves `key` into a new single-character player.
function Service:Detach(key)
    local character = self.partition:GetCharacter(key)
    if character == nil then
        return false, "that character is not known"
    end
    if self.partition:CharactersOf(character.player)[2] == nil then
        return false, "it is already its own player"
    end
    local formerPlayer, wasMain = self:Membership(key)
    if self.partition:MoveToNewPlayer(key, addon.FellowshipStore.SOURCE_MANUAL) == nil then
        return false, "the character could not be moved"
    end
    self:SettleConflicts({ [key] = true }, { main = true })
    self:KeepActingMains()
    self:RecordLeaving(formerPlayer, key, wasMain, "detached")
    return true
end

-- Lookups --------------------------------------------------------------------

-- The player id and record of a character's player, or nil.
function Service:PlayerOf(key)
    local character = self.partition:GetCharacter(key)
    if character == nil then
        return nil
    end
    return character.player, self.partition:GetPlayer(character.player)
end

-- Character keys of a player, main first.
function Service:CharactersOf(playerId)
    return self.partition:CharactersOf(playerId)
end

-- How a character is shown: its name as the roster spells it.
function Service:CharacterName(key)
    local character = self.partition:GetCharacter(key)
    if character == nil then
        return nil
    end
    if self.normalizer ~= nil then
        return self.normalizer:Display(character.name) or key
    end
    return character.name or key
end

-- How a player is shown: "Alias (Main)", or the main's name.
function Service:PlayerName(playerId)
    local player = self.partition:GetPlayer(playerId)
    if player == nil then
        return nil
    end
    local mainName = self:CharacterName(player.main) or player.main
    if player.alias ~= nil then
        return player.alias .. " (" .. mainName .. ")"
    end
    return mainName
end

-- How a character's player is shown, from any of its characters.
function Service:PlayerNameOf(key)
    local playerId = self:PlayerOf(key)
    return playerId and self:PlayerName(playerId) or nil
end

-- Players matching `query` by alias or any in-guild character's name,
-- case-insensitively, for the "Set main…" picker. An empty query lists
-- everyone. Each result: { id, label, matched } where `matched` names the
-- character that matched, when it wasn't the alias. Sorted by label.
function Service:SearchPlayers(query, limit)
    local needle = string.lower(type(query) == "string" and query or "")
    needle = string.gsub(needle, "^%s*(.-)%s*$", "%1")
    local results = {}
    self.partition:EachPlayer(function(id, player)
        local keys = self.partition:CharactersOf(id)
        local inGuild, matched = false, nil
        local aliasMatches = needle == ""
            or (player.alias ~= nil and string.find(string.lower(player.alias), needle, 1, true) ~= nil)
        local index
        for index = 1, #keys do
            if self.partition:IsInGuild(keys[index]) then
                inGuild = true
                local name = self:CharacterName(keys[index]) or keys[index]
                if not aliasMatches and matched == nil and string.find(string.lower(name), needle, 1, true) then
                    matched = name
                end
            end
        end
        if inGuild and (aliasMatches or matched ~= nil) then
            table.insert(results, { id = id, label = self:PlayerName(id), matched = matched })
        end
    end)
    table.sort(results, function(first, second)
        local firstLabel, secondLabel = string.lower(first.label), string.lower(second.label)
        if firstLabel ~= secondLabel then
            return firstLabel < secondLabel
        end
        return first.id < second.id
    end)
    if limit ~= nil then
        while #results > limit do
            table.remove(results)
        end
    end
    return results
end
