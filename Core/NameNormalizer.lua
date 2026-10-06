local _, addon = ...

-- Turns raw character names into canonical keys and display forms. Client
-- name rules are passed in, never detected:
--   rules.twoPartNames  true on WoW Forever, where a name is "First Last"
--   rules.homeRealm     the guild's home realm, used when a name has no suffix
-- A key is "<name>-<realm>", case-folded, with whitespace collapsed to the
-- single internal space Forever names keep and spaces removed from the realm
-- (the form the roster API reports realms in).
local NameNormalizer = {}
addon.NameNormalizer = NameNormalizer

local Normalizer = {}
Normalizer.__index = Normalizer

local function trim(value)
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

-- Lua's string.lower only folds ASCII. Character names may use accented
-- Latin letters, so also fold UTF-8 "À" (C3 80) through "Þ" (C3 9E), except
-- the multiplication sign (C3 97).
local function fold(value)
    value = string.lower(value)
    return (string.gsub(value, "\195([\128-\158])", function(byte)
        if byte == "\151" then
            return "\195" .. byte
        end
        return "\195" .. string.char(string.byte(byte) + 32)
    end))
end

local function compactRealm(realm)
    return (string.gsub(realm, "%s+", ""))
end

function NameNormalizer.Create(rules)
    rules = rules or {}
    local homeRealm = type(rules.homeRealm) == "string" and compactRealm(rules.homeRealm) or ""
    return setmetatable({
        homeRealm = homeRealm,
        homeRealmKey = fold(homeRealm),
        twoPartNames = rules.twoPartNames == true,
    }, Normalizer)
end

-- Splits a raw name into its name and realm parts, cleaned but not folded.
-- Returns nil for anything that isn't a usable name.
function Normalizer:Split(rawName)
    if type(rawName) ~= "string" then
        return nil
    end

    local name, realm = string.match(rawName, "^(.-)%-([^%-]*)$")
    if name == nil then
        name, realm = rawName, ""
    end

    name = trim(string.gsub(name, "%s+", " "))
    if not self.twoPartNames then
        -- Retail names are one word; any space is noise.
        name = string.gsub(name, " ", "")
    end
    realm = compactRealm(realm)
    if realm == "" then
        realm = self.homeRealm
    end

    if name == "" then
        return nil
    end
    return name, realm
end

-- The canonical key for a raw name, or nil.
function Normalizer:Key(rawName)
    local name, realm = self:Split(rawName)
    if name == nil then
        return nil
    end
    return fold(name) .. "-" .. fold(realm)
end

-- How a name is shown: the name as the game spells it, with the realm only
-- when it isn't the guild's home realm.
function Normalizer:Display(rawName)
    local name, realm = self:Split(rawName)
    if name == nil then
        return nil
    end
    if realm == "" or fold(realm) == self.homeRealmKey then
        return name
    end
    return name .. "-" .. realm
end

-- The first name of a Forever two-part name, folded for matching. Retail
-- names have no separate first name, so this returns nil there.
function Normalizer:FirstName(rawName)
    if not self.twoPartNames then
        return nil
    end
    local name = self:Split(rawName)
    if name == nil then
        return nil
    end
    return fold(string.match(name, "^(%S+)"))
end

function Normalizer:IsSameCharacter(first, second)
    local firstKey = self:Key(first)
    return firstKey ~= nil and firstKey == self:Key(second)
end
