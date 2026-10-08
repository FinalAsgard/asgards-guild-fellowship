local _, addon = ...

-- Guild sync's facts and the rule for applying them. A fact is one thing an
-- officer said about the roster, stamped with when (server time) and by
-- whom (a character key):
--
--   { kind = "main", character = key, main = key, at = seconds, by = key }
--
-- "character's main is main"; a character that is its own main says so with
-- main == character. Player ids are local counters, so facts only ever name
-- characters, and each client rebuilds its own players from them.
--
-- Pure: works on a FellowshipStore partition and never touches the game.
local SyncFacts = {
    KIND_MAIN = "main",
}
addon.SyncFacts = SyncFacts

local Facts = {}
Facts.__index = Facts

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isTimestamp(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

-- True when `fact` has the shape of a main-link fact.
function SyncFacts.IsValid(fact)
    return type(fact) == "table"
        and fact.kind == SyncFacts.KIND_MAIN
        and isText(fact.character)
        and isText(fact.main)
        and isTimestamp(fact.at)
        and isText(fact.by)
end

-- Newest wins. Two edits in the same second are settled by author, so every
-- client settles them the same way.
function SyncFacts.IsNewer(at, by, heldAt, heldBy)
    if at ~= heldAt then
        return at > heldAt
    end
    return by > (heldBy or "")
end

-- options.isOfficer(key) -> boolean, from OfficerAuthority.
-- options.now() -> timestamp, used for acting-main history dates.
function SyncFacts.Create(partition, options)
    options = options or {}
    return setmetatable({
        partition = partition,
        isOfficer = options.isOfficer or function()
            return false
        end,
        now = options.now or function()
            return 0
        end,
    }, Facts)
end

-- The main-link fact for `key` as this client holds it, or nil.
function Facts:FactOf(key)
    local character = self.partition:GetCharacter(key)
    local player = character and self.partition:GetPlayer(character.player)
    if player == nil then
        return nil
    end
    local at, by = self.partition:GetMainStamp(key)
    return {
        kind = SyncFacts.KIND_MAIN,
        character = key,
        main = player.main,
        at = at,
        by = by,
    }
end

-- Stamps the current main link of every key in `keys` (a set) as set by
-- `author` at `at`, and returns those facts sorted by character. A stamp is
-- always newer than the one it replaces, so a second edit within the same
-- second still wins everywhere.
function Facts:Stamp(keys, author, at)
    local sorted = {}
    local key
    for key in pairs(keys) do
        if self.partition:GetCharacter(key) ~= nil then
            table.insert(sorted, key)
        end
    end
    table.sort(sorted)
    local facts = {}
    local index
    for index = 1, #sorted do
        local heldAt = self.partition:GetMainStamp(sorted[index])
        self.partition:SetMainStamp(sorted[index], math.max(at, heldAt + 1), author)
        table.insert(facts, self:FactOf(sorted[index]))
    end
    return facts
end

-- Whether a fact received from `sender` should be applied: nil when it
-- should, or why not. Only officers' own edits are accepted for now; facts
-- relayed by someone other than their author are not.
function Facts:Refusal(fact, sender)
    if not SyncFacts.IsValid(fact) then
        return "malformed"
    end
    if fact.by ~= sender then
        return "relayed"
    end
    if not self.isOfficer(fact.by) then
        return "not an officer"
    end
    if self.partition:GetCharacter(fact.character) == nil or self.partition:GetCharacter(fact.main) == nil then
        return "unknown character"
    end
    local heldAt, heldBy = self.partition:GetMainStamp(fact.character)
    if not SyncFacts.IsNewer(fact.at, fact.by, heldAt, heldBy) then
        return "not newer"
    end
    return nil
end

-- Makes the roster agree with one accepted fact.
function Facts:Change(fact)
    local partition = self.partition
    local source = addon.FellowshipStore.SOURCE_SYNC
    local character = partition:GetCharacter(fact.character)
    if fact.main == fact.character then
        -- It's a main. As an alt it leaves for a player of its own; its
        -- former player's characters follow with their own facts.
        if partition:GetPlayer(character.player).main ~= fact.character then
            partition:MoveToNewPlayer(fact.character, source)
        end
    else
        partition:JoinPlayerOf(fact.character, fact.main, source)
        local main = partition:GetCharacter(fact.main)
        if partition:GetPlayer(main.player).main ~= fact.main then
            partition:SetMain(main.player, fact.main)
        end
    end
    partition:GetCharacter(fact.character).source = source
    partition:SetMainStamp(fact.character, fact.at, fact.by)
end

-- Applies every acceptable fact in `facts` from `sender`, then restores the
-- acting-main invariant once. Returns how many were applied.
function Facts:ApplyAll(facts, sender)
    if type(facts) ~= "table" then
        return 0
    end
    local applied = 0
    local index
    for index = 1, #facts do
        if self:Refusal(facts[index], sender) == nil then
            self:Change(facts[index])
            applied = applied + 1
        end
    end
    if applied > 0 then
        addon.ReconcileEngine.EnsureActingMains(self.partition, {}, self.now())
    end
    return applied
end
