local _, addon = ...

-- How many times each player has advertised. Pure: it keeps its records in
-- the saved table it's given, one per guild.
--
-- A record is { n = lifetime total, t = { server times of the ads from the
-- last 30 days } }. Each user's add-on owns the true record of its own posts
-- (kept account-wide, so all of the user's characters add up) and sends it
-- with every "advertised" message. Receivers keep the report under the
-- sender's character, replacing it only when its total is higher, and show a
-- player the highest record among their characters. The 30-day count is
-- worked out when it's shown, so it falls as ads age out.
local RecruitStats = {
    WINDOW_SECONDS = 30 * 24 * 60 * 60,
    -- The most timestamps a report may carry; more is not a real record.
    MAX_RECENT = 2000,
}
addon.RecruitStats = RecruitStats

local Stats = {}
Stats.__index = Stats

local function isTime(value)
    return type(value) == "number" and value == value
end

-- True for a record with a whole, non-negative total and a list of times.
function RecruitStats.IsValid(record)
    if type(record) ~= "table" or type(record.n) ~= "number" or record.n < 0 or record.n ~= math.floor(record.n)
        or type(record.t) ~= "table" or #record.t > RecruitStats.MAX_RECENT
    then
        return false
    end
    local index
    for index = 1, #record.t do
        if not isTime(record.t[index]) then
            return false
        end
    end
    return true
end

-- How many of the record's ads were within the last 30 days at `now`.
function RecruitStats.Recent(record, now)
    local count = 0
    local index
    for index = 1, #record.t do
        if now - record.t[index] < RecruitStats.WINDOW_SECONDS then
            count = count + 1
        end
    end
    return count
end

-- The player panel's line for a record: "Advertised: N (M in last 30
-- days)", or nil for no record.
function RecruitStats.Line(record, now)
    if not RecruitStats.IsValid(record) or not isTime(now) then
        return nil
    end
    return "Advertised: " .. record.n .. " (" .. RecruitStats.Recent(record, now) .. " in last 30 days)"
end

-- Counts one more ad at `now` in the user's own record (a table changed in
-- place), dropping times older than 30 days. Returns a copy to send.
function RecruitStats.AddOwn(record, now)
    if not RecruitStats.IsValid(record) then
        record.n = 0
        record.t = {}
    end
    record.n = record.n + 1
    local recent = {}
    local index
    for index = 1, #record.t do
        if now - record.t[index] < RecruitStats.WINDOW_SECONDS then
            table.insert(recent, record.t[index])
        end
    end
    table.insert(recent, now)
    record.t = recent
    return RecruitStats.Copy(record)
end

function RecruitStats.Copy(record)
    local times = {}
    local index
    for index = 1, #record.t do
        times[index] = record.t[index]
    end
    return { n = record.n, t = times }
end

-- `saved` is the table to keep records in, by character key (nil keeps
-- them only in memory).
function RecruitStats.Create(saved)
    return setmetatable({
        records = type(saved) == "table" and saved or {},
    }, Stats)
end

-- A report about `key`'s player: kept when it's valid and its total is
-- higher than the one held for that character. Returns true when kept.
function Stats:File(key, report)
    if type(key) ~= "string" or not RecruitStats.IsValid(report) then
        return false
    end
    local held = self.records[key]
    if RecruitStats.IsValid(held) and held.n >= report.n then
        return false
    end
    self.records[key] = RecruitStats.Copy(report)
    return true
end

-- The record with the highest total among `keys` (a player's characters),
-- or nil when none has one.
function Stats:Best(keys)
    local best
    local index
    for index = 1, #(keys or {}) do
        local record = self.records[keys[index]]
        if RecruitStats.IsValid(record) and (best == nil or record.n > best.n) then
            best = record
        end
    end
    return best
end
