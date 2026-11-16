local _, addon = ...

-- How much the user has greeted lately, so the quickest greeters' prompts
-- wait a little longer and others get a turn. Each press of Greet adds
-- PER_GREETING, up to CAP; the weight fades by FADE_PER_MINUTE, steadily,
-- down to 0, worked out from when it last changed, so it keeps fading while
-- the user is offline. A new prompt waits SECONDS_PER_WEIGHT longer per
-- weight, but only while at least MIN_ADDON_ONLINE guildmates with the
-- add-on are online, counting the user: with fewer, nobody else is there to
-- take a turn.
--
-- Pure: the saved record ({ weight, at }) and the clock are passed in.
local GreetWeight = {
    PER_GREETING = 1,
    CAP = 6,
    FADE_PER_MINUTE = 0.2,
    SECONDS_PER_WEIGHT = 2.5,
    MIN_ADDON_ONLINE = 3,
}
addon.GreetWeight = GreetWeight

local function isNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Whether `saved` is a usable record.
function GreetWeight.IsRecord(saved)
    return type(saved) == "table" and isNumber(saved.weight) and saved.weight >= 0
        and saved.weight <= GreetWeight.CAP and isNumber(saved.at)
end

-- The weight at `now` of `saved` (nil or unusable counts as none).
function GreetWeight.Current(saved, now)
    if not GreetWeight.IsRecord(saved) or not isNumber(now) then
        return 0
    end
    local minutes = math.max(0, now - saved.at) / 60
    return math.max(0, saved.weight - GreetWeight.FADE_PER_MINUTE * minutes)
end

-- The record after a greeting at `now`.
function GreetWeight.Added(saved, now)
    return {
        weight = math.min(GreetWeight.CAP, GreetWeight.Current(saved, now) + GreetWeight.PER_GREETING),
        at = now,
    }
end

-- Extra seconds a new prompt waits with `weight`, while `addonOnline`
-- guildmates with the add-on (counting the user; nil when unknown) are
-- online.
function GreetWeight.ExtraDelay(weight, addonOnline)
    if not isNumber(weight) or weight <= 0 or not isNumber(addonOnline)
        or addonOnline < GreetWeight.MIN_ADDON_ONLINE
    then
        return 0
    end
    return math.min(weight, GreetWeight.CAP) * GreetWeight.SECONDS_PER_WEIGHT
end

-- Probe lines for `weight` and `addonOnline`.
function GreetWeight.ProbeLines(weight, addonOnline)
    local lines = {
        string.format("Greet weight: %.1f of %d (fades %.1f a minute)", weight, GreetWeight.CAP,
            GreetWeight.FADE_PER_MINUTE),
        "Guildmates online with the add-on, counting you: " .. tostring(addonOnline or "unknown"),
    }
    local extra = GreetWeight.ExtraDelay(weight, addonOnline)
    if extra > 0 then
        table.insert(lines, string.format("New prompts wait %.1f seconds longer so others get a turn.", extra))
    elseif weight > 0 then
        table.insert(lines, "No extra wait: it applies only with " .. GreetWeight.MIN_ADDON_ONLINE ..
            " or more add-on users online.")
    else
        table.insert(lines, "No extra wait.")
    end
    return lines
end
