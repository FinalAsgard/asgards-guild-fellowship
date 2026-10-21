local _, addon = ...

-- A few dates for each character, shared with the whole guild: when it
-- joined, and since when it has held its rank. The automated promotion
-- checks read them.
--
-- Each date is a record { time, source, tolerance?, rank?, at?, by? }:
--   joined     `source` is officer (set by hand), log or live (from the
--              officers' guild log), first-seen (when this add-on first saw
--              it in the guild: approximate), or before-tracking (it was
--              already in the guild when tracking started, which counts as
--              older than any N).
--   rankSince  also carries `rank` (0-based, as the roster numbers ranks),
--              the rank it applies to. `source` is officer, log (a logged
--              promotion or demotion), seen (when a roster scan saw the
--              rank change) or before-tracking.
--   addonSeen  when an officer's add-on last heard the character's add-on
--              (`source` heard). The newest time wins, and like every date
--              fact it's accepted only from officers. Each add-on also keeps
--              the time it heard the character itself (`heard`, local).
-- `tolerance` is how far off a logged time may be. `at` and `by` stamp a
-- record an officer's add-on wrote: those are officer facts and travel to
-- every add-on with guild sync (see SyncFacts). Records worked out from
-- this add-on's own roster scans carry no stamp and stay local: every
-- add-on sees the same roster.
--
-- Which record wins (Replaces): the newest real join wins, so a rejoin
-- restarts it; among records of the same join, the more precise source
-- (officer-set over log, log over live, live over first-seen); a
-- before-tracking mark only fills a gap, and anything else replaces it.
-- For rankSince, a record for another rank wins when it's newer; for the
-- same rank, officer-set over log over seen. An officer's own newer record
-- always replaces their older one. Every add-on applies the same rule, so
-- they settle on the same dates.
--
-- The tracking-start mark: the first roster scan in a guild with no mark
-- sets it, and every character present then is before-tracking. An
-- officer's mark is shared; the earliest wins.
--
-- Stored in the table it's given: { tracking = { time, at?, by? },
-- characters = { [key] = { joined, rankSince, addonSeen, heard?, left? } } },
-- where `left` is when a scan last found the character gone (so its return
-- is a rejoin).
--
-- Pure: the caller passes the saved table and the facts.
local MembershipDates = {
    KIND_JOINED = "joined",
    KIND_RANK_SINCE = "rankSince",
    KIND_TRACKING = "tracking",
    OFFICER = "officer",
    LOG = "log",
    LIVE = "live",
    FIRST_SEEN = "first-seen",
    SEEN = "seen",
    BEFORE_TRACKING = "before-tracking",
    -- Two records of a join closer than this (or than either's tolerance)
    -- are the same join.
    SAME_JOIN_SECONDS = 2 * 3600,
    -- When the character's add-on was last heard (see Heard).
    KIND_ADDON_SEEN = "addonSeen",
    HEARD = "heard",
    -- An officer's add-on shares a character's last-heard time once it's
    -- this much newer than the one the guild already has: the add-on check
    -- counts days, so a day's precision is enough, and it keeps the traffic
    -- to about one fact per character a day.
    HEARD_SHARE_SECONDS = 24 * 3600,
    -- The character's last promotion: when, to which rank, and by whom.
    KIND_LAST_PROMOTION = "lastPromotion",
    -- Promoted with the Promote button older versions had (add-ons can't
    -- promote): such records still load.
    ADDON = "addon",
}
addon.MembershipDates = MembershipDates

MembershipDates.KINDS = {
    [MembershipDates.KIND_JOINED] = true,
    [MembershipDates.KIND_RANK_SINCE] = true,
    [MembershipDates.KIND_TRACKING] = true,
    [MembershipDates.KIND_ADDON_SEEN] = true,
    [MembershipDates.KIND_LAST_PROMOTION] = true,
}

local PROMOTION_SOURCES = {
    addon = 2,
    log = 1,
}

local JOIN_SOURCES = {
    officer = 4,
    log = 3,
    live = 2,
    ["first-seen"] = 1,
    ["before-tracking"] = 0,
}
local RANK_SOURCES = {
    officer = 3,
    log = 2,
    seen = 1,
    ["before-tracking"] = 0,
}

local Dates = {}
Dates.__index = Dates

local function isTime(value)
    return type(value) == "number" and value == value and value >= 0 and value == math.floor(value)
end

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isRank(value)
    return type(value) == "number" and value >= 0 and value <= 9 and value == math.floor(value)
end

-- True when `record` has the shape of a `kind` record.
local function isRecord(kind, record)
    if type(record) ~= "table" or not isTime(record.time) then
        return false
    end
    if record.tolerance ~= nil and not isTime(record.tolerance) then
        return false
    end
    if (record.at ~= nil or record.by ~= nil) and not (isTime(record.at) and isText(record.by)) then
        return false
    end
    if kind == MembershipDates.KIND_JOINED then
        return JOIN_SOURCES[record.source] ~= nil
    end
    if kind == MembershipDates.KIND_ADDON_SEEN then
        return record.source == MembershipDates.HEARD and record.rank == nil
    end
    if kind == MembershipDates.KIND_LAST_PROMOTION then
        return PROMOTION_SOURCES[record.source] ~= nil and isRank(record.rank) and isText(record.promoter)
            and #record.promoter <= 80
    end
    if record.promoter ~= nil then
        return false
    end
    return RANK_SOURCES[record.source] ~= nil and isRank(record.rank)
end

-- Newest wins; the same second is settled by author, as for guild sync.
local function newerStamp(record, held)
    return addon.SyncFacts.IsNewer(record.at, record.by, held.at, held.by)
end

local function sameAuthorNewer(new, held)
    return new.by ~= nil and new.by == held.by and held.at ~= nil and new.at > held.at
end

local function tolerance(record)
    return record.tolerance or 0
end

-- Whether `new` should replace `held` (either may be nil for none) as the
-- `kind` record of one character.
function MembershipDates.Replaces(kind, held, new)
    if new == nil then
        return false
    end
    if held == nil then
        return true
    end
    -- The newest time heard wins; the same time, the newer stamp.
    if kind == MembershipDates.KIND_ADDON_SEEN then
        if new.time ~= held.time then
            return new.time > held.time
        end
        return new.by ~= nil and (held.by == nil or newerStamp(new, held))
    end
    -- A later promotion wins; two records of the same one (same rank, close
    -- in time) prefer the add-on's own record over the log's, then the
    -- newer stamp.
    if kind == MembershipDates.KIND_LAST_PROMOTION then
        local window = math.max(MembershipDates.SAME_JOIN_SECONDS, tolerance(new), tolerance(held))
        if new.rank ~= held.rank or math.abs(new.time - held.time) > window then
            return new.time > held.time
        end
        if PROMOTION_SOURCES[new.source] ~= PROMOTION_SOURCES[held.source] then
            return PROMOTION_SOURCES[new.source] > PROMOTION_SOURCES[held.source]
        end
        return new.by ~= nil and (held.by == nil or newerStamp(new, held))
    end
    if new.source == MembershipDates.BEFORE_TRACKING then
        return false
    end
    if sameAuthorNewer(new, held) then
        return true
    end
    if held.source == MembershipDates.BEFORE_TRACKING then
        return true
    end
    if kind == MembershipDates.KIND_JOINED then
        local window = math.max(MembershipDates.SAME_JOIN_SECONDS, tolerance(new), tolerance(held))
        if new.source == MembershipDates.OFFICER then
            return held.source ~= MembershipDates.OFFICER or newerStamp(new, held)
        end
        -- An officer's date covers every join up to when they set it; only
        -- a join after that is a rejoin.
        if held.source == MembershipDates.OFFICER then
            return new.time > math.max(held.at or 0, held.time + window)
        end
        -- A later join: the character rejoined.
        if new.time > held.time + window then
            return true
        end
        -- First seen only says it was in the guild by then; a logged join
        -- is when it really joined.
        if held.source == MembershipDates.FIRST_SEEN then
            return new.source ~= MembershipDates.FIRST_SEEN
        end
        if new.time < held.time - window then
            return false
        end
        if JOIN_SOURCES[new.source] ~= JOIN_SOURCES[held.source] then
            return JOIN_SOURCES[new.source] > JOIN_SOURCES[held.source]
        end
        return new.time < held.time
    end
    if new.rank ~= held.rank then
        return new.time > held.time
    end
    if new.source == MembershipDates.OFFICER then
        return held.source ~= MembershipDates.OFFICER or newerStamp(new, held)
    end
    if held.source == MembershipDates.OFFICER then
        return false
    end
    if RANK_SOURCES[new.source] ~= RANK_SOURCES[held.source] then
        return RANK_SOURCES[new.source] > RANK_SOURCES[held.source]
    end
    -- The same rank again later (after a demotion and a new promotion) is
    -- the current stint; two reads of one change settle on the earlier.
    local window = math.max(MembershipDates.SAME_JOIN_SECONDS, tolerance(new), tolerance(held))
    if new.time > held.time + window then
        return true
    end
    return new.time < held.time - window or (math.abs(new.time - held.time) <= window and new.time < held.time)
end

-- `saved` is the table to keep the dates in, filled in when empty.
-- options.isOfficer(key) -> boolean decides whose records are shared.
function MembershipDates.Create(saved, options)
    if type(saved.characters) ~= "table" then
        saved.characters = {}
    end
    if saved.tracking ~= nil and (type(saved.tracking) ~= "table" or not isTime(saved.tracking.time)) then
        saved.tracking = nil
    end
    options = options or {}
    return setmetatable({
        saved = saved,
        isOfficer = options.isOfficer or function()
            return false
        end,
    }, Dates)
end

function Dates:entry(key, create)
    local entry = self.saved.characters[key]
    if type(entry) ~= "table" then
        entry = nil
        if create then
            entry = {}
            self.saved.characters[key] = entry
        end
    end
    return entry
end

function Dates:held(key, kind)
    local entry = self:entry(key)
    local record = entry and entry[kind]
    if isRecord(kind, record) then
        return record
    end
    return nil
end

-- Stores `record` as `key`'s `kind` record when it wins. True when it did.
function Dates:Offer(key, kind, record)
    if not isText(key) or not isRecord(kind, record) then
        return false
    end
    if not MembershipDates.Replaces(kind, self:held(key, kind), record) then
        return false
    end
    self:entry(key, true)[kind] = record
    return true
end

-- `key`'s join record, or nil when it isn't known.
function Dates:Joined(key)
    return self:held(key, MembershipDates.KIND_JOINED)
end

-- Since when `key` has held `rank`: its record, or nil when the record is
-- for another rank (or there is none).
function Dates:RankSince(key, rank)
    local record = self:held(key, MembershipDates.KIND_RANK_SINCE)
    if record ~= nil and (rank == nil or record.rank == rank) then
        return record
    end
    return nil
end

-- When tracking started in this guild, or nil before the first scan.
function Dates:TrackingStart()
    return self.saved.tracking and self.saved.tracking.time or nil
end

-- After a roster scan: `present` maps each character in the guild now to
-- its rank. The first scan in a guild with no tracking mark sets one and
-- marks every character before-tracking. Otherwise a character seen for
-- the first time, or back after a scan found it gone, is first seen now,
-- and one seen at a rank its record isn't for has held that rank since
-- now. These records are local. Returns true when this scan set the
-- tracking mark.
function Dates:ObserveScan(present, now)
    if not isTime(now) then
        return false
    end
    local marking = self.saved.tracking == nil
    if marking then
        self.saved.tracking = { time = now }
    end
    local key, entry
    for key, entry in pairs(self.saved.characters) do
        if type(entry) == "table" and present[key] == nil and entry.left == nil then
            entry.left = now
        end
    end
    local rank
    for key, rank in pairs(present) do
        local held = self:entry(key)
        if marking then
            self:Offer(key, MembershipDates.KIND_JOINED, { time = now, source = MembershipDates.BEFORE_TRACKING })
            if isRank(rank) then
                self:Offer(key, MembershipDates.KIND_RANK_SINCE,
                    { time = now, rank = rank, source = MembershipDates.BEFORE_TRACKING })
            end
        else
            if held == nil or held.joined == nil or held.left ~= nil then
                self:Offer(key, MembershipDates.KIND_JOINED, { time = now, source = MembershipDates.FIRST_SEEN })
            end
            local since = self:held(key, MembershipDates.KIND_RANK_SINCE)
            if isRank(rank) and (since == nil or since.rank ~= rank) then
                self:Offer(key, MembershipDates.KIND_RANK_SINCE, { time = now, rank = rank, source = MembershipDates.SEEN })
            end
        end
        held = self:entry(key)
        if held ~= nil then
            held.left = nil
        end
    end
    return marking
end

-- The fact for `key`'s `kind` record, as guild sync carries it, or nil.
function Dates:FactOf(key, kind)
    if kind == MembershipDates.KIND_TRACKING then
        local tracking = self.saved.tracking
        if tracking == nil or tracking.by == nil then
            return nil
        end
        return { kind = kind, character = tracking.by, time = tracking.time, at = tracking.at, by = tracking.by }
    end
    local record = self:held(key, kind)
    if record == nil or record.by == nil then
        return nil
    end
    return {
        kind = kind,
        character = key,
        time = record.time,
        source = record.source,
        tolerance = record.tolerance,
        rank = record.rank,
        promoter = record.promoter,
        at = record.at,
        by = record.by,
    }
end

-- Stamps `key`'s `kind` record as `author`'s at `at`, when it changed
-- here. Returns its fact.
function Dates:stamp(key, kind, author, at)
    local record = self:held(key, kind)
    record.at = math.max(at, (record.at or 0) + 1)
    record.by = author
    return self:FactOf(key, kind)
end

-- An officer's add-on read `entries` (guild log entries, as GuildLog
-- returns them) into its log: joins and logged rank changes become dates,
-- and a logged promotion that names who did it the last promotion too,
-- stamped as `author`'s at `now`. Returns the facts to share.
function Dates:FromLog(entries, author, now)
    local facts = {}
    if not isText(author) or not isTime(now) then
        return facts
    end
    local index
    for index = 1, #(entries or {}) do
        local entry = entries[index]
        local records = {}
        if entry.type == addon.GuildLog.JOIN then
            records[MembershipDates.KIND_JOINED] = {
                time = entry.at,
                tolerance = entry.tolerance,
                source = entry.source == addon.GuildLog.SOURCE_LOG and MembershipDates.LOG or MembershipDates.LIVE,
            }
        elseif (entry.type == addon.GuildLog.PROMOTE or entry.type == addon.GuildLog.DEMOTE) and isRank(entry.toRank) then
            records[MembershipDates.KIND_RANK_SINCE] =
                { time = entry.at, tolerance = entry.tolerance, rank = entry.toRank, source = MembershipDates.LOG }
            if entry.type == addon.GuildLog.PROMOTE and isText(entry.actor) then
                records[MembershipDates.KIND_LAST_PROMOTION] = { time = entry.at, tolerance = entry.tolerance,
                    rank = entry.toRank, promoter = entry.actor, source = MembershipDates.LOG }
            end
        end
        local _, kind
        for _, kind in ipairs({ MembershipDates.KIND_JOINED, MembershipDates.KIND_RANK_SINCE,
            MembershipDates.KIND_LAST_PROMOTION })
        do
            if records[kind] ~= nil and self:Offer(entry.character, kind, records[kind]) then
                table.insert(facts, self:stamp(entry.character, kind, author, now))
            end
        end
    end
    return facts
end

-- `key`'s last promotion { time, rank, promoter, source }, or nil.
function Dates:LastPromotion(key)
    return self:held(key, MembershipDates.KIND_LAST_PROMOTION)
end

-- An officer (`author`) sets `key`'s `kind` date ("joined" or
-- "rankSince") to `time` by hand at `now`; a rankSince date is for `rank`,
-- the character's current rank. Returns its fact, or nil and why not.
function Dates:SetByOfficer(key, kind, time, rank, author, now)
    if not self.isOfficer(author) then
        return nil, "only officers can set dates"
    end
    if kind ~= MembershipDates.KIND_JOINED and kind ~= MembershipDates.KIND_RANK_SINCE then
        return nil, "unknown date"
    end
    if not isTime(time) or not isTime(now) or time > now then
        return nil, "that date isn't in the past"
    end
    local record = { time = time, source = MembershipDates.OFFICER, at = now, by = author }
    if kind == MembershipDates.KIND_RANK_SINCE then
        if not isRank(rank) then
            return nil, "the character's rank isn't known"
        end
        record.rank = rank
    end
    local held = self:held(key, kind)
    if held ~= nil and held.at ~= nil then
        record.at = math.max(now, held.at + 1)
    end
    if not self:Offer(key, kind, record) then
        return nil, "a newer date is already set"
    end
    return self:FactOf(key, kind)
end

-- An add-on message was heard directly from `key` at `now`. Every add-on
-- keeps the newest time it heard each character itself, locally (`heard`
-- on the character's entry); only officers' add-ons pass it on (see
-- ShareHeard). Returns true when the time moved on.
function Dates:Heard(key, now)
    if not isText(key) or not isTime(now) then
        return false
    end
    local entry = self:entry(key, true)
    if isTime(entry.heard) and entry.heard >= now then
        return false
    end
    entry.heard = now
    return true
end

-- On an officer's (`author`'s) add-on: when it heard `key` at least
-- HEARD_SHARE_SECONDS later than the last-heard time the guild has, that
-- time becomes `author`'s fact at `now`, to share. Returns it, or nil.
function Dates:ShareHeard(key, author, now)
    local entry = self:entry(key)
    if entry == nil or not isTime(entry.heard) or not isText(author) or not isTime(now) then
        return nil
    end
    local held = self:held(key, MembershipDates.KIND_ADDON_SEEN)
    if held ~= nil and entry.heard - held.time < MembershipDates.HEARD_SHARE_SECONDS then
        return nil
    end
    entry[MembershipDates.KIND_ADDON_SEEN] = {
        time = entry.heard,
        source = MembershipDates.HEARD,
        at = math.max(now, held and held.at and held.at + 1 or 0),
        by = author,
    }
    return self:FactOf(key, MembershipDates.KIND_ADDON_SEEN)
end

-- When any of `keys`' add-ons was last heard, by this add-on or by an
-- officer's, or nil when never.
function Dates:LastHeard(keys)
    local best
    local index
    for index = 1, #keys do
        local entry = self:entry(keys[index])
        if entry ~= nil then
            if isTime(entry.heard) and (best == nil or entry.heard > best) then
                best = entry.heard
            end
            local shared = self:held(keys[index], MembershipDates.KIND_ADDON_SEEN)
            if shared ~= nil and (best == nil or shared.time > best) then
                best = shared.time
            end
        end
    end
    return best
end

-- A tracking-start mark this officer's add-on set (ObserveScan), stamped
-- as `author`'s at `now`, as a fact to share; nil when there's none to
-- share.
function Dates:StampTracking(author, now)
    local tracking = self.saved.tracking
    if tracking == nil or tracking.by ~= nil or not isText(author) or not isTime(now) then
        return nil
    end
    tracking.at, tracking.by = now, author
    return self:FactOf(nil, MembershipDates.KIND_TRACKING)
end

-- Guild sync ------------------------------------------------------------------

-- True when `fact` (already checked for a character, stamp and author)
-- carries a usable date of its kind.
function MembershipDates.IsFact(fact)
    if fact.kind == MembershipDates.KIND_TRACKING then
        return isTime(fact.time)
    end
    return MembershipDates.KINDS[fact.kind] == true and isRecord(fact.kind, {
        time = fact.time, source = fact.source, tolerance = fact.tolerance, rank = fact.rank,
        promoter = fact.promoter, at = fact.at, by = fact.by,
    })
end

local function recordOf(fact)
    return {
        time = fact.time,
        source = fact.source,
        tolerance = fact.tolerance,
        rank = fact.rank,
        promoter = fact.promoter,
        at = fact.at,
        by = fact.by,
    }
end

-- Whether a received fact would change anything here.
function Dates:Wins(fact)
    if fact.kind == MembershipDates.KIND_TRACKING then
        local tracking = self.saved.tracking
        return tracking == nil or fact.time < tracking.time
            or (fact.time == tracking.time and tracking.by == nil)
    end
    return MembershipDates.Replaces(fact.kind, self:held(fact.character, fact.kind), recordOf(fact))
end

-- Applies a received fact that Wins.
function Dates:Apply(fact)
    if fact.kind == MembershipDates.KIND_TRACKING then
        self.saved.tracking = { time = fact.time, at = fact.at, by = fact.by }
        return
    end
    self:entry(fact.character, true)[fact.kind] = recordOf(fact)
end

-- Re-stamps this officer's own record of `kind` about `key` at `at`, to
-- correct a forgery in their name. Returns its fact, or nil when there's
-- none.
function Dates:Restamp(key, kind, author, at)
    if kind == MembershipDates.KIND_TRACKING then
        local tracking = self.saved.tracking
        if tracking == nil then
            return nil
        end
        tracking.at, tracking.by = at, author
        return self:FactOf(nil, kind)
    end
    if self:held(key, kind) == nil then
        return nil
    end
    return self:stamp(key, kind, author, at)
end

-- Every date fact this add-on can pass on: stamped records whose author is
-- an officer now, the tracking mark first, then by character. `checkpoint`,
-- when given, is called after each character.
function Dates:Facts(checkpoint)
    local facts = {}
    local tracking = self:FactOf(nil, MembershipDates.KIND_TRACKING)
    if tracking ~= nil and self.isOfficer(tracking.by) then
        table.insert(facts, tracking)
    end
    local keys = {}
    local key
    for key in pairs(self.saved.characters) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local index
    for index = 1, #keys do
        local _, kind
        for _, kind in ipairs({ MembershipDates.KIND_JOINED, MembershipDates.KIND_RANK_SINCE,
            MembershipDates.KIND_ADDON_SEEN, MembershipDates.KIND_LAST_PROMOTION })
        do
            local fact = self:FactOf(keys[index], kind)
            if fact ~= nil and self.isOfficer(fact.by) then
                table.insert(facts, fact)
            end
        end
        if checkpoint ~= nil then
            checkpoint()
        end
    end
    return facts
end

-- Reading ---------------------------------------------------------------------

-- The earliest join among `keys` (a player's characters in the guild now):
-- { time, beforeTracking, approximate }, or nil when none is known. A
-- before-tracking join is older than any other.
function Dates:EarliestJoin(keys)
    local best
    local index
    for index = 1, #keys do
        local record = self:Joined(keys[index])
        if record ~= nil then
            local before = record.source == MembershipDates.BEFORE_TRACKING
            if best == nil or (before and not best.beforeTracking)
                or (before == best.beforeTracking and record.time < best.time)
            then
                best = {
                    time = record.time,
                    beforeTracking = before,
                    approximate = record.source == MembershipDates.FIRST_SEEN,
                }
            end
        end
    end
    return best
end

-- A date record in words: "2026-10-01", "2026-10-01 (approx.)", or
-- "before tracking". `formatDate(time)` formats a time.
function MembershipDates.Describe(record, formatDate)
    if record == nil then
        return "unknown"
    end
    if record.source == MembershipDates.BEFORE_TRACKING or record.beforeTracking then
        return "before tracking"
    end
    local text = formatDate(record.time)
    if record.source == MembershipDates.FIRST_SEEN or record.source == MembershipDates.SEEN or record.approximate then
        text = text .. " (approx.)"
    end
    return text
end

-- The server time of midnight UTC on `text` ("YYYY-MM-DD"), or nil when it
-- isn't a date.
function MembershipDates.ParseDate(text)
    local year, month, day = string.match(tostring(text or ""), "^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if year == nil or month < 1 or month > 12 or day < 1 then
        return nil
    end
    local leap = (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
    local lengths = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if day > lengths[month] then
        return nil
    end
    -- Days since 1970-01-01 (the civil-from-days algorithm, reversed).
    local y = month <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (month + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400
end
