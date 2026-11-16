local _, addon = ...

-- How busy greeting has been this session: guild chat lines counted as
-- greetings (from anyone, the user included), arrivals as anti-spam mode
-- counts them, and time spent in anti-spam mode, for the last hour and for
-- the session. Pure and in memory only: time is passed in, nothing is saved
-- and a /reload starts fresh.
local GreetStats = {
    HOUR_SECONDS = 60 * 60,
}
addon.GreetStats = GreetStats

local Stats = {}
Stats.__index = Stats

function GreetStats.Create()
    return setmetatable({
        -- Times of the greeting lines and arrivals within the last hour,
        -- oldest first.
        greetingTimes = {},
        arrivalTimes = {},
        greetings = 0,
        arrivals = 0,
        -- Anti-spam mode's spells, { from, to } each (`to` nil while on),
        -- oldest first, kept while they reach into the last hour.
        spells = {},
        -- Seconds of the session's spells that ended.
        endedSeconds = 0,
    }, Stats)
end

local function prune(times, since)
    while times[1] ~= nil and times[1] <= since do
        table.remove(times, 1)
    end
end

function Stats:prune(now)
    local since = now - GreetStats.HOUR_SECONDS
    prune(self.greetingTimes, since)
    prune(self.arrivalTimes, since)
    while self.spells[1] ~= nil and self.spells[1].to ~= nil and self.spells[1].to <= since do
        table.remove(self.spells, 1)
    end
end

-- A guild chat line counted as a greeting at `now`.
function Stats:Greeting(now)
    if type(now) ~= "number" then
        return
    end
    self:prune(now)
    self.greetings = self.greetings + 1
    table.insert(self.greetingTimes, now)
end

-- An arrival counted at `now`.
function Stats:Arrival(now)
    if type(now) ~= "number" then
        return
    end
    self:prune(now)
    self.arrivals = self.arrivals + 1
    table.insert(self.arrivalTimes, now)
end

-- Anti-spam mode turned on (true) or off (false) at `now`.
function Stats:ModeChanged(on, now)
    if type(now) ~= "number" then
        return
    end
    self:prune(now)
    local last = self.spells[#self.spells]
    local open = last ~= nil and last.to == nil
    if on and not open then
        table.insert(self.spells, { from = now })
    elseif not on and open then
        last.to = math.max(now, last.from)
        self.endedSeconds = self.endedSeconds + (last.to - last.from)
    end
end

-- What happened, at `now`:
--   { hour = { greetings, arrivals, antiSpamSeconds },
--     session = { greetings, arrivals, antiSpamSeconds }, on }
function Stats:Report(now)
    self:prune(now)
    local since = now - GreetStats.HOUR_SECONDS
    local hourSeconds = 0
    local sessionSeconds = self.endedSeconds
    local on = false
    local _, spell
    for _, spell in ipairs(self.spells) do
        local to = spell.to or now
        if spell.to == nil then
            on = true
            sessionSeconds = sessionSeconds + math.max(to - spell.from, 0)
        end
        hourSeconds = hourSeconds + math.max(to - math.max(spell.from, since), 0)
    end
    return {
        hour = { greetings = #self.greetingTimes, arrivals = #self.arrivalTimes, antiSpamSeconds = hourSeconds },
        session = { greetings = self.greetings, arrivals = self.arrivals, antiSpamSeconds = sessionSeconds },
        on = on,
    }
end

-- "1h 05m", "4m 30s", "45s".
function GreetStats.Duration(seconds)
    seconds = math.floor(seconds or 0)
    if seconds >= 3600 then
        return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    end
    if seconds >= 60 then
        return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
    end
    return seconds .. "s"
end

-- Chat lines for `report`, with the officer settings `threshold` (arrivals
-- per 2 minutes) and `cooldownSeconds`.
function GreetStats.Lines(report, threshold, cooldownSeconds)
    local function row(label, counts)
        return string.format("  %s: %d greeting lines, %d arrivals, %s in anti-spam mode", label,
            counts.greetings, counts.arrivals, GreetStats.Duration(counts.antiSpamSeconds))
    end
    return {
        row("Last hour", report.hour),
        row("This session", report.session),
        "  Anti-spam mode is " .. (report.on and "on" or "off") .. " now.",
        string.format("  Officer settings: on at %d arrivals in 2 minutes, %ds guild cooldown.",
            threshold, cooldownSeconds),
    }
end
