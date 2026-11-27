local _, addon = ...

-- Decides whether a guild member coming online gets a greet prompt, and in
-- which category. Pure: it is told who came online or went offline and when,
-- and keeps what it has seen this session in memory.
--
-- It works per player, so a player switching alts is one person:
--   * someone joining the guild is a "join", and the login that comes with
--     it gets nothing more
--   * players already online when the session's roster first loads are seen,
--     and never get a login prompt
--   * the first login seen from a player this session is a "login", however
--     long they were away
--   * a player seen going offline who comes back at least `welcomeBack`
--     seconds later is a "welcomeBack"; sooner is a relog and gets nothing
--   * the user's own characters never get a prompt
-- So the order is join, welcome back, login.
-- Events before the roster first loads are ignored, since nobody is known
-- to be seen yet.
local GreetPolicy = {
    JOIN = "join",
    LOGIN = "login",
    WELCOME_BACK = "welcomeBack",
    WELCOME_BACK_SECONDS = 60 * 60,
}
addon.GreetPolicy = GreetPolicy

local Policy = {}
Policy.__index = Policy

-- options.playerOf: function(key) -> the player a character belongs to, or
--   nil for a character the database doesn't know (it then counts as its
--   own player).
-- options.isMember: function(key) -> true for a current guild member, so
--   friends' online messages are ignored.
-- options.isOwn: function(key) -> true for the user's own characters.
-- options.enabled: function() -> false when Guild Greet is off, or off on
--   this character. Optional.
-- options.categoryEnabled: function(category) -> false when that category's
--   prompts are turned off. Optional.
-- options.welcomeBackSeconds: function() -> the welcome-back threshold in
--   seconds. Optional; WELCOME_BACK_SECONDS otherwise.
function GreetPolicy.Create(options)
    return setmetatable({
        playerOf = options.playerOf,
        isMember = options.isMember,
        isOwn = options.isOwn,
        enabled = options.enabled or function()
            return true
        end,
        categoryEnabled = options.categoryEnabled or function()
            return true
        end,
        welcomeBack = options.welcomeBackSeconds or function()
            return GreetPolicy.WELCOME_BACK_SECONDS
        end,
        ready = false,
        seen = {},
        offlineAt = {},
    }, Policy)
end

-- The player `key` belongs to; a character the database doesn't know is a
-- player of its own.
function Policy:PlayerOf(key)
    local ok, player = pcall(self.playerOf, key)
    if ok and player ~= nil then
        return player
    end
    return "character:" .. key
end

local function answers(callback, key)
    local ok, result = pcall(callback, key)
    return ok and result == true
end

-- True once the session's roster has loaded.
function Policy:IsReady()
    return self.ready
end

-- Records the members online when the session's roster first loads. Later
-- calls do nothing.
function Policy:Seed(onlineKeys)
    if self.ready then
        return
    end
    local index
    for index = 1, #(onlineKeys or {}) do
        self.seen[self:PlayerOf(onlineKeys[index])] = true
    end
    self.ready = true
end

-- A guild member went offline at `now`.
function Policy:WentOffline(key, now)
    if not self.ready or type(key) ~= "string" or type(now) ~= "number" then
        return
    end
    local player = self:PlayerOf(key)
    self.seen[player] = true
    self.offlineAt[player] = now
end

-- A threshold in seconds from `callback`, or `default` when it fails.
local function seconds(callback, default)
    local ok, value = pcall(callback)
    if ok and type(value) == "number" then
        return value
    end
    return default
end

-- The welcome-back threshold in seconds.
function Policy:WelcomeBackSeconds()
    return seconds(self.welcomeBack, GreetPolicy.WELCOME_BACK_SECONDS)
end

function Policy:prompt(category, player, key)
    local ok, enabled = pcall(self.enabled)
    if not ok or enabled == false then
        return nil
    end
    local categoryOk, categoryEnabled = pcall(self.categoryEnabled, category)
    if categoryOk and categoryEnabled == false then
        return nil
    end
    return { category = category, player = player, key = key }
end

-- Someone joined the guild at `now`. They aren't in the database yet, so
-- membership isn't checked. Returns the prompt, or nil.
function Policy:Joined(key, now)
    if not self.ready or type(key) ~= "string" or type(now) ~= "number" or answers(self.isOwn, key) then
        return nil
    end
    local player = self:PlayerOf(key)
    self.seen[player] = true
    self.offlineAt[player] = nil
    return self:prompt(GreetPolicy.JOIN, player, key)
end

-- A guild member came online at `now`. Returns the prompt
-- { category, player, key }, or nil when there's none.
function Policy:CameOnline(key, now)
    if not self.ready or type(key) ~= "string" or type(now) ~= "number" then
        return nil
    end
    if not answers(self.isMember, key) or answers(self.isOwn, key) then
        return nil
    end
    local player = self:PlayerOf(key)
    local wasSeen, offlineAt = self.seen[player], self.offlineAt[player]
    self.seen[player] = true
    self.offlineAt[player] = nil

    local category
    if not wasSeen then
        category = GreetPolicy.LOGIN
    elseif offlineAt ~= nil and now - offlineAt >= self:WelcomeBackSeconds() then
        category = GreetPolicy.WELCOME_BACK
    else
        -- A relog, an alt switch, or a login we never saw end.
        return nil
    end
    return self:prompt(category, player, key)
end
