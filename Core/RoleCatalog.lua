local _, addon = ...

-- Which roles each class can fill, per client. WoW Forever starts from the
-- Classic nine classes and their roles, and may diverge later, which is why
-- each client has its own table. Pure: it never touches the game.
local RoleCatalog = {
    TANK = "tank",
    HEALER = "healer",
    DPS = "dps",
}
-- Every role, in the order slots and defaults consider them.
RoleCatalog.ROLES = { RoleCatalog.TANK, RoleCatalog.HEALER, RoleCatalog.DPS }
-- What each role is called on screen.
RoleCatalog.LABELS = { tank = "Tank", healer = "Healer", dps = "DPS" }
addon.RoleCatalog = RoleCatalog

local Catalog = {}
Catalog.__index = Catalog

local TANK, HEALER, DPS = RoleCatalog.TANK, RoleCatalog.HEALER, RoleCatalog.DPS

local FOREVER = {
    WARRIOR = { TANK, DPS },
    PALADIN = { TANK, HEALER, DPS },
    HUNTER = { DPS },
    ROGUE = { DPS },
    PRIEST = { HEALER, DPS },
    SHAMAN = { HEALER, DPS },
    MAGE = { DPS },
    WARLOCK = { DPS },
    DRUID = { TANK, HEALER, DPS },
}

local RETAIL = {
    WARRIOR = { TANK, DPS },
    PALADIN = { TANK, HEALER, DPS },
    HUNTER = { DPS },
    ROGUE = { DPS },
    PRIEST = { HEALER, DPS },
    SHAMAN = { HEALER, DPS },
    MAGE = { DPS },
    WARLOCK = { DPS },
    DRUID = { TANK, HEALER, DPS },
    DEATHKNIGHT = { TANK, DPS },
    MONK = { TANK, HEALER, DPS },
    DEMONHUNTER = { TANK, DPS },
    EVOKER = { HEALER, DPS },
}

RoleCatalog.TABLES = { forever = FOREVER, retail = RETAIL }

-- Whether `role` is one of the three roles.
function RoleCatalog.IsRole(role)
    return RoleCatalog.LABELS[role] ~= nil
end

-- The catalog for client `clientId`; an unknown client has no classes.
function RoleCatalog.For(clientId)
    return setmetatable({ classes = RoleCatalog.TABLES[clientId] or {} }, Catalog)
end

-- The roles `classToken` can fill, in role order; none for an unknown class.
function Catalog:RolesFor(classToken)
    local roles = self.classes[classToken] or {}
    local copy = {}
    local index
    for index = 1, #roles do
        copy[index] = roles[index]
    end
    return copy
end

-- Whether `classToken` can fill `role`.
function Catalog:Can(classToken, role)
    local roles = self.classes[classToken] or {}
    local index
    for index = 1, #roles do
        if roles[index] == role then
            return true
        end
    end
    return false
end
