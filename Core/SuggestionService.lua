local _, addon = ...

-- Members' suggestions. A member's own edit applies on their side at once,
-- stamped as theirs, and is also kept as a pending suggestion: the facts
-- (SyncFacts) it produced. When an officer is online the member sends them,
-- and each one that differs from the officer's data shows in that officer's
-- conflict queue, labeled with the member. The first officer to approve or
-- reject settles it for every officer: approving turns it into an officer
-- fact under the approver's name; rejecting reverts the member's edit to
-- the officer's value for that thing.
--
-- Queue entries:
--   { character, kind = "suggested main", suggestion = { main = key },
--     from = member key, at = when the member made the edit }
--   { character, kind = "suggested alias", suggestion = { alias = text },
--     from, at }
-- An alias suggestion names the player by its main; an empty alias clears it.
--
-- A pending suggestion also remembers `was`: the value it replaced ({ main =
-- key } or { alias = text }), the officers' value as far as this client
-- knows. Editing the same thing again replaces the suggestion but keeps
-- `was`; changing it back to `was`, or undoing it, drops the suggestion,
-- puts `was` back as if notes or the roster had set it, and withdraws it:
-- the member's newer fact equal to `was` is kept for WITHDRAWAL_SECONDS and
-- sent with suggestions. An officer's queue drops the member's entry when it
-- gets one; an older officer's add-on ignores it, since it changes nothing.
-- Messages between add-ons stay as they were (`was` is never sent).
--
-- Pure: works on a FellowshipStore partition and never touches the game.
local SuggestionService = {
    KIND_MAIN = "suggested main",
    KIND_ALIAS = "suggested alias",
    -- How long a withdrawal is kept for officers who weren't online.
    WITHDRAWAL_SECONDS = 14 * 86400,
}
addon.SuggestionService = SuggestionService

-- Kinds of conflict-queue entries that are suggestions.
SuggestionService.KINDS = {
    [SuggestionService.KIND_MAIN] = true,
    [SuggestionService.KIND_ALIAS] = true,
}

local Service = {}
Service.__index = Service

-- options.isOfficer(key) -> boolean; options.now() -> server time, or 0
-- when unknown.
function SuggestionService.Create(partition, options)
    options = options or {}
    local service = setmetatable({
        partition = partition,
        isOfficer = options.isOfficer or function()
            return false
        end,
        now = options.now or function()
            return 0
        end,
    }, Service)
    service.facts = addon.SyncFacts.Create(partition, {
        isOfficer = service.isOfficer,
        now = service.now,
    })
    return service
end

local function sameThing(first, second)
    return first.kind == second.kind and first.character == second.character
end

-- A fact as it travels between add-ons: no `was`.
local function copy(fact)
    return {
        kind = fact.kind,
        character = fact.character,
        main = fact.main,
        alias = fact.alias,
        at = fact.at,
        by = fact.by,
    }
end

-- Whether `fact` sets the thing it's about to the value in `was`.
local function isValue(fact, was)
    if type(was) ~= "table" then
        return false
    end
    if fact.kind == addon.SyncFacts.KIND_ALIAS then
        return fact.alias == (was.alias or "")
    end
    return fact.main == was.main
end

-- The queue kind for a fact's kind, and back.
local function queueKind(factKind)
    if factKind == addon.SyncFacts.KIND_ALIAS then
        return SuggestionService.KIND_ALIAS
    end
    return SuggestionService.KIND_MAIN
end

local function factKind(kind)
    if kind == SuggestionService.KIND_ALIAS then
        return addon.SyncFacts.KIND_ALIAS
    end
    return addon.SyncFacts.KIND_MAIN
end

-- The member's side ----------------------------------------------------------

-- This member's pending suggestions (valid facts only).
function Service:Pending()
    local pending = {}
    local stored = self.partition:GetSuggestions() or {}
    local index
    for index = 1, #stored do
        if addon.SyncFacts.IsValid(stored[index]) then
            table.insert(pending, stored[index])
        end
    end
    return pending
end

-- Keeps `facts` (this member's newly stamped edits) as pending suggestions,
-- each replacing any earlier one about the same thing. `priorOf(fact)`,
-- when given, is the value the edit replaced ({ main } or { alias }); the
-- first suggestion about a thing remembers it as `was`. An edit back to
-- `was` drops the suggestion and withdraws it. Returns how many were
-- withdrawn.
function Service:Record(facts, priorOf)
    local pending = self:Pending()
    local withdrawn = 0
    local index, other
    for index = 1, #facts do
        local fact = facts[index]
        local was = priorOf and priorOf(fact) or nil
        for other = #pending, 1, -1 do
            if sameThing(pending[other], fact) then
                was = pending[other].was
                table.remove(pending, other)
            end
        end
        self:ForgetWithdrawal(fact)
        if was ~= nil and isValue(fact, was) then
            self:Withdraw(fact, was, fact.at)
            withdrawn = withdrawn + 1
        else
            local entry = copy(fact)
            entry.was = was
            table.insert(pending, entry)
        end
    end
    self.partition:SetSuggestions(pending)
    return withdrawn
end

-- Puts `was` back for the thing `fact` is about, as if notes or the roster
-- had set it, and keeps the member's fact equal to it, stamped `at`, to
-- withdraw the suggestion from officers' queues.
function Service:Withdraw(fact, was, at)
    self.facts:Restore({ kind = fact.kind, character = fact.character, main = was.main, alias = was.alias })
    local withdrawal = copy(fact)
    withdrawal.main = fact.kind == addon.SyncFacts.KIND_MAIN and was.main or nil
    withdrawal.alias = fact.kind == addon.SyncFacts.KIND_ALIAS and (was.alias or "") or nil
    withdrawal.at = at
    withdrawal.kept = self.now()
    local withdrawals = self.partition:GetWithdrawals()
    local index
    for index = #withdrawals, 1, -1 do
        if sameThing(withdrawals[index], withdrawal) then
            table.remove(withdrawals, index)
        end
    end
    table.insert(withdrawals, withdrawal)
    self.partition:SetWithdrawals(withdrawals)
end

-- Drops the withdrawal about the thing `fact` is about, if any: a new edit
-- to it takes over.
function Service:ForgetWithdrawal(fact)
    local withdrawals = self.partition:GetWithdrawals()
    local index
    for index = #withdrawals, 1, -1 do
        if sameThing(withdrawals[index], fact) then
            table.remove(withdrawals, index)
        end
    end
    self.partition:SetWithdrawals(withdrawals)
end

-- Undoes this member's pending suggestion about `character` of fact kind
-- `kind`: puts back the value it replaced and withdraws it. Returns true,
-- or false and why not.
function Service:Undo(character, kind)
    local pending = self:Pending()
    local index
    for index = 1, #pending do
        local fact = pending[index]
        if fact.character == character and fact.kind == kind then
            if fact.was == nil then
                return false, "what it replaced isn't known"
            end
            table.remove(pending, index)
            self.partition:SetSuggestions(pending)
            self:Withdraw(fact, fact.was, math.max(self.now(), fact.at + 1))
            return true
        end
    end
    return false, "that change is no longer waiting"
end

-- What this member sends officers: the pending suggestions and the
-- withdrawals still kept, as facts (without `was`). Withdrawals older than
-- WITHDRAWAL_SECONDS are dropped.
function Service:Outgoing()
    local outgoing = {}
    local pending = self:Pending()
    local index
    for index = 1, #pending do
        table.insert(outgoing, copy(pending[index]))
    end
    local now = self.now()
    local kept = {}
    local withdrawals = self.partition:GetWithdrawals()
    for index = 1, #withdrawals do
        local withdrawal = withdrawals[index]
        if addon.SyncFacts.IsValid(withdrawal)
            and not (now > 0 and type(withdrawal.kept) == "number"
                and now - withdrawal.kept > SuggestionService.WITHDRAWAL_SECONDS)
        then
            table.insert(kept, withdrawal)
            table.insert(outgoing, copy(withdrawal))
        end
    end
    self.partition:SetWithdrawals(kept)
    return outgoing
end

-- This member's pending suggestions that `decided` (see Decision) names.
function Service:Named(decided)
    local named = {}
    if decided == nil then
        return named
    end
    local pending = self:Pending()
    local index
    for index = 1, #pending do
        local fact = pending[index]
        if decided.kind == queueKind(fact.kind) and decided.character == fact.character
            and decided.from == fact.by and type(decided.at) == "number" and fact.at <= decided.at
        then
            table.insert(named, fact)
        end
    end
    return named
end

-- Drops pending suggestions that are settled: decided by an officer
-- (`decided` names one, see Decision), or overtaken because what this client
-- holds for that thing is no longer the member's own edit (a newer officer
-- fact arrived). Returns how many were dropped.
function Service:Prune(decided)
    local pending = self:Pending()
    local kept = {}
    local index
    for index = 1, #pending do
        local fact = pending[index]
        local heldAt, heldBy = self.facts:HeldStamp(fact)
        local settled = decided ~= nil and decided.kind == queueKind(fact.kind)
            and decided.character == fact.character and decided.from == fact.by
            and type(decided.at) == "number" and fact.at <= decided.at
        if not settled and heldAt == fact.at and heldBy == fact.by then
            table.insert(kept, fact)
        end
    end
    self.partition:SetSuggestions(kept)
    return #pending - #kept
end

-- After an officer rejected a suggestion (`decided`, see Decision): every
-- pending suggestion it names that is still this client's data reverts to
-- the officer's value, as if notes or the roster had set it, so officer
-- data wins over it again. An edit made after the rejected one stays.
-- Returns how many were reverted; Prune then drops them.
function Service:Revert(decided)
    if type(decided) ~= "table" or decided.approved or type(decided.official) ~= "table" then
        return 0
    end
    local reverted = 0
    local pending = self:Pending()
    local index
    for index = 1, #pending do
        local fact = pending[index]
        local heldAt, heldBy = self.facts:HeldStamp(fact)
        local named = decided.kind == queueKind(fact.kind) and decided.character == fact.character
            and decided.from == fact.by and type(decided.at) == "number" and fact.at <= decided.at
        if named and heldAt == fact.at and heldBy == fact.by and self.facts:Restore({
            kind = fact.kind,
            character = fact.character,
            main = decided.official.main,
            alias = decided.official.alias,
        }) then
            reverted = reverted + 1
        end
    end
    return reverted
end

-- The officer's side ----------------------------------------------------------

-- Whether `fact` would change what this client holds.
function Service:Differs(fact)
    local character = self.partition:GetCharacter(fact.character)
    local player = character and self.partition:GetPlayer(character.player)
    if player == nil then
        return false
    end
    if fact.kind == addon.SyncFacts.KIND_ALIAS then
        return (player.alias or "") ~= fact.alias
    end
    -- "character's main is main": the same player, led by that main.
    local main = self.partition:GetCharacter(fact.main)
    return not (main ~= nil and main.player == character.player and player.main == fact.main)
end

local function findEntry(conflicts, character, kind)
    local index
    for index = 1, #conflicts do
        if conflicts[index].character == character and conflicts[index].kind == kind then
            return index, conflicts[index]
        end
    end
    return nil
end

-- Queues the suggestions `from` (a member's key) sent, for this officer to
-- decide. Only the member's own edits count, and only those that would
-- change something and are newer than what this client holds. A newer
-- suggestion about the same thing replaces an older one, and a newer one
-- that changes nothing withdraws it. Returns how many entries were queued
-- or withdrawn.
function Service:Queue(facts, from)
    if type(facts) ~= "table" or type(from) ~= "string" or self.isOfficer(from) then
        return 0
    end
    local conflicts = self.partition:GetConflicts() or {}
    local now = self.now()
    local queued = 0
    local index
    for index = 1, #facts do
        local fact = facts[index]
        local usable = addon.SyncFacts.IsValid(fact) and fact.by == from
            and not (now > 0 and fact.at > now + addon.SyncFacts.MAX_FUTURE_SECONDS)
            and self.partition:GetCharacter(fact.character) ~= nil
            and (fact.kind ~= addon.SyncFacts.KIND_MAIN or self.partition:GetCharacter(fact.main) ~= nil)
        if usable then
            local heldAt, heldBy = self.facts:HeldStamp(fact)
            usable = addon.SyncFacts.IsNewer(fact.at, fact.by, heldAt, heldBy) and self:Differs(fact)
        end
        local kind = queueKind(fact.kind)
        -- A newer fact from the member that changes nothing withdraws their
        -- queued suggestion about that thing.
        local valid = addon.SyncFacts.IsValid(fact) and fact.by == from
            and self.partition:GetCharacter(fact.character) ~= nil
        if valid and not usable and not self:Differs(fact) then
            local withdrawnIndex, withdrawn = findEntry(conflicts, fact.character, kind)
            if withdrawn ~= nil and withdrawn.from == from and withdrawn.at < fact.at then
                table.remove(conflicts, withdrawnIndex)
                queued = queued + 1
            end
        end
        local existingIndex, existing
        if usable then
            existingIndex, existing = findEntry(conflicts, fact.character, kind)
            usable = existing == nil or existing.from == nil or existing.at < fact.at
        end
        if usable then
            if existingIndex ~= nil then
                table.remove(conflicts, existingIndex)
            end
            local suggestion = { main = fact.main }
            if fact.kind == addon.SyncFacts.KIND_ALIAS then
                suggestion = { alias = fact.alias }
            end
            table.insert(conflicts, {
                character = fact.character,
                kind = kind,
                suggestion = suggestion,
                from = from,
                at = fact.at,
            })
            queued = queued + 1
        end
    end
    self.partition:SetConflicts(conflicts)
    return queued
end

-- The queued suggestion about `character` of `kind`, or nil.
function Service:Entry(character, kind)
    if not SuggestionService.KINDS[kind] then
        return nil
    end
    local _, entry = findEntry(self.partition:GetConflicts() or {}, character, kind)
    if entry == nil or entry.from == nil or type(entry.suggestion) ~= "table" then
        return nil
    end
    return entry
end

-- What deciding `entry` tells everyone: { kind, character, from, at,
-- approved }. A rejection also carries `official`, this client's value for
-- that thing ({ main = key } or { alias = text }), for the member to revert
-- to.
function Service:Decision(entry, approved)
    local decided = {
        kind = entry.kind,
        character = entry.character,
        from = entry.from,
        at = entry.at,
        approved = approved == true,
    }
    if not decided.approved then
        local held = self:Held(entry) or {}
        decided.official = { main = held.main, alias = held.alias }
    end
    return decided
end

-- This client's fact for the thing `entry` is about.
function Service:Held(entry)
    if entry.kind == SuggestionService.KIND_ALIAS then
        return self.facts:AliasFactOf(entry.character)
    end
    return self.facts:FactOf(entry.character)
end

-- The officer fact this client holds for the thing `entry` is about, or nil
-- when an officer never set it (notes or the roster did).
function Service:OfficialFact(entry)
    local held = self:Held(entry)
    if held == nil or held.by == nil or held.at == 0 or not self.isOfficer(held.by) then
        return nil
    end
    return held
end

-- The officer fact approving `entry` makes, stamped as `officer`'s at `now`
-- (always newer than what this client holds).
function Service:FactFor(entry, officer, now)
    local fact = {
        kind = factKind(entry.kind),
        character = entry.character,
        by = officer,
    }
    if fact.kind == addon.SyncFacts.KIND_ALIAS then
        fact.alias = entry.suggestion.alias
    else
        fact.main = entry.suggestion.main
    end
    local heldAt = self.facts:HeldStamp(fact) or 0
    fact.at = math.max(now, heldAt + 1)
    return fact
end

-- Removes queued suggestions that are settled: the one `decided` names (and
-- older ones about the same thing), and any that are no longer newer than
-- what this client holds. Returns how many were removed.
function Service:Settle(decided)
    local conflicts = self.partition:GetConflicts() or {}
    local removed = 0
    local index
    for index = #conflicts, 1, -1 do
        local entry = conflicts[index]
        if entry.from ~= nil and SuggestionService.KINDS[entry.kind] then
            local named = decided ~= nil and decided.kind == entry.kind and decided.character == entry.character
                and type(decided.at) == "number" and entry.at <= decided.at
            local heldAt, heldBy = self.facts:HeldStamp({ kind = factKind(entry.kind), character = entry.character })
            local overtaken = heldAt == nil or not addon.SyncFacts.IsNewer(entry.at, entry.from, heldAt, heldBy)
            if named or overtaken then
                table.remove(conflicts, index)
                removed = removed + 1
            end
        end
    end
    return removed
end

-- Whether a decision received from another client is well formed.
function SuggestionService.IsDecision(decided)
    return type(decided) == "table" and SuggestionService.KINDS[decided.kind] == true
        and type(decided.character) == "string" and type(decided.from) == "string"
        and type(decided.at) == "number"
end
