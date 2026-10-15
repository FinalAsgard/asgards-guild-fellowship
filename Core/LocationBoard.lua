local _, addon = ...

-- Guildmates' latest positions, as their add-ons report them (see
-- LocationProtocol). Pure: the caller checks that the sender is in the
-- guild and passes the clock.
local LocationBoard = {}
addon.LocationBoard = LocationBoard

local Board = {}
Board.__index = Board

-- options.isOwn: function(key) -> true for the player's own characters,
-- which are never held (the player isn't shown twice).
function LocationBoard.Create(options)
    options = options or {}
    return setmetatable({
        entries = {},
        isOwn = options.isOwn or function()
            return false
        end,
    }, Board)
end

-- A valid `gm-loc` or `gm-near` from character `senderKey`, heard at `now`.
-- Returns true when the board changed.
function Board:OnLocation(message, senderKey, now)
    if message.c ~= senderKey or self.isOwn(senderKey) then
        return false
    end
    self.entries[senderKey] = {
        key = senderKey,
        mapId = message.m,
        x = message.x,
        y = message.y,
        class = message.cl,
        level = message.l,
        heard = now,
    }
    return true
end

-- Every guildmate on the board, sorted by key: each { key, mapId, x, y,
-- class, level, heard }.
function Board:All()
    local found = {}
    local key, entry
    for key, entry in pairs(self.entries) do
        if not self.isOwn(key) then
            table.insert(found, entry)
        end
    end
    table.sort(found, function(left, right)
        return left.key < right.key
    end)
    return found
end
