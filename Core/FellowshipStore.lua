local _, addon = ...

-- The Fellowship database inside the account-wide SavedVariables, schema v1.
-- Core/Persistence owns the root (schema version, the `guilds` container,
-- and refusing corrupt or newer roots). This module owns what lives in it:
-- one partition per guild (name plus realm), each holding durable character
-- and player records. The foundation already writes a v1 root with an empty
-- `guilds` container, so it migrates by creating partitions on first use.
--
-- Only lasting facts are persisted. Live roster state (online, zone,
-- last-online, note text) is read from the game when it's needed and never
-- written here.
local FellowshipStore = {
    SOURCE_ROSTER = "roster",
}
addon.FellowshipStore = FellowshipStore

local Store = {}
Store.__index = Store

local Partition = {}
Partition.__index = Partition

local function isWholeNumber(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function isText(value)
    return type(value) == "string" and value ~= ""
end

-- Returns nil when a character record can be used, or why it can't.
local function characterProblem(character)
    if type(character) ~= "table" then
        return "character record is not a table"
    end
    if not isWholeNumber(character.player) then
        return "character has no valid player id"
    end
    if character.name ~= nil and not isText(character.name) then
        return "character name is invalid"
    end
    if character.class ~= nil and not isText(character.class) then
        return "character class is invalid"
    end
    if character.level ~= nil and not isWholeNumber(character.level) then
        return "character level is invalid"
    end
    if character.rank ~= nil and not isWholeNumber(character.rank) then
        return "character rank is invalid"
    end
    if character.source ~= nil and not isText(character.source) then
        return "character source is invalid"
    end
    return nil
end

local function playerProblem(player)
    if type(player) ~= "table" then
        return "player record is not a table"
    end
    if not isText(player.main) then
        return "player has no main character"
    end
    return nil
end

-- Moves a record that can't be read aside, intact, so nothing is lost and
-- the rest of the partition stays usable.
local function quarantine(partition, collection, key, record, reason)
    table.insert(partition.quarantine, {
        collection = collection,
        key = key,
        reason = reason,
        record = record,
    })
end

-- Repairs one partition in place. Returns false when the partition itself is
-- unusable (it is then left untouched).
local function validatePartition(data)
    -- Check every container before touching anything, so a rejected
    -- partition is left exactly as it was.
    if type(data) ~= "table" then
        return false
    end
    local containers = { "characters", "players", "quarantine" }
    local index
    for index = 1, #containers do
        local value = data[containers[index]]
        if value ~= nil and type(value) ~= "table" then
            return false
        end
    end
    if (data.nextPlayerId ~= nil and not isWholeNumber(data.nextPlayerId))
        or (data.lastFullScan ~= nil and type(data.lastFullScan) ~= "number")
    then
        return false
    end
    for index = 1, #containers do
        if data[containers[index]] == nil then
            data[containers[index]] = {}
        end
    end

    local highestId = 0
    local key, record
    for key, record in pairs(data.players) do
        local problem = "player id is not a whole number"
        if isWholeNumber(key) and key > 0 then
            problem = playerProblem(record)
        end
        if problem ~= nil then
            data.players[key] = nil
            quarantine(data, "players", key, record, problem)
        elseif key > highestId then
            highestId = key
        end
    end
    for key, record in pairs(data.characters) do
        local problem = "character key is invalid"
        if isText(key) then
            problem = characterProblem(record)
        end
        if problem == nil and data.players[record.player] == nil then
            problem = "character's player is missing"
        end
        if problem ~= nil then
            data.characters[key] = nil
            quarantine(data, "characters", key, record, problem)
        end
    end
    if data.nextPlayerId == nil or data.nextPlayerId <= highestId then
        data.nextPlayerId = highestId + 1
    end
    return true
end

-- `database` is the live SavedVariables root from Persistence:GetDatabase().
function FellowshipStore.Create(database)
    return setmetatable({ database = database, partitions = {} }, Store)
end

-- The partition key for a guild identity: "<guild name>-<realm>", with the
-- realm's spaces removed so it matches roster realm suffixes.
function FellowshipStore.PartitionKey(guild)
    if type(guild) ~= "table" or not isText(guild.name) or not isText(guild.realm) then
        return nil
    end
    return guild.name .. "-" .. string.gsub(guild.realm, "%s+", "")
end

-- The guild's partition, created on first use. Returns nil and a reason
-- when the database or that partition can't be used; corrupt data is then
-- left exactly as it was.
function Store:Partition(guild)
    local key = FellowshipStore.PartitionKey(guild)
    if key == nil then
        return nil, "guild identity is unavailable"
    end
    if self.partitions[key] ~= nil then
        return self.partitions[key]
    end
    if type(self.database) ~= "table" or type(self.database.guilds) ~= "table" then
        return nil, "saved data is unavailable"
    end

    local data = self.database.guilds[key]
    if data == nil then
        data = {}
        self.database.guilds[key] = data
    end
    if not validatePartition(data) then
        return nil, "saved data for " .. guild.name .. " is unreadable; it was left unchanged"
    end

    local partition = setmetatable({ data = data, key = key }, Partition)
    self.partitions[key] = partition
    return partition
end

-- Saved window geometry, shared by every guild. Returns nil when absent or
-- unusable.
function Store:GetWindowState()
    local window = type(self.database) == "table" and self.database.window or nil
    if type(window) ~= "table" then
        return nil
    end
    return window
end

-- Replaces the saved geometry. An unusable existing value is left alone.
function Store:SetWindowState(state)
    if type(self.database) ~= "table" or type(state) ~= "table" then
        return false
    end
    if self.database.window ~= nil and type(self.database.window) ~= "table" then
        return false
    end
    self.database.window = state
    return true
end

function Partition:GetCharacter(key)
    return self.data.characters[key]
end

function Partition:GetPlayer(id)
    return self.data.players[id]
end

-- Calls `callback(key, character)` for every stored character.
function Partition:EachCharacter(callback)
    local key, character
    for key, character in pairs(self.data.characters) do
        callback(key, character)
    end
end

-- Records a character seen in the roster. A character with no known
-- relationships becomes the main of its own single-character player. Only
-- lasting facts (name, class, level, rank) are stored; everything else in
-- `facts` is ignored.
function Partition:RecordCharacter(key, facts)
    if not isText(key) or type(facts) ~= "table" then
        return nil
    end

    local character = self.data.characters[key]
    if character == nil then
        local id = self.data.nextPlayerId
        self.data.nextPlayerId = id + 1
        self.data.players[id] = { main = key }
        character = { player = id, source = FellowshipStore.SOURCE_ROSTER }
        self.data.characters[key] = character
    end

    -- The name exactly as the roster spells it (capitalization, realm
    -- suffix), so it can still be shown once the character isn't in the
    -- live roster.
    if isText(facts.name) then
        character.name = facts.name
    end
    if isText(facts.classToken) then
        character.class = facts.classToken
    end
    if isWholeNumber(facts.level) then
        character.level = facts.level
    end
    if isWholeNumber(facts.rankIndex) then
        character.rank = facts.rankIndex
    end
    return character
end

function Partition:HasBeenScanned()
    return self.data.lastFullScan ~= nil
end

function Partition:MarkScanned(timestamp)
    if type(timestamp) ~= "number" then
        return false
    end
    self.data.lastFullScan = timestamp
    return true
end

function Partition:GetLastScan()
    return self.data.lastFullScan
end
