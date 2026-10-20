local _, addon = ...

-- The only code that touches AceComm-3.0, ChatThrottleLib, AceSerializer-3.0,
-- the guild rank permission API, and combat, encounter and keystone state.
-- Messages are tables, serialized and sent to the guild (or only its
-- officers, or whispered to one guildmate) at ChatThrottleLib's
-- lowest ("BULK") priority, so sync traffic always yields to chat and other
-- add-ons. Small messages others should hear within seconds (Guild Greet's
-- "greeted") can ask for "NORMAL" instead. Like the WoW adapter, every method returns nil or false instead
-- of raising.
local Comm = {
    DISTRIBUTION = "GUILD",
    WHISPER = "WHISPER",
    OFFICER = "OFFICER",
    PRIORITY = "BULK",
    PRIORITY_NORMAL = "NORMAL",
    -- Indexes in a rank's permission flags: listening and speaking in
    -- officer chat, and "view officer note".
    OFFICER_CHAT_LISTEN_FLAG = 3,
    OFFICER_CHAT_SPEAK_FLAG = 4,
    VIEW_OFFICER_NOTE_FLAG = 11,
}
addon.Comm = Comm

local Endpoint = {}
Endpoint.__index = Endpoint

-- `client` is the WoW adapter; `prefix` the build's add-on message prefix.
function Comm.Create(client, prefix)
    return setmetatable({ client = client, prefix = prefix }, Endpoint)
end

-- Starts listening: onMessage(message, sender) runs for every guild message
-- with this prefix that deserializes to a table, onWhisper(message,
-- sender), when given, for every whispered one, and onOfficer(message,
-- sender), when given, for every one sent to the officer channel. Returns
-- false when the libraries are missing, so sync simply stays off.
function Endpoint:Start(onMessage, onWhisper, onOfficer)
    if self.endpoint ~= nil then
        return true
    end
    local aceComm = self.client:GetLibrary("AceComm-3.0")
    local serializer = self.client:GetLibrary("AceSerializer-3.0")
    if aceComm == nil or serializer == nil or type(onMessage) ~= "function" then
        return false
    end
    local endpoint = {}
    if not pcall(aceComm.Embed, aceComm, endpoint) then
        return false
    end
    local ok = pcall(endpoint.RegisterComm, endpoint, self.prefix, function(_, text, distribution, sender)
        local receive = distribution == Comm.DISTRIBUTION and onMessage
            or distribution == Comm.WHISPER and onWhisper
            or distribution == Comm.OFFICER and onOfficer or nil
        if type(receive) ~= "function" or type(text) ~= "string" or type(sender) ~= "string" then
            return
        end
        local decoded, success, message = pcall(serializer.Deserialize, serializer, text)
        if decoded and success and type(message) == "table" then
            pcall(receive, message, sender)
        end
    end)
    if not ok then
        return false
    end
    self.endpoint = endpoint
    self.serializer = serializer
    return true
end

-- Sends `message` to the guild at `priority` (BULK when nil). Returns false
-- when it couldn't be sent.
function Endpoint:Broadcast(message, priority)
    if self.endpoint == nil or type(message) ~= "table" then
        return false
    end
    local serialized, text = pcall(self.serializer.Serialize, self.serializer, message)
    if not serialized or type(text) ~= "string" then
        return false
    end
    local ok = pcall(self.endpoint.SendCommMessage, self.endpoint, self.prefix, text,
        Comm.DISTRIBUTION, nil, priority or Comm.PRIORITY)
    return ok
end

-- Sends `message` to the guild's officer channel at BULK priority: only
-- guildmates whose rank can listen to officer chat get it. Returns false
-- when it couldn't be sent.
function Endpoint:SendOfficers(message)
    if self.endpoint == nil or type(message) ~= "table" then
        return false
    end
    local serialized, text = pcall(self.serializer.Serialize, self.serializer, message)
    if not serialized or type(text) ~= "string" then
        return false
    end
    local ok = pcall(self.endpoint.SendCommMessage, self.endpoint, self.prefix, text,
        Comm.OFFICER, nil, Comm.PRIORITY)
    return ok
end

-- Whispers `message` to the character named `target` at BULK priority.
-- Returns false when it couldn't be sent (whispered add-on messages may not
-- work on every client).
function Endpoint:Whisper(message, target)
    if self.endpoint == nil or type(message) ~= "table" or type(target) ~= "string" or target == "" then
        return false
    end
    local serialized, text = pcall(self.serializer.Serialize, self.serializer, message)
    if not serialized or type(text) ~= "string" then
        return false
    end
    local ok = pcall(self.endpoint.SendCommMessage, self.endpoint, self.prefix, text,
        Comm.WHISPER, target, Comm.PRIORITY)
    return ok
end

-- Whether guild rank `rankIndex` (0-based, as the roster reports it) has
-- permission flag `flag`: true, false, or nil when the client can't say.
function Endpoint:RankHasFlag(rankIndex, flag)
    if type(rankIndex) ~= "number" then
        return nil
    end
    local guildInfo = self.client:GetGlobal("C_GuildInfo")
    local getFlags = type(guildInfo) == "table" and guildInfo.GuildControlGetRankFlags or nil
    if type(getFlags) ~= "function" then
        return nil
    end
    local ok, flags = pcall(getFlags, rankIndex + 1)
    if not ok or type(flags) ~= "table" then
        return nil
    end
    return flags[flag] == true
end

-- Whether guild rank `rankIndex` can view officer notes: true, false, or
-- nil when the client can't say.
function Endpoint:RankCanViewOfficerNotes(rankIndex)
    return self:RankHasFlag(rankIndex, Comm.VIEW_OFFICER_NOTE_FLAG)
end

-- Calls the global function at `path` (a list of names) with no arguments:
-- true when it answers true. A missing or failing check answers false.
local function answersTrue(client, path)
    local value = client:GetGlobal(path[1])
    local index
    for index = 2, #path do
        value = type(value) == "table" and value[path[index]] or nil
    end
    if type(value) ~= "function" then
        return false
    end
    local ok, answer = pcall(value)
    return ok and answer == true
end

-- True while the player is in combat, or, on clients that have them, in a
-- boss encounter or a keystone run. Sync waits until they aren't.
function Endpoint:IsBusy()
    return answersTrue(self.client, { "InCombatLockdown" })
        or answersTrue(self.client, { "IsEncounterInProgress" })
        or answersTrue(self.client, { "C_ChallengeMode", "IsChallengeModeActive" })
end
