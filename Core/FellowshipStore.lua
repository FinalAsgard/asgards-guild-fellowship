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
    -- The longest recruitment ad: one chat message.
    RECRUIT_AD_MAX = 255,
}
-- Player profile text fields (schema 4), each with its longest value. A
-- character's own: stored on the character that wrote it, as `<field>`,
-- `<field>At` and `<field>By`.
FellowshipStore.PROFILE_FIELDS = { discord = 32, location = 40, bio = 500 }
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

local ROLES = { tank = true, healer = true, dps = true }

-- Whether `roles` is a list of distinct roles ("tank", "healer", "dps");
-- an empty list means none.
function FellowshipStore.IsRoleList(roles)
    if type(roles) ~= "table" or #roles > 3 then
        return false
    end
    local seen = {}
    local index
    for index = 1, #roles do
        if not ROLES[roles[index]] or seen[roles[index]] then
            return false
        end
        seen[roles[index]] = true
    end
    local count = 0
    local _
    for _ in pairs(roles) do
        count = count + 1
    end
    return count == #roles
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
    -- Player profile (schema 3): the roles this character is willing to
    -- play, and when and by whom (always the character itself) they were set.
    if character.roles ~= nil and not FellowshipStore.IsRoleList(character.roles) then
        return "character role preferences are invalid"
    end
    if character.rolesAt ~= nil and not isWholeNumber(character.rolesAt) then
        return "character role preferences time is invalid"
    end
    if character.rolesBy ~= nil and not isText(character.rolesBy) then
        return "character role preferences author is invalid"
    end
    -- Declared main (schema 4): the player deliberately says this character
    -- is its main, and when and by whom that was set (officer data).
    if character.declared ~= nil and type(character.declared) ~= "boolean" then
        return "character declared main is invalid"
    end
    if character.declaredAt ~= nil and not isWholeNumber(character.declaredAt) then
        return "character declared main time is invalid"
    end
    if character.declaredBy ~= nil and not isText(character.declaredBy) then
        return "character declared main author is invalid"
    end
    if character.declaredSource ~= nil and not isText(character.declaredSource) then
        return "character declared main source is invalid"
    end
    -- Player profile text (schema 4): Discord, location and bio, each with
    -- when and by whom it was set. An empty value was cleared.
    local field, longest
    for field, longest in pairs(FellowshipStore.PROFILE_FIELDS) do
        local value = character[field]
        if value ~= nil and (type(value) ~= "string" or #value > longest) then
            return "character " .. field .. " is invalid"
        end
        if character[field .. "At"] ~= nil and not isWholeNumber(character[field .. "At"]) then
            return "character " .. field .. " time is invalid"
        end
        if character[field .. "By"] ~= nil and not isText(character[field .. "By"]) then
            return "character " .. field .. " author is invalid"
        end
    end
    -- An out-of-date note an officer chose to leave alone: the note's
    -- fingerprint and the suggested note at the time (see NoteAudit).
    if character.noteIgnored ~= nil then
        local ignored = character.noteIgnored
        if type(ignored) ~= "table" or not isText(ignored.note) or type(ignored.suggested) ~= "string" then
            return "character ignored note is invalid"
        end
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
        "recruitLedger", "recruitConfig", "recruitStats", "groupHistory", "ownCharacters", "dismissedOwn", "withdrawals",
        "welcomeConfig", "welcomeLedger",
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
    -- An officer's ledger and forgery log, and Guild Recruit's ad times,
    -- are only created when needed.
    local optional = {
        unapplied = true, ledger = true, forgeries = true, recruitLedger = true, recruitConfig = true,
        recruitStats = true, groupHistory = true, ownCharacters = true, dismissedOwn = true, withdrawals = true,
        welcomeConfig = true, welcomeLedger = true,
    }
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

-- The master frame's saved geometry, shared by every guild, or nil when
-- absent or unusable. Until the frame saves its own, the old roster
-- window's saved position is its starting point; that window's size is
-- left behind, so the frame opens at its larger default size.
function Store:GetFrameState()
    if type(self.database) ~= "table" then
        return nil
    end
    local frame = self.database.frame
    if type(frame) == "table" then
        return frame
    end
    local window = self.database.window
    if frame ~= nil or type(window) ~= "table" then
        return nil
    end
    return { point = window.point, relativePoint = window.relativePoint, x = window.x, y = window.y }
end

-- Replaces the master frame's saved geometry. An unusable existing value is
-- left alone.
function Store:SetFrameState(state)
    if type(self.database) ~= "table" or type(state) ~= "table" then
        return false
    end
    if self.database.frame ~= nil and type(self.database.frame) ~= "table" then
        return false
    end
    self.database.frame = state
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

-- The kinds of chat tag whose color can be chosen (see ChatAnnotator).
local CHAT_TAG_KINDS = { alias = true, main = true }

-- Whether `color` is a color as saved: six hex digits, "rrggbb".
function FellowshipStore.IsColor(color)
    return type(color) == "string" and string.find(color, "^%x%x%x%x%x%x$") ~= nil
end

-- The color chosen for a kind of chat tag ("alias" or "main"), shared by
-- every guild, as "rrggbb" in lower case; nil when none was chosen or the
-- saved value is unusable.
function Store:ChatTagColor(kind)
    local colors = type(self.database) == "table" and self.database.chatTagColors or nil
    if type(colors) ~= "table" or not FellowshipStore.IsColor(colors[kind]) then
        return nil
    end
    return string.lower(colors[kind])
end

-- Saves the color for a kind of chat tag. False for an unknown kind or
-- anything that isn't a color; an unusable existing value is left alone.
function Store:SetChatTagColor(kind, color)
    if type(self.database) ~= "table" or not CHAT_TAG_KINDS[kind] or not FellowshipStore.IsColor(color) then
        return false
    end
    local colors = self.database.chatTagColors
    if colors == nil then
        colors = {}
        self.database.chatTagColors = colors
    elseif type(colors) ~= "table" then
        return false
    end
    colors[kind] = string.lower(color)
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

-- Whether Guild Greet prompts inside a dungeon, raid, battleground or arena.
-- On unless turned off; unusable saved data counts as on.
function Store:GreetInInstances()
    local state = type(self.database) == "table" and self.database.greet or nil
    return type(state) ~= "table" or state.inInstances ~= false
end

-- Turns Guild Greet's prompts inside instances on or off. An unusable
-- existing value is left alone.
function Store:SetGreetInInstances(enabled)
    if type(enabled) ~= "boolean" then
        return false
    end
    local state = self:GetGreetState()
    if state == nil or (state.inInstances ~= nil and type(state.inInstances) ~= "boolean") then
        return false
    end
    state.inInstances = enabled
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

-- Whether Guild Greet prompts for `category` (a GreetPolicy category). On
-- unless turned off; an unusable saved value counts as on.
function Store:GreetCategoryEnabled(category)
    local state = type(self.database) == "table" and self.database.greet or nil
    local categories = type(state) == "table" and state.categories or nil
    return type(categories) ~= "table" or categories[category] ~= false
end

-- Turns one category's prompts on or off. An unusable existing value is
-- left alone.
function Store:SetGreetCategoryEnabled(category, enabled)
    if not isText(category) or type(enabled) ~= "boolean" then
        return false
    end
    local state = self:GetGreetState()
    if state == nil then
        return false
    end
    if state.categories == nil then
        state.categories = {}
    end
    local categories = state.categories
    if type(categories) ~= "table" or (categories[category] ~= nil and type(categories[category]) ~= "boolean") then
        return false
    end
    categories[category] = enabled
    return true
end

-- Guild Greet's whole-number settings: the saved field, default and range.
FellowshipStore.GREET_NUMBERS = {
    -- Minutes someone must be gone before coming back is a welcome back.
    welcomeBackMinutes = { default = 15, min = 1, max = 120 },
    -- Days since anyone last saw a player before a login is a long absence.
    longAbsenceDays = { default = 30, min = 1, max = 365 },
}

local function isInRange(value, range)
    return type(value) == "number" and value == math.floor(value) and value >= range.min and value <= range.max
end

-- A Guild Greet number setting (a GREET_NUMBERS name). The default when none
-- is saved or the saved one is unusable.
function Store:GreetNumber(name)
    local range = FellowshipStore.GREET_NUMBERS[name]
    if range == nil then
        return nil
    end
    local state = type(self.database) == "table" and self.database.greet or nil
    local value = type(state) == "table" and state[name] or nil
    if not isInRange(value, range) then
        return range.default
    end
    return value
end

-- Sets a Guild Greet number setting to a whole number within its range. An
-- unusable existing value is left alone.
function Store:SetGreetNumber(name, value)
    local range = FellowshipStore.GREET_NUMBERS[name]
    if range == nil or not isInRange(value, range) then
        return false
    end
    local state = self:GetGreetState()
    if state == nil or (state[name] ~= nil and not isInRange(state[name], range)) then
        return false
    end
    state[name] = value
    return true
end

-- Whether Guild Greet is on for the character `key`. Each character is on
-- unless turned off; the set of characters it's off on is account-wide, and
-- an unusable one counts as empty.
function Store:GreetOnCharacter(key)
    local state = type(self.database) == "table" and self.database.greet or nil
    local off = type(state) == "table" and state.offCharacters or nil
    return type(off) ~= "table" or off[key] ~= true
end

-- Turns Guild Greet on or off for the character `key`. An unusable existing
-- set is left alone.
function Store:SetGreetOnCharacter(key, enabled)
    if not isText(key) or type(enabled) ~= "boolean" then
        return false
    end
    local state = self:GetGreetState()
    if state == nil then
        return false
    end
    if state.offCharacters == nil then
        state.offCharacters = {}
    end
    if type(state.offCharacters) ~= "table" then
        return false
    end
    state.offCharacters[key] = (not enabled) or nil
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

-- Guild Recruit's saved state, shared by every character on the account and
-- created on first use: the user's own ad, and the characters that turned
-- advertise prompts on. Nil when an unusable value is stored there; it is
-- then left alone.
function Store:GetRecruitState()
    if type(self.database) ~= "table" then
        return nil
    end
    if self.database.recruit == nil then
        self.database.recruit = {}
    end
    if type(self.database.recruit) ~= "table" then
        return nil
    end
    return self.database.recruit
end

-- Where the Guild Recruit window sits ({ point, x, y }, measured from that
-- point of the screen), shared by every character. Nil when none is saved
-- or the saved one is unusable, so the window uses its default place.
function Store:RecruitAnchor()
    local state = type(self.database) == "table" and self.database.recruit or nil
    local anchor = type(state) == "table" and state.anchor or nil
    if not isAnchor(anchor) then
        return nil
    end
    return { point = anchor.point, x = anchor.x, y = anchor.y }
end

-- Saves where the Guild Recruit window sits. As with greet prompts, an
-- unusable saved position is replaced: the user just placed the window.
function Store:SetRecruitAnchor(anchor)
    if not isAnchor(anchor) then
        return false
    end
    local state = self:GetRecruitState()
    if state == nil then
        return false
    end
    state.anchor = { point = anchor.point, x = anchor.x, y = anchor.y }
    return true
end

-- Guildmates on the map, on every character: "share" (send the player's
-- location to the guild) and "show" (draw guildmates on the maps and
-- minimap). Both on unless turned off; an unusable stored value counts as
-- on.
local GUILD_MAP_SETTINGS = { share = true, show = true }

function Store:GuildMapEnabled(setting)
    local state = type(self.database) == "table" and self.database.guildMap or nil
    return type(state) ~= "table" or state[setting] ~= false
end

-- Turns a guild map setting on or off. Refuses an unknown setting, and
-- when an unusable value is stored for the guild map.
function Store:SetGuildMapEnabled(setting, enabled)
    if type(self.database) ~= "table" or not GUILD_MAP_SETTINGS[setting] or type(enabled) ~= "boolean" then
        return false
    end
    if self.database.guildMap == nil then
        self.database.guildMap = {}
    end
    if type(self.database.guildMap) ~= "table" then
        return false
    end
    -- Only "off" is stored; on is the default.
    if enabled then
        self.database.guildMap[setting] = nil
    else
        self.database.guildMap[setting] = false
    end
    return true
end

-- Whether Do Not Disturb is on for the Group Finder, on every character.
function Store:GroupFinderDnd()
    local state = type(self.database) == "table" and self.database.groupFinder or nil
    return type(state) == "table" and state.dnd == true
end

-- Turns Do Not Disturb on or off. Refuses when an unusable value is stored
-- for the Group Finder.
function Store:SetGroupFinderDnd(enabled)
    if type(self.database) ~= "table" then
        return false
    end
    if self.database.groupFinder == nil then
        self.database.groupFinder = {}
    end
    if type(self.database.groupFinder) ~= "table" then
        return false
    end
    self.database.groupFinder.dnd = enabled == true or nil
    return true
end

-- The user's own ad, exactly as written. Empty when none is saved or the
-- saved one is unusable.
function Store:RecruitAd()
    local state = type(self.database) == "table" and self.database.recruit or nil
    local ad = type(state) == "table" and state.ad or nil
    if type(ad) ~= "string" or string.len(ad) > FellowshipStore.RECRUIT_AD_MAX then
        return ""
    end
    return ad
end

-- Saves the user's own ad. Refuses text longer than one chat message.
function Store:SetRecruitAd(text)
    if type(text) ~= "string" or string.len(text) > FellowshipStore.RECRUIT_AD_MAX then
        return false
    end
    local state = self:GetRecruitState()
    if state == nil then
        return false
    end
    state.ad = text
    return true
end

-- Guild Mail's saved draft, shared by every character on the account:
--   { subject, body, ranks, mode, skipDiscord, activeOnly }
-- `ranks` is the list of ticked rank indexes, `mode` the Send to choice's
-- id. Each field is nil when missing or unusable. Nil when nothing usable
-- is saved.
function Store:GuildMailDraft()
    local saved = type(self.database) == "table" and self.database.guildMail or nil
    if type(saved) ~= "table" then
        return nil
    end
    local ranks = {}
    if type(saved.ranks) == "table" then
        local index
        for index = 1, #saved.ranks do
            local rank = saved.ranks[index]
            if type(rank) == "number" and rank == math.floor(rank) then
                table.insert(ranks, rank)
            end
        end
    end
    local function text(value)
        return type(value) == "string" and value or nil
    end
    local function flag(value)
        if type(value) == "boolean" then
            return value
        end
        return nil
    end
    return {
        subject = text(saved.subject),
        body = text(saved.body),
        ranks = ranks,
        mode = text(saved.mode),
        skipDiscord = flag(saved.skipDiscord),
        activeOnly = flag(saved.activeOnly),
    }
end

-- Saves Guild Mail's draft (as GuildMailDraft returns it). An unusable
-- existing value is left alone.
function Store:SetGuildMailDraft(draft)
    if type(self.database) ~= "table" or type(draft) ~= "table" then
        return false
    end
    if self.database.guildMail ~= nil and type(self.database.guildMail) ~= "table" then
        return false
    end
    local ranks = {}
    local index
    for index = 1, #(draft.ranks or {}) do
        if type(draft.ranks[index]) == "number" then
            table.insert(ranks, draft.ranks[index])
        end
    end
    self.database.guildMail = {
        subject = type(draft.subject) == "string" and draft.subject or "",
        body = type(draft.body) == "string" and draft.body or "",
        ranks = ranks,
        mode = type(draft.mode) == "string" and draft.mode or nil,
        skipDiscord = draft.skipDiscord == true,
        activeOnly = draft.activeOnly == true,
    }
    return true
end

-- Guild Mail's outbox: the list of sends, oldest first, shared by every
-- character on the account, created on first use. Guild Mail keeps each
-- entry up to date in place (see GuildMail). Nil when an unusable value is
-- stored there; it is then left alone.
function Store:GuildMailOutbox()
    if type(self.database) ~= "table" then
        return nil
    end
    if self.database.guildMailOutbox == nil then
        self.database.guildMailOutbox = {}
    end
    if type(self.database.guildMailOutbox) ~= "table" then
        return nil
    end
    return self.database.guildMailOutbox
end

-- The user's own ad record (see RecruitStats), shared by every character
-- on the account and created on first use. Nil when an unusable value is
-- stored there; it is then left alone.
function Store:RecruitOwnStats()
    local state = self:GetRecruitState()
    if state == nil then
        return nil
    end
    if state.stats == nil then
        state.stats = { n = 0, t = {} }
    end
    if type(state.stats) ~= "table" then
        return nil
    end
    return state.stats
end

-- The user's own timers: how long a zone's General ("general") or Trade
-- ("trade") must go without an ad before the user is asked to post there.
-- The guild's gap is a floor under them (see GuildRecruit).
FellowshipStore.RECRUIT_MY_GAPS = {
    general = { field = "myGeneralGapMinutes", default = 60 },
    trade = { field = "myTradeGapMinutes", default = 60 },
}
FellowshipStore.RECRUIT_MY_GAP_MIN = 5
FellowshipStore.RECRUIT_MY_GAP_MAX = 4 * 60

local function isMyGap(value)
    return type(value) == "number" and value == math.floor(value)
        and value >= FellowshipStore.RECRUIT_MY_GAP_MIN and value <= FellowshipStore.RECRUIT_MY_GAP_MAX
end

-- The user's own timer for `channel` ("general" or "trade"), in minutes,
-- shared by every character on the account. The default when none is saved
-- or the saved one is unusable.
function Store:RecruitMyGap(channel)
    local gap = FellowshipStore.RECRUIT_MY_GAPS[channel]
    if gap == nil then
        return nil
    end
    local state = type(self.database) == "table" and self.database.recruit or nil
    local value = type(state) == "table" and state[gap.field] or nil
    if not isMyGap(value) then
        return gap.default
    end
    return value
end

-- Sets the user's own timer for `channel`, in whole minutes from 5 to 240.
function Store:SetRecruitMyGap(channel, minutes)
    local gap = FellowshipStore.RECRUIT_MY_GAPS[channel]
    if gap == nil or not isMyGap(minutes) then
        return false
    end
    local state = self:GetRecruitState()
    if state == nil then
        return false
    end
    state[gap.field] = minutes
    return true
end

-- Whether the user posts the officers' guild ad too. On unless turned off;
-- an unusable saved value counts as on.
function Store:RecruitUseOfficerAd()
    local state = type(self.database) == "table" and self.database.recruit or nil
    return type(state) ~= "table" or state.useOfficerAd ~= false
end

-- Turns posting the officers' guild ad on or off, for every character on
-- the account.
function Store:SetRecruitUseOfficerAd(enabled)
    if type(enabled) ~= "boolean" then
        return false
    end
    local state = self:GetRecruitState()
    if state == nil then
        return false
    end
    state.useOfficerAd = enabled
    return true
end

-- The zones the user turned off with Off here, shared by every character on
-- the account: zone key -> { name, at } (when it was turned off). Unusable
-- entries are left out.
function Store:RecruitOffZones()
    local state = type(self.database) == "table" and self.database.recruit or nil
    local saved = type(state) == "table" and state.offZones or nil
    local zones = {}
    if type(saved) ~= "table" then
        return zones
    end
    local key, entry
    for key, entry in pairs(saved) do
        if isText(key) and type(entry) == "table" and isText(entry.n) and isWholeNumber(entry.a) then
            zones[key] = { name = entry.n, at = entry.a }
        end
    end
    return zones
end

-- Turns prompts in the zone `key` (named `name`) off from `at`, until
-- turned back on.
function Store:SetRecruitOffZone(key, name, at)
    if not isText(key) or not isText(name) or not isWholeNumber(at) then
        return false
    end
    local state = self:GetRecruitState()
    if state == nil then
        return false
    end
    if type(state.offZones) ~= "table" then
        state.offZones = {}
    end
    state.offZones[key] = { n = name, a = at }
    return true
end

-- Turns prompts in the zone `key` back on.
function Store:ClearRecruitOffZone(key)
    local state = type(self.database) == "table" and self.database.recruit or nil
    if type(state) ~= "table" or type(state.offZones) ~= "table" then
        return false
    end
    state.offZones[key] = nil
    return true
end

-- The character `key`'s answer to "Help with guild recruitment?": true
-- (Yes), false (No), or nil while undecided. An unusable saved set, or an
-- unusable answer in it, counts as undecided.
function Store:RecruitOptIn(key)
    local state = type(self.database) == "table" and self.database.recruit or nil
    local optIn = type(state) == "table" and state.optIn or nil
    if type(optIn) ~= "table" then
        return nil
    end
    local answer = optIn[key]
    if type(answer) ~= "boolean" then
        return nil
    end
    return answer
end

-- True only when the character `key` answered Yes; only that allows
-- advertise prompts.
function Store:RecruitOptedIn(key)
    return self:RecruitOptIn(key) == true
end

-- Saves the character `key`'s answer: true or false, or nil to make it
-- undecided again. Each character's answer is its own. An unusable
-- existing set is left alone.
function Store:SetRecruitOptIn(key, answer)
    if not isText(key) or (answer ~= nil and type(answer) ~= "boolean") then
        return false
    end
    local state = self:GetRecruitState()
    if state == nil then
        return false
    end
    if state.optIn == nil then
        if answer == nil then
            return true
        end
        state.optIn = {}
    end
    if type(state.optIn) ~= "table" then
        return false
    end
    state.optIn[key] = answer
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

-- Leaves an out-of-date note alone while the note (its fingerprint) and the
-- suggested note both stay as they are now.
function Partition:IgnoreNote(key, fingerprint, suggested)
    local character = self.data.characters[key]
    if character == nil or not isText(fingerprint) or type(suggested) ~= "string" then
        return false
    end
    character.noteIgnored = { note = fingerprint, suggested = suggested }
    return true
end

-- The note fingerprint and suggested note an officer ignored for `key`, or
-- nil.
function Partition:GetIgnoredNote(key)
    local character = self.data.characters[key]
    local ignored = character and character.noteIgnored
    if ignored == nil then
        return nil
    end
    return ignored.note, ignored.suggested
end

-- After `key` has moved out of `oldPlayer`: removes the old player if it is
-- now empty, or hands its main role to the highest-level character left
-- (ties by name). Acting-main rules (in-guild first) are applied on top by
-- ReconcileEngine.EnsureActingMains.
function Partition:LeftPlayer(oldPlayer, key)
    local remaining = self:CharactersOf(oldPlayer)
    if remaining[1] == nil then
        local alias = self.data.players[oldPlayer].alias
        self.data.players[oldPlayer] = nil
        self:AliasesChanged(alias, nil)
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

-- Kinds of note conflict a new, changed, or cleared alias may settle.
local ALIAS_RETRY_KINDS = { unresolved = true, ambiguous = true }

-- After the partition's set of aliases changed from `old` to `new` (either
-- may be nil): notes with a pending unresolved or ambiguous conflict are
-- marked unread, so the next scan reads them against the new aliases.
function Partition:AliasesChanged(old, new)
    if isText(old) and isText(new) and string.lower(old) == string.lower(new) then
        return
    end
    if not isText(old) and not isText(new) then
        return
    end
    local conflicts = self.data.conflicts
    if type(conflicts) ~= "table" then
        return
    end
    local index
    for index = 1, #conflicts do
        local entry = conflicts[index]
        if type(entry) == "table" and entry.from == nil and ALIAS_RETRY_KINDS[entry.kind] then
            self:ForgetNoteFingerprint(entry.character)
        end
    end
end

function Partition:ClearAlias(playerId, source)
    local player = self.data.players[playerId]
    if player == nil then
        return false
    end
    local old = player.alias
    player.alias = nil
    player.aliasSource = source
    self:AliasesChanged(old, nil)
    return true
end

function Partition:SetAlias(playerId, alias, source)
    local player = self.data.players[playerId]
    if player == nil or not isText(alias) then
        return false
    end
    local old = player.alias
    player.alias = alias
    player.aliasSource = source
    self:AliasesChanged(old, alias)
    return true
end

-- Ids of the players whose alias is `alias`, ignoring case, in id order.
function Partition:PlayersWithAlias(alias)
    local ids = {}
    if not isText(alias) then
        return ids
    end
    local folded = string.lower(alias)
    local id, player
    for id, player in pairs(self.data.players) do
        if isText(player.alias) and string.lower(player.alias) == folded then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    return ids
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
-- accepted. An "ambiguous" conflict from an alias held by several players
-- also has `alias` and `mains` (the main of each of those players). Never
-- the note text. A member's suggestion queued for an
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

-- A member's withdrawn suggestions (SuggestionService), kept to tell
-- officers who log in later.
function Partition:GetWithdrawals()
    return self.data.withdrawals or {}
end

function Partition:SetWithdrawals(entries)
    if type(entries) ~= "table" then
        return false
    end
    self.data.withdrawals = entries
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

-- The most group history entries kept; the oldest go first.
FellowshipStore.GROUP_HISTORY_MAX = 1000

local function isHistoryEntry(entry)
    if type(entry) ~= "table" or not isWholeNumber(entry.at) or type(entry.characters) ~= "table"
        or (entry.dungeon ~= nil and not isText(entry.dungeon))
    then
        return false
    end
    local index
    for index = 1, #entry.characters do
        if not isText(entry.characters[index]) then
            return false
        end
    end
    return true
end

-- Own characters on this install (schema 4): every character this game
-- install has logged in on in this guild, with when it last did, and the
-- ones the player dismissed as suggestions. Local only, never synced.

-- Records that character `key` logged in at `at`.
function Partition:RecordOwnCharacter(key, at)
    if not isText(key) or not isWholeNumber(at) then
        return false
    end
    self.data.ownCharacters = self.data.ownCharacters or {}
    self.data.ownCharacters[key] = at
    return true
end

-- The keys of the characters this install has logged in on, sorted.
-- Unreadable entries are skipped.
function Partition:OwnCharacters()
    local keys = {}
    local key, at
    for key, at in pairs(self.data.ownCharacters or {}) do
        if isText(key) and isWholeNumber(at) then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    return keys
end

-- Stops offering character `key` as one of the player's own, for good.
function Partition:DismissOwnCharacter(key)
    if not isText(key) then
        return false
    end
    self.data.dismissedOwn = self.data.dismissedOwn or {}
    self.data.dismissedOwn[key] = true
    return true
end

function Partition:IsOwnCharacterDismissed(key)
    return self.data.dismissedOwn ~= nil and self.data.dismissedOwn[key] == true
end

-- The parties this player was in with guildmates (GroupHistory), oldest
-- first: local only, never synced. Unreadable entries are skipped.
function Partition:GetGroupHistory()
    local stored = self.data.groupHistory or {}
    local entries = {}
    local index
    for index = 1, #stored do
        if isHistoryEntry(stored[index]) then
            table.insert(entries, stored[index])
        end
    end
    return entries
end

-- Adds a group history entry, dropping the oldest past GROUP_HISTORY_MAX.
function Partition:AddGroupHistory(entry)
    if not isHistoryEntry(entry) then
        return false
    end
    if self.data.groupHistory == nil then
        self.data.groupHistory = {}
    end
    table.insert(self.data.groupHistory, entry)
    while #self.data.groupHistory > FellowshipStore.GROUP_HISTORY_MAX do
        table.remove(self.data.groupHistory, 1)
    end
    return true
end

-- Guild Recruit's ad counts heard from other add-on users, by character
-- (see RecruitStats), created on first use.
function Partition:GetRecruitStats()
    if self.data.recruitStats == nil then
        self.data.recruitStats = {}
    end
    return self.data.recruitStats
end

-- Guild Recruit's officer settings (see RecruitConfig), created on first
-- use.
function Partition:GetRecruitConfig()
    if self.data.recruitConfig == nil then
        self.data.recruitConfig = {}
    end
    return self.data.recruitConfig
end

-- Guild Mail's welcome mail settings (see GuildWelcome), kept as officer
-- settings like Guild Recruit's, created on first use.
function Partition:GetWelcomeConfig()
    if self.data.welcomeConfig == nil then
        self.data.welcomeConfig = {}
    end
    return self.data.welcomeConfig
end

-- Guild Mail's welcome ledger (see GuildWelcome): { seen = { [key] = when
-- first seen }, welcomed = { [key] = { main, at, by } }, gone = { [key] =
-- true for a noted newcomer who left } }, created on first use, with any
-- list made when missing or unusable.
function Partition:GetWelcomeLedger()
    if type(self.data.welcomeLedger) ~= "table" then
        self.data.welcomeLedger = {}
    end
    local ledger = self.data.welcomeLedger
    if type(ledger.seen) ~= "table" then
        ledger.seen = {}
    end
    if type(ledger.welcomed) ~= "table" then
        ledger.welcomed = {}
    end
    if type(ledger.gone) ~= "table" then
        ledger.gone = {}
    end
    return ledger
end

-- Guild Recruit's last ad time in each channel (see RecruitLedger), created
-- on first use.
function Partition:GetRecruitLedger()
    if self.data.recruitLedger == nil then
        self.data.recruitLedger = {}
    end
    return self.data.recruitLedger
end

-- Who posted the ad behind each ledger time, by channel key, as { a = the
-- ad's time, k = the poster's character key, n = their name as the game
-- gave it }, created on first use. Nil when an unusable value is stored
-- there; it is then left alone.
function Partition:GetRecruitPosters()
    if self.data.recruitPosters == nil then
        self.data.recruitPosters = {}
    end
    if type(self.data.recruitPosters) ~= "table" then
        return nil
    end
    return self.data.recruitPosters
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

-- Declared main: whether `key` is declared its player's main (a player
-- saying "this is really my main", even with no alts). Only a player's main
-- counts as declared.
function Partition:IsDeclared(key)
    local character = self.data.characters[key]
    return character ~= nil and character.declared == true
end

-- Sets whether `key` is declared a main, and where that came from (a
-- FellowshipStore source: by hand, from a note, or through sync), leaving
-- its stamp alone.
function Partition:SetDeclared(key, declared, source)
    local character = self.data.characters[key]
    if character == nil or type(declared) ~= "boolean" or (source ~= nil and not isText(source)) then
        return false
    end
    character.declared = declared or nil
    character.declaredSource = source
    return true
end

-- Whether a note may still decide `key`'s declaration: nobody declared it,
-- or took that back, by hand or through sync.
function Partition:DeclaredUntouched(key)
    local character = self.data.characters[key]
    if character == nil then
        return false
    end
    local source = character.declaredSource
    return (character.declaredAt or 0) == 0
        and source ~= FellowshipStore.SOURCE_MANUAL and source ~= FellowshipStore.SOURCE_SYNC
end

-- When `key`'s declared main was last set or cleared, and by whom; like main
-- links, never set is at 0 with no author.
function Partition:GetDeclaredStamp(key)
    local character = self.data.characters[key]
    if character == nil then
        return nil
    end
    return character.declaredAt or 0, character.declaredBy
end

function Partition:SetDeclaredStamp(key, at, by)
    local character = self.data.characters[key]
    if character == nil or not isWholeNumber(at) or not isText(by) then
        return false
    end
    character.declaredAt = at
    character.declaredBy = by
    return true
end

function Partition:ClearDeclaredStamp(key)
    local character = self.data.characters[key]
    if character ~= nil then
        character.declaredAt = nil
        character.declaredBy = nil
    end
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

-- The roles `key` is willing to play, as a new list, or nil when never set
-- (the class's roles then apply).
function Partition:GetRoles(key)
    local character = self.data.characters[key]
    if character == nil or character.roles == nil then
        return nil
    end
    local copy = {}
    local index
    for index = 1, #character.roles do
        copy[index] = character.roles[index]
    end
    return copy
end

-- When `key`'s role preferences were last set, and by whom; never set is
-- the oldest possible, at 0 with no author. Nil for an unknown character.
function Partition:GetRolesStamp(key)
    local character = self.data.characters[key]
    if character == nil then
        return nil
    end
    return character.rolesAt or 0, character.rolesBy
end

-- Sets `key`'s role preferences, stamped `at` by `by`.
function Partition:SetRoles(key, roles, at, by)
    local character = self.data.characters[key]
    if character == nil or not FellowshipStore.IsRoleList(roles) or not isWholeNumber(at) or not isText(by) then
        return false
    end
    local copy = {}
    local index
    for index = 1, #roles do
        copy[index] = roles[index]
    end
    character.roles = copy
    character.rolesAt = at
    character.rolesBy = by
    return true
end

-- Whether `text` can be a value of profile field `field`: text no longer
-- than the field allows ("" clears it).
function FellowshipStore.IsProfileText(field, text)
    local longest = FellowshipStore.PROFILE_FIELDS[field]
    return longest ~= nil and type(text) == "string" and #text <= longest
end

-- `key`'s own value of profile field `field` ("discord", "location" or
-- "bio"): text, "" when it was cleared, or nil when never set.
function Partition:GetProfileText(key, field)
    local character = self.data.characters[key]
    if character == nil or FellowshipStore.PROFILE_FIELDS[field] == nil then
        return nil
    end
    return character[field]
end

-- When `key` last set profile field `field`, and by whom; never set is the
-- oldest possible, at 0 with no author. Nil for an unknown character.
function Partition:GetProfileStamp(key, field)
    local character = self.data.characters[key]
    if character == nil or FellowshipStore.PROFILE_FIELDS[field] == nil then
        return nil
    end
    return character[field .. "At"] or 0, character[field .. "By"]
end

-- Sets `key`'s profile field `field` to `text` ("" clears it), stamped `at`
-- by `by`.
function Partition:SetProfileText(key, field, text, at, by)
    local character = self.data.characters[key]
    if character == nil or not FellowshipStore.IsProfileText(field, text) or not isWholeNumber(at)
        or not isText(by)
    then
        return false
    end
    character[field] = text
    character[field .. "At"] = at
    character[field .. "By"] = by
    return true
end

-- The player's value of profile field `field`: the newest any of its
-- characters set, or nil when none set one or the newest cleared it. Also
-- returns that value's stamp (at, by), or 0 when none was ever set.
function Partition:PlayerProfileText(playerId, field)
    local keys = self:CharactersOf(playerId)
    local value, newestAt, newestBy = nil, 0, nil
    local index
    for index = 1, #keys do
        local at, by = self:GetProfileStamp(keys[index], field)
        if at ~= nil and at > 0 and (newestBy == nil or at > newestAt or (at == newestAt and by > newestBy)) then
            value, newestAt, newestBy = self:GetProfileText(keys[index], field), at, by
        end
    end
    if value == "" then
        value = nil
    end
    return value, newestAt, newestBy
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
