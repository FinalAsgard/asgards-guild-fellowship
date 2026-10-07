local _, addon = ...

-- Decides when the guild roster is scanned and runs each scan in small,
-- time-budgeted steps across frames, so even a large guild never hitches.
--
--   full         at login (or when the roster first becomes available) if
--                the last full scan is over 24 hours old, and on request
--   incremental  when roster updates show characters the store hasn't seen
--
-- Opening the roster window never scans. A scan only ever works from a
-- complete roster read: an empty or partial roster (as at login, while it
-- loads asynchronously) waits for the next roster update instead.
local ScanScheduler = {
    FULL_SCAN_INTERVAL = 24 * 60 * 60,
    -- Roster updates arrive in bursts; they are coalesced into one check.
    COALESCE_SECONDS = 2,
    -- How long to wait for a requested roster refresh before reading anyway
    -- (the client throttles refresh requests).
    REFRESH_WAIT_SECONDS = 3,
    -- Milliseconds of work per frame.
    BUDGET_MS = 4,
    -- Without a precise clock, yield after this many characters instead.
    STEPS_WITHOUT_CLOCK = 50,
}
addon.ScanScheduler = ScanScheduler

local Scheduler = {}
Scheduler.__index = Scheduler

-- options:
--   client       the compatibility adapter
--   context      function() -> guild, partition, normalizer (or nil)
--   rules        the client profile's name rules
--   onFinished   function(result, summary) after a scan completes
function ScanScheduler.Create(options)
    return setmetatable({
        client = options.client,
        context = options.context,
        rules = options.rules or {},
        onFinished = options.onFinished or function() end,
        ready = false,
        dailyChecked = false,
    }, Scheduler)
end

function Scheduler:IsRunning()
    return self.job ~= nil or self.waiting ~= nil
end

-- Saved data is ready: ask for the roster, so the daily check can run when
-- it arrives.
function Scheduler:OnSavedDataReady()
    self.ready = true
    self.client:RequestGuildRoster()
end

-- Requests a full scan. `manual` scans reprocess every note. Returns false
-- and a reason when a scan can't start.
function Scheduler:RequestFull(manual)
    if self:IsRunning() then
        return false, "running"
    end
    if self.context() == nil then
        return false, "unavailable"
    end
    self.waiting = { mode = "full", force = manual == true }
    self.client:RequestGuildRoster()
    -- If the client throttles the refresh and no update arrives, read the
    -- roster anyway after a short wait.
    local waiting = self.waiting
    if not self.client:After(ScanScheduler.REFRESH_WAIT_SECONDS, function()
        if self.waiting == waiting then
            self:StartWaiting()
        end
    end) then
        self:StartWaiting()
    end
    return true
end

function Scheduler:StartWaiting()
    local waiting = self.waiting
    self.waiting = nil
    if waiting ~= nil then
        self:Start(waiting.mode, waiting.force)
    end
end

-- Called on every GUILD_ROSTER_UPDATE.
function Scheduler:OnRosterUpdate()
    if not self.ready then
        return
    end
    if self.waiting ~= nil then
        self:StartWaiting()
        return
    end
    if self.job ~= nil then
        -- The roster changed under a running read; that read can't be trusted.
        self.rosterChanged = true
        return
    end
    if not self.dailyChecked then
        self:CheckDaily()
        return
    end
    self:ScheduleIncremental()
end

-- Runs a full scan when the last one is over 24 hours old (or never ran).
-- Only marked done once a scan can actually start, so a roster that isn't
-- available yet is checked again on the next update.
function Scheduler:CheckDaily()
    -- Without a guild, context() returns nil and a message, not a partition.
    local guild, partition = self.context()
    if guild == nil then
        return
    end
    self.dailyChecked = true
    local lastScan = partition:GetLastScan()
    local now = self.client:Timestamp() or 0
    if lastScan == nil or now - lastScan > ScanScheduler.FULL_SCAN_INTERVAL then
        self:Start("full", false)
    end
end

-- Coalesces a burst of roster updates into one incremental check.
function Scheduler:ScheduleIncremental()
    if self.incrementalPending then
        return
    end
    self.incrementalPending = true
    local function run()
        self.incrementalPending = false
        if not self:IsRunning() then
            self:Start("incremental", false)
        end
    end
    if not self.client:After(ScanScheduler.COALESCE_SECONDS, run) then
        run()
    end
end

-- Inside a scan: yields once this frame's budget is spent.
function Scheduler:Checkpoint()
    local now = self.client:PreciseMilliseconds()
    if now ~= nil then
        if now - self.stepStarted >= ScanScheduler.BUDGET_MS then
            coroutine.yield()
        end
        return
    end
    self.stepCount = self.stepCount + 1
    if self.stepCount >= ScanScheduler.STEPS_WITHOUT_CLOCK then
        coroutine.yield()
    end
end

-- Reads the whole roster, keyed by character key. Returns nil when the
-- roster is empty, partial, or changed (size, order, or members) while it
-- was read.
function Scheduler:ReadRoster(normalizer)
    local count = self.client:GetGuildRosterCount()
    if count == nil or count <= 0 then
        return nil
    end
    -- The read spans frames. The client fires a roster update whenever its
    -- roster changes, so a read with an update in the middle may mix two
    -- rosters (one member left, another joined, same count) and isn't used.
    self.rosterChanged = false
    local members = {}
    local distinct = 0
    local index
    for index = 1, count do
        local member = self.client:GetGuildMember(index)
        local key = member and normalizer:Key(member.name)
        if key == nil then
            return nil
        end
        if members[key] == nil then
            distinct = distinct + 1
        end
        members[key] = member
        self:Checkpoint()
    end
    -- The read spans frames, so a roster re-sorted mid-read repeats some
    -- members and skips others; that read isn't complete.
    if self.rosterChanged then
        return nil, "changed"
    end
    if distinct ~= count or self.client:GetGuildRosterCount() ~= count then
        return nil
    end
    return members
end

function Scheduler:Run(mode, force)
    local guild, partition, normalizer = self.context()
    if guild == nil then
        return nil
    end
    local members, why = self:ReadRoster(normalizer)
    if members == nil then
        return { incomplete = true, changed = why == "changed" }
    end
    -- The read spans frames: a roster that now belongs to another guild
    -- must never be saved into this guild's records.
    local currentGuild, current = self.context()
    if currentGuild == nil or current.key ~= partition.key then
        return { incomplete = true }
    end

    local engine = addon.ReconcileEngine
    local planMode = mode
    if mode == "full" and not partition:HasBeenScanned() then
        planMode = "initial"
    end
    local checkpoint = function()
        self:Checkpoint()
    end
    local now = self.client:Timestamp() or 0
    local plan = engine.Plan({
        partition = partition,
        members = members,
        normalizer = normalizer,
        rules = self.rules,
        mode = planMode,
        force = force,
        checkpoint = checkpoint,
        now = now,
    })
    -- An incremental check that finds nobody new or returning changes
    -- nothing.
    if planMode == "incremental" and next(plan.processed) == nil and plan.rejoins[1] == nil then
        return { idle = true }
    end
    local result = engine.Apply(partition, plan, checkpoint)
    if planMode ~= "incremental" then
        partition:MarkScanned(now)
    end
    local summary = {
        at = now,
        mode = planMode,
        newCharacters = result.newCharacters,
        linked = result.linked,
        aliased = result.aliased,
        conflicts = result.conflicts,
        departed = result.departed,
        rejoined = result.rejoined,
        promoted = result.promoted,
    }
    partition:SetLastScanSummary(summary)
    return { result = result, summary = summary }
end

-- Starts a scan as a coroutine, one budgeted step per frame.
function Scheduler:Start(mode, force)
    if self.job ~= nil then
        return false
    end
    self.jobMode, self.jobForce = mode, force
    self.job = coroutine.create(function()
        return self:Run(mode, force)
    end)
    self:Step()
    return true
end

function Scheduler:Step()
    local job = self.job
    if job == nil then
        return
    end
    self.stepStarted = self.client:PreciseMilliseconds() or 0
    self.stepCount = 0
    local ok, outcome = coroutine.resume(job)
    if coroutine.status(job) ~= "dead" then
        if not self.client:After(0, function()
            self:Step()
        end) then
            -- No timer: finish now rather than never.
            self:Step()
        end
        return
    end

    self.job = nil
    if not ok then
        self.client:Print(addon.Identity.chatPrefix .. " The roster scan failed: " .. tostring(outcome))
        return
    end
    if outcome == nil or outcome.idle then
        return
    end
    if outcome.incomplete then
        -- A full scan tries again when the roster finishes loading; an
        -- incremental check simply runs on the next update.
        if self.jobMode ~= "incremental" then
            local waiting = { mode = self.jobMode, force = self.jobForce }
            self.waiting = waiting
            -- A read cut short by a roster update has already used that
            -- update, so the retry can't wait for the next one: it reads
            -- again once the burst settles.
            if outcome.changed then
                self.client:After(ScanScheduler.COALESCE_SECONDS, function()
                    if self.waiting == waiting then
                        self:StartWaiting()
                    end
                end)
            end
        end
        return
    end
    self.onFinished(outcome.result, outcome.summary)
end
