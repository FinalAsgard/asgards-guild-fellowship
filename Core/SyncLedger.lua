local _, addon = ...

-- An officer's record of the facts (SyncFacts) they wrote, used to catch
-- forged edits: a relayed fact naming this officer as its author that the
-- ledger doesn't know was never made by them.
--
-- Stored in the partition:
--   ledger    { since = time, facts = { ["main|key"] = { at, main },
--               ["alias|key"] = { at, alias } } }
--             Only the newest fact about each thing is kept. `since` is
--             when the ledger started: facts dated earlier (made before
--             this install kept a ledger) can't be judged and are trusted.
--   forgeries a list, newest last, of
--             { kind, character, main?, alias?, at, relayedBy, seen }
--             keeping the last MAX_FORGERIES.
--
-- Pure: works on a FellowshipStore partition and never touches the game.
local SyncLedger = {
    MAX_FORGERIES = 50,
}
addon.SyncLedger = SyncLedger

local Ledger = {}
Ledger.__index = Ledger

function SyncLedger.Create(partition)
    return setmetatable({ partition = partition }, Ledger)
end

local function keyOf(fact)
    return fact.kind .. "|" .. fact.character
end

local function isTime(value)
    return type(value) == "number" and value > 0
end

-- The stored ledger, started at `now` when there is none yet, or nil when
-- the time isn't known.
function Ledger:Data(now)
    local data = self.partition:GetLedger()
    if type(data) == "table" and isTime(data.since) and type(data.facts) == "table" then
        return data
    end
    if not isTime(now) then
        return nil
    end
    data = { since = now, facts = {} }
    self.partition:SetLedger(data)
    return data
end

-- Records facts this officer just wrote.
function Ledger:Record(facts, now)
    local data = self:Data(now)
    if data == nil or type(facts) ~= "table" then
        return
    end
    local index
    for index = 1, #facts do
        local fact = facts[index]
        if addon.SyncFacts.IsValid(fact) then
            local held = data.facts[keyOf(fact)]
            if type(held) ~= "table" or not isTime(held.at) or fact.at >= held.at then
                data.facts[keyOf(fact)] = { at = fact.at, main = fact.main, alias = fact.alias }
            end
        end
    end
end

-- Whether `fact`, naming this officer as its author, is one they never
-- wrote: newer than anything they wrote about that thing, or the same
-- moment with a different value. Facts older than the ledger itself, or
-- older than this officer's own newer edit, can't change anything they hold
-- and aren't judged.
function Ledger:IsForged(fact, now)
    local data = self:Data(now)
    if data == nil or not addon.SyncFacts.IsValid(fact) or fact.at < data.since then
        return false
    end
    local held = data.facts[keyOf(fact)]
    if type(held) ~= "table" or not isTime(held.at) then
        return true
    end
    if fact.at ~= held.at then
        return fact.at > held.at
    end
    return fact.main ~= held.main or fact.alias ~= held.alias
end

-- Logs a forged fact and the character (key) that relayed it.
function Ledger:LogForgery(fact, relayedBy, now)
    local log = self:Forgeries()
    table.insert(log, {
        kind = fact.kind,
        character = fact.character,
        main = fact.main,
        alias = fact.alias,
        at = fact.at,
        relayedBy = relayedBy,
        seen = now,
    })
    while #log > SyncLedger.MAX_FORGERIES do
        table.remove(log, 1)
    end
    self.partition:SetForgeries(log)
end

-- The forgery log, oldest first.
function Ledger:Forgeries()
    local log = self.partition:GetForgeries()
    if type(log) ~= "table" then
        return {}
    end
    return log
end
