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
--             { kind, character, main?, alias?, text?, roles?, declared?,
--               date?, at, relayedBy, seen, heldAt? }
--             keeping the last MAX_FORGERIES. `heldAt` is the stamp the
--             ledger held for that thing when the fact arrived (nil when
--             it held none).
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

-- Whether this officer stamped an alias at `at` for the player `character`
-- belongs to now, under that player's main then (a character of the same
-- player). The ledger keys by stamp are found once per ledger, and each is
-- checked against the ledger as it is now, since a ledger can change while
-- sync yields.
function Ledger:StampedAlias(data, character, at)
    local prefix = addon.SyncFacts.KIND_ALIAS .. "|"
    if self.aliasStamps == nil then
        self.aliasStamps = {}
        local key, held
        for key, held in pairs(data.facts) do
            if string.sub(key, 1, #prefix) == prefix and type(held) == "table" and isTime(held.at) then
                self.aliasStamps[held.at] = self.aliasStamps[held.at] or {}
                table.insert(self.aliasStamps[held.at], key)
            end
        end
    end
    local current = self.partition:GetCharacter(character)
    if current == nil then
        return false
    end
    local keys = self.aliasStamps[at] or {}
    local index
    for index = 1, #keys do
        local held = data.facts[keys[index]]
        local former = self.partition:GetCharacter(string.sub(keys[index], #prefix + 1))
        if type(held) == "table" and held.at == at and former ~= nil and former.player == current.player then
            return true
        end
    end
    return false
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
    if fact.kind == addon.SyncFacts.KIND_ALIAS and self:StampedAlias(data, fact.character, fact.at) then
        return false
    end
    local held = data.facts[keyOf(fact)]
    if type(held) ~= "table" or not isTime(held.at) then
        return true
    end
    return fact.at > held.at
end

-- Logs a forged fact and the character (key) that relayed it, with the
-- stamp the ledger held for that thing.
function Ledger:LogForgery(fact, relayedBy, now)
    local log = self:Forgeries()
    local data = self.partition:GetLedger()
    local held = type(data) == "table" and type(data.facts) == "table" and data.facts[keyOf(fact)] or nil
    table.insert(log, {
        kind = fact.kind,
        character = fact.character,
        main = fact.main,
        alias = fact.alias,
        text = fact.text,
        roles = fact.roles,
        declared = fact.declared,
        date = addon.SyncFacts.DateValue(fact),
        at = fact.at,
        relayedBy = relayedBy,
        seen = now,
        heldAt = type(held) == "table" and isTime(held.at) and held.at or nil,
    })
    while #log > SyncLedger.MAX_FORGERIES do
        table.remove(log, 1)
    end
    self.partition:SetForgeries(log)
end

-- What a logged forgery set, as text.
local function valueOf(entry)
    if entry.main ~= nil then
        return "main " .. tostring(entry.main)
    end
    if entry.alias ~= nil then
        return entry.alias == "" and "alias cleared" or ('alias "' .. tostring(entry.alias) .. '"')
    end
    if entry.declared ~= nil then
        return entry.declared and "declared a main" or "not declared a main"
    end
    if type(entry.roles) == "table" then
        local roles = {}
        local index
        for index = 1, #entry.roles do
            roles[index] = tostring(entry.roles[index])
        end
        return "roles " .. (roles[1] ~= nil and table.concat(roles, ", ") or "none")
    end
    if entry.text ~= nil then
        return entry.text == "" and "cleared" or ('"' .. tostring(entry.text) .. '"')
    end
    if entry.date ~= nil then
        return "date " .. tostring(entry.date)
    end
    return "?"
end

-- The newest `limit` logged forgeries of `partition`, oldest first, one
-- line each, for `/agf probe forgeries`. `formatTime(timestamp)` -> text.
function SyncLedger.ForgeryLines(partition, formatTime, limit)
    local log = SyncLedger.Create(partition):Forgeries()
    local lines = {}
    local data = partition:GetLedger()
    if type(data) == "table" and isTime(data.since) then
        table.insert(lines, "Ledger of your edits kept since " .. formatTime(data.since) .. ".")
    end
    if log[1] == nil then
        table.insert(lines, "No forged edits are logged here.")
        return lines
    end
    local first = math.max(1, #log - limit + 1)
    table.insert(lines, #log .. " forged edits logged; the last " .. (#log - first + 1) .. ", oldest first:")
    local index
    for index = first, #log do
        local entry = log[index]
        if type(entry) == "table" then
            table.insert(lines, formatTime(entry.seen) .. " from " .. tostring(entry.relayedBy) .. ": " ..
                tostring(entry.kind) .. " of " .. tostring(entry.character) .. ", " .. valueOf(entry) ..
                ", stamped " .. formatTime(entry.at) .. "; your ledger held " ..
                (isTime(entry.heldAt) and formatTime(entry.heldAt) or "nothing") .. ".")
        end
    end
    return lines
end

-- The forgery log, oldest first.
function Ledger:Forgeries()
    local log = self.partition:GetForgeries()
    if type(log) ~= "table" then
        return {}
    end
    return log
end
