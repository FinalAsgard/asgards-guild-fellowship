local _, addon = ...

-- Each guild rank's promotion requirements: what a character at that rank
-- must do to move up to the next rank. Every rank starts with none.
--
-- Two kinds of record, each stamped with when (server time) and by whom (a
-- character key) it last changed:
--   item  { t = "item", id, rank, label, kind, n?, position, deleted?, at,
--         by }
--         `rank` is the 0-based rank index (as the roster numbers ranks) the
--         item belongs to, `kind` an item kind (KINDS), `n` an automated
--         kind's number (days, or a level), `position` its place in the
--         rank's list. A deleted item stays as a tombstone, so it
--         beats older edits made elsewhere.
--   rank  { t = "rank", rank, name, at, by }: the rank's name when an
--         officer last edited its requirements, so the editor can warn when
--         the game's rank at that index has another name (the guild master
--         inserted or removed a rank).
-- The newest record wins per item (and per rank name), with sync's
-- tie-break (time, then author), so every add-on settles on the same list.
-- Only records by officers are accepted, and labels longer than MAX_LABEL
-- are refused.
--
-- Sharing (CreateSync): a change goes to the guild at once; at login an
-- add-on asks, and one add-on that holds requirements answers with all of
-- them (officers first), unless someone else's answer already covered what
-- it holds.
--
-- Pure: the caller passes the saved table, the clock and messaging.
local RankRequirements = {
    PROTOCOL = 1,
    -- { v, t = TYPE_STATE, r = { record, ... } }
    TYPE_STATE = "reqs",
    -- { v, t = TYPE_ASK }: who has the requirements?
    TYPE_ASK = "reqs-ask",
    KIND_CHECK = "check",
    KIND_CHECK_NOTE = "check-note",
    -- Automated kinds, checked from the guild's dates and the roster.
    KIND_CHAR_DAYS = "char-guild-days",
    KIND_PLAYER_DAYS = "player-guild-days",
    KIND_RANK_DAYS = "rank-days",
    KIND_LEVEL = "level",
    MAX_LABEL = 60,
    -- The most items a rank can have.
    MAX_ITEMS = 15,
    MAX_RANK = 9,
    -- An officer's add-on answers an ask after OFFICER_ANSWER_MIN to
    -- OFFICER_ANSWER_MAX seconds, others after ANSWER_MIN to ANSWER_MAX.
    OFFICER_ANSWER_MIN = 1,
    OFFICER_ANSWER_MAX = 2,
    ANSWER_MIN = 3,
    ANSWER_MAX = 5,
    -- The ask goes out ASK_DELAY to ASK_DELAY + ASK_SPREAD seconds after
    -- ranks are first known, so logging in stays quiet and a guild logging
    -- in together doesn't ask all at once.
    ASK_DELAY = 120,
    ASK_SPREAD = 30,
}
addon.RankRequirements = RankRequirements

-- The item kinds, and their names in the editor.
RankRequirements.KINDS = {
    [RankRequirements.KIND_CHECK] = "Checkbox",
    [RankRequirements.KIND_CHECK_NOTE] = "Checkbox, needs a note",
    [RankRequirements.KIND_CHAR_DAYS] = "Character days in guild",
    [RankRequirements.KIND_PLAYER_DAYS] = "Player days in guild",
    [RankRequirements.KIND_RANK_DAYS] = "Days at rank",
    [RankRequirements.KIND_LEVEL] = "Character level",
}

-- The editor's kinds, in the order its kind button steps through them.
RankRequirements.KIND_ORDER = {
    RankRequirements.KIND_CHECK,
    RankRequirements.KIND_CHECK_NOTE,
    RankRequirements.KIND_CHAR_DAYS,
    RankRequirements.KIND_PLAYER_DAYS,
    RankRequirements.KIND_RANK_DAYS,
    RankRequirements.KIND_LEVEL,
}

-- The automated kinds, each with the range of its `n` and the label an
-- item gets when the officer leaves it blank.
RankRequirements.AUTOMATED = {
    [RankRequirements.KIND_CHAR_DAYS] = { low = 1, high = 3650, label = "In the guild %d days" },
    [RankRequirements.KIND_PLAYER_DAYS] = { low = 1, high = 3650, label = "Player in the guild %d days" },
    [RankRequirements.KIND_RANK_DAYS] = { low = 1, high = 3650, label = "At this rank %d days" },
    [RankRequirements.KIND_LEVEL] = { low = 1, high = 100, label = "Level %d" },
}

RankRequirements.TYPES = {
    [RankRequirements.TYPE_STATE] = true,
    [RankRequirements.TYPE_ASK] = true,
}

local Requirements = {}
Requirements.__index = Requirements

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isWhole(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

local function isStamp(record)
    return isWhole(record.at, 1, math.huge) and isText(record.by)
end

local function isLabel(value)
    return isText(value) and #value <= RankRequirements.MAX_LABEL and string.find(value, "%S") ~= nil
end

-- True when `record` has the shape of an item or rank record.
function RankRequirements.IsRecord(record)
    if type(record) ~= "table" or not isStamp(record) or not isWhole(record.rank, 0, RankRequirements.MAX_RANK) then
        return false
    end
    if record.t == "rank" then
        return isText(record.name) and #record.name <= RankRequirements.MAX_LABEL
    end
    if not (record.t == "item" and isText(record.id) and #record.id <= 80 and isLabel(record.label)
        and RankRequirements.KINDS[record.kind] ~= nil and isWhole(record.position, 0, 10000)
        and (record.deleted == nil or record.deleted == true))
    then
        return false
    end
    local automated = RankRequirements.AUTOMATED[record.kind]
    if automated == nil then
        return record.n == nil
    end
    return isWhole(record.n, automated.low, automated.high)
end

-- Whether `kind` is checked by the add-on rather than ticked.
function RankRequirements.IsAutomated(kind)
    return RankRequirements.AUTOMATED[kind] ~= nil
end

-- The label an automated item of `kind` gets for `n` when left blank.
function RankRequirements.DefaultLabel(kind, n)
    local automated = RankRequirements.AUTOMATED[kind]
    return automated and string.format(automated.label, n) or nil
end

-- Why `n` doesn't suit automated `kind`, or nil when it does.
function RankRequirements.NumberProblem(kind, n)
    local automated = RankRequirements.AUTOMATED[kind]
    if automated ~= nil and not isWhole(n, automated.low, automated.high) then
        return (kind == RankRequirements.KIND_LEVEL and "a level" or "a number of days") .. " needs to be "
            .. automated.low .. " to " .. automated.high
    end
    return nil
end

local function copy(record)
    local result = {}
    local key, value
    for key, value in pairs(record) do
        result[key] = value
    end
    return result
end

-- `saved` is the table to keep the requirements in, filled in when empty.
-- options.isOfficer(key) -> boolean.
function RankRequirements.Create(saved, options)
    if type(saved.items) ~= "table" then
        saved.items = {}
    end
    if type(saved.ranks) ~= "table" then
        saved.ranks = {}
    end
    options = options or {}
    return setmetatable({
        saved = saved,
        isOfficer = options.isOfficer or function()
            return false
        end,
    }, Requirements)
end

local function rankKey(rank)
    return "r" .. tostring(rank)
end

function Requirements:heldOf(record)
    if record.t == "rank" then
        return self.saved.ranks[rankKey(record.rank)]
    end
    return self.saved.items[record.id]
end

-- Applies a record received from another add-on (or made here): when it
-- has the right shape, its author is an officer, and it's newer than the
-- one held. Returns true when applied.
function Requirements:Apply(record)
    if not RankRequirements.IsRecord(record) then
        return false
    end
    local ok, officer = pcall(self.isOfficer, record.by)
    if not ok or officer ~= true then
        return false
    end
    local held = self:heldOf(record)
    if held ~= nil and RankRequirements.IsRecord(held)
        and not addon.SyncFacts.IsNewer(record.at, record.by, held.at, held.by)
    then
        return false
    end
    if record.t == "rank" then
        self.saved.ranks[rankKey(record.rank)] = copy(record)
    else
        self.saved.items[record.id] = copy(record)
    end
    return true
end

local function byPosition(a, b)
    if a.position ~= b.position then
        return a.position < b.position
    end
    return a.id < b.id
end

-- The live items of `rank`, in order.
function Requirements:Items(rank)
    local items = {}
    local _, record
    for _, record in pairs(self.saved.items) do
        if RankRequirements.IsRecord(record) and record.rank == rank and not record.deleted then
            table.insert(items, record)
        end
    end
    table.sort(items, byPosition)
    return items
end

-- The live item `id`, or nil.
function Requirements:Item(id)
    local record = self.saved.items[id]
    if RankRequirements.IsRecord(record) and not record.deleted then
        return record
    end
    return nil
end

-- The ranks that have requirements, lowest index first.
function Requirements:Ranks()
    local seen, ranks = {}, {}
    local _, record
    for _, record in pairs(self.saved.items) do
        if RankRequirements.IsRecord(record) and not record.deleted and not seen[record.rank] then
            seen[record.rank] = true
            table.insert(ranks, record.rank)
        end
    end
    table.sort(ranks)
    return ranks
end

-- The name `rank` had when its requirements were last edited, or nil.
function Requirements:RankName(rank)
    local record = self.saved.ranks[rankKey(rank)]
    if RankRequirements.IsRecord(record) then
        return record.name
    end
    return nil
end

-- True when `rank` has requirements and was set up under another name than
-- `gameName`, the game's name for that rank index now.
function Requirements:Mismatch(rank, gameName)
    local stored = self:RankName(rank)
    return stored ~= nil and gameName ~= nil and stored ~= gameName and self:Items(rank)[1] ~= nil
end

-- Editing ------------------------------------------------------------------------

-- A new stamp for `record`'s change by `author` at `at`: always newer than
-- the one it replaces.
function Requirements:stamped(record, author, at)
    local held = self:heldOf(record)
    if held ~= nil and isWhole(held.at, 1, math.huge) and at <= held.at then
        at = held.at + 1
    end
    record.at, record.by = at, author
    return record
end

-- Makes and applies an officer's records. Returns them, or nil and why.
function Requirements:commit(records, author)
    local ok, officer = pcall(self.isOfficer, author)
    if not ok or officer ~= true then
        return nil, "only officers can change promotion requirements"
    end
    local index
    for index = 1, #records do
        if not RankRequirements.IsRecord(records[index]) then
            return nil, "that can't be saved"
        end
    end
    for index = 1, #records do
        self:Apply(records[index])
    end
    return records
end

-- The rank's name record, when `rankName` is known.
function Requirements:nameRecord(rank, rankName, author, at)
    if not isText(rankName) then
        return nil
    end
    return self:stamped({ t = "rank", rank = rank, name = rankName }, author, at)
end

local function trimmed(text)
    return type(text) == "string" and (string.gsub(text, "^%s*(.-)%s*$", "%1")) or text
end

-- An officer adds an item of `kind` labelled `label` to the end of `rank`'s
-- list, stamping the rank's current name `rankName` too. An automated kind
-- needs its number `n`, and a blank label becomes DefaultLabel. Returns
-- the records to share, or nil and why not.
function Requirements:Add(rank, label, kind, rankName, author, at, n)
    if RankRequirements.KINDS[kind] == nil then
        return nil, "unknown kind of item"
    end
    if not RankRequirements.IsAutomated(kind) then
        n = nil
    elseif RankRequirements.NumberProblem(kind, n) then
        return nil, RankRequirements.NumberProblem(kind, n)
    end
    label = trimmed(label)
    if (label == nil or label == "") and n ~= nil then
        label = RankRequirements.DefaultLabel(kind, n)
    end
    if not isLabel(label) then
        return nil, "a label needs 1 to " .. RankRequirements.MAX_LABEL .. " characters"
    end
    local items = self:Items(rank)
    if #items >= RankRequirements.MAX_ITEMS then
        return nil, "a rank can have at most " .. RankRequirements.MAX_ITEMS .. " items"
    end
    local position = items[#items] and items[#items].position + 1 or 1
    local id = tostring(author) .. ":" .. tostring(at)
    local suffix = 1
    while self.saved.items[id] ~= nil do
        suffix = suffix + 1
        id = tostring(author) .. ":" .. tostring(at) .. ":" .. suffix
    end
    local records = {
        self:stamped({ t = "item", id = id, rank = rank, label = label, kind = kind, n = n, position = position },
            author, at),
    }
    table.insert(records, self:nameRecord(rank, rankName, author, at))
    return self:commit(records, author)
end

-- An officer changes item `id`'s `field` to `value` (a new record of the
-- whole item). Returns the records to share, or nil and why not.
function Requirements:change(id, author, at, edit)
    local item = self:Item(id)
    if item == nil then
        return nil, "that item no longer exists"
    end
    local record = copy(item)
    edit(record)
    return self:commit({ self:stamped(record, author, at) }, author)
end

-- An officer renames item `id`. Ticks on it are kept: they name the id.
function Requirements:Rename(id, label, author, at)
    label = trimmed(label)
    if not isLabel(label) then
        return nil, "a label needs 1 to " .. RankRequirements.MAX_LABEL .. " characters"
    end
    return self:change(id, author, at, function(record)
        record.label = label
    end)
end

-- An officer changes automated item `id`'s number to `n`. A label still
-- reading as the old number's default follows the new number.
function Requirements:SetNumber(id, n, author, at)
    local item = self:Item(id)
    if item == nil then
        return nil, "that item no longer exists"
    end
    if not RankRequirements.IsAutomated(item.kind) then
        return nil, "only an automated item has a number"
    end
    if RankRequirements.NumberProblem(item.kind, n) then
        return nil, RankRequirements.NumberProblem(item.kind, n)
    end
    if n == item.n then
        return {}
    end
    return self:change(id, author, at, function(record)
        if record.label == RankRequirements.DefaultLabel(record.kind, record.n) then
            record.label = RankRequirements.DefaultLabel(record.kind, n)
        end
        record.n = n
    end)
end

-- An officer deletes item `id`, leaving a tombstone.
function Requirements:Delete(id, author, at)
    return self:change(id, author, at, function(record)
        record.deleted = true
    end)
end

-- An officer moves item `id` one place up (`step` -1) or down (1) in its
-- rank's list. Every item of the rank gets its new position, so the order
-- is the same everywhere. Returns the records to share, or nil and why not.
function Requirements:Move(id, step, author, at)
    local item = self:Item(id)
    if item == nil then
        return nil, "that item no longer exists"
    end
    local items = self:Items(item.rank)
    local from
    local index
    for index = 1, #items do
        if items[index].id == id then
            from = index
        end
    end
    local to = from + (step < 0 and -1 or 1)
    if to < 1 or to > #items then
        return nil, "it can't move further"
    end
    items[from], items[to] = items[to], items[from]
    local records = {}
    for index = 1, #items do
        if items[index].position ~= index then
            local record = copy(items[index])
            record.position = index
            table.insert(records, self:stamped(record, author, at))
        end
    end
    return self:commit(records, author)
end

-- Snapshots ----------------------------------------------------------------------

-- Every record held, tombstones included, for sending to other add-ons.
function Requirements:Snapshot()
    local records = {}
    local _, record
    for _, record in pairs(self.saved.ranks) do
        if RankRequirements.IsRecord(record) then
            table.insert(records, copy(record))
        end
    end
    for _, record in pairs(self.saved.items) do
        if RankRequirements.IsRecord(record) then
            table.insert(records, copy(record))
        end
    end
    table.sort(records, function(a, b)
        local aKey = a.t == "rank" and rankKey(a.rank) or a.id
        local bKey = b.t == "rank" and rankKey(b.rank) or b.id
        if a.t ~= b.t then
            return a.t == "rank"
        end
        return aKey < bKey
    end)
    return records
end

-- True when `records` (a received snapshot) holds, for every record held
-- here, the same one or a newer one: nothing here would be news to whoever
-- sent it.
function Requirements:CoveredBy(records)
    if type(records) ~= "table" then
        return false
    end
    local heard = {}
    local index
    for index = 1, #records do
        local record = records[index]
        if RankRequirements.IsRecord(record) then
            heard[record.t == "rank" and rankKey(record.rank) or ("item:" .. record.id)] = record
        end
    end
    local held = self:Snapshot()
    for index = 1, #held do
        local record = held[index]
        local other = heard[record.t == "rank" and rankKey(record.rank) or ("item:" .. record.id)]
        if other == nil or addon.SyncFacts.IsNewer(record.at, record.by, other.at, other.by) then
            return false
        end
    end
    return true
end

-- Sharing -------------------------------------------------------------------------

-- options:
--   store()        -> this guild's RankRequirements (or another store with
--                     the same Apply, Snapshot and CoveredBy), or nil
--   stateType, askType  the message types (TYPE_STATE and TYPE_ASK by
--                     default)
--   selfKey()      -> the logged-in character's key, or nil
--   senderKey(sender) -> a character key for a message's sender
--   isOfficer(key) -> boolean
--   announce(message) sends to the guild's add-on users
--   after(seconds, callback) -> false when there are no timers
--   random(low, high)
--   onChange()     called after received records changed the requirements
local Sync = {}
Sync.__index = Sync

function RankRequirements.CreateSync(options)
    return setmetatable({
        requirements = options.store,
        stateType = options.stateType or RankRequirements.TYPE_STATE,
        askType = options.askType or RankRequirements.TYPE_ASK,
        selfKey = options.selfKey,
        senderKey = options.senderKey,
        isOfficer = options.isOfficer,
        announce = options.announce,
        after = options.after or function()
            return false
        end,
        random = options.random or function(low)
            return low
        end,
        onChange = options.onChange or function() end,
        asked = false,
        answering = false,
    }, Sync)
end

-- Sends `records` (from an edit) to the guild.
function Sync:Share(records)
    if type(records) == "table" and records[1] ~= nil then
        self.announce({ v = RankRequirements.PROTOCOL, t = self.stateType, r = records })
    end
end

-- Asks the guild's add-ons for the requirements, once a session, a while
-- after it's first called.
function Sync:AskOnce()
    if self.asked or self.requirements() == nil or self.selfKey() == nil then
        return false
    end
    self.asked = true
    local function ask()
        if self.requirements() ~= nil then
            self.announce({ v = RankRequirements.PROTOCOL, t = self.askType })
        end
    end
    if not self.after(RankRequirements.ASK_DELAY + self.random(0, RankRequirements.ASK_SPREAD), ask) then
        ask()
    end
    return true
end

-- A received message from `sender`. Returns true when the requirements
-- changed.
function Sync:OnMessage(message, sender)
    if type(message) ~= "table" or message.v ~= RankRequirements.PROTOCOL then
        return false
    end
    local requirements = self.requirements()
    local senderKey = self.senderKey(sender)
    local selfKey = self.selfKey()
    if requirements == nil or senderKey == nil or senderKey == selfKey then
        return false
    end
    if message.t == self.askType then
        self:Answer(requirements, selfKey)
        return false
    end
    if message.t ~= self.stateType or type(message.r) ~= "table" then
        return false
    end
    if self.answering and requirements:CoveredBy(message.r) then
        self.answering = false
    end
    local changed = false
    local index
    for index = 1, #message.r do
        if requirements:Apply(message.r[index]) then
            changed = true
        end
    end
    if changed then
        self.onChange()
    end
    return changed
end

-- Answers an ask with everything held, after a random short wait, unless
-- an answer covering it is heard first.
function Sync:Answer(requirements, selfKey)
    if self.answering or requirements:Snapshot()[1] == nil then
        return
    end
    self.answering = true
    local officer = selfKey ~= nil and self.isOfficer(selfKey)
    local delay = officer and self.random(RankRequirements.OFFICER_ANSWER_MIN, RankRequirements.OFFICER_ANSWER_MAX)
        or self.random(RankRequirements.ANSWER_MIN, RankRequirements.ANSWER_MAX)
    local function answer()
        if not self.answering then
            return
        end
        self.answering = false
        local current = self.requirements()
        if current ~= nil then
            self:Share(current:Snapshot())
        end
    end
    if not self.after(delay, answer) then
        answer()
    end
end
