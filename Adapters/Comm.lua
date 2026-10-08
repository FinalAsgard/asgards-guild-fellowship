local _, addon = ...

-- The only code that touches AceComm-3.0, ChatThrottleLib, AceSerializer-3.0,
-- and the guild rank permission API. Messages are tables, serialized and
-- sent to the guild at ChatThrottleLib's lowest ("BULK") priority, so sync
-- traffic always yields to chat and other add-ons. Like the WoW adapter,
-- every method returns nil or false instead of raising.
local Comm = {
    DISTRIBUTION = "GUILD",
    PRIORITY = "BULK",
    -- Index of "view officer note" in a rank's permission flags.
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
-- with this prefix that deserializes to a table. Returns false when the
-- libraries are missing, so sync simply stays off.
function Endpoint:Start(onMessage)
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
        if distribution ~= Comm.DISTRIBUTION or type(text) ~= "string" or type(sender) ~= "string" then
            return
        end
        local decoded, success, message = pcall(serializer.Deserialize, serializer, text)
        if decoded and success and type(message) == "table" then
            pcall(onMessage, message, sender)
        end
    end)
    if not ok then
        return false
    end
    self.endpoint = endpoint
    self.serializer = serializer
    return true
end

-- Sends `message` to the guild. Returns false when it couldn't be sent.
function Endpoint:Broadcast(message)
    if self.endpoint == nil or type(message) ~= "table" then
        return false
    end
    local serialized, text = pcall(self.serializer.Serialize, self.serializer, message)
    if not serialized or type(text) ~= "string" then
        return false
    end
    local ok = pcall(self.endpoint.SendCommMessage, self.endpoint, self.prefix, text,
        Comm.DISTRIBUTION, nil, Comm.PRIORITY)
    return ok
end

-- Whether guild rank `rankIndex` (0-based, as the roster reports it) can
-- view officer notes: true, false, or nil when the client can't say.
function Endpoint:RankCanViewOfficerNotes(rankIndex)
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
    return flags[Comm.VIEW_OFFICER_NOTE_FLAG] == true
end
