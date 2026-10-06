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
}

-- A fake LibStub registry and Details! Framework global. `options.libStub =
-- false` omits LibStub, `options.missingLibraries` lists majors left
-- unregistered, and `options.frameworkFailed` leaves the framework half
-- loaded (registered, but its core file stopped before finishing).
local function installLibraries(environment, options)
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

-- Sample guilds per client: Forever names are "First Last", Retail names are
-- one word, and both carry a realm suffix as the roster API reports them.
Fixtures.GUILDS = {
    Forever = {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box-Camelot", class = "WARRIOR", level = 60, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge" },
            { name = "Hammer Smith-Camelot", class = "PALADIN", level = 42, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 0, 3, 2 } },
            { name = "Zélie Rune-Camelot", class = "MAGE", level = 12, rank = 4, rankName = "Initiate",
                online = false, lastOnline = { 0, 0, 0, 0 } },
        },
    },
    Retail = {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 2, 0, 0 } },
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
            "", "", member.online, 0, member.class
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
    if profile == "Retail" then
        environment.C_GuildInfo = { GuildRoster = request }
        environment.GetNormalizedRealmName = function()
            return world.guild and string.gsub(world.guild.realm, "%s+", "") or "Camelot"
        end
    else
        environment.GuildRoster = request
    end
    environment.GetServerTime = function()
        return 1790000000
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
    Retail = function(world, environment, declaredClient)
        environment.C_AddOns = { GetAddOnMetadata = metadataReader(world, declaredClient) }
        environment.WOW_PROJECT_ID = 1
        environment.WOW_PROJECT_MAINLINE = 1
    end,
}

-- Returns a WoW-like global environment for `profile`. `options.addonName`
-- picks the build (production by default), `options.declaredClient` overrides
-- the manifest's X-Client value (false removes it), and `options.database`
-- seeds that build's SavedVariables; see installLibraries for the library
-- options. `options.guild = false` puts the character outside any guild,
-- `options.guild = {...}` replaces the profile's sample guild, and
-- `options.rosterReady = false` starts with the roster still loading. The SavedVariables global lives in
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
    installLibraries(environment, options)
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
