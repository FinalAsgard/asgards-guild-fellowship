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
    SOURCE_MANUAL = "manual",
    SOURCE_NOTE = "note",
    SOURCE_ROSTER = "roster",
    -- Applied from an officer's edit received over guild sync.
    SOURCE_SYNC = "sync",
    -- How many greetings a player must already have before this user's
    -- greet prompt for them closes (GreetTally).
    GREET_CAP_DEFAULT = 2,
    GREET_CAP_MIN = 1,
    GREET_CAP_MAX = 10,
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
    if character.note ~= nil and not isText(character.note) then
        return "character note fingerprint is invalid"
    end
    if character.departed ~= nil and type(character.departed) ~= "number" then
        return "character departure date is invalid"
    end
    -- Guild sync (schema 2): when this character's main link was last set,
    -- and by whom (a character key).
    if character.mainAt ~= nil and not isWholeNumber(character.mainAt) then
        return "character main link time is invalid"
    end
    if character.mainBy ~= nil and not isText(character.mainBy) then
        return "character main link author is invalid"
    end
    if character.rejected ~= nil then
        if type(character.rejected) ~= "table" then
            return "character rejected fingerprints are invalid"
        end
        local kind, fingerprint
        for kind, fingerprint in pairs(character.rejected) do
            if not isText(kind) or not isText(fingerprint) then
                return "character rejected fingerprints are invalid"
            end
        end
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
    if player.alias ~= nil and not isText(player.alias) then
        return "player alias is invalid"
    end
    if player.aliasSource ~= nil and not isText(player.aliasSource) then
        return "player alias source is invalid"
    end
    -- Guild sync (schema 2): when this player's alias was last set or
    -- cleared, and by whom (a character key).
    if player.aliasAt ~= nil and not isWholeNumber(player.aliasAt) then
        return "player alias time is invalid"
    end
    if player.aliasBy ~= nil and not isText(player.aliasBy) then
        return "player alias author is invalid"
    end
    -- "Don't sync": this client keeps its own version of the player.
    if player.noSync ~= nil and player.noSync ~= true then
        return "player don't sync flag is invalid"
    end
    if player.history ~= nil then
        if type(player.history) ~= "table" then
            return "player history is invalid"
        end
        local index
        for index = 1, #player.history do
            local entry = player.history[index]
            if type(entry) ~= "table" or not isText(entry.name) or not isText(entry.role) then
                return "player history is invalid"
            end
        end
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
    local containers = {
        "characters", "players", "quarantine", "conflicts", "suggestions", "ledger", "forgeries", "unapplied",
    }
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
    -- Markers an earlier build recorded as `unapplied` become conflicts.
    if data.unapplied ~= nil and data.conflicts == nil then
        data.conflicts = {}
        local entryIndex
        for entryIndex = 1, #data.unapplied do
            local entry = data.unapplied[entryIndex]
            if type(entry) == "table" and isText(entry.character) and isText(entry.reason)
                and entry.reason ~= "player already organized"
            then
                table.insert(data.conflicts, {
                    character = entry.character,
                    fingerprint = entry.fingerprint,
                    kind = entry.reason,
                })
            end
        end
    end
    data.unapplied = nil
    -- An officer's ledger and forgery log are only created when needed.
    local optional = { unapplied = true, ledger = true, forgeries = true }
    for index = 1, #containers do
        if not optional[containers[index]] and data[containers[index]] == nil then
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

-- The minimap button's saved state (LibDBIcon's angle and hidden flag),
-- created on first use. Nil when an unusable value is stored there; it is
-- then left alone.
function Store:GetMinimapState()
    if type(self.database) ~= "table" then
        return nil
    end
    if self.database.minimap == nil then
        self.database.minimap = {}
    end
    if type(self.database.minimap) ~= "table" then
        return nil
    end
    return self.database.minimap
end

-- Whether chat tags are on, shared by every guild. On unless turned off;
-- an unusable stored value counts as on.
function Store:ChatTagsEnabled()
    return type(self.database) ~= "table" or self.database.chatTags ~= false
end

-- Turns chat tags on or off. An unusable existing value is left alone.
function Store:SetChatTagsEnabled(enabled)
    if type(self.database) ~= "table" or type(enabled) ~= "boolean" then
        return false
    end
    if self.database.chatTags ~= nil and type(self.database.chatTags) ~= "boolean" then
        return false
    end
    self.database.chatTags = enabled
    return true
end

-- Guild Greet's saved state, shared by every character on the account and
-- created on first use: the on/off switch, the greetings, and the last
-- greeting used in each category (GreetingLibrary owns their shape). Nil
-- when an unusable value is stored there; it is then left alone.
function Store:GetGreetState()
    if type(self.database) ~= "table" then
        return nil
    end
    if self.database.greet == nil then
        self.database.greet = {}
    end
    if type(self.database.greet) ~= "table" then
        return nil
    end
    return self.database.greet
end

-- Whether Guild Greet is on. On unless turned off; unusable saved data
-- counts as on, as with chat tags.
function Store:GreetEnabled()
    local state = type(self.database) == "table" and self.database.greet or nil
    return type(state) ~= "table" or state.enabled ~= false
end

-- Turns Guild Greet on or off. An unusable existing value is left alone.
function Store:SetGreetEnabled(enabled)
    if type(enabled) ~= "boolean" then
        return false
    end
    local state = self:GetGreetState()
    if state == nil or (state.enabled ~= nil and type(state.enabled) ~= "boolean") then
        return false
    end
    state.enabled = enabled
    return true
end

local function isGreetCap(value)
    return type(value) == "number" and value == math.floor(value)
        and value >= FellowshipStore.GREET_CAP_MIN and value <= FellowshipStore.GREET_CAP_MAX
end

-- The greeting cap, shared by every character. The default when none is
-- saved or the saved one is unusable.
function Store:GreetCap()
    local state = type(self.database) == "table" and self.database.greet or nil
    local cap = type(state) == "table" and state.cap or nil
    if not isGreetCap(cap) then
        return FellowshipStore.GREET_CAP_DEFAULT
    end
    return cap
end

-- Sets the greeting cap (a whole number from 1 to 10). An unusable existing
-- value is left alone.
function Store:SetGreetCap(cap)
    if not isGreetCap(cap) then
        return false
    end
    local state = self:GetGreetState()
    if state == nil or (state.cap ~= nil and not isGreetCap(state.cap)) then
        return false
    end
    state.cap = cap
    return true
end

-- The points a saved greet prompt position may be measured from.
local ANCHOR_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- A usable screen offset: a real number, not NaN or far off any screen.
local function isOffset(value)
    return type(value) == "number" and value == value and math.abs(value) < 100000
end

local function isAnchor(anchor)
    return type(anchor) == "table" and ANCHOR_POINTS[anchor.point] == true
        and isOffset(anchor.x) and isOffset(anchor.y)
end

-- Where greet prompts stack from ({ point, x, y }, measured from that point
-- of the screen), shared by every character. Nil when none is saved or the
-- saved one is unusable, so the prompts use their default place.
function Store:GreetAnchor()
    local state = type(self.database) == "table" and self.database.greet or nil
    local anchor = type(state) == "table" and state.anchor or nil
    if not isAnchor(anchor) then
        return nil
    end
    return { point = anchor.point, x = anchor.x, y = anchor.y }
end

-- Saves where greet prompts stack from. Unlike other settings, an unusable
-- saved position is replaced: the user just placed the prompts, and leaving
-- it would keep them at the default forever.
function Store:SetGreetAnchor(anchor)
    if not isAnchor(anchor) then
        return false
    end
    local state = self:GetGreetState()
    if state == nil then
        return false
    end
    state.anchor = { point = anchor.point, x = anchor.x, y = anchor.y }
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
        self.members = nil
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

-- Stores the fingerprint of a character's current public note (never the
-- note text itself).
function Partition:SetNoteFingerprint(key, fingerprint)
    local character = self.data.characters[key]
    if character == nil or not isText(fingerprint) then
        return false
    end
    character.note = fingerprint
    return true
end

-- Marks a character's note as unread, so the next scan, even a quick one,
-- reads it again against the current data.
function Partition:ForgetNoteFingerprint(key)
    local character = self.data.characters[key]
    if character ~= nil then
        character.note = nil
    end
end

-- After `key` has moved out of `oldPlayer`: removes the old player if it is
-- now empty, or hands its main role to the highest-level character left
-- (ties by name). Acting-main rules (in-guild first) are applied on top by
-- ReconcileEngine.EnsureActingMains.
function Partition:LeftPlayer(oldPlayer, key)
    local remaining = self:CharactersOf(oldPlayer)
    if remaining[1] == nil then
        self.data.players[oldPlayer] = nil
    elseif self.data.players[oldPlayer].main == key then
        local best = remaining[1]
        local index
        for index = 2, #remaining do
            local candidate = self.data.characters[remaining[index]]
            if (candidate.level or 0) > (self.data.characters[best].level or 0) then
                best = remaining[index]
            end
        end
        self.data.players[oldPlayer].main = best
    end
end

-- Moves `altKey` into the player of `mainKey`. The alt's old player is
-- removed when the alt was its only character.
function Partition:JoinPlayerOf(altKey, mainKey, source)
    local alt = self.data.characters[altKey]
    local main = self.data.characters[mainKey]
    if alt == nil or main == nil or altKey == mainKey then
        return false
    end
    local oldPlayer = alt.player
    if oldPlayer == main.player then
        return true
    end

    alt.player = main.player
    alt.source = source
    self.members = nil
    self:LeftPlayer(oldPlayer, altKey)
    return true
end

-- Moves a character into a new player of its own, as its main. Returns the
-- new player id.
function Partition:MoveToNewPlayer(key, source)
    local character = self.data.characters[key]
    if character == nil then
        return nil
    end
    local oldPlayer = character.player
    local id = self.data.nextPlayerId
    self.data.nextPlayerId = id + 1
    self.data.players[id] = { main = key }
    character.player = id
    character.source = source
    self.members = nil
    self:LeftPlayer(oldPlayer, key)
    return id
end

function Partition:ClearAlias(playerId, source)
    local player = self.data.players[playerId]
    if player == nil then
        return false
    end
    player.alias = nil
    player.aliasSource = source
    return true
end

function Partition:SetAlias(playerId, alias, source)
    local player = self.data.players[playerId]
    if player == nil or not isText(alias) then
        return false
    end
    player.alias = alias
    player.aliasSource = source
    return true
end

-- Keys of every character of a player, main first, then alphabetical. The
-- reverse index is rebuilt in memory when needed and never persisted.
function Partition:CharactersOf(playerId)
    if self.members == nil then
        self.members = {}
        local key, character
        for key, character in pairs(self.data.characters) do
            self.members[character.player] = self.members[character.player] or {}
            table.insert(self.members[character.player], key)
        end
    end
    local keys = {}
    local main = self.data.players[playerId] and self.data.players[playerId].main
    local index
    local list = self.members[playerId] or {}
    for index = 1, #list do
        table.insert(keys, list[index])
    end
    table.sort(keys, function(first, second)
        if (first == main) ~= (second == main) then
            return first == main
        end
        return first < second
    end)
    return keys
end

-- Calls `callback(id, player)` for every stored player.
function Partition:EachPlayer(callback)
    local id, player
    for id, player in pairs(self.data.players) do
        callback(id, player)
    end
end

-- The pending conflict queue: a list of
--   { character, kind, fingerprint, suggestion? }
-- where kind is "main", "alias", "unresolved", "ambiguous", "cycle",
-- "self reference", "chain too long", or "competing aliases", and
-- suggestion is { main = key } or { alias = text } for the kinds that can be
-- accepted. Never the note text. A member's suggestion queued for an
-- officer has kind "suggested main" or "suggested alias", plus `from` (the
-- member's key) and `at` (when they made the edit); see SuggestionService.
function Partition:SetConflicts(entries)
    if type(entries) ~= "table" then
        return false
    end
    self.data.conflicts = entries
    return true
end

function Partition:GetConflicts()
    return self.data.conflicts
end

-- This member's own edits waiting for an officer's decision: a list of the
-- facts they stamped (see SyncFacts and SuggestionService).
function Partition:GetSuggestions()
    return self.data.suggestions
end

function Partition:SetSuggestions(entries)
    if type(entries) ~= "table" then
        return false
    end
    self.data.suggestions = entries
    return true
end

-- An officer's ledger of the facts they wrote, and the log of forged edits
-- relayed in their name (see SyncLedger).
function Partition:GetLedger()
    return self.data.ledger
end

function Partition:SetLedger(ledger)
    if type(ledger) ~= "table" then
        return false
    end
    self.data.ledger = ledger
    return true
end

function Partition:GetForgeries()
    return self.data.forgeries
end

function Partition:SetForgeries(entries)
    if type(entries) ~= "table" then
        return false
    end
    self.data.forgeries = entries
    return true
end

-- Removes one conflict, found by character and kind. Returns it, or nil.
function Partition:RemoveConflict(character, kind)
    local conflicts = self.data.conflicts
    local index
    for index = 1, #conflicts do
        local entry = conflicts[index]
        if entry.character == character and entry.kind == kind then
            table.remove(conflicts, index)
            return entry
        end
    end
    return nil
end

-- Remembers that a conflict of this kind from this note fingerprint was
-- rejected, so it isn't queued again until the note changes.
function Partition:SetRejected(key, kind, fingerprint)
    local character = self.data.characters[key]
    if character == nil or not isText(kind) or not isText(fingerprint) then
        return false
    end
    character.rejected = character.rejected or {}
    character.rejected[kind] = fingerprint
    return true
end

-- Forgets a rejection, once the player accepts that kind of suggestion.
function Partition:ClearRejected(key, kind)
    local character = self.data.characters[key]
    if character ~= nil and character.rejected ~= nil then
        character.rejected[kind] = nil
        if next(character.rejected) == nil then
            character.rejected = nil
        end
    end
end

-- Guild sync ---------------------------------------------------------------

-- When `key`'s main link was last set, and by whom. A link nobody stamped
-- (seeded from notes or the roster) is the oldest possible: at 0, no author.
function Partition:GetMainStamp(key)
    local character = self.data.characters[key]
    if character == nil then
        return nil
    end
    return character.mainAt or 0, character.mainBy
end

function Partition:SetMainStamp(key, at, by)
    local character = self.data.characters[key]
    if character == nil or not isWholeNumber(at) or not isText(by) then
        return false
    end
    character.mainAt = at
    character.mainBy = by
    return true
end

-- When the alias of `key`'s player was last set or cleared, and by whom;
-- like main links, an unstamped alias is at 0 with no author.
function Partition:GetAliasStamp(key)
    local character = self.data.characters[key]
    local player = character and self.data.players[character.player]
    if player == nil then
        return nil
    end
    return player.aliasAt or 0, player.aliasBy
end

function Partition:SetAliasStamp(key, at, by)
    local character = self.data.characters[key]
    local player = character and self.data.players[character.player]
    if player == nil or not isWholeNumber(at) or not isText(by) then
        return false
    end
    player.aliasAt = at
    player.aliasBy = by
    return true
end

-- Forgets when and by whom `key`'s main link was set, making it the oldest
-- possible again.
function Partition:ClearMainStamp(key)
    local character = self.data.characters[key]
    if character ~= nil then
        character.mainAt = nil
        character.mainBy = nil
    end
end

-- The same for the alias of `key`'s player.
function Partition:ClearAliasStamp(key)
    local character = self.data.characters[key]
    local player = character and self.data.players[character.player]
    if player ~= nil then
        player.aliasAt = nil
        player.aliasBy = nil
    end
end

-- "Don't sync": whether this client keeps its own version of a player,
-- ignoring guild sync for it.
function Partition:IsNoSync(playerId)
    local player = self.data.players[playerId]
    return player ~= nil and player.noSync == true
end

function Partition:SetNoSync(playerId, enabled)
    local player = self.data.players[playerId]
    if player == nil then
        return false
    end
    player.noSync = enabled and true or nil
    return true
end

-- Departure and history -------------------------------------------------

-- Marks a character as having left the guild at `timestamp`.
function Partition:MarkDeparted(key, timestamp)
    local character = self.data.characters[key]
    if character == nil or type(timestamp) ~= "number" then
        return false
    end
    character.departed = timestamp
    return true
end

-- Clears a character's departed flag when it is seen in the roster again.
-- It keeps its stored player, so it rejoins that player automatically.
function Partition:MarkRejoined(key)
    local character = self.data.characters[key]
    if character == nil or character.departed == nil then
        return false
    end
    character.departed = nil
    return true
end

function Partition:IsInGuild(key)
    local character = self.data.characters[key]
    return character ~= nil and character.departed == nil
end

-- Adds an entry to a player's history of former and out-of-guild
-- characters: { name, role ("main" or "alt"), character?, since?, until?,
-- reason }. History is kept when characters are purged.
function Partition:AddHistory(playerId, entry)
    local player = self.data.players[playerId]
    if player == nil or type(entry) ~= "table" or not isText(entry.name) or not isText(entry.role) then
        return false
    end
    player.history = player.history or {}
    table.insert(player.history, entry)
    return true
end

function Partition:GetHistory(playerId)
    local player = self.data.players[playerId]
    return player and player.history or {}
end

-- Makes `key` its player's main. Returns false when it isn't a member.
function Partition:SetMain(playerId, key)
    local player = self.data.players[playerId]
    local character = self.data.characters[key]
    if player == nil or character == nil or character.player ~= playerId then
        return false
    end
    player.main = key
    return true
end

-- Removes a departed character for good. Its player keeps a history entry
-- for it; a player left with no characters is removed.
function Partition:Purge(key, timestamp)
    local character = self.data.characters[key]
    if character == nil or character.departed == nil then
        return false
    end
    local playerId = character.player
    local player = self.data.players[playerId]
    if player ~= nil then
        local recorded = false
        local index
        -- A departed main is already recorded; earlier moves ("detached",
        -- "moved to …") don't count, since the character came back.
        for index = 1, #(player.history or {}) do
            local entry = player.history[index]
            if entry.character == key and (entry.reason == "departed" or entry.reason == "purged") then
                recorded = true
            end
        end
        if not recorded then
            self:AddHistory(playerId, {
                character = key,
                name = character.name or key,
                role = player.main == key and "main" or "alt",
                ["until"] = character.departed,
                reason = "purged",
            })
        end
    end

    self.data.characters[key] = nil
    self.members = nil
    if player ~= nil then
        local remaining = self:CharactersOf(playerId)
        if remaining[1] == nil then
            self.data.players[playerId] = nil
        elseif player.main == key then
            player.main = remaining[1]
        end
    end
    self:RemoveConflictsFor(key)
    return true
end

function Partition:RemoveConflictsFor(key)
    local conflicts = self.data.conflicts
    local index = #conflicts
    while index >= 1 do
        if conflicts[index].character == key then
            table.remove(conflicts, index)
        end
        index = index - 1
    end
end

-- What the latest scan found, for the window's status line:
-- { at, mode, newCharacters, linked, aliased, conflicts }.
function Partition:SetLastScanSummary(summary)
    if type(summary) ~= "table" then
        return false
    end
    self.data.lastScanSummary = summary
    return true
end

function Partition:GetLastScanSummary()
    local summary = self.data.lastScanSummary
    if type(summary) ~= "table" then
        return nil
    end
    return summary
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

-- When this client last compared or exchanged guild sync data with another
-- add-on user, or nil.
function Partition:GetLastSync()
    local at = self.data.lastSync
    if type(at) ~= "number" then
        return nil
    end
    return at
end

function Partition:MarkSynced(timestamp)
    if type(timestamp) ~= "number" then
        return false
    end
    self.data.lastSync = timestamp
    return true
end
