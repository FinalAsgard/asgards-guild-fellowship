local _, addon = ...

-- Whether a character could join a listing on the Guild LFG Board:
--   dungeon   its level is within the dungeon's range and a role it's
--             willing to play is still open
--   questing  its level is within the zone's range and the party has room,
--             whatever its role and wherever it is
--   raid      the party has room, and its level fits the range when the
--             leader set one
--   other     the leader set a range and its level fits, and there's room;
--             with no range, never (it goes to Other Parties)
-- A character is { level, roles = the roles it's willing to play }, as for
-- the current character and each alt. Pure.
local LfgRelevance = {}
addon.LfgRelevance = LfgRelevance

local function hasRange(listing)
    return type(listing.minLevel) == "number" and type(listing.maxLevel) == "number"
end

local function levelFits(listing, level)
    return type(level) == "number" and level >= listing.minLevel and level <= listing.maxLevel
end

-- Whether `listing`'s party has room for one more.
function LfgRelevance.HasRoom(listing)
    return type(listing.size) == "number" and type(listing.maxSize) == "number" and listing.size < listing.maxSize
end

local function playsAnOpenRole(listing, roles)
    local willing = {}
    local index
    for index = 1, #(roles or {}) do
        willing[roles[index]] = true
    end
    for index = 1, #(listing.openRoles or {}) do
        if willing[listing.openRoles[index]] then
            return true
        end
    end
    return false
end

-- Whether `character` could join `listing` (a board listing).
function LfgRelevance.Fits(listing, character)
    if type(listing) ~= "table" or type(character) ~= "table" or not LfgRelevance.HasRoom(listing) then
        return false
    end
    if listing.kind == "dungeon" then
        return hasRange(listing) and levelFits(listing, character.level)
            and playsAnOpenRole(listing, character.roles)
    elseif listing.kind == "questing" or listing.kind == "raid" then
        return not hasRange(listing) or levelFits(listing, character.level)
    elseif listing.kind == "other" then
        return hasRange(listing) and levelFits(listing, character.level)
    end
    return false
end
