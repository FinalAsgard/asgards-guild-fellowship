local _, addon = ...

-- Decides which channels the user should be prompted to advertise in right
-- now. Pure: it's given the user's location, the ledger and the user's
-- state, and keeps nothing itself.
--
-- A channel is prompted only when the character can invite to the guild,
-- the user has opted in, there is an ad to post, the channel is there to
-- post in, and the ledger has no fresh time for it. An unknown channel
-- counts as due.
local RecruitPolicy = {
    GENERAL = "general",
}
addon.RecruitPolicy = RecruitPolicy

local Policy = {}
Policy.__index = Policy

-- options.canInvite: function() -> true when the logged-in character can
--   invite to the guild.
-- options.optedIn: function() -> true when the user turned prompts on.
-- options.hasAd: function() -> true when the user has an ad to post.
function RecruitPolicy.Create(options)
    return setmetatable({
        canInvite = options.canInvite,
        optedIn = options.optedIn,
        hasAd = options.hasAd,
    }, Policy)
end

local function answers(callback)
    local ok, result = pcall(callback)
    return ok and result == true
end

-- True when the user may be prompted at all: permission, an ad, and opt-in.
-- The opt-in is asked last, since it's the only one that reads guild data.
function Policy:Allowed()
    return answers(self.canInvite) and answers(self.hasAd) and answers(self.optedIn)
end

-- The prompts due at `now`, in a stable order: { key, channel, zoneKey,
-- zoneName, channelNumber } each. `location` is { key, name, general }, the
-- zone and its General channel's number (nil when the user isn't in it), or
-- nil when the zone is unknown. `ledger` is a RecruitLedger.
function Policy:Due(location, ledger, now)
    local due = {}
    if type(location) ~= "table" or location.key == nil or not self:Allowed() then
        return due
    end
    if type(location.general) == "number" then
        local key = addon.RecruitLedger.GeneralKey(location.key)
        if ledger:State(key, now) ~= addon.RecruitLedger.FRESH then
            table.insert(due, {
                key = key,
                channel = RecruitPolicy.GENERAL,
                zoneKey = location.key,
                zoneName = location.name,
                channelNumber = location.general,
            })
        end
    end
    return due
end
