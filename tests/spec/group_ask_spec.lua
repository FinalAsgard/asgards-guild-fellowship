local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local DEADMINES = { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 }

local function load()
    return test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/DungeonCatalog.lua",
        "Adapters/GroupFinderWindow.lua")
end

local function member(key, classToken, fields)
    local made = { key = key, name = key, classToken = classToken, inGuild = true }
    local name, value
    for name, value in pairs(fields or {}) do
        made[name] = value
    end
    return made
end

local function newSession(addon, party)
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    session:UpdateParty(party, #party > 1)
    return session
end

-- The line --------------------------------------------------------------------

test.test("ask in guild: the line names the open roles, the dungeon and its range", function()
    local addon = load()

    local solo = newSession(addon, { member("Me", "WARRIOR", { isPlayer = true }) })
    test.assertEqual("LF healer and 3 DPS for The Deadmines (17–26), whisper me!", solo:AskLine(DEADMINES))

    local nearly = newSession(addon, {
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
        member("Shot", "HUNTER"),
    })
    test.assertEqual("LF healer for The Deadmines (17–26), whisper me!", nearly:AskLine(DEADMINES))

    local priest = newSession(addon, {
        member("Me", "PRIEST", { isPlayer = true }),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
    })
    test.assertEqual("LF tank and DPS for The Deadmines (17–26), whisper me!", priest:AskLine(DEADMINES))

    local fresh = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    fresh:Start("dm")
    test.assertEqual("LF tank, healer and 3 DPS for The Deadmines (17–26), whisper me!", fresh:AskLine(DEADMINES))
end)

test.test("ask in guild: no line once every role is filled", function()
    local addon = load()
    local full = newSession(addon, {
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Cleric", "PRIEST"),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
        member("Shot", "HUNTER"),
    })

    test.assertEqual(nil, full:AskLine(DEADMINES))
    test.assertEqual(0, #full:OpenRoles())
end)

-- The chat box ------------------------------------------------------------------

local function newWindow(party)
    local addon = load()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local world = { opened = {} }
    local roles = addon.RoleCatalog.For("forever")
    world.session = addon.GroupSession.Create(roles)
    world.window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES }) end,
        playerLevel = function() return 20 end,
        session = world.session,
        roles = roles,
        syncParty = function()
            if world.session:IsActive() then
                world.session:UpdateParty(party, #party > 1)
            end
        end,
        openGuildChat = function(text)
            table.insert(world.opened, text)
        end,
    })
    world.window:Opened()
    world.window:Pick("dm")
    return world
end
local LINE = "LF healer and 3 DPS for The Deadmines (17–26), whisper me!"

local function solo()
    return newWindow({ member("Me", "WARRIOR", { isPlayer = true }) })
end

test.test("ask in guild: the button opens guild chat with the line typed in, and sends nothing itself", function()
    local world = solo()
    local window = world.window
    test.assertTrue(window.askButton.shown)

    window.askButton.scripts.OnClick()

    test.assertEqual(1, #world.opened)
    test.assertEqual(LINE, world.opened[1])
end)

test.test("ask in guild: each press offers the line for the roles still open", function()
    local world = newWindow({
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
        member("Shot", "HUNTER"),
    })

    world.window.askButton.scripts.OnClick()

    test.assertEqual("LF healer for The Deadmines (17–26), whisper me!", world.opened[1])
end)

test.test("ask in guild: no button once the group is complete", function()
    local world = newWindow({
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Cleric", "PRIEST"),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
        member("Shot", "HUNTER"),
    })

    test.assertFalse(world.window.askButton.shown)
    test.assertTrue(world.window.completeText.shown)
end)

test.test("ask in guild: the composed add-on opens the game's chat box on guild chat, and sends nothing", function()
    local world = fixtures.newEnvironment("Forever")
    local opened = {}
    world.environment.ChatFrame_OpenChat = function(text)
        table.insert(opened, text)
    end
    local addon = fixtures.loadAddon(world)
    local options
    addon.GroupFinderWindow.Create = function(_, _, given)
        options = given
        return { Refresh = function() end }
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.openGroupFinder(world)

    options.openGuildChat("LF healer for The Deadmines (17–26), whisper me!")

    test.assertEqual("/g LF healer for The Deadmines (17–26), whisper me!", opened[1])
    -- The player sends it from the chat box; the add-on posts nothing.
    test.assertEqual(0, #world.chat)
end)

test.test("adapter: guild chat opens through the client's chat box call", function()
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    local opened = {}
    local retail = addon.Compatibility.Create({
        ChatFrameUtil = { OpenChat = function(text) table.insert(opened, "util " .. text) end },
        ChatFrame_OpenChat = function(text) table.insert(opened, "global " .. text) end,
    })
    local older = addon.Compatibility.Create({
        ChatFrame_OpenChat = function(text) table.insert(opened, "global " .. text) end,
    })

    test.assertTrue(retail:OpenGuildChat("LF tank"))
    test.assertTrue(older:OpenGuildChat("LF tank"))
    test.assertEqual("util /g LF tank", opened[1])
    test.assertEqual("global /g LF tank", opened[2])
    test.assertFalse(older:OpenGuildChat(""))
    test.assertFalse(addon.Compatibility.Create({}):OpenGuildChat("LF tank"))
end)

test.test("adapter: a whisper opens through the client's send-tell call, or the chat box", function()
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    local opened = {}
    local retail = addon.Compatibility.Create({
        ChatFrameUtil = { SendTell = function(name) table.insert(opened, "util " .. name) end },
        ChatFrame_SendTell = function(name) table.insert(opened, "global " .. name) end,
    })
    local older = addon.Compatibility.Create({
        ChatFrame_SendTell = function(name) table.insert(opened, "global " .. name) end,
    })
    local bare = addon.Compatibility.Create({
        ChatFrame_OpenChat = function(text) table.insert(opened, "chat " .. text) end,
    })

    test.assertTrue(retail:OpenWhisper("Bolt-Area52"))
    test.assertTrue(older:OpenWhisper("Tool Box"))
    test.assertTrue(bare:OpenWhisper("Bolt"))
    test.assertEqual("util Bolt-Area52", opened[1])
    test.assertEqual("global Tool Box", opened[2])
    test.assertEqual("chat /w Bolt ", opened[3])
    test.assertFalse(older:OpenWhisper(""))
    test.assertFalse(addon.Compatibility.Create({}):OpenWhisper("Bolt"))
end)
