local _, addon = ...

-- A zone's level range, for questing listings. The game's own range where
-- the client has one; otherwise the party's lowest to highest level, MARGIN
-- levels wider each way. Whether WoW Forever has zone level data is still
-- to be checked in game, so the range says where it came from and
-- `/agf probe lfg` reports it. Pure: the game's range and the levels are
-- handed in.
local ZoneLevels = {
    MARGIN = 5,
    GAME = "game",
    FALLBACK = "fallback",
}
addon.ZoneLevels = ZoneLevels

local function isLevel(value)
    return type(value) == "number" and value >= 1 and value == math.floor(value)
end

-- The range for a zone: { minLevel, maxLevel, source }, from `game` ({
-- minLevel, maxLevel } as the client reports it, or nil) when it's usable,
-- else from the party's `levels` (a list). Nil when neither says anything.
function ZoneLevels.For(game, levels)
    if type(game) == "table" and isLevel(game.minLevel) and isLevel(game.maxLevel)
        and game.minLevel <= game.maxLevel
    then
        return { minLevel = game.minLevel, maxLevel = game.maxLevel, source = ZoneLevels.GAME }
    end
    local lowest, highest
    local index
    for index = 1, #(type(levels) == "table" and levels or {}) do
        local level = levels[index]
        if isLevel(level) then
            lowest = math.min(lowest or level, level)
            highest = math.max(highest or level, level)
        end
    end
    if lowest == nil then
        return nil
    end
    return {
        minLevel = math.max(1, lowest - ZoneLevels.MARGIN),
        maxLevel = highest + ZoneLevels.MARGIN,
        source = ZoneLevels.FALLBACK,
    }
end
