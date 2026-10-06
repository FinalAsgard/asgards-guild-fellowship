local _, addon = ...

-- The only module that touches WoW globals. Every method returns nil or false
-- when the client lacks an API or the API raises, so callers never see errors
-- from the game client.
local Compatibility = {}
addon.Compatibility = Compatibility

local Client = {}
Client.__index = Client

local function callMethod(object, methodName, ...)
    if type(object) ~= "table" then
        return false
    end

    local method = object[methodName]
    if type(method) ~= "function" then
        return false
    end

    local ok = pcall(method, object, ...)
    return ok
end

local function callFunction(callback, ...)
    if type(callback) ~= "function" then
        return false
    end

    return pcall(callback, ...)
end

function Compatibility.Create(environment)
    return setmetatable({
        databaseName = addon.Identity.databaseName,
        environment = environment or _G,
    }, Client)
end

function Client:GetClientProfile()
    if self.clientProfile == nil then
        self.clientProfile = addon.ClientProfile.Detect(
            self.environment,
            addon.Identity.addonName
        )
    end

    return self.clientProfile
end

function Client:GetAddOnMetadata(field)
    return addon.ClientProfile.ReadMetadata(
        self.environment,
        addon.Identity.addonName,
        field
    )
end

function Client:CreateEventFrame()
    local ok, frame = callFunction(self.environment.CreateFrame, "Frame")
    if not ok or frame == nil then
        return nil
    end

    return frame
end

function Client:RegisterEvent(frame, eventName)
    return callMethod(frame, "RegisterEvent", eventName)
end

function Client:SetEventHandler(frame, handler)
    return callMethod(frame, "SetScript", "OnEvent", handler)
end

function Client:IsLoggedIn()
    local ok, loggedIn = callFunction(self.environment.IsLoggedIn)
    return ok and loggedIn ~= nil and loggedIn ~= false
end

local function withoutLeadingSlash(command)
    return (string.gsub(command, "^/", ""))
end

function Client:RegisterSlashCommand(command, alias, key, handler)
    if type(command) ~= "string"
        or type(alias) ~= "string"
        or type(key) ~= "string"
        or type(handler) ~= "function"
    then
        return false
    end

    local registerNewSlashCommand = self.environment.RegisterNewSlashCommand
    if type(registerNewSlashCommand) == "function" then
        local ok = pcall(
            registerNewSlashCommand,
            handler,
            withoutLeadingSlash(command),
            withoutLeadingSlash(alias)
        )
        if ok then
            return true
        end
    end

    local slashCommands = self.environment.SlashCmdList
    if type(slashCommands) ~= "table" then
        return false
    end

    self.environment["SLASH_" .. key .. "1"] = command
    self.environment["SLASH_" .. key .. "2"] = alias
    slashCommands[key] = handler
    return true
end

function Client:Print(message)
    if callMethod(self.environment.DEFAULT_CHAT_FRAME, "AddMessage", message) then
        return true
    end

    local ok = callFunction(self.environment.print, message)
    return ok
end

function Client:HasLibStub()
    local libStub = self.environment.LibStub
    return type(libStub) == "table" and type(libStub.GetLibrary) == "function"
end

-- The library LibStub has registered under `major`, or nil when LibStub or
-- the library is missing.
function Client:GetLibrary(major)
    if not self:HasLibStub() then
        return nil
    end

    local libStub = self.environment.LibStub
    local ok, library = pcall(libStub.GetLibrary, libStub, major, true)
    if not ok then
        return nil
    end

    return library
end

function Client:GetGlobal(name)
    if type(name) ~= "string" then
        return nil
    end

    return self.environment[name]
end

-- The player's current guild as { name, realm }, or nil when guildless or
-- unknown. GetGuildInfo reports no realm for a guild on the player's realm.
function Client:GetGuildIdentity()
    local ok, name, _, _, realm = callFunction(self.environment.GetGuildInfo, "player")
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end

    if type(realm) ~= "string" or realm == "" then
        local realmOk, currentRealm = callFunction(self.environment.GetRealmName)
        realm = realmOk and currentRealm or nil
    end
    if type(realm) ~= "string" or realm == "" then
        return nil
    end

    return { name = name, realm = realm }
end

function Client:IsInGuild()
    local ok, inGuild = callFunction(self.environment.IsInGuild)
    return ok and inGuild ~= nil and inGuild ~= false
end

-- How many members the guild roster currently holds, or nil.
function Client:GetGuildRosterCount()
    local ok, total = callFunction(self.environment.GetNumGuildMembers)
    if not ok or type(total) ~= "number" or total < 0 then
        return nil
    end
    return total
end

-- Facts about the roster member at `index`, or nil when the client can't
-- say (the roster loads asynchronously, so early reads may be empty).
function Client:GetGuildMember(index)
    local ok, name, rankName, rankIndex, level, _, zone, note, _, online, _, classToken =
        callFunction(self.environment.GetGuildRosterInfo, index)
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end

    local member = {
        name = name,
        classToken = type(classToken) == "string" and classToken or nil,
        level = type(level) == "number" and level or nil,
        rankIndex = type(rankIndex) == "number" and rankIndex or nil,
        rankName = type(rankName) == "string" and rankName or nil,
        online = online == true or online == 1,
        zone = type(zone) == "string" and zone ~= "" and zone or nil,
        -- The public note, read live. It is only parsed, never stored.
        note = type(note) == "string" and note or "",
    }

    local lastOk, years, months, days, hours =
        callFunction(self.environment.GetGuildRosterLastOnline, index)
    if lastOk and (type(years) == "number" or type(months) == "number"
        or type(days) == "number" or type(hours) == "number")
    then
        member.lastOnline = {
            years = years or 0,
            months = months or 0,
            days = days or 0,
            hours = hours or 0,
        }
    end
    return member
end

-- Asks the client to refresh the guild roster. GUILD_ROSTER_UPDATE follows.
function Client:RequestGuildRoster()
    local guildInfo = self.environment.C_GuildInfo
    if type(guildInfo) == "table" and callFunction(guildInfo.GuildRoster) then
        return true
    end
    return (callFunction(self.environment.GuildRoster))
end

-- Calls onUpdate() on every GUILD_ROSTER_UPDATE. Returns false when the
-- client can't deliver the event.
function Client:ObserveGuildRoster(onUpdate)
    if type(onUpdate) ~= "function" then
        return false
    end
    local frame = self:CreateEventFrame()
    if frame == nil
        or not self:SetEventHandler(frame, function()
            onUpdate()
        end)
        or not self:RegisterEvent(frame, "GUILD_ROSTER_UPDATE")
    then
        return false
    end
    self.rosterFrame = frame
    return true
end

-- The realm name as roster names spell it (no spaces), or nil.
function Client:GetHomeRealm()
    local ok, realm = callFunction(self.environment.GetNormalizedRealmName)
    if not ok or type(realm) ~= "string" or realm == "" then
        ok, realm = callFunction(self.environment.GetRealmName)
    end
    if not ok or type(realm) ~= "string" or realm == "" then
        return nil
    end
    return (string.gsub(realm, "%s+", ""))
end

-- Wall-clock seconds for saved records, or nil.
function Client:Timestamp()
    local ok, now = callFunction(self.environment.GetServerTime)
    if not ok or type(now) ~= "number" then
        ok, now = callFunction(self.environment.time)
    end
    if not ok or type(now) ~= "number" then
        return nil
    end
    return now
end

-- The class color as an "ffrrggbb" hex string, or nil.
function Client:GetClassColor(classToken)
    local colors = self.environment.RAID_CLASS_COLORS
    local color = type(colors) == "table" and type(classToken) == "string" and colors[classToken] or nil
    if type(color) ~= "table" then
        return nil
    end
    if type(color.colorStr) == "string" then
        return color.colorStr
    end
    if type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
        return string.format("ff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
    end
    return nil
end

function Client:GetAccountDatabase()
    return self.environment[self.databaseName]
end

function Client:SetAccountDatabase(database)
    self.environment[self.databaseName] = database
    return true
end
