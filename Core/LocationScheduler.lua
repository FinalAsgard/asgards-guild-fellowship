local _, addon = ...

-- Decides when the player's location goes to the guild. Pure: the caller
-- passes the clock and the player's current spot, and sends what it
-- returns.
--
-- A `gm-loc` goes out every BROADCAST_SECONDS, and promptly after a zone
-- change, but never more often than once every MIN_GAP_SECONDS. A `gm-near`
-- goes every NEAR_SECONDS to the add-on guildmates last heard in the
-- player's zone: whispered to each when there are only a few, and sent to
-- the guild once when NEAR_GUILD_MIN or more are near. The game allows each
-- add-on prefix about one message a second, so whispering a crowded zone
-- would use all of it. After a whisper fails, a crowd still hears the
-- guild-wide gm-near, and a few only the gm-loc broadcast. With sharing turned off, or
-- inside an instance, one `gm-hide` goes out and then nothing until sharing
-- is back on and the player is out.
local LocationScheduler = {
    BROADCAST_SECONDS = 120,
    -- The fast same-zone `gm-near` updates are off for now: a whisper to a
    -- guildmate who just logged off gets the sender "No player named ...
    -- is currently playing.", even after the first one drops them, since
    -- whispers already queued still go out. Same-zone guildmates show where
    -- they were at their last gm-loc until this is reworked.
    NEAR_ENABLED = false,
    MIN_GAP_SECONDS = 10,
    NEAR_SECONDS = 10,
    -- With this many guildmates near, one gm-near goes to the guild instead
    -- of a whisper to each.
    NEAR_GUILD_MIN = 3,
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
        -- One gm-hide, and another when the reason changes (sharing off
        -- and entering an instance, or leaving one with sharing off), so
        -- guildmates know who's inside.
        local reason = state.inInstance and "instance" or "off"
        if self.hidden == reason then
            return nil
        end
        self.hidden = reason
        return addon.LocationProtocol.Hide(state.character, state.inInstance == true)
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
-- Returns the `gm-near` to send now and the names to whisper it to, or
-- the `gm-near`, no names and true when it goes to the guild instead, or
-- nil.
function Scheduler:Near(state)
    if not LocationScheduler.NEAR_ENABLED then
        return nil
    end
    local spot = state.spot
    if state.sharing == false or state.inInstance or type(state.now) ~= "number" or state.character == nil
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
    if #near == 0 or (self.whisperOff and #near < LocationScheduler.NEAR_GUILD_MIN) then
        return nil
    end
    local message = addon.LocationProtocol.Near(state.character, spot)
    if #near >= LocationScheduler.NEAR_GUILD_MIN then
        self.nearAt = state.now
        return message, {}, true
    end
    local targets = {}
    for index = 1, #near do
        table.insert(targets, near[index].name)
    end
    self.nearAt = state.now
    return message, targets, false
end

-- A whisper couldn't be sent: no more whispered `gm-near`; the guild-wide
-- one and the guild broadcast go on.
function Scheduler:WhisperFailed()
    self.whisperOff = true
end
