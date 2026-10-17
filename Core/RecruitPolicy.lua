local _, addon = ...

-- Decides which channels the user should be prompted to advertise in right
-- now. Pure: it's given the user's location, the ledger and the user's
-- state, and keeps nothing itself.
--
-- A channel is prompted only when the character can invite to the guild,
-- the user has opted in, there is an ad to post, the channel is there to
-- post in, and the ledger has it due: asked about, with no fresh time
-- from anyone. A channel whose time is unknown is asked about first, and
-- never prompted while that ask waits. The zone's General and Trade (where the user is in it) are
-- separate prompts. Nothing is prompted while the user is busy, for a
-- channel the user snoozed with Not now, or in a zone the user turned off
-- with Off here (its General, and Trade while there).
local RecruitPolicy = {
    GENERAL = "general",
    TRADE = "trade",
}
addon.RecruitPolicy = RecruitPolicy

local Policy = {}
Policy.__index = Policy

-- options.canInvite: function() -> true when the logged-in character can
--   invite to the guild.
-- options.optedIn: function() -> true when the user turned prompts on.
-- options.hasAd: function() -> true when the user has an ad to post.
-- options.busy: function() -> true while prompts are held (combat, boss
--   encounters, keystones, instances, battlegrounds). Optional.
-- options.snoozedUntil: function(key) -> when a Not now on that channel
--   ends, or nil. Optional.
-- options.muted: function(zoneKey) -> true when Off here was pressed in
--   that zone. Optional.
-- options.paused: function() -> true while officers have paused recruitment
--   for the whole guild. Optional.
function RecruitPolicy.Create(options)
    return setmetatable({
        canInvite = options.canInvite,
        optedIn = options.optedIn,
        hasAd = options.hasAd,
        busy = options.busy or function()
            return false
        end,
        snoozedUntil = options.snoozedUntil or function()
            return nil
        end,
        muted = options.muted or function()
            return false
        end,
        paused = options.paused or function()
            return false
        end,
    }, Policy)
end

local function answers(callback)
    local ok, result = pcall(callback)
    return ok and result == true
end

-- True when the user may be prompted at all: permission, an ad, opt-in, and
-- recruitment not paused for the guild.
function Policy:Allowed()
    return answers(self.canInvite) and answers(self.hasAd) and answers(self.optedIn) and not self:Paused()
end

-- True while officers have paused recruitment for the whole guild.
function Policy:Paused()
    return answers(self.paused)
end

-- The channels the user could advertise in at `location` ({ key, name,
-- general, trade }: the zone, and the General and Trade channels' numbers,
-- nil where the user isn't in them), each as { key, channel, zoneKey,
-- zoneName, channelNumber }.
local function channelsAt(location)
    local channels = {}
    if type(location) ~= "table" or location.key == nil then
        return channels
    end
    if type(location.general) == "number" then
        table.insert(channels, {
            key = addon.RecruitLedger.GeneralKey(location.key),
            channel = RecruitPolicy.GENERAL,
            zoneKey = location.key,
            zoneName = location.name,
            channelNumber = location.general,
        })
    end
    if type(location.trade) == "number" then
        table.insert(channels, {
            key = addon.RecruitLedger.TRADE_KEY,
            channel = RecruitPolicy.TRADE,
            zoneKey = location.key,
            zoneName = location.name,
            channelNumber = location.trade,
        })
    end
    return channels
end

-- When a Not now on `key` ends, if it's still running at `now`.
function Policy:snoozeEnd(key, now)
    local ok, untilTime = pcall(self.snoozedUntil, key)
    if ok and type(untilTime) == "number" and untilTime > now then
        return untilTime
    end
    return nil
end

-- The channels at `location` the user hasn't turned off here.
function Policy:channels(location)
    local channels = channelsAt(location)
    if #channels > 0 then
        local ok, muted = pcall(self.muted, location.key)
        if ok and muted == true then
            return {}
        end
    end
    return channels
end

-- The channels at `location` in ledger state `state` that the user could be
-- prompted for (allowed, not busy, not turned off here).
function Policy:inState(location, ledger, now, state)
    local found = {}
    if not self:Allowed() or answers(self.busy) then
        return found
    end
    local channels = self:channels(location)
    local index
    for index = 1, #channels do
        if ledger:State(channels[index].key, now) == state then
            table.insert(found, channels[index])
        end
    end
    return found
end

-- The prompts due at `now` at `location` (see channelsAt), in a stable
-- order: General, then Trade. `ledger` is a RecruitLedger.
function Policy:Due(location, ledger, now)
    local due = {}
    local channels = self:inState(location, ledger, now, addon.RecruitLedger.DUE)
    local index
    for index = 1, #channels do
        if self:snoozeEnd(channels[index].key, now) == nil then
            table.insert(due, channels[index])
        end
    end
    return due
end

-- The channels at `location` whose time is unknown and that the user could
-- be prompted for: the ones to ask the other add-on users about.
function Policy:Unknown(location, ledger, now)
    return self:inState(location, ledger, now, addon.RecruitLedger.UNKNOWN)
end

-- Seconds from `now` until the first channel at `location` that was
-- advertised in lately, or snoozed, comes due, so the user can be prompted
-- without moving; nil when there's none or no prompts are allowed.
function Policy:NextDue(location, ledger, now)
    if not self:Allowed() then
        return nil
    end
    local channels = self:channels(location)
    local soonest
    local index
    for index = 1, #channels do
        local key = channels[index].key
        local seconds = ledger:FreshFor(key, now)
        local snoozeEnd = self:snoozeEnd(key, now)
        if snoozeEnd ~= nil and (seconds == nil or snoozeEnd - now > seconds) then
            seconds = snoozeEnd - now
        end
        if seconds ~= nil and (soonest == nil or seconds < soonest) then
            soonest = seconds
        end
    end
    return soonest
end
