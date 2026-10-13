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
-- Opens the game's chat box on guild chat with `text` typed in, for the
-- player to edit and send with Enter: the game sends it, so nothing an
-- add-on can't do is involved. Retail keeps the call in ChatFrameUtil;
-- older clients have it as a global. Returns true when it opened.
function Client:OpenGuildChat(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local line = "/g " .. text
    local util = self.environment.ChatFrameUtil
    if type(util) == "table" and type(util.OpenChat) == "function" then
        return (callFunction(util.OpenChat, line))
    end
    return (callFunction(self.environment.ChatFrame_OpenChat, line))
end

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

-- True when the logged-in character's guild rank can invite to the guild.
-- False when the client can't say.
function Client:CanGuildInvite()
    local guildInfo = self.environment.C_GuildInfo
    local ok, can
    if type(guildInfo) == "table" and type(guildInfo.CanGuildInvite) == "function" then
        ok, can = callFunction(guildInfo.CanGuildInvite)
    else
        ok, can = callFunction(self.environment.CanGuildInvite)
    end
    return ok and can ~= nil and can ~= false
end

-- Map types finer than a zone (dungeon levels, micro and orphan maps); the
-- zone a General channel belongs to is the first map above them.
local SUB_ZONE_MAP_TYPE = 4

-- The zone's map ID where the client has maps: the player's map, climbing
-- out of any finer map to the zone it's in. Nil otherwise, and then true
-- as well when the client's maps work but haven't placed the player on one
-- yet.
function Client:zoneMapId()
    local maps = self.environment.C_Map
    if type(maps) ~= "table" then
        return nil
    end
    local ok, mapId = callFunction(maps.GetBestMapForUnit, "player")
    if ok and mapId == nil then
        return nil, true
    end
    if not ok or type(mapId) ~= "number" then
        return nil
    end
    local steps
    for steps = 1, 10 do
        local infoOk, info = callFunction(maps.GetMapInfo, mapId)
        if not infoOk or type(info) ~= "table" or type(info.mapType) ~= "number"
            or info.mapType < SUB_ZONE_MAP_TYPE or type(info.parentMapID) ~= "number" or info.parentMapID == 0
        then
            return mapId
        end
        mapId = info.parentMapID
    end
    return mapId
end

-- The name of the map `mapID`, as the client shows it, or nil.
function Client:GetMapName(mapID)
    local maps = self.environment.C_Map
    if type(maps) ~= "table" or type(mapID) ~= "number" then
        return nil
    end
    local ok, info = callFunction(maps.GetMapInfo, mapID)
    if not ok or type(info) ~= "table" or type(info.name) ~= "string" or info.name == "" then
        return nil
    end
    return info.name
end

-- The zone the player is in as { key, name }: the key is "map:<ID>" where
-- the client has maps, else "zone:<name>"; the name is as the client shows
-- it. Nil when the client can't say, including while a client whose maps
-- work hasn't placed the player on one yet (just after a loading screen, or
-- on a boat), so one zone never goes by two keys.
function Client:GetZone()
    local ok, name = callFunction(self.environment.GetRealZoneText)
    if not ok or type(name) ~= "string" or name == "" then
        ok, name = callFunction(self.environment.GetZoneText)
    end
    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end
    local mapId, unplaced = self:zoneMapId()
    if mapId ~= nil then
        return { key = "map:" .. mapId, name = name }
    end
    if unplaced then
        return nil
    end
    return { key = "zone:" .. name, name = name }
end

-- True in a dungeon, raid, scenario, battleground or arena, or a keystone
-- run on clients that have them. False when the client can't say.
function Client:IsInInstance()
    local ok, inside = callFunction(self.environment.IsInInstance)
    if ok and inside ~= nil and inside ~= false then
        return true
    end
    local challengeMode = self.environment.C_ChallengeMode
    if type(challengeMode) == "table" then
        local activeOk, active = callFunction(challengeMode.IsChallengeModeActive)
        return activeOk and active ~= nil and active ~= false
    end
    return false
end

-- How many channel numbers to look through for the General channel.
Compatibility.MAX_CHANNELS = 20

-- The channel numbers the client reports as disabled here. The player stays
-- in Trade after leaving a city, but the client marks it disabled (greyed out
-- in the channel list) until they're back in one. GetChannelList gives each
-- channel as its number, name and, on clients that report it, whether it's
-- disabled; a list that can't be read disables nothing.
function Client:disabledChannels()
    local disabled = {}
    local ok, list = callFunction(function()
        return { self.environment.GetChannelList() }
    end)
    if not ok or type(list) ~= "table" then
        return disabled
    end
    local current
    local index
    for index = 1, #list do
        local value = list[index]
        if type(value) == "number" then
            current = value
        elseif value == true and current ~= nil then
            disabled[current] = true
        end
    end
    return disabled
end

-- The channels the client lists here, in order, as { number, name,
-- disabled }, read from GetChannelList as the channel lookup reads it; an
-- empty list when it can't be read.
function Client:ListedChannels()
    local listed = {}
    local ok, list = callFunction(function()
        return { self.environment.GetChannelList() }
    end)
    if not ok or type(list) ~= "table" then
        return listed
    end
    local index
    for index = 1, #list do
        local value = list[index]
        if type(value) == "number" then
            table.insert(listed, { number = value, disabled = false })
        elseif type(value) == "string" and listed[#listed] ~= nil and listed[#listed].name == nil then
            listed[#listed].name = value
        elseif value == true and listed[#listed] ~= nil then
            listed[#listed].disabled = true
        end
    end
    return listed
end

-- What Guild Recruit sees where the player stands, for `/agf channels`:
-- lines of text naming the zone, every channel the client lists (and
-- whether it's disabled), and the channels it would use for General and
-- Trade.
function Client:ChannelReport()
    local lines = {}
    local zone = self:GetZone()
    table.insert(lines, "Zone: " .. (zone and (zone.name .. " (" .. zone.key .. ")") or "unknown"))
    local listed = self:ListedChannels()
    if listed[1] == nil then
        table.insert(lines, "The game lists no channels here.")
    end
    local index
    for index = 1, #listed do
        local channel = listed[index]
        local _, _, fullName = callFunction(self.environment.GetChannelName, channel.number)
        table.insert(lines, channel.number .. ". " .. tostring(channel.name or "?") ..
            (type(fullName) == "string" and fullName ~= channel.name and (" (" .. fullName .. ")") or "") ..
            (channel.disabled and ", disabled here" or ""))
    end
    local general, trade = self:GetGeneralChannel(), self:GetTradeChannel()
    table.insert(lines, "General: " .. (general and ("channel " .. general) or "none here"))
    table.insert(lines, "Trade: " .. (trade and ("channel " .. trade) or "none here"))
    return lines
end

-- The number of the joined channel named `name` ("Trade - City" and plain
-- "Trade" are both named Trade), or nil when the player isn't in one.
function Client:joinedChannel(name)
    local prefix = name .. " - "
    local number
    for number = 1, Compatibility.MAX_CHANNELS do
        local ok, id, fullName = callFunction(self.environment.GetChannelName, number)
        if ok and type(id) == "number" and id > 0 and type(fullName) == "string"
            and not self:IsSecretValue(fullName)
            and (fullName == name or string.sub(fullName, 1, string.len(prefix)) == prefix)
        then
            return id
        end
    end
    return nil
end

-- The number of a server channel the player is in and can post to here, or
-- nil. The channel is found by its English name (`name`) in the client's
-- channel list, which also names channels the client has disabled here (out
-- of a city, Trade is listed but disabled, and the client gives it no full
-- name). The channel by that name decides: when it's disabled, there's none
-- here. It's never found by position in the client's list of server channel
-- names, whose order differs between clients (WoW Forever's has no Trade,
-- and LocalDefense second), so a client in another language finds neither
-- channel rather than the wrong one. Without a channel list, joined
-- channels are found by full name.
function Client:findServerChannel(name)
    local listed = self:ListedChannels()
    if listed[1] == nil then
        return self:joinedChannel(name)
    end
    local index
    for index = 1, #listed do
        if listed[index].name == name then
            if listed[index].disabled then
                return nil
            end
            return listed[index].number
        end
    end
    return nil
end

-- The number of the General channel the player is in, or nil.
function Client:GetGeneralChannel()
    return self:findServerChannel("General")
end

-- False when the channel numbered `number` is named for a zone other than
-- `zoneName` ("General - Booty Bay" while the client still reports the zone
-- the player just left). True when it's named for that zone, or its name
-- can't be read or carries no zone, so nothing is ruled out then.
function Client:IsChannelOfZone(number, zoneName)
    local ok, _, fullName = callFunction(self.environment.GetChannelName, number)
    if not ok or type(fullName) ~= "string" or self:IsSecretValue(fullName) then
        return true
    end
    local zone = string.match(fullName, "^[^-]+ %- (.+)$")
    return zone == nil or zone == zoneName
end

-- The number of the Trade channel, or nil when the player isn't in it or
-- the client reports it disabled here (outside a city). Trade is one channel
-- in every city, so this also answers whether Trade is available here.
function Client:GetTradeChannel()
    return self:findServerChannel("Trade")
end

-- True when the player can post to the Trade channel here.
function Client:IsTradeAvailable()
    return self:GetTradeChannel() ~= nil
end

-- Posts `text` to the channel numbered `channelNumber`. Retail keeps the call
-- in C_ChatInfo; older clients have it as a global. Returns true when the
-- client accepted it.
function Client:SendChannelMessage(text, channelNumber)
    if type(text) ~= "string" or text == "" or type(channelNumber) ~= "number" then
        return false
    end
    local chatInfo = self.environment.C_ChatInfo
    if type(chatInfo) == "table" and type(chatInfo.SendChatMessage) == "function" then
        return (callFunction(chatInfo.SendChatMessage, text, "CHANNEL", nil, channelNumber))
    end
    return (callFunction(self.environment.SendChatMessage, text, "CHANNEL", nil, channelNumber))
end

-- Calls onChange() whenever the player may have changed zone or channels:
-- a new zone, a loading screen, the channel list changing (the client moves
-- the player to the new zone's General a moment after arriving), or a
-- channel being joined, left, or disabled or enabled here.
-- Returns false when the client can't deliver the events.
function Client:ObserveZone(onChange)
    if type(onChange) ~= "function" then
        return false
    end
    local frame = self:CreateEventFrame()
    if frame == nil
        or not self:SetEventHandler(frame, function()
            pcall(onChange)
        end)
        or not self:RegisterEvent(frame, "ZONE_CHANGED_NEW_AREA")
    then
        return false
    end
    self:RegisterEvent(frame, "PLAYER_ENTERING_WORLD")
    self:RegisterEvent(frame, "CHANNEL_UI_UPDATE")
    -- Leaving a city, the client reports the new zone first and disables
    -- Trade a moment later, with a channel notice, so channels are checked
    -- again then. Newer clients also report channel flag changes.
    self:RegisterEvent(frame, "CHAT_MSG_CHANNEL_NOTICE")
    self:RegisterEvent(frame, "CHANNEL_FLAGS_UPDATED")
    self.zoneFrame = frame
    return true
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

-- The logged-in character's level, or nil while the client can't say.
function Client:GetPlayerLevel()
    local ok, level = callFunction(self.environment.UnitLevel, "player")
    if not ok or type(level) ~= "number" or level < 1 then
        return nil
    end
    return level
end

-- Whether the player is in a party or raid. False when the client can't say.
function Client:IsInGroup()
    local environment = self.environment
    local ok, grouped = callFunction(environment.IsInGroup)
    if ok then
        return grouped ~= nil and grouped ~= false
    end
    local count
    ok, count = callFunction(environment.GetNumGroupMembers)
    if not ok then
        ok, count = callFunction(environment.GetNumPartyMembers)
    end
    return ok and type(count) == "number" and count > 0
end

-- The game's assigned roles, as the Group Finder names them.
Compatibility.ASSIGNED_ROLES = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }
Compatibility.PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

-- The player and their party members, each { key, name, classToken, level,
-- guid, assignedRole, inGuild, isPlayer }. `key` is the GUID where the
-- client gives one, else the name. `assignedRole` is nil where the client assigns none.
function Client:GetPartyMembers()
    local environment = self.environment
    local members = {}
    local index
    for index = 1, #Compatibility.PARTY_UNITS do
        local unit = Compatibility.PARTY_UNITS[index]
        local existsOk, exists = callFunction(environment.UnitExists, unit)
        if unit == "player" or (existsOk and exists) then
            -- A member from another realm comes with that realm; the
            -- name then carries it, as the guild roster spells it.
            local nameOk, name, realm = callFunction(environment.UnitName, unit)
            if nameOk and type(name) == "string" and name ~= "" and type(realm) == "string" and realm ~= "" then
                name = name .. "-" .. realm
            end
            if nameOk and type(name) == "string" and name ~= "" then
                local _, guid = callFunction(environment.UnitGUID, unit)
                local _, _, classToken = callFunction(environment.UnitClass, unit)
                local _, level = callFunction(environment.UnitLevel, unit)
                local _, role = callFunction(environment.UnitGroupRolesAssigned, unit)
                local _, inGuild = callFunction(environment.UnitIsInMyGuild, unit)
                table.insert(members, {
                    key = type(guid) == "string" and guid ~= "" and guid or name,
                    name = name,
                    guid = type(guid) == "string" and guid ~= "" and guid or nil,
                    classToken = type(classToken) == "string" and classToken or nil,
                    level = type(level) == "number" and level > 0 and level or nil,
                    assignedRole = Compatibility.ASSIGNED_ROLES[role],
                    inGuild = unit == "player" or (inGuild ~= nil and inGuild ~= false),
                    isPlayer = unit == "player",
                })
            end
        end
    end
    return members
end

-- Sends the game's party invite to the character `name`. Retail keeps it
-- in C_PartyInfo; older clients have it as a global. Returns true when the
-- client accepted the call. Only ever called from the organizer's click.
function Client:InviteToParty(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local partyInfo = self.environment.C_PartyInfo
    if type(partyInfo) == "table" and type(partyInfo.InviteUnit) == "function" then
        return (callFunction(partyInfo.InviteUnit, name))
    end
    return (callFunction(self.environment.InviteUnit, name))
end

-- Calls onChange() whenever the party or its assigned roles change.
-- Returns false when the client can't deliver the events.
function Client:ObserveParty(onChange)
    if type(onChange) ~= "function" then
        return false
    end
    local frame = self:CreateEventFrame()
    if frame == nil or not self:SetEventHandler(frame, function()
        pcall(onChange)
    end) then
        return false
    end
    -- Retail and newer clients send GROUP_ROSTER_UPDATE; older ones the
    -- party events. Each client registers whichever it knows.
    local registered = self:RegisterEvent(frame, "GROUP_ROSTER_UPDATE")
    registered = self:RegisterEvent(frame, "PARTY_MEMBERS_CHANGED") or registered
    self:RegisterEvent(frame, "PLAYER_ROLES_ASSIGNED")
    self.partyFrame = frame
    return registered
end

-- The game's Dungeon Finder classifies each entry; the Group Finder lists
-- only regular dungeons at normal difficulty, not random queues or heroics.
Compatibility.LFG_TYPE_RANDOM = 6
Compatibility.LFG_SUBTYPE_DUNGEON = 1

-- The Dungeon Finder's dungeons as { id, name, minLevel, maxLevel }, or nil
-- on a client without one (WoW Forever) or when it lists none.
function Client:GetDungeonList()
    local environment = self.environment
    local ok, order = callFunction(environment.GetLFDChoiceOrder, {})
    if not ok or type(order) ~= "table" or type(environment.GetLFGDungeonInfo) ~= "function" then
        return nil
    end
    local dungeons = {}
    local index
    for index = 1, #order do
        local id = order[index]
        local infoOk, name, typeId, subtypeId, minLevel, maxLevel = callFunction(environment.GetLFGDungeonInfo, id)
        if infoOk and type(name) == "string" and name ~= ""
            and typeId ~= Compatibility.LFG_TYPE_RANDOM and subtypeId == Compatibility.LFG_SUBTYPE_DUNGEON
            and type(minLevel) == "number" and type(maxLevel) == "number"
        then
            table.insert(dungeons, { id = id, name = name, minLevel = minLevel, maxLevel = maxLevel })
        end
    end
    if #dungeons == 0 then
        return nil
    end
    return dungeons
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
