local _, addon = ...

-- Officers' ticks on characters' promotion checklists (see
-- RankRequirements). Each record is one item for one character at one
-- rank:
--   { t = "tick", character, rank, item, ticked, note?, at, by }
-- `rank` is the character's rank (0-based) when the tick was made,
-- `item` the requirement item's id, `ticked` false for an untick, and
-- `note` what the officer typed for an item that needs one. On an
-- automated item (RankRequirements.IsAutomated) a tick is an officer's
-- override of a failed check, and `note` its optional reason. The newest
-- record wins per character and item, with sync's tie-break, and only
-- officers' records are accepted. Unticking is stamped too, so it beats
-- older ticks everywhere.
--
-- A record made for another rank than the character's current one is
-- stale: a promotion, a demotion, or a rank change made in the game's own
-- guild UI clears the checklist with no message of its own. So is one made
-- before the character's current stint at its rank began (`stintStart`):
-- promoted and then demoted back, it starts that rank's checklist afresh,
-- even on an add-on that never saw it at the other rank. Stale records are
-- ignored, pruned (Prune), and never sent.
--
-- Pure: the caller passes the saved table and the facts.
local PromotionChecks = {
    PROTOCOL = 1,
    TYPE_STATE = "ticks",
    TYPE_ASK = "ticks-ask",
    -- The longest note.
    MAX_NOTE = 100,
}
addon.PromotionChecks = PromotionChecks

PromotionChecks.TYPES = {
    [PromotionChecks.TYPE_STATE] = true,
    [PromotionChecks.TYPE_ASK] = true,
}

local Checks = {}
Checks.__index = Checks

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isWhole(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

-- True when `record` has the shape of a tick record.
function PromotionChecks.IsRecord(record)
    return type(record) == "table" and record.t == "tick" and isText(record.character) and #record.character <= 80
        and isWhole(record.rank, 0, 9) and isText(record.item) and #record.item <= 80
        and type(record.ticked) == "boolean"
        and (record.note == nil or (type(record.note) == "string" and #record.note <= PromotionChecks.MAX_NOTE))
        and isWhole(record.at, 1, math.huge) and isText(record.by)
end

local function keyOf(record)
    return record.character .. "\31" .. record.item
end

local function copy(record)
    return {
        t = "tick",
        character = record.character,
        rank = record.rank,
        item = record.item,
        ticked = record.ticked,
        note = record.note,
        at = record.at,
        by = record.by,
    }
end

-- `saved` is the table to keep the ticks in, filled in when empty.
-- options:
--   isOfficer(key) -> boolean
--   rankOf(key)    -> the character's current rank (0-based), or nil when
--                     it isn't in the guild
--   stintStart(key) -> the earliest a record for the character's current
--                     rank can be and still be current (when its stint at
--                     that rank began, less any doubt), or nil when that
--                     isn't known for sure
function PromotionChecks.Create(saved, options)
    if type(saved.records) ~= "table" then
        saved.records = {}
    end
    options = options or {}
    return setmetatable({
        saved = saved,
        isOfficer = options.isOfficer or function()
            return false
        end,
        rankOf = options.rankOf or function()
            return nil
        end,
        stintStart = options.stintStart or function()
            return nil
        end,
    }, Checks)
end

-- Whether `record` is for the character's current rank, and made during
-- its current stint there.
function Checks:current(record)
    local ok, rank = pcall(self.rankOf, record.character)
    if not ok or rank == nil or rank ~= record.rank then
        return false
    end
    local okStart, start = pcall(self.stintStart, record.character)
    return not okStart or type(start) ~= "number" or record.at >= start
end

-- Applies a record received from another add-on (or made here): when it
-- has the right shape, is for the character's current rank, its author is
-- an officer, and it's newer than the one held. `fromOfficer` is true when
-- an officer's add-on sent it: then its author need only have been an
-- officer when they ticked it. Returns true when applied.
function Checks:Apply(record, fromOfficer)
    if not PromotionChecks.IsRecord(record) or not self:current(record) then
        return false
    end
    if fromOfficer ~= true then
        local ok, officer = pcall(self.isOfficer, record.by)
        if not ok or officer ~= true then
            return false
        end
    end
    local held = self.saved.records[keyOf(record)]
    if PromotionChecks.IsRecord(held) and self:current(held)
        and not addon.SyncFacts.IsNewer(record.at, record.by, held.at, held.by)
    then
        return false
    end
    self.saved.records[keyOf(record)] = copy(record)
    return true
end

-- The current record of `item` for `character`, or nil (never ticked, or
-- ticked at an earlier rank).
function Checks:Record(character, item)
    local record = self.saved.records[character .. "\31" .. item]
    if PromotionChecks.IsRecord(record) and self:current(record) then
        return record
    end
    return nil
end

-- Whether `item` is ticked for `character` at its current rank.
function Checks:IsTicked(character, item)
    local record = self:Record(character, item)
    return record ~= nil and record.ticked
end

-- An officer (`author`) ticks or unticks `item` (a RankRequirements item)
-- for `character` at `at`. An item that needs a note can only be ticked
-- with one. Returns the records to share, or nil and why not.
function Checks:Set(character, item, ticked, note, author, at)
    local ok, officer = pcall(self.isOfficer, author)
    if not ok or officer ~= true then
        return nil, "only officers can tick promotion requirements"
    end
    local okRank, rank = pcall(self.rankOf, character)
    if not okRank or rank == nil then
        return nil, "that character isn't in the guild"
    end
    if type(item) ~= "table" or item.rank ~= rank then
        return nil, "that item isn't for the character's rank"
    end
    if type(note) == "string" then
        note = string.gsub(note, "^%s*(.-)%s*$", "%1")
        if note == "" then
            note = nil
        end
    end
    if ticked and item.kind == addon.RankRequirements.KIND_CHECK_NOTE and note == nil then
        return nil, "this item needs a note"
    end
    if note ~= nil and #note > PromotionChecks.MAX_NOTE then
        return nil, "a note can have at most " .. PromotionChecks.MAX_NOTE .. " characters"
    end
    local held = self:Record(character, item.id)
    if held ~= nil and at <= held.at then
        at = held.at + 1
    end
    local record = {
        t = "tick",
        character = character,
        rank = rank,
        item = item.id,
        ticked = ticked == true,
        note = ticked and note or nil,
        at = at,
        by = author,
    }
    if not self:Apply(record) then
        return nil, "that can't be saved"
    end
    return { record }
end

-- Drops every stale record (made at another rank than the character's
-- current one, or for a character no longer in the guild). Returns how
-- many were dropped.
function Checks:Prune()
    local dropped = 0
    local key, record
    for key, record in pairs(self.saved.records) do
        if not PromotionChecks.IsRecord(record) or not self:current(record) then
            self.saved.records[key] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

-- Every current record, for sending to other add-ons.
function Checks:Snapshot()
    local records = {}
    local _, record
    for _, record in pairs(self.saved.records) do
        if PromotionChecks.IsRecord(record) and self:current(record) then
            table.insert(records, copy(record))
        end
    end
    table.sort(records, function(a, b)
        return keyOf(a) < keyOf(b)
    end)
    return records
end

-- True when `records` holds, for every current record here, the same one
-- or a newer one.
function Checks:CoveredBy(records)
    if type(records) ~= "table" then
        return false
    end
    local heard = {}
    local index
    for index = 1, #records do
        if PromotionChecks.IsRecord(records[index]) then
            heard[keyOf(records[index])] = records[index]
        end
    end
    local held = self:Snapshot()
    for index = 1, #held do
        local other = heard[keyOf(held[index])]
        if other == nil or addon.SyncFacts.IsNewer(held[index].at, held[index].by, other.at, other.by) then
            return false
        end
    end
    return true
end
