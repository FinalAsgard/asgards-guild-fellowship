local _, addon = ...

-- An officer's record of the facts (SyncFacts) they wrote, used to catch
-- forged edits: a relayed fact naming this officer as its author that the
-- ledger doesn't know was never made by them.
--
-- Stored in the partition:
--   ledger    { since = time, facts = { ["main|key"] = { at, main },
--               ["alias|key"] = { at, alias },
--               ["discord|key"] = { at, text },
--               ["joined|key"] = { at, date } } }
--             (`date` is a membership date's value, SyncFacts.DateValue)
--             Only the newest fact about each thing is kept. `since` is
--             when the ledger started: facts dated earlier (made before
--             this install kept a ledger) can't be judged and are trusted.
--   forgeries a list, newest last, of
--             { kind, character, main?, alias?, text?, at, relayedBy, seen }
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
                data.facts[keyOf(fact)] = {
                    at = fact.at, main = fact.main, alias = fact.alias, text = fact.text,
                    date = addon.SyncFacts.DateValue(fact),
                }
            end
        end
    end
end

-- Whether this officer stamped an alias at `at`, about any player.
function Ledger:StampedAlias(data, at)
    if self.aliasStamps == nil then
        self.aliasStamps = {}
        local key, held
        for key, held in pairs(data.facts) do
            if string.sub(key, 1, #addon.SyncFacts.KIND_ALIAS + 1) == addon.SyncFacts.KIND_ALIAS .. "|"
                and type(held) == "table" and isTime(held.at)
            then
                self.aliasStamps[held.at] = true
            end
        end
    end
    return self.aliasStamps[at] == true
end

-- Whether `fact`, naming this officer as its author, is one they never
-- wrote: newer than anything they wrote about that thing. Facts older than
-- the ledger itself, or older than this officer's own newer edit, can't
-- change anything they hold and aren't judged.
--
-- A fact carrying a stamp this officer did write isn't forged, even when
-- its value differs: facts are rebuilt from each roster, so a player whose
-- main left the guild (and got an acting main) or moved by a guild note
-- reports the officer's stamp with the main it has now. That's the same
-- moment about the same thing, or for an alias (named by the player's
-- main) an alias stamp of theirs under another main. It can't win over
-- what anyone who held the officer's fact holds.
function Ledger:IsForged(fact, now)
    local data = self:Data(now)
    if data == nil or not addon.SyncFacts.IsValid(fact) or fact.at < data.since then
        return false
    end
    if fact.kind == addon.SyncFacts.KIND_ALIAS and self:StampedAlias(data, fact.at) then
        return false
    end
    local held = data.facts[keyOf(fact)]
    if type(held) ~= "table" or not isTime(held.at) then
        return true
    end
    return fact.at > held.at
end

-- Logs a forged fact and the character (key) that relayed it.
function Ledger:LogForgery(fact, relayedBy, now)
    local log = self:Forgeries()
    table.insert(log, {
        kind = fact.kind,
        character = fact.character,
        main = fact.main,
        alias = fact.alias,
        text = fact.text,
        roles = fact.roles,
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
