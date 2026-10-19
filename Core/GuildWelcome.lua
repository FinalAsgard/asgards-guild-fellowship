local _, addon = ...

-- Guild Mail's welcome mail: one guild setting, a subject and a message
-- (with Guild Mail's placeholders) and an on/off switch that starts off.
-- Officers change it; it's kept per guild as officer settings in Guild
-- Recruit's way (RecruitConfig: { value, at, by }, newest change wins, only
-- officers' changes accepted), so it lasts across reloads, and it's shared
-- with the guild's other add-on users the same way: a "welcome-config"
-- message with every changed setting after each change and in answer to an
-- "ask-welcome-config". When the switch was last turned on is kept: only
-- characters first seen after it get the welcome.
--
-- Newcomers: a character this add-on first sees in the guild while welcome
-- mail is on (the "has joined the guild" message, or new in a roster scan)
-- is noted with when it was seen; one it already knew (a rejoiner), or any
-- from the first scan of a guild, isn't. A noted character is due
-- DUE_SECONDS later, so an alt has time to be linked. When due it's
-- skipped for good if its player has a character that was in the guild
-- before it, or that has been welcomed. Each player is welcomed once: of a
-- new player's noted characters, only their main is due (else the first
-- seen). A noted character that leaves is dropped. Welcomes are recorded
-- (MarkWelcomed) with the player's main, when, and by whom, and kept.
--
-- Pure: the saved data, the clock and messaging are handed in.
--   partition()   -> the current guild's partition, or nil
--   keyOf(rawName) -> a character key for a name from a game message
--   selfKey()     -> the logged-in character's key, or nil
--   isOfficer(key) -> true when that character is an officer
--   senderIsOfficer(sender) -> true when a message's sender is an officer
--   isOwn(sender) -> true when a message came from this add-on
--   now()         -> wall-clock seconds, or nil
--   announce(message) -> sends a message to the guild's add-on users
--   random(low, high), after(seconds, callback)   for answering an ask
--   onChange()    called when the welcome mail changed
--   onWelcomed(key, main)  called when another officer welcomed `key`
--                 (their player's main `main`)
local GuildWelcome = {
    PROTOCOL = 1,
    -- { v, t = TYPE_CONFIG, s = { [setting] = { value, at, by } } }
    TYPE_CONFIG = "welcome-config",
    -- { v, t = TYPE_ASK_CONFIG }: who has the welcome mail?
    TYPE_ASK_CONFIG = "ask-welcome-config",
    -- { v, t = TYPE_WELCOMED, c = the welcomed character's key, m = their
    -- player's main's key, a = when (wall-clock seconds) }: the sender
    -- welcomed them, so nobody else does.
    TYPE_WELCOMED = "welcomed",
    -- An officer's add-on answers an ask after a random wait in this range,
    -- so one answer usually covers everyone.
    ANSWER_DELAY_MIN = 1,
    ANSWER_DELAY_MAX = 5,
    -- How long after first being seen a newcomer is due a welcome.
    DUE_SECONDS = 24 * 60 * 60,
}
addon.GuildWelcome = GuildWelcome

local function textUpTo(letters)
    return function(value)
        return type(value) == "string" and addon.GuildMailComposer.Letters(value) <= letters
    end
end

-- The welcome mail's officer settings.
GuildWelcome.SETTINGS = {
    subject = { default = "", valid = textUpTo(addon.GuildMailComposer.SUBJECT_LETTERS) },
    body = { default = "", valid = textUpTo(addon.GuildMailComposer.BODY_LETTERS) },
    on = {
        default = false,
        valid = function(value)
            return type(value) == "boolean"
        end,
    },
}

-- Every message type, for routing.
GuildWelcome.TYPES = {
    [GuildWelcome.TYPE_CONFIG] = "OnConfig",
    [GuildWelcome.TYPE_ASK_CONFIG] = "OnAskConfig",
    [GuildWelcome.TYPE_WELCOMED] = "OnWelcomed",
}

local Welcome = {}
Welcome.__index = Welcome

function GuildWelcome.Create(options)
    options = options or {}
    local function option(name, fallback)
        return type(options[name]) == "function" and options[name] or fallback
    end
    local function none()
        return nil
    end
    return setmetatable({
        partition = option("partition", none),
        keyOf = option("keyOf", none),
        selfKey = option("selfKey", none),
        isOfficer = option("isOfficer", function()
            return false
        end),
        senderIsOfficer = option("senderIsOfficer", function()
            return false
        end),
        isOwn = option("isOwn", function()
            return true
        end),
        now = option("now", none),
        announce = option("announce", function()
            return false
        end),
        random = option("random", function(low)
            return low
        end),
        after = option("after", function()
            return false
        end),
        onChange = option("onChange", function() end),
        onWelcomed = option("onWelcomed", function() end),
        asked = false,
        answering = false,
    }, Welcome)
end

-- The current guild's settings, or nil outside a guild.
function Welcome:Config()
    local ok, partition = pcall(self.partition)
    if not ok or partition == nil then
        return nil
    end
    return addon.RecruitConfig.Create(partition:GetWelcomeConfig(), {
        settings = GuildWelcome.SETTINGS,
        isOfficer = self.isOfficer,
    })
end

local function ask(callback, ...)
    local ok, value = pcall(callback, ...)
    if ok then
        return value
    end
    return nil
end

function Welcome:get(name)
    local config = self:Config()
    if config == nil then
        return GuildWelcome.SETTINGS[name].default
    end
    return config:Get(name)
end

function Welcome:Subject()
    return self:get("subject")
end

function Welcome:Body()
    return self:get("body")
end

function Welcome:IsOn()
    return self:get("on") == true
end

-- When welcome mail was last switched on (wall-clock seconds), or nil while
-- it's off.
function Welcome:OnSince()
    local config = self:Config()
    local entry = config and config:entry("on") or nil
    if entry == nil or entry.value ~= true then
        return nil
    end
    return entry.at
end

function Welcome:IsOfficer()
    local selfKey = ask(self.selfKey)
    return selfKey ~= nil and ask(self.isOfficer, selfKey) == true
end

-- An officer changes the welcome mail: `changes` holds any of subject,
-- body and on. Each changed one is saved stamped with now and the officer,
-- and the guild's add-on users are told. Returns true, or nil and a reason
-- a player can read.
function Welcome:Set(changes)
    local selfKey, now = ask(self.selfKey), ask(self.now)
    if not self:IsOfficer() then
        return nil, "only officers can change it"
    end
    local config = self:Config()
    if config == nil or type(now) ~= "number" then
        return nil, "saved data is unavailable"
    end
    local name
    for name in pairs(changes or {}) do
        if GuildWelcome.SETTINGS[name] == nil or not GuildWelcome.SETTINGS[name].valid(changes[name]) then
            return nil, "it can't be set to that"
        end
    end
    local changed = false
    for name in pairs(changes or {}) do
        if config:Get(name) ~= changes[name] then
            config:Set(name, changes[name], now, selfKey)
            changed = true
        end
    end
    if changed then
        self:send()
        pcall(self.onChange)
    end
    return true
end

-- Sends every changed setting, if any.
function Welcome:send()
    local config = self:Config()
    local changes = config and config:Changes() or nil
    if changes ~= nil then
        pcall(self.announce, { v = GuildWelcome.PROTOCOL, t = GuildWelcome.TYPE_CONFIG, s = changes })
    end
end

-- Asks the officers' add-ons for the newest welcome mail, once a session,
-- when the user is an officer.
function Welcome:AskOnce()
    if self.asked or not self:IsOfficer() or self:Config() == nil then
        return false
    end
    self.asked = true
    pcall(self.announce, { v = GuildWelcome.PROTOCOL, t = GuildWelcome.TYPE_ASK_CONFIG })
    return true
end

function Welcome:fromOthers(sender)
    return type(sender) == "string" and ask(self.isOwn, sender) == false
end

-- A "welcome-config": applied setting by setting, newest wins, when the
-- sender and each change's author are officers. Hearing one that holds
-- everything this add-on knows stops its own answer to an ask. Returns
-- true when anything changed.
function Welcome:OnConfig(message, sender)
    if type(message) ~= "table" or message.v ~= GuildWelcome.PROTOCOL or message.t ~= GuildWelcome.TYPE_CONFIG
        or type(message.s) ~= "table" or not self:fromOthers(sender) or ask(self.senderIsOfficer, sender) ~= true
    then
        return false
    end
    local config = self:Config()
    if config == nil then
        return false
    end
    if self.answering and config:CoveredBy(message.s) then
        self.answering = false
    end
    local changed = false
    local name
    for name in pairs(GuildWelcome.SETTINGS) do
        if config:Apply(name, message.s[name]) then
            changed = true
        end
    end
    if changed then
        pcall(self.onChange)
    end
    return changed
end

-- Another add-on user's "ask-welcome-config": an officer's add-on with
-- settings answers after a random short wait, unless an answer holding
-- them all is heard first. Returns true when an answer was scheduled.
function Welcome:OnAskConfig(message, sender)
    local config = self:Config()
    if type(message) ~= "table" or message.v ~= GuildWelcome.PROTOCOL or message.t ~= GuildWelcome.TYPE_ASK_CONFIG
        or not self:fromOthers(sender) or self.answering or not self:IsOfficer()
        or config == nil or config:Changes() == nil
    then
        return false
    end
    self.answering = true
    local function answer()
        if self.answering then
            self.answering = false
            self:send()
        end
    end
    local delay = ask(self.random, GuildWelcome.ANSWER_DELAY_MIN, GuildWelcome.ANSWER_DELAY_MAX)
    if type(delay) ~= "number" or delay < 0 then
        delay = GuildWelcome.ANSWER_DELAY_MIN
    end
    if ask(self.after, delay, answer) ~= true then
        answer()
    end
    return true
end

-- Hands a received welcome message to its handler. False for any other.
function Welcome:OnMessage(message, sender)
    local handler = type(message) == "table" and GuildWelcome.TYPES[message.t] or nil
    if handler == nil then
        return false
    end
    return self[handler](self, message, sender)
end

-- The welcome ledger, or nil outside a guild.
function Welcome:ledger()
    local partition = ask(self.partition)
    if partition == nil then
        return nil, nil
    end
    return partition:GetWelcomeLedger(), partition
end

-- Notes `key` as first seen now, when welcome mail is on and it's new to
-- the ledger. Returns true when noted.
function Welcome:note(key, ledger)
    local now = ask(self.now)
    local since = self:OnSince()
    if type(key) ~= "string" or type(now) ~= "number" or since == nil or now < since
        or ledger.seen[key] ~= nil or ledger.welcomed[key] ~= nil
    then
        return false
    end
    ledger.seen[key] = now
    return true
end

-- The game said `rawName` joined the guild. A character this add-on already
-- knew is rejoining and isn't new.
function Welcome:OnJoined(rawName)
    local ledger, partition = self:ledger()
    local key = ask(self.keyOf, rawName)
    if ledger == nil or key == nil or partition:GetCharacter(key) ~= nil then
        return false
    end
    return self:note(key, ledger)
end

-- A roster scan found `keys`, characters new to this add-on. A scan that
-- found every character it knows is the guild's first, so nobody in it is
-- new to the guild. Returns how many were noted.
function Welcome:OnScan(keys)
    local ledger, partition = self:ledger()
    if ledger == nil or type(keys) ~= "table" or #keys == 0 then
        return 0
    end
    local known = 0
    partition:EachCharacter(function()
        known = known + 1
    end)
    if known <= #keys then
        return 0
    end
    local noted = 0
    local index
    for index = 1, #keys do
        if self:note(keys[index], ledger) then
            noted = noted + 1
        end
    end
    return noted
end

-- The main of `key`'s player (`key` itself without one).
local function mainOf(partition, key)
    local character = partition:GetCharacter(key)
    local player = character and partition:GetPlayer(character.player)
    return player and player.main or key
end

-- The noted characters due a welcome at `now`, oldest first: each a
-- character key. Ones skipped for good, or gone, are dropped from the
-- ledger.
function Welcome:Due(now)
    local ledger, partition = self:ledger()
    if ledger == nil or type(now) ~= "number" then
        return {}
    end
    -- Noted characters by player, dropping any that left. One the roster
    -- hasn't shown yet (heard joining, not yet scanned) waits.
    local players = {}
    local key, at
    for key, at in pairs(ledger.seen) do
        local character = partition:GetCharacter(key)
        if type(at) ~= "number" or (character ~= nil and character.departed ~= nil) then
            ledger.seen[key] = nil
            -- Remembered, so a new player's alt leaving never makes the
            -- player someone who was here before.
            ledger.gone[key] = true
        elseif character ~= nil then
            local player = character.player
            players[player] = players[player] or {}
            table.insert(players[player], key)
        end
    end
    local due = {}
    local player, keys
    for player, keys in pairs(players) do
        -- Anyone of the player's who isn't a noted newcomer was in the guild
        -- first, even if they've left since, or was welcomed: the whole
        -- player is skipped for good.
        local settled = false
        local members = partition:CharactersOf(player)
        local index
        for index = 1, #members do
            local member = members[index]
            if ledger.welcomed[member] ~= nil or (ledger.seen[member] == nil and not ledger.gone[member]) then
                settled = true
            end
        end
        if settled then
            for index = 1, #keys do
                ledger.seen[keys[index]] = nil
            end
        else
            -- The main when it's a noted newcomer, else the first seen.
            local record = partition:GetPlayer(player)
            local main = record and record.main or nil
            local target = main ~= nil and ledger.seen[main] ~= nil and main or nil
            if target == nil then
                table.sort(keys, function(a, b)
                    if ledger.seen[a] ~= ledger.seen[b] then
                        return ledger.seen[a] < ledger.seen[b]
                    end
                    return a < b
                end)
                target = keys[1]
            end
            if ledger.seen[target] + GuildWelcome.DUE_SECONDS <= now then
                table.insert(due, target)
            end
        end
    end
    table.sort(due, function(a, b)
        if ledger.seen[a] ~= ledger.seen[b] then
            return ledger.seen[a] < ledger.seen[b]
        end
        return a < b
    end)
    return due
end

-- Records that `key` was welcomed at `at` by `by` (a character key): it and
-- every other character of its player are done.
function Welcome:MarkWelcomed(key, at, by)
    local ledger, partition = self:ledger()
    if ledger == nil or type(key) ~= "string" or type(at) ~= "number" then
        return false
    end
    ledger.welcomed[key] = { main = mainOf(partition, key), at = at, by = by }
    ledger.seen[key] = nil
    return true
end

function Welcome:IsWelcomed(key)
    local ledger = self:ledger()
    return ledger ~= nil and ledger.welcomed[key] ~= nil
end

-- This add-on welcomed `key` at `at`: recorded, and the guild's add-on
-- users are told so they don't welcome them too.
function Welcome:Welcomed(key, at)
    if not self:MarkWelcomed(key, at, ask(self.selfKey)) then
        return false
    end
    local ledger = self:ledger()
    pcall(self.announce, {
        v = GuildWelcome.PROTOCOL, t = GuildWelcome.TYPE_WELCOMED, c = key, m = ledger.welcomed[key].main, a = at,
    })
    return true
end

-- Another officer's "welcomed": recorded, and Guild Mail drops them (and
-- their player) from its own Welcome mails. Ignored from a non-officer.
-- Returns true when recorded.
function Welcome:OnWelcomed(message, sender)
    if type(message) ~= "table" or message.v ~= GuildWelcome.PROTOCOL or message.t ~= GuildWelcome.TYPE_WELCOMED
        or type(message.c) ~= "string" or message.c == "" or type(message.a) ~= "number"
        or not self:fromOthers(sender) or ask(self.senderIsOfficer, sender) ~= true
    then
        return false
    end
    if not self:MarkWelcomed(message.c, message.a, ask(self.keyOf, sender)) then
        return false
    end
    local main = type(message.m) == "string" and message.m or nil
    pcall(self.onWelcomed, message.c, main)
    return true
end

-- Forgets the newcomer `key` (their welcome was cancelled): not due again.
function Welcome:Forget(key)
    local ledger = self:ledger()
    if ledger == nil or type(key) ~= "string" then
        return false
    end
    ledger.seen[key] = nil
    return true
end
