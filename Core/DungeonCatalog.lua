local _, addon = ...

-- The dungeons the Group Finder can form a group for, each
-- { id, name, minLevel, maxLevel }. Where the client has a Dungeon Finder
-- (Retail), the WoW adapter supplies its dungeons; otherwise, or when it
-- supplies none, the client's static table below is used. It answers which
-- dungeons fit a level and whether a level fits a dungeon. Pure: it never
-- touches the game.
local DungeonCatalog = {}
addon.DungeonCatalog = DungeonCatalog

local Catalog = {}
Catalog.__index = Catalog

local function dungeon(id, name, minLevel, maxLevel)
    return { id = id, name = name, minLevel = minLevel, maxLevel = maxLevel }
end

-- Per-client tables, by client profile id. WoW Forever has no Dungeon
-- Finder, so its Classic dungeons and their fixed ranges live here; its
-- ranges still need checking in game. Retail's table is only a fallback for
-- when the Dungeon Finder reports nothing: the current expansion's leveling
-- dungeons, a best guess until checked in game.
DungeonCatalog.STATIC = {
    forever = {
        dungeon("rfc", "Ragefire Chasm", 13, 18),
        dungeon("wc", "Wailing Caverns", 17, 24),
        dungeon("dm", "The Deadmines", 17, 26),
        dungeon("sfk", "Shadowfang Keep", 22, 30),
        dungeon("bfd", "Blackfathom Deeps", 24, 32),
        dungeon("stocks", "The Stockade", 24, 32),
        dungeon("gnomer", "Gnomeregan", 29, 38),
        dungeon("rfk", "Razorfen Kraul", 29, 38),
        dungeon("smgy", "Scarlet Monastery: Graveyard", 26, 36),
        dungeon("smlib", "Scarlet Monastery: Library", 29, 39),
        dungeon("smarm", "Scarlet Monastery: Armory", 32, 42),
        dungeon("smcath", "Scarlet Monastery: Cathedral", 35, 45),
        dungeon("rfd", "Razorfen Downs", 37, 46),
        dungeon("ulda", "Uldaman", 41, 51),
        dungeon("zf", "Zul'Farrak", 42, 46),
        dungeon("mara", "Maraudon", 46, 55),
        dungeon("st", "The Temple of Atal'Hakkar", 50, 56),
        dungeon("brd", "Blackrock Depths", 52, 60),
        dungeon("lbrs", "Lower Blackrock Spire", 55, 60),
        dungeon("ubrs", "Upper Blackrock Spire", 55, 60),
        dungeon("dme", "Dire Maul: East", 55, 60),
        dungeon("dmw", "Dire Maul: West", 57, 60),
        dungeon("dmn", "Dire Maul: North", 57, 60),
        dungeon("scholo", "Scholomance", 58, 60),
        dungeon("strat", "Stratholme", 58, 60),
        -- Forever's own dungeons, alongside the Classic ones. Ranges from
        -- the beta, still provisional.
        dungeon("thanes", "Hall of Thanes", 13, 18),
        dungeon("lordaeron", "Ruins of Lordaeron", 15, 20),
        dungeon("excavation", "Excavation Site: Wetlands", 26, 31),
        dungeon("dalaran", "City of Dalaran", 28, 33),
        dungeon("drowned", "The Drowned City", 35, 40),
        dungeon("kroldok", "Krol'dok Stronghold", 40, 45),
        dungeon("alcaz", "Alcaz Island Prison", 48, 53),
        dungeon("blackmaw", "Blackmaw Hold", 55, 60),
        dungeon("shapers", "Shaper's Terrace", 58, 60),
    },
    retail = {
        dungeon("windrunner", "Windrunner Spire", 80, 90),
        dungeon("murderrow", "Murder Row", 80, 90),
        dungeon("nalorakk", "Den of Nalorakk", 80, 90),
        dungeon("maisara", "Maisara Caverns", 80, 90),
        dungeon("blindingvale", "The Blinding Vale", 80, 90),
        dungeon("magisters", "Magisters' Terrace", 80, 90),
        dungeon("xenas", "Nexus-Point Xenas", 80, 90),
        dungeon("voidscar", "Voidscar Arena", 80, 90),
    },
}

local function isDungeon(entry)
    return type(entry) == "table" and entry.id ~= nil
        and type(entry.name) == "string" and entry.name ~= ""
        and type(entry.minLevel) == "number" and type(entry.maxLevel) == "number"
        and entry.minLevel <= entry.maxLevel
end

-- Lowest range first; ties by name, then id, so the order never shifts.
local function byRange(a, b)
    if a.minLevel ~= b.minLevel then
        return a.minLevel < b.minLevel
    end
    if a.maxLevel ~= b.maxLevel then
        return a.maxLevel < b.maxLevel
    end
    if a.name ~= b.name then
        return a.name < b.name
    end
    return tostring(a.id) < tostring(b.id)
end

-- A catalog of `entries`; unusable entries are left out.
function DungeonCatalog.Create(entries)
    local dungeons, byId = {}, {}
    local index
    for index = 1, #(type(entries) == "table" and entries or {}) do
        local entry = entries[index]
        if isDungeon(entry) and byId[entry.id] == nil then
            local copy = dungeon(entry.id, entry.name, entry.minLevel, entry.maxLevel)
            table.insert(dungeons, copy)
            byId[copy.id] = copy
        end
    end
    table.sort(dungeons, byRange)
    return setmetatable({ dungeons = dungeons, byId = byId }, Catalog)
end

-- The catalog for client `clientId`: the Dungeon Finder's dungeons
-- (`supplied`) when there are any, else the client's static table.
function DungeonCatalog.For(clientId, supplied)
    local catalog = DungeonCatalog.Create(supplied)
    if #catalog.dungeons > 0 then
        return catalog
    end
    return DungeonCatalog.Create(DungeonCatalog.STATIC[clientId])
end

-- Every dungeon, lowest range first.
function Catalog:All()
    local list = {}
    local index
    for index = 1, #self.dungeons do
        list[index] = self.dungeons[index]
    end
    return list
end

function Catalog:Get(id)
    return self.byId[id]
end

-- Whether `level` is within the range of the dungeon with `id`.
function Catalog:Fits(id, level)
    local found = self.byId[id]
    return found ~= nil and type(level) == "number"
        and level >= found.minLevel and level <= found.maxLevel
end

-- The dungeons `level` fits, then the rest, each lowest range first.
function Catalog:Split(level)
    local fitting, others = {}, {}
    local index
    for index = 1, #self.dungeons do
        local entry = self.dungeons[index]
        if self:Fits(entry.id, level) then
            table.insert(fitting, entry)
        else
            table.insert(others, entry)
        end
    end
    return fitting, others
end
