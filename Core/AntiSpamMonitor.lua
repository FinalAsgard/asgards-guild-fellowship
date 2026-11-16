local _, addon = ...

-- Anti-spam mode for one session: on by itself when the guild is busy, off
-- again once it calms down. Pure: it's told about arrivals, greetings and
-- departures with the time, and keeps what it has seen in memory.
--
--   * Arrivals: each guild member online message counts once per character
--     within DEDUPE_SECONDS. The caller leaves out the user's own characters
--     and joins, and counts arrivals whatever the user's own Guild Greet
--     settings, so add-ons that have been online for a while see the same
--     arrivals.
--   * Trigger: `threshold()` arrivals within WINDOW_SECONDS turn it on.
--   * Waiting: arrived players with no greeting yet. A player stops waiting
--     when greeted, when they go offline, or once their arrival is
--     `lifetime` seconds old (their prompt is gone by then).
--   * Exit: it turns off once no more than CALM_WAITING players have been
--     waiting for EXIT_MULTIPLIER x `cooldownSeconds()`, unbroken.
--   * Guild cooldown: while it's on, each greeting seen starts the guild
--     cooldown again at full length. For one cooldown after the session's
--     roster loads, there's a cooldown anyway, before this add-on can know
--     whether the guild is busy.
-- `onChange(on)` hears each turn on (true) or off (false).
local AntiSpamMonitor = {
    WINDOW_SECONDS = 2 * 60,
    DEDUPE_SECONDS = 3 * 60,
    CALM_WAITING = 2,
    EXIT_MULTIPLIER = 10,
}
addon.AntiSpamMonitor = AntiSpamMonitor

local Monitor = {}
Monitor.__index = Monitor

-- options:
--   threshold()        -> arrivals within the window that turn it on
--   cooldownSeconds()  -> the guild cooldown in seconds
--   lifetime           seconds an arrival can wait for a greeting
--   onChange(on)       optional
function AntiSpamMonitor.Create(options)
    return setmetatable({
        threshold = options.threshold,
        cooldownSeconds = options.cooldownSeconds,
        lifetime = options.lifetime,
        onChange = options.onChange or function() end,
        on = false,
        -- Seconds of the arrivals counted, oldest first.
        arrivals = {},
        -- When each character last counted as arriving.
        lastArrival = {},
        -- Waiting players: player -> { player, key, rawName, arrivedAt }.
        waiting = {},
        waitingCount = 0,
        -- While on: since when no more than CALM_WAITING have waited.
        calmSince = nil,
        -- When the guild cooldown and the startup cooldown end.
        cooldownUntil = nil,
        startupUntil = nil,
    }, Monitor)
end

local function number(callback, fallback)
    local ok, value = pcall(callback)
    if ok and type(value) == "number" then
        return value
    end
    return fallback
end

function Monitor:IsOn()
    return self.on
end

-- Seconds the waiting count must stay calm before it turns off.
function Monitor:ExitSeconds()
    return AntiSpamMonitor.EXIT_MULTIPLIER * number(self.cooldownSeconds, 15)
end

function Monitor:setOn(on)
    if self.on == on then
        return
    end
    self.on = on
    self.calmSince = nil
    if not on then
        self.cooldownUntil = nil
    end
    pcall(self.onChange, on)
end

-- Notes the waiting count changed at `now`: calm starts when it drops to
-- CALM_WAITING or fewer, and breaks when it rises above.
function Monitor:countChanged(now)
    if not self.on then
        return
    end
    if self.waitingCount > AntiSpamMonitor.CALM_WAITING then
        self.calmSince = nil
    elseif self.calmSince == nil then
        self.calmSince = now
    end
end

function Monitor:drop(player, now)
    if self.waiting[player] == nil then
        return false
    end
    self.waiting[player] = nil
    self.waitingCount = self.waitingCount - 1
    self:countChanged(now)
    return true
end

-- Brings things up to `now`: drops arrivals out of the window and waiting
-- players whose arrival is too old, and turns it off once calm long enough.
function Monitor:Update(now)
    if type(now) ~= "number" then
        return
    end
    while self.arrivals[1] ~= nil and self.arrivals[1] <= now - AntiSpamMonitor.WINDOW_SECONDS do
        table.remove(self.arrivals, 1)
    end
    -- Oldest first, so calm starts when the right one drops out.
    local expired = {}
    local _, entry
    for _, entry in pairs(self.waiting) do
        if entry.arrivedAt + self.lifetime <= now then
            table.insert(expired, entry)
        end
    end
    table.sort(expired, function(a, b)
        return a.arrivedAt < b.arrivedAt
    end)
    local index
    for index = 1, #expired do
        self:drop(expired[index].player, expired[index].arrivedAt + self.lifetime)
    end
    if self.on and self.calmSince ~= nil and now - self.calmSince >= self:ExitSeconds() then
        self:setOn(false)
    end
end

-- Guild member `key` (of `player`, named `rawName` by the game) came online
-- at `now`. Returns true when it counted as an arrival.
function Monitor:Arrived(key, player, rawName, now)
    if type(key) ~= "string" or player == nil or type(now) ~= "number" then
        return false
    end
    self:Update(now)
    local last = self.lastArrival[key]
    if last ~= nil and now - last < AntiSpamMonitor.DEDUPE_SECONDS then
        return false
    end
    self.lastArrival[key] = now
    table.insert(self.arrivals, now)
    if self.waiting[player] == nil then
        self.waitingCount = self.waitingCount + 1
    end
    self.waiting[player] = { player = player, key = key, rawName = rawName, arrivedAt = now }
    self:countChanged(now)
    if not self.on and #self.arrivals >= number(self.threshold, 8) then
        self:setOn(true)
        self:countChanged(now)
    end
    return true
end

-- Character `key` joined the guild at `now`: joins never count, nor the
-- online message that comes with one.
function Monitor:Joined(key, now)
    if type(key) == "string" and type(now) == "number" then
        self.lastArrival[key] = now
    end
end

-- `player` was greeted at `now`. Returns true when they were waiting.
function Monitor:Greeted(player, now)
    self:Update(now)
    return self:drop(player, now)
end

-- `player` went offline (or left the guild) at `now`.
function Monitor:Left(player, now)
    self:Update(now)
    return self:drop(player, now)
end

-- The waiting players at `now` ({ player, key, rawName, arrivedAt } each).
function Monitor:Waiting(now)
    self:Update(now)
    local list = {}
    local _, entry
    for _, entry in pairs(self.waiting) do
        table.insert(list, entry)
    end
    return list
end

function Monitor:HasWaiting(now)
    self:Update(now)
    return self.waitingCount > 0
end

-- When, with nothing else happening, it could next change on its own: when
-- it would turn off, or, while on and busy, when the next waiting arrival
-- gets too old. Nil when nothing's due.
function Monitor:NextCheckAt(now)
    self:Update(now)
    if not self.on then
        return nil
    end
    if self.calmSince ~= nil then
        return self.calmSince + self:ExitSeconds()
    end
    local soonest
    local _, entry
    for _, entry in pairs(self.waiting) do
        local at = entry.arrivedAt + self.lifetime
        if soonest == nil or at < soonest then
            soonest = at
        end
    end
    return soonest
end

-- The session's roster loaded at `now`: a cooldown runs from it.
function Monitor:Started(now)
    if type(now) == "number" then
        self.startupUntil = now + number(self.cooldownSeconds, 15)
    end
end

-- A greeting was seen at `now`: while on, the guild cooldown starts again
-- at full length. Returns true when it did.
function Monitor:GreetingSeen(now)
    self:Update(now)
    if not self.on or type(now) ~= "number" then
        return false
    end
    self.cooldownUntil = now + number(self.cooldownSeconds, 15)
    return true
end

-- When the latest guild or startup cooldown ends (or ended), or nil when
-- there has been none this session or since it last turned off.
function Monitor:CooldownEndsAt(now)
    self:Update(now)
    local ends = self.startupUntil
    if self.on and self.cooldownUntil ~= nil and (ends == nil or self.cooldownUntil > ends) then
        ends = self.cooldownUntil
    end
    return ends
end
