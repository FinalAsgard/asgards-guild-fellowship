local _, addon = ...

-- Decides when the player's location goes to the guild. Pure: the caller
-- passes the clock and the player's current spot, and sends what it
-- returns.
--
-- A `gm-loc` goes out every BROADCAST_SECONDS, and promptly after a zone
-- change, but never more often than once every MIN_GAP_SECONDS. A `gm-near`
-- is whispered every NEAR_SECONDS to the add-on guildmates last heard in the
-- player's zone, at most the NEAR_MAX most recently heard, until a whisper
-- fails; then only the guild broadcast is used. With sharing turned off, or
-- inside an instance, one `gm-hide` goes out and then nothing until sharing
-- is back on and the player is out.
local LocationScheduler = {
    BROADCAST_SECONDS = 120,
    MIN_GAP_SECONDS = 10,
    NEAR_SECONDS = 10,
    NEAR_MAX = 10,
    -- How often the caller should ask (Tick), so a zone change made inside
    -- the minimum gap still goes out soon after it ends.
    TICK_SECONDS = 5,
}
addon.LocationScheduler = LocationScheduler

local Scheduler = {}
Scheduler.__index = Scheduler

function LocationScheduler.Create()
    return setmetatable({}, Scheduler)
end

-- state:
--   now        wall-clock seconds
--   character  the player's character key
--   spot       { mapId, x, y, class, level }, or nil while the client can't
--              place the player
--   sharing    false when the player turned sharing off
--   inInstance true in a dungeon, raid, battleground or arena
-- Returns the message to send to the guild now, or nil.
function Scheduler:Tick(state)
    local spot = state.spot
    if type(state.now) ~= "number" or state.character == nil then
        return nil
    end
    if state.sharing == false or state.inInstance then
        if self.hidden then
            return nil
        end
        self.hidden = true
        return addon.LocationProtocol.Hide(state.character)
    end
    if self.hidden then
        -- Back on, or out of the instance: the location goes out at once.
        self.hidden = false
        self.sentAt = nil
    end
    if spot == nil then
        return nil
    end
    local since = self.sentAt and (state.now - self.sentAt) or nil
    local due = since == nil or since >= LocationScheduler.BROADCAST_SECONDS
        or (spot.mapId ~= self.sentMap and since >= LocationScheduler.MIN_GAP_SECONDS)
    if not due then
        return nil
    end
    self.sentAt = state.now
    self.sentMap = spot.mapId
    return addon.LocationProtocol.Location(state.character, spot)
end

-- state:
--   now        wall-clock seconds
--   character  the player's character key
--   spot       as for Tick
--   sharing    as for Tick
--   inInstance as for Tick
--   guildmates the board's entries: each { key, name, mapId, heard }, with
--              `name` the name to whisper
-- Returns the `gm-near` to whisper now and the names to whisper it to, or
-- nil.
function Scheduler:Near(state)
    local spot = state.spot
    if self.whisperOff or state.sharing == false or state.inInstance or type(state.now) ~= "number" or state.character == nil
        or spot == nil
    then
        return nil
    end
    if self.nearAt ~= nil and state.now - self.nearAt < LocationScheduler.NEAR_SECONDS then
        return nil
    end
    local near = {}
    local index
    for index = 1, #(state.guildmates or {}) do
        local guildmate = state.guildmates[index]
        if guildmate.mapId == spot.mapId and type(guildmate.name) == "string" then
            table.insert(near, guildmate)
        end
    end
    if #near == 0 then
        return nil
    end
    table.sort(near, function(left, right)
        if left.heard ~= right.heard then
            return left.heard > right.heard
        end
        return left.key < right.key
    end)
    local targets = {}
    for index = 1, math.min(#near, LocationScheduler.NEAR_MAX) do
        table.insert(targets, near[index].name)
    end
    self.nearAt = state.now
    return addon.LocationProtocol.Near(state.character, spot), targets
end

-- A whisper couldn't be sent: no more `gm-near`, the guild broadcast goes on.
function Scheduler:WhisperFailed()
    self.whisperOff = true
end
