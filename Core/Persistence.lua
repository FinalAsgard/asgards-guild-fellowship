local _, addon = ...

-- Account-wide SavedVariables: the root table with a schema version and a
-- per-guild partition container (FellowshipStore owns what lives in each
-- partition). Existing data is never wiped: unknown fields stay as they are,
-- and a root or field of the wrong type leaves the whole store read-only for
-- the session instead of being overwritten.
--
-- Schema 2 adds guild sync's per-fact timestamps and authors. Its fields are
-- all optional, so v1 data is already valid v2 data and upgrading only
-- raises the version. An older add-on then refuses the data instead of
-- dropping fields it doesn't know. Unstamped facts count as the oldest
-- possible; an officer's unstamped manual edits are stamped later, once
-- the roster shows they are an officer (SyncSession:UpgradeLegacy).
--
-- Schema 3 adds player profile data on character records: each
-- character's role preferences, and when and by whom they were set. Like
-- schema 2's, the fields are optional, so v2 data is already valid v3 data.
--
-- Schema 4 adds the player profile's text fields on character records:
-- Discord, location and bio, each with when and by whom it was set; a
-- declared-main flag with its stamp (officer data); and, per
-- guild, the characters this install has logged in on and the ones the
-- player dismissed as suggestions (local only). Optional again, so v3 data
-- is already valid v4 data.
local Persistence = {
    SCHEMA_VERSION = 4,
}
addon.Persistence = Persistence

local Store = {}
Store.__index = Store

local function isSchemaVersion(value)
    return type(value) == "number" and value >= 1 and value == math.floor(value)
end

-- Returns nil when `database` can be used, or why it must be left untouched.
local function problemWith(database)
    if type(database) ~= "table" then
        return "saved data is a " .. type(database) .. ", not a table; it was left unchanged"
    end

    local schemaVersion = database.schemaVersion
    if schemaVersion ~= nil and not isSchemaVersion(schemaVersion) then
        return "saved data has an invalid schema version; it was left unchanged"
    end
    if schemaVersion ~= nil and schemaVersion > Persistence.SCHEMA_VERSION then
        return "saved data is from a newer version of the add-on; it was left unchanged"
    end

    if database.guilds ~= nil and type(database.guilds) ~= "table" then
        return "saved guild data is invalid; it was left unchanged"
    end

    return nil
end

function Persistence.Create(client)
    return setmetatable({ client = client }, Store)
end

-- Matches the lifecycle's state contract: true when the store is ready, or
-- false and a reason the player is told once.
function Store:Initialize()
    local database = self.client:GetAccountDatabase()

    if database == nil then
        database = {
            schemaVersion = Persistence.SCHEMA_VERSION,
            guilds = {},
        }
        if self.client:SetAccountDatabase(database) ~= true then
            return false, "new saved data could not be stored"
        end
        self.database = database
        return true
    end

    local problem = problemWith(database)
    if problem ~= nil then
        return false, problem
    end

    -- Only missing fields are filled in and an older version is raised;
    -- present values are never replaced.
    if database.schemaVersion == nil or database.schemaVersion < Persistence.SCHEMA_VERSION then
        database.schemaVersion = Persistence.SCHEMA_VERSION
    end
    if database.guilds == nil then
        database.guilds = {}
    end

    self.database = database
    return true
end

-- The live SavedVariables table, or nil when it is missing or unusable.
function Store:GetDatabase()
    return self.database
end
