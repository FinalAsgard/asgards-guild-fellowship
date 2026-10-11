local _, addon = ...

-- When the guild last advertised in each channel. Pure: it keeps its times
-- in the saved table it's given ({ [channel key] = server time }), so they
-- last across reloads and logouts.
--
-- A channel's key is RecruitLedger.GeneralKey(zone) for a zone's General
-- channel, so each zone has its own time. A time within the channel's gap is
-- fresh: the guild advertised there lately. No time, or only one older than
-- the gap, is unknown. Unknown never means "advertised".
local RecruitLedger = {
    FRESH = "fresh",
    UNKNOWN = "unknown",
}
addon.RecruitLedger = RecruitLedger

local Ledger = {}
Ledger.__index = Ledger

-- The channel key for a zone's General channel.
function RecruitLedger.GeneralKey(zoneKey)
    return "general:" .. tostring(zoneKey)
end

-- `saved` is the table to keep times in (nil keeps them only in memory).
-- `gapOf(key)` returns the channel's gap in seconds.
function RecruitLedger.Create(saved, gapOf)
    return setmetatable({
        times = type(saved) == "table" and saved or {},
        gapOf = gapOf,
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
    return true
end

-- The last ad time recorded for `key`, or nil.
function Ledger:Time(key)
    local time = self.times[key]
    return isTime(time) and time or nil
end

-- FRESH when `key` has a time within its gap at `now`, UNKNOWN otherwise.
function Ledger:State(key, now)
    local time, gap = self:Time(key), self:gap(key)
    if time ~= nil and gap ~= nil and isTime(now) and now - time < gap then
        return RecruitLedger.FRESH
    end
    return RecruitLedger.UNKNOWN
end

-- Forgets every time older than its channel's gap, and anything that isn't
-- a time. A channel whose gap can't be read keeps its time.
function Ledger:Prune(now)
    if not isTime(now) then
        return
    end
    local key, time
    local stale = {}
    for key, time in pairs(self.times) do
        local gap = self:gap(key)
        if type(key) ~= "string" or not isTime(time) or (gap ~= nil and now - time >= gap) then
            table.insert(stale, key)
        end
    end
    local index
    for index = 1, #stale do
        self.times[stale[index]] = nil
    end
end
