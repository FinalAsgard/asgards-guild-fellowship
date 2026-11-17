local _, addon = ...

-- Guild Greet's Slow mode officer setting: the minutes each greeter waits
-- after a greeting before getting greet prompts again, 0 for off. Officers
-- change it; it's kept per guild as an officer setting in Guild Recruit's
-- way (RecruitConfig: { value, at, by }, newest change wins, only officers'
-- changes accepted), so it lasts across reloads. Every add-on user's add-on
-- follows it, so it's shared with all of the guild's add-on users: a
-- "slowmode-config" message after each change and in answer to an
-- "ask-slowmode-config", which every add-on sends once a session. Older
-- add-ons ignore both types.
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
--   onChange()    called when the setting changed
local SlowModeConfig = {
    PROTOCOL = 1,
    -- { v, t = TYPE_CONFIG, s = { [setting] = { value, at, by } } }
    TYPE_CONFIG = "slowmode-config",
    -- { v, t = TYPE_ASK_CONFIG }: who has the Slow mode setting?
    TYPE_ASK_CONFIG = "ask-slowmode-config",
    -- An officer's add-on answers an ask after a random wait in this range,
    -- so one answer usually covers everyone.
    ANSWER_DELAY_MIN = 1,
    ANSWER_DELAY_MAX = 5,
    -- The session's ask goes out ASK_DELAY to ASK_DELAY + ASK_SPREAD seconds
    -- after it's first called, so logins don't all ask at once, and not at
    -- all if an officer's setting was heard by then.
    -- The value saved last session holds until then.
    ASK_DELAY = 120,
    ASK_SPREAD = 30,
}
addon.SlowModeConfig = SlowModeConfig

-- The officer setting: whole minutes from 0 (off) to 15.
SlowModeConfig.SETTINGS = {
    slowModeMinutes = {
        default = 0,
        min = 0,
        max = 15,
        valid = function(value)
            return type(value) == "number" and value == math.floor(value) and value >= 0 and value <= 15
        end,
    },
}

-- Every message type, for routing.
SlowModeConfig.TYPES = {
    [SlowModeConfig.TYPE_CONFIG] = "OnConfig",
    [SlowModeConfig.TYPE_ASK_CONFIG] = "OnAskConfig",
}

local Config = {}
Config.__index = Config

function SlowModeConfig.Create(options)
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

-- The current guild's setting, or nil outside a guild.
function Config:Config()
    local partition = ask(self.partition)
    if partition == nil then
        return nil
    end
    return addon.RecruitConfig.Create(partition:GetSlowModeConfig(), {
        settings = SlowModeConfig.SETTINGS,
        isOfficer = self.isOfficer,
    })
end

-- The minutes between each greeter's greetings, 0 when Slow mode is off.
-- The default when nothing usable is saved or outside a guild.
function Config:Minutes()
    local config = self:Config()
    if config == nil then
        return SlowModeConfig.SETTINGS.slowModeMinutes.default
    end
    return config:Get("slowModeMinutes")
end

function Config:IsOfficer()
    local selfKey = ask(self.selfKey)
    return selfKey ~= nil and ask(self.isOfficer, selfKey) == true
end

-- An officer changes the minutes: saved stamped with now and the officer,
-- and the guild's add-on users are told. Returns true, or nil and a reason a
-- player can read.
function Config:SetMinutes(value)
    local setting = SlowModeConfig.SETTINGS.slowModeMinutes
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
    if config:Get("slowModeMinutes") == value then
        return true
    end
    if config:Set("slowModeMinutes", value, now, ask(self.selfKey)) == nil then
        return nil, "saved data is unavailable"
    end
    self:send()
    pcall(self.onChange)
    return true
end

-- Sends the changed setting, if it was ever changed.
function Config:send()
    local config = self:Config()
    local changes = config and config:Changes() or nil
    if changes ~= nil then
        pcall(self.announce, { v = SlowModeConfig.PROTOCOL, t = SlowModeConfig.TYPE_CONFIG, s = changes })
    end
end

-- Asks the officers' add-ons for the newest setting, once a session, a
-- while after it's first called. Every add-on asks, since every greeter
-- follows it, unless an officer's setting arrives first: an answer to
-- anyone's ask holds it for all.
function Config:AskOnce()
    if self.asked or self:Config() == nil then
        return false
    end
    self.asked = true
    local function send()
        if not self.heard and self:Config() ~= nil then
            pcall(self.announce, { v = SlowModeConfig.PROTOCOL, t = SlowModeConfig.TYPE_ASK_CONFIG })
        end
    end
    local spread = ask(self.random, 0, SlowModeConfig.ASK_SPREAD)
    if type(spread) ~= "number" or spread < 0 then
        spread = 0
    end
    if ask(self.after, SlowModeConfig.ASK_DELAY + spread, send) ~= true then
        send()
    end
    return true
end

function Config:fromOthers(sender)
    return type(sender) == "string" and ask(self.isOwn, sender) == false
end

-- A "slowmode-config": applied when the sender and the change's author are
-- officers and it's newer, with sync's tie-break. Hearing one stops this
-- add-on's own ask, and its answer to someone else's ask when it holds
-- everything this add-on knows. Returns true when the value changed.
function Config:OnConfig(message, sender)
    if type(message) ~= "table" or message.v ~= SlowModeConfig.PROTOCOL or message.t ~= SlowModeConfig.TYPE_CONFIG
        or type(message.s) ~= "table" or message.s.slowModeMinutes == nil
        or not self:fromOthers(sender) or ask(self.senderIsOfficer, sender) ~= true
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
    if not config:Apply("slowModeMinutes", message.s.slowModeMinutes) then
        return false
    end
    pcall(self.onChange)
    return true
end

-- Another add-on user's "ask-slowmode-config": an officer's add-on with a
-- changed setting answers after a random short wait, unless an answer
-- holding it is heard first. Returns true when an answer was scheduled.
function Config:OnAskConfig(message, sender)
    local config = self:Config()
    if type(message) ~= "table" or message.v ~= SlowModeConfig.PROTOCOL
        or message.t ~= SlowModeConfig.TYPE_ASK_CONFIG
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
    local delay = ask(self.random, SlowModeConfig.ANSWER_DELAY_MIN, SlowModeConfig.ANSWER_DELAY_MAX)
    if type(delay) ~= "number" or delay < 0 then
        delay = SlowModeConfig.ANSWER_DELAY_MIN
    end
    if ask(self.after, delay, answer) ~= true then
        answer()
    end
    return true
end

-- Hands a received Slow mode message to its handler. False for any other.
function Config:OnMessage(message, sender)
    local handler = type(message) == "table" and SlowModeConfig.TYPES[message.t] or nil
    if handler == nil then
        return false
    end
    return self[handler](self, message, sender)
end
