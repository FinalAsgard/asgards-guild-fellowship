local _, addon = ...

-- "/agf resync <name>": copies an officer's whole view of the roster's
-- structure (main links, aliases, declared mains, Discord, location and
-- bio) over this client's, whatever the stamps held here, for when this
-- client's data went wrong and guild sync's newest-wins rule keeps it so.
--
--   1. The user names a player (a character's name or an alias). One of
--      that player's characters must be online with an officer rank; this
--      add-on whispers it "resync-ask".
--   2. The officer's add-on whispers back "resync-data" with its snapshot
--      (SyncFacts:ResyncSnapshot), answering each guildmate at most once
--      per ANSWER_GAP_SECONDS.
--   3. This add-on applies it (SyncFacts:Overwrite) only when it asked
--      that officer within WAIT_SECONDS, and that character is still an
--      officer.
-- Membership dates, roles and the user's own profile text are left alone.
--
-- Pure: messaging, the roster and the clock are handed in.
--   context()      -> partition, normalizer for the current guild, or nil
--   selfKey()      -> the logged-in character's key, or nil
--   isOfficer(key) -> true for an officer
--   isOwn(key)     -> true for the user's own characters
--   online()       -> { [key] = name } of guildmates online now, names as
--                     the game reports them
--   now()          -> seconds, or nil
--   whisper(message, name) -> true when sent
--   print(text)    a line in the user's own chat frame
--   onApplied(changed)  called after a resync changed the roster
local Resync = {
    PROTOCOL = 1,
    -- { v, t = TYPE_ASK }: send me your roster data.
    TYPE_ASK = "resync-ask",
    -- { v, t = TYPE_DATA, s = snapshot }
    TYPE_DATA = "resync-data",
    -- A whole roster is a long whisper; the asker waits this long for it.
    WAIT_SECONDS = 5 * 60,
    ANSWER_GAP_SECONDS = 60,
}
addon.Resync = Resync

Resync.TYPES = {
    [Resync.TYPE_ASK] = "OnAsk",
    [Resync.TYPE_DATA] = "OnData",
}

local Session = {}
Session.__index = Session

function Resync.Create(options)
    local function option(name, fallback)
        return type(options[name]) == "function" and options[name] or fallback
    end
    local function none()
        return nil
    end
    return setmetatable({
        context = option("context", none),
        selfKey = option("selfKey", none),
        isOfficer = option("isOfficer", function()
            return false
        end),
        isOwn = option("isOwn", function()
            return false
        end),
        online = option("online", function()
            return {}
        end),
        now = option("now", none),
        whisper = option("whisper", function()
            return false
        end),
        print = option("print", function() end),
        onApplied = option("onApplied", function() end),
        -- The officer asked: { key, name, untilAt }.
        pending = nil,
        -- When this officer last answered each guildmate.
        answered = {},
    }, Session)
end

local function ask(callback, ...)
    local ok, value, second = pcall(callback, ...)
    if ok then
        return value, second
    end
    return nil
end

function Session:facts(partition)
    return addon.SyncFacts.Create(partition, {
        isOfficer = function(key)
            return ask(self.isOfficer, key) == true
        end,
        now = function()
            return ask(self.now) or 0
        end,
    })
end

-- The player `name` means: a character's name, else an alias (ignoring
-- case). Returns the player id, or nil.
local function playerNamed(partition, normalizer, name)
    local key = normalizer:Key(name)
    local character = key and partition:GetCharacter(key)
    if character ~= nil then
        return character.player
    end
    local wanted = addon.NameNormalizer.Fold(name)
    local found
    partition:EachPlayer(function(id, player)
        if found == nil and type(player.alias) == "string" and addon.NameNormalizer.Fold(player.alias) == wanted then
            found = id
        end
    end)
    return found
end

-- Asks the officer playing `name` (a character's name or alias) for their
-- roster data. Returns true, or nil, with a line for the user either way.
function Session:Ask(name)
    local partition, normalizer = ask(self.context)
    local now = ask(self.now)
    if partition == nil or normalizer == nil or type(now) ~= "number" then
        return nil, "You need to be in a guild, with its roster loaded, to resync."
    end
    if type(name) ~= "string" or string.find(name, "%S") == nil then
        return nil, "Name an officer to copy roster data from: /agf resync <name>."
    end
    name = string.match(name, "^%s*(.-)%s*$")
    local player = playerNamed(partition, normalizer, name)
    if player == nil then
        return nil, "Nobody in the guild is called " .. name .. "."
    end
    local online = ask(self.online) or {}
    local keys = partition:CharactersOf(player)
    -- The user's own characters are skipped: a roster gone wrong can hold
    -- them in the officer's player.
    local target, anyOnline, ownOnline
    local index
    for index = 1, #keys do
        local key = keys[index]
        if online[key] ~= nil then
            if ask(self.isOwn, key) == true then
                ownOnline = true
            else
                anyOnline = true
                if target == nil and ask(self.isOfficer, key) == true then
                    target = { key = key, name = online[key] }
                end
            end
        end
    end
    if not anyOnline and ownOnline then
        return nil, "That's you: name another officer."
    end
    if not anyOnline then
        return nil, name .. " isn't online. Resync from an officer who is."
    end
    if target == nil then
        return nil, name .. " isn't an officer. Only an officer's roster data can be copied."
    end
    if ask(self.whisper, { v = Resync.PROTOCOL, t = Resync.TYPE_ASK }, target.name) ~= true then
        return nil, "The request to " .. target.name .. " couldn't be sent."
    end
    self.pending = { key = target.key, name = target.name, untilAt = now + Resync.WAIT_SECONDS }
    return true, "Asked " .. target.name .. " for their roster data. A big guild's can take a minute or two "
        .. "to arrive; you'll see a line here when it's applied."
end

-- The sender's key, when they're a current guild member other than the
-- user, or nil.
function Session:senderKey(sender, partition, normalizer)
    local key = type(sender) == "string" and normalizer:Key(sender) or nil
    if key == nil or not partition:IsInGuild(key) or ask(self.isOwn, key) == true then
        return nil
    end
    return key
end

-- A guildmate's "resync-ask": an officer's add-on whispers back its
-- snapshot, once per ANSWER_GAP_SECONDS per guildmate. Returns true when it
-- answered.
function Session:OnAsk(message, sender)
    local partition, normalizer = ask(self.context)
    local selfKey, now = ask(self.selfKey), ask(self.now)
    if type(message) ~= "table" or message.v ~= Resync.PROTOCOL or partition == nil or normalizer == nil
        or selfKey == nil or type(now) ~= "number" or ask(self.isOfficer, selfKey) ~= true
    then
        return false
    end
    local key = self:senderKey(sender, partition, normalizer)
    if key == nil or (self.answered[key] ~= nil and now - self.answered[key] < Resync.ANSWER_GAP_SECONDS) then
        return false
    end
    self.answered[key] = now
    local snapshot = self:facts(partition):ResyncSnapshot()
    if ask(self.whisper, { v = Resync.PROTOCOL, t = Resync.TYPE_DATA, s = snapshot }, sender) ~= true then
        return false
    end
    pcall(self.print, "Sending your roster data to " .. sender .. ", who asked to resync from you.")
    return true
end

-- The officer's "resync-data": applied over this client's roster when it's
-- the answer this add-on is waiting for. Returns how many players changed,
-- or nil when it wasn't applied.
function Session:OnData(message, sender)
    local partition, normalizer = ask(self.context)
    local now = ask(self.now)
    local pending = self.pending
    if type(message) ~= "table" or message.v ~= Resync.PROTOCOL or partition == nil or normalizer == nil
        or type(now) ~= "number" or pending == nil
    then
        return nil
    end
    local key = self:senderKey(sender, partition, normalizer)
    if key ~= pending.key then
        return nil
    end
    self.pending = nil
    if now > pending.untilAt then
        pcall(self.print, "Roster data from " .. sender .. " came too late and wasn't applied. Try again.")
        return nil
    end
    if ask(self.isOfficer, key) ~= true then
        pcall(self.print, sender .. " is no longer an officer, so their roster data wasn't applied.")
        return nil
    end
    local own = {}
    partition:EachCharacter(function(characterKey)
        if ask(self.isOwn, characterKey) == true then
            own[characterKey] = true
        end
    end)
    local facts = self:facts(partition)
    local ok, changed = pcall(facts.Overwrite, facts, message.s, key, own)
    if not ok or changed == nil then
        pcall(self.print, "Roster data from " .. sender .. " couldn't be read; nothing changed.")
        return nil
    end
    pcall(self.onApplied, changed)
    local players = changed == 1 and "1 player" or (changed .. " players")
    pcall(self.print, "Resynced from " .. sender .. ": " .. players .. " changed to match their roster.")
    return changed
end

-- Hands a received resync whisper to its handler. False for any other.
function Session:OnMessage(message, sender)
    local handler = type(message) == "table" and Resync.TYPES[message.t] or nil
    if handler == nil then
        return false
    end
    return self[handler](self, message, sender)
end
