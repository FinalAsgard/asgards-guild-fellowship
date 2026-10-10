local _, addon = ...

-- Counts the greetings each player has had for their current arrival, from
-- the user's own Greet presses and other add-on users' "greeted" messages,
-- so a login isn't met by a wall of greetings. Each greeter counts once per
-- arrival, whatever category they used, and greetings for any of a player's
-- characters count toward that player (callers pass player identities).
--
-- An arrival's count lasts until `window()` seconds (the welcome-back
-- window) pass after its latest greeting; then it starts again from zero. A
-- greeting reported for an arrival that's already that old is late and
-- isn't counted. Pure: times are passed in, and nothing is saved.
local GreetTally = {}
addon.GreetTally = GreetTally

local Tally = {}
Tally.__index = Tally

-- `window()` returns the welcome-back window in seconds.
function GreetTally.Create(window)
    return setmetatable({
        window = window,
        players = {},
    }, Tally)
end

-- The player's tally, or nil once it has lapsed (then it's forgotten).
function Tally:current(player, now)
    local tally = self.players[player]
    if tally ~= nil and now - tally.lastAt >= self.window() then
        self.players[player] = nil
        tally = nil
    end
    return tally
end

-- Counts a greeting for `player` by `greeter`, for the arrival at
-- `arrivedAt`. Returns the player's count afterward.
function Tally:Add(player, greeter, arrivedAt, now)
    if player == nil or greeter == nil or type(arrivedAt) ~= "number" or type(now) ~= "number" then
        return self:Count(player, now)
    end
    local tally = self:current(player, now)
    if now - arrivedAt >= self.window() then
        return tally and tally.count or 0
    end
    if tally == nil then
        tally = { count = 0, greeters = {}, lastAt = now }
        self.players[player] = tally
    end
    if not tally.greeters[greeter] then
        tally.greeters[greeter] = true
        tally.count = tally.count + 1
        tally.lastAt = now
    end
    return tally.count
end

-- How many greetings `player` has had for their current arrival.
function Tally:Count(player, now)
    if player == nil or type(now) ~= "number" then
        return 0
    end
    local tally = self:current(player, now)
    return tally and tally.count or 0
end

-- True once `player` has had at least `cap` greetings: their prompt closes
-- and they aren't prompted again until the count lapses.
function Tally:Reached(player, cap, now)
    return type(cap) == "number" and self:Count(player, now) >= cap
end
