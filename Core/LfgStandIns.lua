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

-- The stand-in listings for a character, facts:
--   level     the character's level
--   alt       optional { name, level }: one of the player's alts
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
    local away = level > 30 and { 13, 18 } or { 55, 60 }
    add("greyed", { k = "dungeon", p = "Far Away Keep", lo = away[1], hi = away[2], r = { "dps" }, s = 4, x = 5,
        mb = members(4, away[2], { "tank", "healer", "dps", "dps" }) })
    add("full", { k = "dungeon", p = name, lo = lo, hi = hi, r = {}, s = 5, x = 5,
        mb = members(5, level, { "tank", "healer", "dps", "dps", "dps" }) })
    add("raid", { k = "raid", p = "Guild event", s = 12, x = 40, mb = members(12, level) })
    return listings, note
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
