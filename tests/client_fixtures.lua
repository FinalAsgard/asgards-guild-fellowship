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

function Fixtures.manifestFiles(path)
    local files = {}
    local line
    for line in io.lines(path) do
        line = line:gsub("%s+$", "")
        if string.sub(line, 1, 2) ~= "##" and string.match(line, "%.lua$") then
            table.insert(files, line)
        end
    end
    return files
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
-- seeds that build's SavedVariables. The SavedVariables global lives in
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
