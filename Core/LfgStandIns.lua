local _, addon = ...

-- The Dev build's /agfdev lfgtest: stand-in listings for every look of the
-- Guild LFG Board, made for the character it runs on, plus a stand-in
-- request and a stand-in party for "fill the empty slot?". Stand-ins are
-- keyed with PREFIX, so the add-on can keep anything for them off the wire.
-- Pure: the character's facts are handed in.
local LfgStandIns = {
    PREFIX = "lfgtest:",
}
addon.LfgStandIns = LfgStandIns

local CLASSES = { "WARRIOR", "PRIEST", "MAGE", "ROGUE", "PALADIN", "DRUID", "HUNTER", "WARLOCK" }
local NAMES = { "Tankard", "Brightleaf", "Emberly", "Quickstep", "Oakheart", "Moonfur", "Farshot", "Gloom" }

-- Whether `key` is a stand-in's.
function LfgStandIns.IsStandIn(key)
    return type(key) == "string" and string.sub(key, 1, #LfgStandIns.PREFIX) == LfgStandIns.PREFIX
end

local function clamp(level)
    return math.max(1, math.min(level, 80))
end

-- `count` stand-in members at `level`, member i playing `roles[i]` (if
-- given).
local function members(count, level, roles)
    local list = {}
    local index
    for index = 1, count do
        local slot = (index - 1) % #NAMES + 1
        local name = NAMES[slot]
        if index > #NAMES then
            name = name .. tostring(math.floor((index - 1) / #NAMES) + 1)
        end
        list[index] = { n = name, c = CLASSES[slot], l = level, r = roles and roles[index] or nil }
    end
    return list
end

-- A dungeon `level` fits from `dungeons` (a DungeonCatalog), else a
-- made-up one around it.
local function fittingDungeon(dungeons, level)
    local fitting = dungeons and dungeons:Split(level) or {}
    if fitting[1] ~= nil then
        return fitting[1].name, fitting[1].minLevel, fitting[1].maxLevel
    end
    return "Stand-in Dungeon", clamp(level - 2), clamp(level + 2)
end

-- A 6-level range neither `level` nor any of `alts` (each { level }) fits:
-- 13-18 for a high character and 55-60 for a low one when those are clear,
-- else the clear one farthest from `level`. Nil when there's none.
local function awayRange(level, alts)
    local levels = { level }
    local index
    for index = 1, #(alts or {}) do
        if type(alts[index].level) == "number" then
            table.insert(levels, alts[index].level)
        end
    end
    local function clear(lo)
        for index = 1, #levels do
            if levels[index] >= lo and levels[index] <= lo + 5 then
                return false
            end
        end
        return true
    end
    local preferred = level > 30 and 13 or 55
    if clear(preferred) then
        return preferred, preferred + 5
    end
    local best, farthest
    local lo
    for lo = 1, 75 do
        local distance = math.abs(lo + 2.5 - level)
        if clear(lo) and (best == nil or distance > farthest) then
            best, farthest = lo, distance
        end
    end
    if best == nil then
        return nil
    end
    return best, best + 5
end

-- The stand-in listings for a character, facts:
--   level     the character's level
--   alt       optional { name, level }: one of the player's alts
--   alts      optional list of every alt ({ level }), which the greyed
--             listing must not fit
--   dungeons  optional DungeonCatalog for real dungeon names
-- Returns { { key, sender, message, case } }: a relevant dungeon, a
-- relevant purpose with a note, a dungeon only the alt fits (when the alt's
-- level allows one), one nothing fits (greyed), a full one, and a raid.
-- `note` says which case couldn't be made, if any.
function LfgStandIns.Listings(facts)
    local level = type(facts.level) == "number" and facts.level or 1
    local listings = {}
    local function add(case, fields)
        local index = #listings + 1
        local sender = fields.mb[1].n .. "-StandIn"
        fields.aj = fields.aj ~= false
        table.insert(listings, { key = LfgStandIns.PREFIX .. index, sender = sender, case = case,
            message = addon.LfgProtocol.Listing(fields) })
    end
    local name, lo, hi = fittingDungeon(facts.dungeons, level)
    add("relevant", { k = "dungeon", p = name, lo = lo, hi = hi, r = { "tank", "healer", "dps" }, s = 2, x = 5,
        mb = members(2, level, { "dps", "dps" }) })
    add("note", { k = "other", p = "Gold run", lo = clamp(level - 5), hi = clamp(level + 5), s = 3, x = 5,
        no = "3 bosses down, 2 to go", mb = members(3, level) })
    local note
    local alt = facts.alt
    if alt ~= nil and type(alt.level) == "number" and math.abs(alt.level - level) > 1 then
        local altLo, altHi = alt.level, alt.level
        add("alts", { k = "dungeon", p = "For " .. alt.name, lo = altLo, hi = altHi, r = { "tank", "healer", "dps" },
            s = 1, x = 5, mb = members(1, alt.level, { "dps" }) })
    else
        note = "no alt far enough from this character's level for an alts-only listing"
    end
    local awayLo, awayHi = awayRange(level, facts.alts)
    if awayLo ~= nil then
        add("greyed", { k = "dungeon", p = "Far Away Keep", lo = awayLo, hi = awayHi, r = { "dps" }, s = 4, x = 5,
            mb = members(4, awayHi, { "tank", "healer", "dps", "dps" }) })
    else
        note = (note and (note .. "; ") or "") .. "no level range that this character and its alts all miss," ..
            " for a greyed listing"
    end
    add("full", { k = "dungeon", p = name, lo = lo, hi = hi, r = {}, s = 5, x = 5,
        mb = members(5, level, { "tank", "healer", "dps", "dps", "dps" }) })
    add("raid", { k = "raid", p = "Guild event", s = 12, x = 40, mb = members(12, level) })
    return listings, note
end

-- Stand-in Find guildmates rows for the player's `listing` ({ minLevel?,
-- maxLevel? }), as LfgFillCandidates.List gives them: two who could fill a
-- slot, then one already in a listed group. Never invited.
function LfgStandIns.Candidates(listing)
    local level = type(listing.minLevel) == "number" and listing.minLevel or 1
    local rows = {}
    local index
    for index = 1, 3 do
        local slot = index + 4
        table.insert(rows, { key = LfgStandIns.PREFIX .. "fill" .. index, name = NAMES[slot],
            whisper = NAMES[slot] .. "-StandIn", level = level, class = CLASSES[slot], classToken = CLASSES[slot],
            label = NAMES[slot], inGroup = index == 3, standIn = true })
    end
    return rows
end

-- A stand-in Ask to join request, for the leader's toast.
function LfgStandIns.Request()
    return { key = LfgStandIns.PREFIX .. "asker", sender = "Brightleaf-StandIn", name = "Brightleaf",
        classToken = "PRIEST", level = 24, role = "healer", standIn = true }
end

-- A stand-in party for "fill the empty slot?" (LfgDrawerModel's party).
function LfgStandIns.Party()
    return { kind = "dungeon", label = "Stand-in party", size = 4, maxSize = 5, slotRole = "healer",
        openRoles = { "healer" } }
end
