local _, addon = ...

-- Decides when the player's location goes to the guild. Pure: the caller
-- passes the clock and the player's current spot, and sends what it
-- returns.
--
-- A `gm-loc` goes out every BROADCAST_SECONDS, and promptly after a zone
-- change, but never more often than once every MIN_GAP_SECONDS.
local LocationScheduler = {
    BROADCAST_SECONDS = 120,
    MIN_GAP_SECONDS = 10,
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
-- Returns the message to send to the guild now, or nil.
function Scheduler:Tick(state)
    local spot = state.spot
    if type(state.now) ~= "number" or state.character == nil or spot == nil then
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
