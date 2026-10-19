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
-- Pure: the saved data, the clock and messaging are handed in.
--   partition()   -> the current guild's partition, or nil
--   selfKey()     -> the logged-in character's key, or nil
--   isOfficer(key) -> true when that character is an officer
--   senderIsOfficer(sender) -> true when a message's sender is an officer
--   isOwn(sender) -> true when a message came from this add-on
--   now()         -> wall-clock seconds, or nil
--   announce(message) -> sends a message to the guild's add-on users
--   random(low, high), after(seconds, callback)   for answering an ask
--   onChange()    called when the welcome mail changed
local GuildWelcome = {
    PROTOCOL = 1,
    -- { v, t = TYPE_CONFIG, s = { [setting] = { value, at, by } } }
    TYPE_CONFIG = "welcome-config",
    -- { v, t = TYPE_ASK_CONFIG }: who has the welcome mail?
    TYPE_ASK_CONFIG = "ask-welcome-config",
    -- An officer's add-on answers an ask after a random wait in this range,
    -- so one answer usually covers everyone.
    ANSWER_DELAY_MIN = 1,
    ANSWER_DELAY_MAX = 5,
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
