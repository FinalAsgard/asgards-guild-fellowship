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
-- Of two records of one event, whether `event`'s time is the better one:
-- the more precise, then a live one over one from the game log, then the
-- earlier. Every add-on picks the same, so officers' logs settle on one
-- time for each event.
local function betterTime(event, entry)
    local tolerance = event.tolerance or GuildLog.LIVE_TOLERANCE
    local held = entry.tolerance or GuildLog.LIVE_TOLERANCE
    if tolerance ~= held then
        return tolerance < held
    end
    local live, heldLive = event.source == GuildLog.SOURCE_LIVE, entry.source == GuildLog.SOURCE_LIVE
    if live ~= heldLive then
        return live
    end
    return event.at < entry.at
end

-- Adds what `event` knows that `entry` doesn't, and takes its time when
-- it's the better one. True when `entry` changed.
local function merge(entry, event)
    local changed = false
    local fields = { "name", "actor", "actorName", "fromRank", "toRank", "rankName" }
    local fieldIndex
    for fieldIndex = 1, #fields do
        local field = fields[fieldIndex]
        if entry[field] == nil and event[field] ~= nil then
            entry[field] = event[field]
            changed = true
        end
    end
    if betterTime(event, entry) then
        entry.at = event.at
        entry.tolerance = event.tolerance or GuildLog.LIVE_TOLERANCE
        entry.source = event.source or GuildLog.SOURCE_LIVE
        changed = true
    end
    return changed
end

-- Records the events of one reading (a read of the game log, or one live
-- event): each is stored unless it repeats a stored entry, which it then
-- fills in. Events of the same reading never repeat each other, and each
-- stored entry is repeated by at most one of them, so a leave and a rejoin
-- in one read stay two entries. `checkpoint`, when given, is called after
-- each event so a scheduler can spread the work across frames. Returns how
-- many entries were added, and the entries added or changed.
function Log:RecordBatch(events, checkpoint)
    local added = 0
    local changed = {}
    local used = {}
    local eventIndex
    for eventIndex = 1, #(events or {}) do
        local event = events[eventIndex]
        if valid(event) then
            local entry = self:match(event, used)
            if entry ~= nil then
                if merge(entry, event) then
                    table.insert(changed, entry)
                end
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
                table.insert(changed, entry)
            end
        end
        if checkpoint ~= nil then
            checkpoint()
        end
    end
    return added, changed
end

-- Records one live event about `character` (named `name` by the game),
-- seen at `at`. True when it was added, and the entries added or changed
-- (as RecordBatch).
function Log:RecordLive(eventType, character, at, name)
    local added, changed = self:RecordBatch({ {
        type = eventType,
        character = character,
        name = name,
        at = at,
        tolerance = GuildLog.LIVE_TOLERANCE,
        source = GuildLog.SOURCE_LIVE,
    } })
    return added == 1, changed
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

-- One page of entries that pass the filters. options:
--   types       set of entry types to keep ({ join = true, ... }), or nil
--               for every type
--   from, to    keep entries at or after `from` and at or before `to`
--               (either may be nil)
--   characters  set of character keys to keep, or nil for everyone
--   sort        "date" (newest first, the default) or "name" (by
--               `nameOf(entry)`, then newest first)
--   nameOf      function(entry) -> the name to sort by (default the key)
--   page        1-based page number (default 1; past the end gives the
--               last page)
--   pageSize    entries per page (default PAGE_SIZE)
-- Returns { entries, total, page, pages }: `total` entries passed the
-- filters, over `pages` pages (at least 1).
GuildLog.PAGE_SIZE = 100

function Log:Query(options)
    options = options or {}
    local matches = {}
    local entryIndex
    for entryIndex = 1, #self.entries do
        local entry = self.entries[entryIndex]
        if valid(entry)
            and (options.types == nil or options.types[entry.type])
            and (options.from == nil or entry.at >= options.from)
            and (options.to == nil or entry.at <= options.to)
            and (options.characters == nil or options.characters[entry.character])
        then
            table.insert(matches, entry)
        end
    end
    if options.sort == "name" then
        local nameOf = options.nameOf or function(entry)
            return entry.character
        end
        local names = {}
        for entryIndex = 1, #matches do
            names[matches[entryIndex]] = string.lower(tostring(nameOf(matches[entryIndex]) or ""))
        end
        table.sort(matches, function(a, b)
            if names[a] ~= names[b] then
                return names[a] < names[b]
            end
            return newestFirst(a, b)
        end)
    else
        table.sort(matches, newestFirst)
    end
    local pageSize = type(options.pageSize) == "number" and options.pageSize >= 1 and math.floor(options.pageSize)
        or GuildLog.PAGE_SIZE
    local pages = math.max(1, math.ceil(#matches / pageSize))
    local page = type(options.page) == "number" and math.floor(options.page) or 1
    page = math.max(1, math.min(page, pages))
    local entries = {}
    for entryIndex = (page - 1) * pageSize + 1, math.min(page * pageSize, #matches) do
        table.insert(entries, matches[entryIndex])
    end
    return { entries = entries, total = #matches, page = page, pages = pages }
end

-- Sharing between officers -------------------------------------------------------

-- Officers compare their logs the way guild sync compares facts (see
-- SyncDigest), in buckets of MONTH by entry time: an officer who was away
-- a week differs in the latest month or two, so catching up sends only
-- those months' entries. A month's checksum is the sum of its entries'
-- hashes, over what officers' logs settle on for an entry (see merge), so
-- two officers who hold the same entries agree.
GuildLog.MONTH = 30 * GuildLog.DAY
-- The most months a digest from another officer may name (a century).
GuildLog.MAX_MONTHS = 1200
-- The longest text an entry from another officer may carry.
GuildLog.MAX_TEXT = 64
-- The highest rank index the game has.
GuildLog.MAX_RANK = 9

local MODULUS = 4294967296
local SEPARATOR = "\31"

-- The same string hash as SyncDigest's.
local function hash(text)
    local value = 5381
    local position
    for position = 1, #text do
        value = (value * 33 + string.byte(text, position)) % MODULUS
    end
    return value
end

-- Which month `at` falls in.
function GuildLog.MonthOf(at)
    return math.floor(at / GuildLog.MONTH)
end

function GuildLog.HashOf(entry)
    return hash(table.concat({
        tostring(entry.type), tostring(entry.character), tostring(entry.actor or ""),
        tostring(entry.toRank or ""), tostring(math.floor(entry.at)),
    }, SEPARATOR))
end

-- The checksum of each month that holds an entry: { [month] = checksum }.
-- `checkpoint`, as for RecordBatch.
function Log:Digest(checkpoint)
    local digest = {}
    local entryIndex
    for entryIndex = 1, #self.entries do
        local entry = self.entries[entryIndex]
        if valid(entry) then
            local month = GuildLog.MonthOf(entry.at)
            digest[month] = ((digest[month] or 0) + GuildLog.HashOf(entry)) % MODULUS
        end
        if checkpoint ~= nil then
            checkpoint()
        end
    end
    return digest
end

local function isWhole(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

-- True when `digest` has the shape of a digest (it came from another
-- officer).
function GuildLog.IsDigest(digest)
    if type(digest) ~= "table" then
        return false
    end
    local months = 0
    local month, checksum
    for month, checksum in pairs(digest) do
        months = months + 1
        if months > GuildLog.MAX_MONTHS or not isWhole(month, 0, math.huge) or not isWhole(checksum, 0, MODULUS - 1) then
            return false
        end
    end
    return true
end

-- The months where two valid digests differ, oldest first. Empty when they
-- agree.
function GuildLog.DifferingMonths(mine, theirs)
    local months = {}
    local month, checksum
    for month, checksum in pairs(mine) do
        if theirs[month] ~= checksum then
            table.insert(months, month)
        end
    end
    for month in pairs(theirs) do
        if mine[month] == nil then
            table.insert(months, month)
        end
    end
    table.sort(months)
    return months
end

-- True when `months` is a list of months (it came from another officer).
function GuildLog.IsMonthList(months)
    if type(months) ~= "table" or #months > GuildLog.MAX_MONTHS then
        return false
    end
    local monthIndex
    for monthIndex = 1, #months do
        if not isWhole(months[monthIndex], 0, math.huge) then
            return false
        end
    end
    return true
end

-- An entry as it travels: only its fields, in a new table.
local function copy(entry)
    return {
        type = entry.type,
        character = entry.character,
        name = entry.name,
        actor = entry.actor,
        actorName = entry.actorName,
        fromRank = entry.fromRank,
        toRank = entry.toRank,
        rankName = entry.rankName,
        at = entry.at,
        tolerance = entry.tolerance,
        source = entry.source,
    }
end
GuildLog.Copy = copy

-- Copies of the entries that lie in any of `months`. `checkpoint`, as for
-- RecordBatch.
function Log:EntriesInMonths(months, checkpoint)
    local wanted = {}
    local monthIndex
    for monthIndex = 1, #months do
        wanted[months[monthIndex]] = true
    end
    local found = {}
    local entryIndex
    for entryIndex = 1, #self.entries do
        local entry = self.entries[entryIndex]
        if valid(entry) and wanted[GuildLog.MonthOf(entry.at)] then
            table.insert(found, copy(entry))
        end
        if checkpoint ~= nil then
            checkpoint()
        end
    end
    return found
end

local function text(value)
    if type(value) == "string" and value ~= "" and #value <= GuildLog.MAX_TEXT then
        return value
    end
    return nil
end

local function rank(value)
    if isWhole(value, 0, GuildLog.MAX_RANK) then
        return value
    end
    return nil
end

-- An entry from another officer, cleaned: only known fields of the right
-- kind, or nil when it isn't an entry at all.
function GuildLog.Clean(entry)
    if type(entry) ~= "table" or not KNOWN[entry.type] or text(entry.character) == nil
        or not isWhole(entry.at, 0, math.huge)
    then
        return nil
    end
    local tolerance = entry.tolerance
    if not isWhole(tolerance, 0, 100 * 365 * GuildLog.DAY) then
        tolerance = GuildLog.LIVE_TOLERANCE
    end
    return {
        type = entry.type,
        character = entry.character,
        name = text(entry.name),
        actor = text(entry.actor),
        actorName = text(entry.actorName),
        fromRank = rank(entry.fromRank),
        toRank = rank(entry.toRank),
        rankName = text(entry.rankName),
        at = entry.at,
        tolerance = tolerance,
        source = entry.source == GuildLog.SOURCE_LOG and GuildLog.SOURCE_LOG or GuildLog.SOURCE_LIVE,
    }
end

-- Merges `entries` received from another officer: each is cleaned (those
-- that aren't entries are dropped) and recorded as one reading, so it
-- fills in the entry it repeats rather than adding a second. `checkpoint`,
-- as for RecordBatch. Returns how many were added, and the entries added
-- or changed.
function Log:Merge(entries, checkpoint)
    local events = {}
    local entryIndex
    for entryIndex = 1, #(type(entries) == "table" and entries or {}) do
        local event = GuildLog.Clean(entries[entryIndex])
        if event ~= nil then
            table.insert(events, event)
        end
    end
    return self:RecordBatch(events, checkpoint)
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
