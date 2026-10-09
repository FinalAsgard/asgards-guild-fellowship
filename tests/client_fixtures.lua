local test = require("tests.test_helper")

-- Controlled WoW API surfaces representative of each supported client. Only
-- the differences the adapter must handle are modelled; everything else is
-- shared so a behavior difference between profiles is always deliberate.
local Fixtures = {
    BUILDS = { "AsgardsGuildFellowship", "AsgardsGuildFellowshipDev" },
    PROFILES = { "Forever", "Retail" },
}

local MANIFEST_SUFFIXES = {
    Forever = "_Camelot",
    Retail = "_Mainline",
}

function Fixtures.manifestPath(profile, addonName)
    return (addonName or test.DEFAULT_ADDON_NAME) .. MANIFEST_SUFFIXES[profile] .. ".toc"
end

function Fixtures.manifestMetadata(path)
    local metadata = {}
    local line
    for line in io.lines(path) do
        local field, value = string.match(line, "^## ([%w%-]+):%s*(.-)%s*$")
        if field ~= nil then
            metadata[field] = value
        end
    end
    return metadata
end

-- Every file line in the manifest, libraries included, in order.
function Fixtures.manifestLines(path)
    local files = {}
    local line
    for line in io.lines(path) do
        line = line:gsub("%s+$", "")
        if line ~= "" and string.sub(line, 1, 2) ~= "##" then
            table.insert(files, line)
        end
    end
    return files
end

-- The add-on's own files in manifest order. Library files are skipped: the
-- fixtures stand in for them, so CI never needs the fetched libraries.
function Fixtures.manifestFiles(path)
    local files = {}
    local lines = Fixtures.manifestLines(path)
    local index
    for index = 1, #lines do
        if string.sub(lines[index], 1, 5) ~= "Libs/" then
            table.insert(files, lines[index])
        end
    end
    return files
end

-- The majors the fake LibStub registers unless a test removes them.
Fixtures.LIBRARY_MAJORS = {
    "CallbackHandler-1.0",
    "LibDataBroker-1.1",
    "LibDBIcon-1.0",
    "LibSharedMedia-3.0",
    "DetailsFramework-1.0",
    "AceSerializer-3.0",
    "AceComm-3.0",
}

-- A stand-in for AceSerializer-3.0. Each serialized message is kept in this
-- registry as a copy and named by a token, so a receiver always gets its own
-- copy, never the sender's tables.
local serialized = { count = 0 }

local function newSerializer()
    local serializer = {}
    function serializer:Serialize(...)
        serialized.count = serialized.count + 1
        local token = "serialized#" .. serialized.count
        serialized[token] = Fixtures.snapshot({ n = select("#", ...), ... })
        return token
    end
    function serializer:Deserialize(text)
        local packed = serialized[text]
        if packed == nil then
            return false, "not a serialized message"
        end
        packed = Fixtures.snapshot(packed)
        return true, unpack(packed, 1, packed.n)
    end
    return serializer
end

-- A stand-in for AceComm-3.0. Messages a world sends are recorded in
-- `world.sentMessages` and, when the world joined a channel, queued there
-- until Fixtures.deliver hands them to every world on it.
local function newComm(world)
    local comm = {}
    function comm:Embed(target)
        function target:RegisterComm(prefix, handler)
            world.commHandlers[prefix] = handler
        end
        function target:SendCommMessage(prefix, text, distribution, recipient, priority)
            table.insert(world.sentMessages, {
                prefix = prefix,
                text = text,
                distribution = distribution,
                priority = priority,
            })
            if world.channel ~= nil then
                table.insert(world.channel.queue, {
                    from = world,
                    prefix = prefix,
                    text = text,
                    distribution = distribution,
                })
            end
        end
        return target
    end
    return comm
end

-- A fake LibStub registry and Details! Framework global. `options.libStub =
-- false` omits LibStub, `options.missingLibraries` lists majors left
-- unregistered, and `options.frameworkFailed` leaves the framework half
-- loaded (registered, but its core file stopped before finishing).
local function installLibraries(world, environment, options)
    world.commHandlers = {}
    world.sentMessages = {}
    if options.libStub == false then
        return
    end

    local missing = {}
    local index
    for index = 1, #(options.missingLibraries or {}) do
        missing[options.missingLibraries[index]] = true
    end

    local libStub = { libs = {}, minors = {} }
    function libStub:GetLibrary(major, silent)
        if self.libs[major] == nil and not silent then
            error("Cannot find a library instance of \"" .. tostring(major) .. "\".", 2)
        end
        return self.libs[major], self.minors[major]
    end
    for index = 1, #Fixtures.LIBRARY_MAJORS do
        local major = Fixtures.LIBRARY_MAJORS[index]
        if not missing[major] then
            libStub.libs[major] = {}
            libStub.minors[major] = 1
        end
    end
    if libStub.libs["AceSerializer-3.0"] ~= nil then
        libStub.libs["AceSerializer-3.0"] = newSerializer()
    end
    if libStub.libs["AceComm-3.0"] ~= nil then
        libStub.libs["AceComm-3.0"] = newComm(world)
    end
    environment.LibStub = libStub

    local framework = libStub.libs["DetailsFramework-1.0"]
    if framework ~= nil then
        if not options.frameworkFailed then
            framework.FrameWorkVersion = "746"
        end
        environment.DetailsFramework = framework
    end
end

local function newFrame(world)
    local frame = { registeredEvents = {} }
    table.insert(world.frames, frame)
    function frame:RegisterEvent(eventName)
        self.registeredEvents[eventName] = true
    end
    function frame:SetScript(scriptName, handler)
        if scriptName == "OnEvent" then
            self.handler = handler
        end
    end
    return frame
end

-- Answers metadata for the loaded build's manifest; `declaredClient` replaces
-- its X-Client value (false removes it).
local function metadataReader(world, declaredClient)
    return function(addonName, field)
        if addonName ~= world.addonName then
            return nil
        end
        if field == "X-Client" then
            return declaredClient or nil
        end
        return world.manifest[field]
    end
end

-- Sample guilds per client: Forever names are "First Last" with no realm,
-- Retail names are one word with a realm suffix, as each roster reports them.
-- In each, Hammer's note marks it as an alt of the officer, whose note sets
-- the alias "TheTool".
Fixtures.GUILDS = {
    Forever = {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box", class = "WARRIOR", level = 60, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge", note = "@TheTool raid lead" },
            { name = "Hammer Smith", class = "PALADIN", level = 42, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 0, 3, 2 }, note = "Healer >Tool Box" },
            { name = "Zélie Rune", class = "MAGE", level = 12, rank = 4, rankName = "Initiate",
                online = false, lastOnline = { 0, 0, 0, 0 } },
        },
    },
    Retail = {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal", note = "@TheTool raid lead" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 2, 0, 0 }, note = "Healer >Toolbox" },
            { name = "Visitor-Stormrage", class = "MAGE", level = 80, rank = 4, rankName = "Initiate",
                online = false, lastOnline = { 1, 0, 0, 0 } },
        },
    },
}

-- Installs the guild APIs. `world.guild` (nil = not in a guild) holds name,
-- realm, and members; `world.rosterReady = false` makes the roster report
-- nothing, as it does while it loads; `world.rosterRequests` counts refresh
-- requests.
local function installGuild(world, environment, profile)
    environment.IsInGuild = function()
        return world.guild ~= nil
    end
    environment.GetGuildInfo = function(unit)
        test.assertEqual("player", unit)
        if world.guild == nil then
            return nil
        end
        -- The realm is reported only for a guild on another realm.
        return world.guild.name, "Member", 3, nil
    end
    environment.GetRealmName = function()
        return world.guild and world.guild.realm or "Camelot"
    end
    environment.GetNumGuildMembers = function()
        if world.guild == nil or not world.rosterReady then
            return 0, 0, 0
        end
        return #world.guild.members, 1, 1
    end
    environment.GetGuildRosterInfo = function(index)
        local member = world.rosterReady and world.guild and world.guild.members[index]
        if not member then
            return nil
        end
        return member.name, member.rankName, member.rank, member.level, "Class", member.zone,
            member.note or "", "", member.online, 0, member.class, 0, 0, false, false, 0,
            "Player-1-" .. member.name
    end
    environment.GetGuildRosterLastOnline = function(index)
        local member = world.rosterReady and world.guild and world.guild.members[index]
        if not member or not member.lastOnline then
            return nil
        end
        return member.lastOnline[1], member.lastOnline[2], member.lastOnline[3], member.lastOnline[4]
    end
    world.rosterRequests = 0
    local function request()
        world.rosterRequests = world.rosterRequests + 1
    end
    -- Rank permission flags, as C_GuildInfo.GuildControlGetRankFlags reports
    -- them for a 1-based rank order; flag 11 is "view officer note". Ranks
    -- listed in `world.officerRanks` (0-based, like roster rank indexes)
    -- have it. WoW Forever is assumed to match Retail here.
    world.officerRanks = { [0] = true, [1] = true }
    local function rankFlags(rankOrder)
        local flags = {}
        local index
        for index = 1, 20 do
            flags[index] = false
        end
        flags[11] = world.officerRanks[rankOrder - 1] == true
        return flags
    end
    environment.C_GuildInfo = { GuildControlGetRankFlags = rankFlags }
    if profile == "Retail" then
        environment.C_GuildInfo.GuildRoster = request
        environment.GetNormalizedRealmName = function()
            return world.guild and string.gsub(world.guild.realm, "%s+", "") or "Camelot"
        end
    else
        environment.GuildRoster = request
    end
    -- The logged-in character, named as the roster spells it: the guild's
    -- first member unless `world.playerName` was set. Retail reports it as
    -- "Name", "Realm". WoW Forever reports only the first name, plus the
    -- server's realm, while its roster has "First Last" with no realm.
    local function playerRosterName()
        local fullName = world.playerName
        if fullName == nil and world.guild ~= nil then
            fullName = world.guild.members[1].name
        end
        return fullName
    end
    environment.UnitFullName = function(unit)
        test.assertEqual("player", unit)
        local fullName = playerRosterName()
        if fullName == nil then
            return nil
        end
        local name, realm = string.match(fullName, "^(.-)%-([^%-]*)$")
        name = name or fullName
        if profile ~= "Retail" then
            local serverRealm = world.guild and world.guild.realm or "Camelot"
            return string.match(name, "^(%S+)"), (string.gsub(serverRealm, "%s+", ""))
        end
        return name, realm
    end
    -- GUIDs are the same in UnitGUID and the roster, whatever the names.
    environment.UnitGUID = function(unit)
        test.assertEqual("player", unit)
        local fullName = playerRosterName()
        return fullName and ("Player-1-" .. fullName) or nil
    end
    -- A fake clock: `world.time` is wall-clock seconds, `world.precise` the
    -- millisecond profiler clock, and C_Timer callbacks wait in
    -- `world.timers` until Fixtures.runTimers delivers them.
    world.time = 1790000000
    world.precise = 0
    world.timers = {}
    environment.GetServerTime = function()
        return world.time
    end
    environment.debugprofilestop = function()
        return world.precise
    end
    environment.C_Timer = {
        After = function(seconds, callback)
            table.insert(world.timers, { at = world.time + seconds, callback = callback })
        end,
    }
    -- `world.inCombat = true` puts the player in combat.
    world.inCombat = false
    environment.InCombatLockdown = function()
        return world.inCombat
    end
    environment.RAID_CLASS_COLORS = {
        WARRIOR = { colorStr = "ffc69b6d" },
        PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
    }
end

local PROFILE_APIS = {
    -- Forever exposes the legacy metadata global and the newer slash API, and
    -- shares Retail's project constants, which must not make it Retail.
    Forever = function(world, environment, declaredClient)
        environment.GetAddOnMetadata = metadataReader(world, declaredClient)
        environment.WOW_PROJECT_ID = 1
        environment.WOW_PROJECT_MAINLINE = 1
        environment.RegisterNewSlashCommand = function(callback, command, alias)
            local key = string.upper(command)
            environment["SLASH_" .. key .. "1"] = "/" .. command
            environment["SLASH_" .. key .. "2"] = "/" .. alias
            environment.SlashCmdList[key] = callback
        end
    end,
    -- Retail also reports boss encounters (`world.inEncounter`) and keystone
    -- runs (`world.inKeystone`).
    Retail = function(world, environment, declaredClient)
        environment.C_AddOns = { GetAddOnMetadata = metadataReader(world, declaredClient) }
        environment.WOW_PROJECT_ID = 1
        environment.WOW_PROJECT_MAINLINE = 1
        world.inEncounter = false
        world.inKeystone = false
        environment.IsEncounterInProgress = function()
            return world.inEncounter
        end
        environment.C_ChallengeMode = {
            IsChallengeModeActive = function()
                return world.inKeystone
            end,
        }
    end,
}

-- Returns a WoW-like global environment for `profile`. `options.addonName`
-- picks the build (production by default), `options.declaredClient` overrides
-- the manifest's X-Client value (false removes it), and `options.database`
-- seeds that build's SavedVariables; see installLibraries for the library
-- options. `options.guild = false` puts the character outside any guild,
-- `options.guild = {...}` replaces the profile's sample guild, and
-- `options.rosterReady = false` starts with the roster still loading, and
-- `options.playerName` ("Name-Realm") picks the logged-in character. The SavedVariables global lives in
-- `world.database`, and every read or write of it through the environment is
-- counted in `world.savedVariableReads` and `world.savedVariableWrites`.
function Fixtures.newEnvironment(profile, options)
    options = options or {}
    local addonName = options.addonName or test.DEFAULT_ADDON_NAME
    local databaseName = addonName .. "DB"
    local world = {
        addonName = addonName,
        database = options.database,
        frames = {},
        loggedIn = false,
        manifestPath = Fixtures.manifestPath(profile, addonName),
        messages = {},
        playerName = options.playerName,
        savedVariableReads = 0,
        savedVariableWrites = 0,
    }
    world.manifest = Fixtures.manifestMetadata(world.manifestPath)

    local environment = {
        CreateFrame = function()
            return newFrame(world)
        end,
        DEFAULT_CHAT_FRAME = {
            AddMessage = function(_, message)
                table.insert(world.messages, message)
            end,
        },
        IsLoggedIn = function()
            return world.loggedIn
        end,
        SlashCmdList = {},
    }
    setmetatable(environment, {
        __index = function(_, key)
            if key == databaseName then
                world.savedVariableReads = world.savedVariableReads + 1
                return world.database
            end
            return _G[key]
        end,
        __newindex = function(target, key, value)
            if key == databaseName then
                world.savedVariableWrites = world.savedVariableWrites + 1
                world.database = value
                return
            end
            rawset(target, key, value)
        end,
    })
    environment._G = environment

    local declaredClient = options.declaredClient
    if declaredClient == nil then
        declaredClient = profile
    end
    PROFILE_APIS[profile](world, environment, declaredClient)
    installLibraries(world, environment, options)
    if options.guild ~= false then
        world.guild = options.guild or Fixtures.snapshot(Fixtures.GUILDS[profile])
    end
    world.rosterReady = options.rosterReady ~= false
    installGuild(world, environment, profile)

    world.environment = environment
    world.profile = profile
    return world
end

-- Loads the world's manifest files in order inside `world.environment`.
function Fixtures.loadAddon(world)
    local addon = {}
    local files = Fixtures.manifestFiles(world.manifestPath)
    local index
    for index = 1, #files do
        test.loadAddonFileInEnvironment(files[index], addon, world.environment, world.addonName)
    end
    world.addon = addon
    return addon
end

-- Delivers a client event to every frame that registered for it.
function Fixtures.fire(world, eventName, ...)
    local index
    for index = 1, #world.frames do
        local frame = world.frames[index]
        if frame.registeredEvents[eventName] and frame.handler ~= nil then
            frame.handler(frame, eventName, ...)
        end
    end
end

-- Moves the fake wall clock forward by `seconds` and delivers every timer
-- that comes due, including timers those callbacks schedule (as a frame
-- loop would). Returns how many callbacks ran.
function Fixtures.runTimers(world, seconds)
    world.time = world.time + (seconds or 0)
    local ran = 0
    while true do
        local dueIndex
        local index
        for index = 1, #world.timers do
            if world.timers[index].at <= world.time then
                dueIndex = index
                break
            end
        end
        if dueIndex == nil then
            return ran
        end
        local timer = table.remove(world.timers, dueIndex)
        timer.callback()
        ran = ran + 1
        if ran > 100000 then
            error("timers never settle")
        end
    end
end

-- A guild add-on channel shared by several worlds: what one sends reaches
-- them all, the sender included (the game echoes guild add-on messages), once
-- Fixtures.deliver runs. Returns the channel.
function Fixtures.newChannel(worlds)
    local channel = { queue = {}, worlds = worlds or {} }
    local index
    for index = 1, #channel.worlds do
        channel.worlds[index].channel = channel
    end
    return channel
end

function Fixtures.joinChannel(channel, world)
    table.insert(channel.worlds, world)
    world.channel = channel
end

-- Delivers queued messages, including any sent while delivering, as the
-- sender's full name. Returns how many were delivered.
function Fixtures.deliver(channel)
    local delivered = 0
    while channel.queue[1] ~= nil do
        local message = table.remove(channel.queue, 1)
        local sender = message.from.playerName or message.from.guild.members[1].name
        local index
        for index = 1, #channel.worlds do
            local handler = channel.worlds[index].commHandlers[message.prefix]
            if handler ~= nil then
                handler(message.prefix, message.text, message.distribution, sender)
            end
        end
        delivered = delivered + 1
        if delivered > 100000 then
            error("messages never settle")
        end
    end
    return delivered
end

-- Runs the build's slash command as a player typing it would.
function Fixtures.slash(world, input)
    local key = world.addon.Identity.slashKey
    world.environment.SlashCmdList[key](input)
end

function Fixtures.snapshot(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    local key, item
    for key, item in pairs(value) do
        copy[key] = Fixtures.snapshot(item)
    end
    return copy
end

function Fixtures.assertSameData(expected, actual, path)
    path = path or "data"
    test.assertEqual(type(expected), type(actual), path .. " type")
    if type(expected) ~= "table" then
        test.assertEqual(expected, actual, path)
        return
    end

    local key
    for key in pairs(expected) do
        Fixtures.assertSameData(expected[key], actual[key], path .. "." .. tostring(key))
    end
    for key in pairs(actual) do
        test.assertTrue(expected[key] ~= nil, path .. "." .. tostring(key) .. " was added")
    end
end

return Fixtures
