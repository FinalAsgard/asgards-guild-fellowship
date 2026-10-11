local _, addon = ...

-- When the guild last advertised in each channel. Pure: it keeps its times
-- in the saved table it's given ({ [channel key] = server time }), so they
-- last across reloads and logouts.
--
-- A channel's key is RecruitLedger.GeneralKey(zone) for a zone's General
-- channel, so each zone has its own time, and RecruitLedger.TRADE_KEY for
-- Trade, which is one channel in every city and so has one time. A time
-- within the channel's gap is fresh: the guild advertised there lately. No
-- time, or only one older than the gap, is unknown: the add-on should ask
-- the other add-on users. Unknown never means "advertised". A channel marked
-- due was asked about and nobody had a fresh time, so it's taken as not
-- advertised in. Due marks are kept only for the session, and a new time
-- clears one, so a time that later goes stale is asked about again.
local RecruitLedger = {
    FRESH = "fresh",
    DUE = "due",
    UNKNOWN = "unknown",
    TRADE_KEY = "trade",
    -- How far ahead of this client's clock a time may be: enough for clocks
    -- that disagree a little, as guild sync allows.
    MAX_FUTURE_SECONDS = 300,
}
addon.RecruitLedger = RecruitLedger

local Ledger = {}
Ledger.__index = Ledger

-- The channel key for a zone's General channel.
function RecruitLedger.GeneralKey(zoneKey)
    return "general:" .. tostring(zoneKey)
end

-- `saved` is the table to keep times in (nil keeps them only in memory).
-- `gapOf(key)` returns the channel's gap in seconds. `due` is the table to
-- keep this session's due marks in (nil keeps them only in this ledger).
function RecruitLedger.Create(saved, gapOf, due)
    return setmetatable({
        times = type(saved) == "table" and saved or {},
        gapOf = gapOf,
        due = type(due) == "table" and due or {},
    }, Ledger)
end

local function isTime(value)
    return type(value) == "number" and value == value
end

-- The channel's gap in seconds, or nil when it can't be read.
function Ledger:gap(key)
    local ok, gap = pcall(self.gapOf, key)
    if ok and type(gap) == "number" and gap > 0 then
        return gap
    end
    return nil
end

-- Records an ad in `key` at `at`, keeping the newest time. Returns true when
-- the time was kept.
function Ledger:Record(key, at)
    if type(key) ~= "string" or not isTime(at) then
        return false
    end
    local current = self.times[key]
    if isTime(current) and current >= at then
        return false
    end
    self.times[key] = at
    self.due[key] = nil
    return true
end

-- Marks `key` due: asked about, and nobody had a fresh time.
function Ledger:MarkDue(key)
    if type(key) == "string" then
        self.due[key] = true
    end
end

-- The last ad time recorded for `key`, or nil.
function Ledger:Time(key)
    local time = self.times[key]
    return isTime(time) and time or nil
end

-- FRESH when `key` has a time within its gap at `now`; otherwise DUE when
-- it's marked due, and UNKNOWN when not.
function Ledger:State(key, now)
    local time, gap = self:Time(key), self:gap(key)
    if time ~= nil and gap ~= nil and isTime(now) and now - time < gap then
        return RecruitLedger.FRESH
    end
    if self.due[key] then
        return RecruitLedger.DUE
    end
    return RecruitLedger.UNKNOWN
end

-- Seconds from `now` until a fresh `key` stops being fresh, or nil when it
-- isn't fresh.
function Ledger:FreshFor(key, now)
    if self:State(key, now) ~= RecruitLedger.FRESH then
        return nil
    end
    return self:Time(key) + self:gap(key) - now
end

-- Forgets every time older than `keep` seconds (by default its channel's
-- gap), any dated further ahead than MAX_FUTURE_SECONDS (saved before such
-- times were refused), and anything that isn't a time. A channel whose gap
-- can't be read keeps its time unless it's in the future. A time kept past
-- its gap is only history: it counts as unknown, never as fresh.
function Ledger:Prune(now, keep)
    if not isTime(now) then
        return
    end
    local key, time
    local stale = {}
    for key, time in pairs(self.times) do
        local gap = self:gap(key)
        if type(keep) == "number" then
            gap = keep
        end
        if type(key) ~= "string" or not isTime(time) or time > now + RecruitLedger.MAX_FUTURE_SECONDS
            or (gap ~= nil and now - time >= gap)
        then
            table.insert(stale, key)
        end
    end
    local index
    for index = 1, #stale do
        self.times[stale[index]] = nil
    end
end
