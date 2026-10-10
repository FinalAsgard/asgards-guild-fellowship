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

-- The logged-in character as "Name-Realm", or nil while the client can't
-- say. UnitFullName may leave out the realm (early at login, or on older
-- clients), so the player's own realm fills it in.
function Client:GetPlayerFullName()
    local ok, name, realm = callFunction(self.environment.UnitFullName, "player")
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end
    if type(realm) ~= "string" or realm == "" then
        local realmOk, ownRealm = callFunction(self.environment.GetNormalizedRealmName)
        if not realmOk or type(ownRealm) ~= "string" or ownRealm == "" then
            realmOk, ownRealm = callFunction(self.environment.GetRealmName)
        end
        realm = realmOk and ownRealm or nil
    end
    if type(realm) ~= "string" or realm == "" then
        return nil
    end
    return name .. "-" .. realm
end

-- The logged-in character's GUID, or nil. Unlike its name, it's spelled the
-- same way the guild roster reports it on every client.
function Client:GetPlayerGuid()
    local ok, guid = callFunction(self.environment.UnitGUID, "player")
    if not ok or type(guid) ~= "string" or guid == "" then
        return nil
    end
    return guid
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
    local ok, name, rankName, rankIndex, level, _, zone, note, _, online, _, classToken, _, _, _, _, _, guid =
        callFunction(self.environment.GetGuildRosterInfo, index)
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end

    local member = {
        name = name,
        guid = type(guid) == "string" and guid ~= "" and guid or nil,
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

-- Runs filter(event, message, sender) on every chat line of `events`. A
-- string it returns replaces the message text; anything else, or an error,
-- leaves the line as it was. The sender and the rest of the line pass
-- through untouched, so name links keep working. Retail keeps the filter
-- API in ChatFrameUtil; older clients have it as a global. Returns false
-- when the client has neither, or no event could be registered.
function Client:AddChatMessageFilter(events, filter)
    if type(events) ~= "table" or type(filter) ~= "function" then
        return false
    end
    local chatFrameUtil = self.environment.ChatFrameUtil
    local addFilter = type(chatFrameUtil) == "table" and chatFrameUtil.AddMessageEventFilter or nil
    if type(addFilter) ~= "function" then
        addFilter = self.environment.ChatFrame_AddMessageEventFilter
    end
    if type(addFilter) ~= "function" then
        return false
    end

    local function handler(_, event, message, sender, ...)
        local ok, replacement = pcall(filter, event, message, sender)
        if ok and type(replacement) == "string" then
            return false, replacement, sender, ...
        end
        return false
    end

    local registered = false
    local index
    for index = 1, #events do
        if pcall(addFilter, events[index], handler) then
            registered = true
        end
    end
    return registered
end

-- The system messages that report someone coming online, going offline, or
-- joining the guild, by kind: the client's own format string (so every
-- locale works), with the English text as a fallback. Online and offline
-- fire for friends too; callers check guild membership.
Compatibility.PRESENCE_FORMATS = {
    { kind = "online", global = "ERR_FRIEND_ONLINE_SS", fallback = "|Hplayer:%s|h[%s]|h has come online." },
    { kind = "offline", global = "ERR_FRIEND_OFFLINE_S", fallback = "%s has gone offline." },
    { kind = "join", global = "ERR_GUILD_JOIN_S", fallback = "%s has joined the guild." },
}

-- A Lua pattern matching a client format string, capturing each "%s" (or
-- positional "%1$s"). Nil for anything that isn't text.
function Compatibility.PatternFor(format)
    if type(format) ~= "string" or format == "" then
        return nil
    end
    local pattern = string.gsub(format, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    pattern = string.gsub(pattern, "%%%%%d%%%$s", "(.-)")
    pattern = string.gsub(pattern, "%%%%s", "(.-)")
    return "^" .. pattern .. "$"
end

-- Calls onPresence(kind, name) for every system message saying someone came
-- online, went offline, or joined the guild, with the name as the message gives it (from the
-- player link when there is one). Messages the client hides from add-ons
-- are skipped. Returns false when the client can't deliver the event.
function Client:ObservePresence(onPresence)
    if type(onPresence) ~= "function" then
        return false
    end
    local patterns = {}
    local index
    for index = 1, #Compatibility.PRESENCE_FORMATS do
        local entry = Compatibility.PRESENCE_FORMATS[index]
        local format = self.environment[entry.global]
        local pattern = Compatibility.PatternFor(type(format) == "string" and format or entry.fallback)
        if pattern ~= nil then
            table.insert(patterns, { kind = entry.kind, pattern = pattern })
        end
    end
    local frame = self:CreateEventFrame()
    if frame == nil
        or not self:SetEventHandler(frame, function(_, _, message)
            if type(message) ~= "string" or self:IsSecretValue(message) then
                return
            end
            local patternIndex
            for patternIndex = 1, #patterns do
                local name = string.match(message, patterns[patternIndex].pattern)
                if name ~= nil and name ~= "" then
                    pcall(onPresence, patterns[patternIndex].kind, name)
                    return
                end
            end
        end)
        or not self:RegisterEvent(frame, "CHAT_MSG_SYSTEM")
    then
        return false
    end
    self.presenceFrame = frame
    return true
end

-- Calls onChange(busy) when the player enters or leaves combat or, on
-- clients that report them, a boss encounter: busy is true while either
-- lasts. Returns the current state (false when the client can't say), or
-- nil when the client can't deliver the events. Leaving an instance or
-- reconnecting may skip ENCOUNTER_END, so the encounter state is read again
-- after every loading screen, where the client can report it.
function Client:ObserveCombat(onChange)
    if type(onChange) ~= "function" then
        return nil
    end
    local function asks(callback)
        local ok, answer = callFunction(callback)
        return ok and answer ~= nil and answer ~= false
    end
    local inCombat = asks(self.environment.InCombatLockdown)
    local inEncounter = asks(self.environment.IsEncounterInProgress)
    local frame = self:CreateEventFrame()
    if frame == nil or not self:SetEventHandler(frame, function(_, eventName)
        if eventName == "PLAYER_REGEN_DISABLED" then
            inCombat = true
        elseif eventName == "PLAYER_REGEN_ENABLED" then
            inCombat = false
        elseif eventName == "ENCOUNTER_START" then
            inEncounter = true
        elseif eventName == "ENCOUNTER_END" then
            inEncounter = false
        elseif eventName == "PLAYER_ENTERING_WORLD" then
            if type(self.environment.IsEncounterInProgress) ~= "function" then
                return
            end
            inEncounter = asks(self.environment.IsEncounterInProgress)
        else
            return
        end
        pcall(onChange, inCombat or inEncounter)
    end) then
        return nil
    end
    if not self:RegisterEvent(frame, "PLAYER_REGEN_DISABLED")
        or not self:RegisterEvent(frame, "PLAYER_REGEN_ENABLED")
    then
        return nil
    end
    -- Encounter events are optional; a client without them only holds for
    -- combat.
    self:RegisterEvent(frame, "ENCOUNTER_START")
    self:RegisterEvent(frame, "ENCOUNTER_END")
    self:RegisterEvent(frame, "PLAYER_ENTERING_WORLD")
    self.combatFrame = frame
    return inCombat or inEncounter
end

-- Posts `text` to guild chat. Retail keeps the call in C_ChatInfo; older
-- clients have it as a global. Returns true when the client accepted it.
function Client:SendGuildMessage(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local chatInfo = self.environment.C_ChatInfo
    if type(chatInfo) == "table" and type(chatInfo.SendChatMessage) == "function" then
        return (callFunction(chatInfo.SendChatMessage, text, "GUILD"))
    end
    return (callFunction(self.environment.SendChatMessage, text, "GUILD"))
end

-- True when the client hides `value` from add-ons (Retail's secret values,
-- during encounters and keystone runs). False on a client without the
-- check. A check that errors answers true, so callers leave the value alone.
function Client:IsSecretValue(value)
    local isSecret = self.environment.issecretvalue
    if type(isSecret) ~= "function" then
        return false
    end
    local ok, secret = pcall(isSecret, value)
    return not ok or (secret ~= nil and secret ~= false)
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

-- Runs callback once after `seconds` (0 means the next frame). Returns false
-- when the client has no timer, so callers can act immediately instead.
function Client:After(seconds, callback)
    local timers = self.environment.C_Timer
    if type(timers) ~= "table" or type(timers.After) ~= "function" or type(callback) ~= "function" then
        return false
    end

    local ok = pcall(timers.After, seconds, callback)
    return ok
end

-- A random whole number from `low` to `high`, or `low` when the client has
-- no random numbers.
function Client:Random(low, high)
    local math = self.environment.math
    local ok, value = callFunction(type(math) == "table" and math.random or nil, low, high)
    if not ok or type(value) ~= "number" then
        return low
    end
    return value
end

-- A high-resolution clock in milliseconds for time budgets, or nil.
function Client:PreciseMilliseconds()
    local ok, now = callFunction(self.environment.debugprofilestop)
    if ok and type(now) == "number" then
        return now
    end
    ok, now = callFunction(self.environment.GetTimePreciseSec)
    if ok and type(now) == "number" then
        return now * 1000
    end
    return nil
end

-- A timestamp as "2026-10-05", or the raw number when the client has no
-- date function.
function Client:FormatDate(timestamp)
    if type(timestamp) ~= "number" then
        return ""
    end
    local ok, text = callFunction(self.environment.date, "%Y-%m-%d", timestamp)
    if ok and type(text) == "string" then
        return text
    end
    return tostring(timestamp)
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
