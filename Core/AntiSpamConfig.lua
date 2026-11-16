local _, addon = ...

-- Guild Greet's anti-spam officer settings: how many arrivals within the
-- trigger window turn anti-spam mode on, and the guild cooldown between
-- greetings while it's on. Officers change them; they're kept per guild as
-- officer settings in Guild Recruit's way (RecruitConfig: { value, at, by },
-- newest change wins, only officers' changes accepted), so they last across
-- reloads. Every add-on user's add-on follows them, so they're shared with
-- all of the guild's add-on users: an "antispam-config" message with every
-- changed setting after each change and in answer to an
-- "ask-antispam-config", which every add-on sends once a session.
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
--   onChange()    called when a setting changed
local AntiSpamConfig = {
    PROTOCOL = 1,
    -- { v, t = TYPE_CONFIG, s = { [setting] = { value, at, by } } }
    TYPE_CONFIG = "antispam-config",
    -- { v, t = TYPE_ASK_CONFIG }: who has the anti-spam settings?
    TYPE_ASK_CONFIG = "ask-antispam-config",
    -- An officer's add-on answers an ask after a random wait in this range,
    -- so one answer usually covers everyone.
    ANSWER_DELAY_MIN = 1,
    ANSWER_DELAY_MAX = 5,
    -- The session's ask goes out ASK_DELAY to ASK_DELAY + ASK_SPREAD seconds
    -- after it's first called, so logins don't all ask at once, and not at
    -- all if an officer's settings were heard by then.
    -- Settings saved last session hold until then.
    ASK_DELAY = 120,
    ASK_SPREAD = 30,
}
addon.AntiSpamConfig = AntiSpamConfig

-- A setting of whole numbers from `min` to `max`.
local function wholeNumber(default, min, max)
    return {
        default = default,
        min = min,
        max = max,
        valid = function(value)
            return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
        end,
    }
end

-- The officer settings: arrivals within the trigger window that turn
-- anti-spam mode on, and the guild cooldown in seconds.
AntiSpamConfig.SETTINGS = {
    threshold = wholeNumber(8, 3, 30),
    cooldownSeconds = wholeNumber(15, 5, 60),
}

-- Every message type, for routing.
AntiSpamConfig.TYPES = {
    [AntiSpamConfig.TYPE_CONFIG] = "OnConfig",
    [AntiSpamConfig.TYPE_ASK_CONFIG] = "OnAskConfig",
}

local Config = {}
Config.__index = Config

function AntiSpamConfig.Create(options)
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
        heard = false,
        answering = false,
    }, Config)
end

local function ask(callback, ...)
    local ok, value = pcall(callback, ...)
    if ok then
        return value
    end
    return nil
end

-- The current guild's settings, or nil outside a guild.
function Config:Config()
    local partition = ask(self.partition)
    if partition == nil then
        return nil
    end
    return addon.RecruitConfig.Create(partition:GetAntiSpamConfig(), {
        settings = AntiSpamConfig.SETTINGS,
        isOfficer = self.isOfficer,
    })
end

-- The setting's value, or its default when nothing usable is saved or
-- outside a guild.
function Config:Get(name)
    local setting = AntiSpamConfig.SETTINGS[name]
    if setting == nil then
        return nil
    end
    local config = self:Config()
    if config == nil then
        return setting.default
    end
    return config:Get(name)
end

-- Arrivals within the trigger window that turn anti-spam mode on.
function Config:Threshold()
    return self:Get("threshold")
end

-- The guild cooldown between greetings in anti-spam mode, in seconds.
function Config:CooldownSeconds()
    return self:Get("cooldownSeconds")
end

function Config:IsOfficer()
    local selfKey = ask(self.selfKey)
    return selfKey ~= nil and ask(self.isOfficer, selfKey) == true
end

-- An officer changes setting `name` to `value`: saved stamped with now and
-- the officer, and the guild's add-on users are told. Returns true, or nil
-- and a reason a player can read.
function Config:Set(name, value)
    local setting = AntiSpamConfig.SETTINGS[name]
    if setting == nil then
        return nil, "there's no such setting"
    end
    if not self:IsOfficer() then
        return nil, "only officers can change it"
    end
    if not setting.valid(value) then
        return nil, "it must be a whole number from " .. setting.min .. " to " .. setting.max
    end
    local config, now = self:Config(), ask(self.now)
    if config == nil or type(now) ~= "number" then
        return nil, "saved data is unavailable"
    end
    if config:Get(name) == value then
        return true
    end
    if config:Set(name, value, now, ask(self.selfKey)) == nil then
        return nil, "saved data is unavailable"
    end
    self:send()
    pcall(self.onChange)
    return true
end

-- Sends every changed setting, if any.
function Config:send()
    local config = self:Config()
    local changes = config and config:Changes() or nil
    if changes ~= nil then
        pcall(self.announce, { v = AntiSpamConfig.PROTOCOL, t = AntiSpamConfig.TYPE_CONFIG, s = changes })
    end
end

-- Asks the officers' add-ons for the newest settings, once a session, a
-- while after it's first called. Every add-on asks, since every greeter
-- follows them, unless an officer's settings arrive first: an answer to
-- anyone's ask holds them all.
function Config:AskOnce()
    if self.asked or self:Config() == nil then
        return false
    end
    self.asked = true
    local function send()
        if not self.heard and self:Config() ~= nil then
            pcall(self.announce, { v = AntiSpamConfig.PROTOCOL, t = AntiSpamConfig.TYPE_ASK_CONFIG })
        end
    end
    local spread = ask(self.random, 0, AntiSpamConfig.ASK_SPREAD)
    if type(spread) ~= "number" or spread < 0 then
        spread = 0
    end
    if ask(self.after, AntiSpamConfig.ASK_DELAY + spread, send) ~= true then
        send()
    end
    return true
end

function Config:fromOthers(sender)
    return type(sender) == "string" and ask(self.isOwn, sender) == false
end

-- An "antispam-config": applied setting by setting, newest wins, when the
-- sender and each change's author are officers. Hearing one that holds
-- everything this add-on knows stops its own answer to an ask. Returns
-- true when anything changed.
function Config:OnConfig(message, sender)
    if type(message) ~= "table" or message.v ~= AntiSpamConfig.PROTOCOL or message.t ~= AntiSpamConfig.TYPE_CONFIG
        or type(message.s) ~= "table" or not self:fromOthers(sender) or ask(self.senderIsOfficer, sender) ~= true
    then
        return false
    end
    local config = self:Config()
    if config == nil then
        return false
    end
    self.heard = true
    if self.answering and config:CoveredBy(message.s) then
        self.answering = false
    end
    local changed = false
    local name
    for name in pairs(AntiSpamConfig.SETTINGS) do
        if config:Apply(name, message.s[name]) then
            changed = true
        end
    end
    if changed then
        pcall(self.onChange)
    end
    return changed
end

-- Another add-on user's "ask-antispam-config": an officer's add-on with
-- changed settings answers after a random short wait, unless an answer
-- holding them all is heard first. Returns true when an answer was
-- scheduled.
function Config:OnAskConfig(message, sender)
    local config = self:Config()
    if type(message) ~= "table" or message.v ~= AntiSpamConfig.PROTOCOL
        or message.t ~= AntiSpamConfig.TYPE_ASK_CONFIG
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
    local delay = ask(self.random, AntiSpamConfig.ANSWER_DELAY_MIN, AntiSpamConfig.ANSWER_DELAY_MAX)
    if type(delay) ~= "number" or delay < 0 then
        delay = AntiSpamConfig.ANSWER_DELAY_MIN
    end
    if ask(self.after, delay, answer) ~= true then
        answer()
    end
    return true
end

-- Hands a received anti-spam settings message to its handler. False for
-- any other.
function Config:OnMessage(message, sender)
    local handler = type(message) == "table" and AntiSpamConfig.TYPES[message.t] or nil
    if handler == nil then
        return false
    end
    return self[handler](self, message, sender)
end
