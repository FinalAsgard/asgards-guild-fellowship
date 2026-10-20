local _, addon = ...

-- The long-term guild log: joins, invites, leaves, kicks, promotions and
-- demotions, kept forever (never pruned) in the saved table it's given.
-- Only officers' add-ons keep one. Events come from the game's guild event
-- log, whose entries carry only a relative age ("3 days ago"), and from
-- live events the add-on sees; the same event read again, or seen both
-- ways, is stored once.
--
-- Each entry: { type, character, name?, actor?, actorName?, fromRank?,
-- toRank?, rankName?, at, tolerance, source }. `character` and `actor` are
-- character keys (`name` and `actorName` their names as the game gave
-- them, for characters the roster no longer knows),
-- `fromRank` and `toRank` 0-based rank indexes (as the roster numbers
-- them), `rankName` the rank name the game gave for a rank change, `at` an
-- approximate server time, `tolerance` how far off `at` may be in seconds,
-- and `source` GuildLog.SOURCE_LOG or SOURCE_LIVE.
--
-- Pure: the caller passes the saved table and the facts.
local GuildLog = {
    JOIN = "join",
    INVITE = "invite",
    LEAVE = "leave",
    KICK = "kick",
    PROMOTE = "promote",
    DEMOTE = "demote",
    SOURCE_LOG = "log",
    SOURCE_LIVE = "live",
    HOUR = 3600,
    DAY = 86400,
    -- A live event's time is exact; this covers clocks that disagree and
    -- the game log's ages, which count whole hours.
    LIVE_TOLERANCE = 2 * 3600,
}
addon.GuildLog = GuildLog

GuildLog.TYPES = {
    GuildLog.JOIN, GuildLog.INVITE, GuildLog.LEAVE, GuildLog.KICK, GuildLog.PROMOTE, GuildLog.DEMOTE,
}
local KNOWN = {}
local index
for index = 1, #GuildLog.TYPES do
    KNOWN[GuildLog.TYPES[index]] = true
end

-- The game's event log type for each of ours, and who the entry's players
-- are: `actor` is the first player named, else none.
local GAME_TYPES = {
    join = { type = GuildLog.JOIN, character = 1 },
    invite = { type = GuildLog.INVITE, character = 2, actor = 1 },
    quit = { type = GuildLog.LEAVE, character = 1 },
    remove = { type = GuildLog.KICK, character = 2, actor = 1 },
    promote = { type = GuildLog.PROMOTE, character = 2, actor = 1, step = 1 },
    demote = { type = GuildLog.DEMOTE, character = 2, actor = 1, step = -1 },
}

local Log = {}
Log.__index = Log

local function isTime(value)
    return type(value) == "number" and value == value
end

local function count(value)
    return type(value) == "number" and value > 0 and math.floor(value) or 0
end

-- The approximate server time of an event `age` ({ years, months, days,
-- hours }, as the game log gives it) before `now`, and how far off it may
-- be: an hour's rounding, plus the length of months and years, which the
-- game doesn't say. Nil for no time.
function GuildLog.AgeToTime(now, age)
    if not isTime(now) or type(age) ~= "table" then
        return nil
    end
    local years, months = count(age.years), count(age.months)
    local seconds = (years * 365 + months * 30 + count(age.days)) * GuildLog.DAY + count(age.hours) * GuildLog.HOUR
    local tolerance = GuildLog.LIVE_TOLERANCE + (years * 12 + months) * 2 * GuildLog.DAY
    return now - seconds, tolerance
end

-- Turns entries read from the game's guild event log into events for
-- RecordBatch. Each raw entry is { type, actor, target, rank, age } as the
-- WoW adapter reads it (`actor` the first player named, `target` the
-- second). `keyOf(name)` gives a character key, and `rankIndexOf(name)` a
-- rank name's 0-based index or nil. Entries of an unknown type, or naming
-- nobody, are left out.
function GuildLog.FromGameEntries(raw, now, keyOf, rankIndexOf)
    local events = {}
    local rawIndex
    for rawIndex = 1, #(raw or {}) do
        local entry = raw[rawIndex]
        local kind = type(entry) == "table" and GAME_TYPES[entry.type] or nil
        local at, tolerance = GuildLog.AgeToTime(now, entry and entry.age)
        if kind ~= nil and at ~= nil then
            local names = { entry.actor, entry.target }
            local character = keyOf(names[kind.character])
            if character ~= nil then
                local event = {
                    type = kind.type,
                    character = character,
                    name = names[kind.character],
                    actor = kind.actor and keyOf(names[kind.actor]) or nil,
                    actorName = kind.actor and names[kind.actor] or nil,
                    at = at,
                    tolerance = tolerance,
                    source = GuildLog.SOURCE_LOG,
                }
                if kind.step ~= nil and type(entry.rank) == "string" and entry.rank ~= "" then
                    event.rankName = entry.rank
                    event.toRank = rankIndexOf(entry.rank)
                    -- Promotions and demotions move one rank at a time; a
                    -- promotion lowers the index.
                    if event.toRank ~= nil then
                        event.fromRank = event.toRank + kind.step
                    end
                end
                table.insert(events, event)
            end
        end
    end
    return events
end

-- `saved` is the table to keep the log in ({ entries = { ... } }), created
-- inside it when missing.
function GuildLog.Create(saved)
    if type(saved.entries) ~= "table" then
        saved.entries = {}
    end
    local log = setmetatable({ entries = saved.entries, byCharacter = {} }, Log)
    local entryIndex
    for entryIndex = 1, #log.entries do
        log:index(log.entries[entryIndex])
    end
    return log
end

function Log:index(entry)
    if type(entry) ~= "table" or type(entry.character) ~= "string" then
        return
    end
    local list = self.byCharacter[entry.character]
    if list == nil then
        list = {}
        self.byCharacter[entry.character] = list
    end
    table.insert(list, entry)
end

local function valid(event)
    return type(event) == "table" and KNOWN[event.type] and type(event.character) == "string"
        and event.character ~= "" and isTime(event.at)
end

-- Whether `other`, an entry of a different type, falls between two exact
-- live times: a leave between two live joins makes them two joins.
function Log:separated(a, b)
    if a.source ~= GuildLog.SOURCE_LIVE or b.source ~= GuildLog.SOURCE_LIVE then
        return false
    end
    local low, high = math.min(a.at, b.at), math.max(a.at, b.at)
    local list = self.byCharacter[a.character] or {}
    local otherIndex
    for otherIndex = 1, #list do
        local other = list[otherIndex]
        if other.type ~= a.type and other.at > low and other.at < high then
            return true
        end
    end
    return false
end

-- The stored entry `event` repeats, or nil: the same type, character, and
-- actor (when both name one), at a time within either's tolerance, and not
-- one in `skip`. The closest in time wins.
function Log:match(event, skip)
    local best, bestGap
    local list = self.byCharacter[event.character] or {}
    local entryIndex
    for entryIndex = 1, #list do
        local entry = list[entryIndex]
        if not skip[entry] and entry.type == event.type
            and (entry.actor == nil or event.actor == nil or entry.actor == event.actor)
        then
            local gap = math.abs(entry.at - event.at)
            local tolerance = math.max(entry.tolerance or GuildLog.LIVE_TOLERANCE,
                event.tolerance or GuildLog.LIVE_TOLERANCE)
            if gap <= tolerance and (bestGap == nil or gap < bestGap) and not self:separated(entry, event) then
                best, bestGap = entry, gap
            end
        end
    end
    return best
end

-- Adds what `event` knows that `entry` doesn't, and takes its time when
-- it's the more precise one.
local function merge(entry, event)
    entry.name = entry.name or event.name
    entry.actor = entry.actor or event.actor
    entry.actorName = entry.actorName or event.actorName
    entry.fromRank = entry.fromRank or event.fromRank
    entry.toRank = entry.toRank or event.toRank
    entry.rankName = entry.rankName or event.rankName
    local tolerance = event.tolerance or GuildLog.LIVE_TOLERANCE
    if tolerance < (entry.tolerance or GuildLog.LIVE_TOLERANCE) then
        entry.at = event.at
        entry.tolerance = tolerance
        entry.source = event.source
    end
end

-- Records the events of one reading (a read of the game log, or one live
-- event): each is stored unless it repeats a stored entry, which it then
-- fills in. Events of the same reading never repeat each other, and each
-- stored entry is repeated by at most one of them, so a leave and a rejoin
-- in one read stay two entries. Returns how many entries were added.
function Log:RecordBatch(events)
    local added = 0
    local used = {}
    local eventIndex
    for eventIndex = 1, #(events or {}) do
        local event = events[eventIndex]
        if valid(event) then
            local entry = self:match(event, used)
            if entry ~= nil then
                merge(entry, event)
                used[entry] = true
            else
                entry = {
                    type = event.type,
                    character = event.character,
                    name = event.name,
                    actor = event.actor,
                    actorName = event.actorName,
                    fromRank = event.fromRank,
                    toRank = event.toRank,
                    rankName = event.rankName,
                    at = event.at,
                    tolerance = event.tolerance or GuildLog.LIVE_TOLERANCE,
                    source = event.source or GuildLog.SOURCE_LIVE,
                }
                table.insert(self.entries, entry)
                self:index(entry)
                used[entry] = true
                added = added + 1
            end
        end
    end
    return added
end

-- Records one live event about `character` (named `name` by the game),
-- seen at `at`. True when it was added.
function Log:RecordLive(eventType, character, at, name)
    return self:RecordBatch({ {
        type = eventType,
        character = character,
        name = name,
        at = at,
        tolerance = GuildLog.LIVE_TOLERANCE,
        source = GuildLog.SOURCE_LIVE,
    } }) == 1
end

local function newestFirst(a, b)
    if a.at ~= b.at then
        return a.at > b.at
    end
    return tostring(a.character) < tostring(b.character)
end

-- Every entry, newest first.
function Log:Entries()
    local list = {}
    local entryIndex
    for entryIndex = 1, #self.entries do
        if valid(self.entries[entryIndex]) then
            table.insert(list, self.entries[entryIndex])
        end
    end
    table.sort(list, newestFirst)
    return list
end

-- The entries about `character`, newest first.
function Log:EntriesFor(character)
    local list = {}
    local entries = self.byCharacter[character] or {}
    local entryIndex
    for entryIndex = 1, #entries do
        if valid(entries[entryIndex]) then
            table.insert(list, entries[entryIndex])
        end
    end
    table.sort(list, newestFirst)
    return list
end

-- What happened, in words: "Joined", "Invited", "Left", "Kicked",
-- "Promoted to Officer", "Demoted to Member". `rankName(index)` names a
-- rank by its index (nil when unknown); the name the game gave is used
-- when it can't.
function GuildLog.Describe(entry, rankName)
    local words = {
        join = "Joined",
        invite = "Invited",
        leave = "Left",
        kick = "Kicked",
        promote = "Promoted",
        demote = "Demoted",
    }
    local text = words[entry.type] or tostring(entry.type)
    if entry.type == GuildLog.PROMOTE or entry.type == GuildLog.DEMOTE then
        local name = entry.toRank ~= nil and rankName and rankName(entry.toRank) or nil
        name = name or entry.rankName
        if name ~= nil then
            text = text .. " to " .. name
        end
    end
    return text
end

local function ageText(age)
    age = type(age) == "table" and age or {}
    return count(age.years) .. "y " .. count(age.months) .. "m " .. count(age.days) .. "d " ..
        count(age.hours) .. "h"
end

-- What `/agf probe log` prints: whether each event log call exists
-- (`calls`, a list of { name, present }), then, when the log could be read
-- (`raw`, as the WoW adapter reads it), how many entries it holds, the
-- oldest one's age, and the first `shown` entries as the game gave them.
function GuildLog.ProbeLines(calls, raw, shown)
    local lines = {}
    local callIndex
    for callIndex = 1, #calls do
        table.insert(lines, calls[callIndex].name .. ": " .. (calls[callIndex].present and "yes" or "missing"))
    end
    if raw == nil then
        table.insert(lines, "The guild event log can't be read here; joins and leaves are recorded as they happen.")
        return lines
    end
    table.insert(lines, "Entries: " .. #raw)
    local oldest, oldestAt
    local rawIndex
    for rawIndex = 1, #raw do
        local at = GuildLog.AgeToTime(0, raw[rawIndex].age)
        if at ~= nil and (oldestAt == nil or at < oldestAt) then
            oldest, oldestAt = raw[rawIndex], at
        end
    end
    if oldest ~= nil then
        table.insert(lines, "Oldest entry: " .. ageText(oldest.age) .. " ago")
    end
    for rawIndex = 1, math.min(shown or 5, #raw) do
        local entry = raw[rawIndex]
        table.insert(lines, rawIndex .. ": type=" .. tostring(entry.type) .. " actor=" .. tostring(entry.actor) ..
            " target=" .. tostring(entry.target) .. " rank=" .. tostring(entry.rank) .. " age=" .. ageText(entry.age))
    end
    return lines
end
