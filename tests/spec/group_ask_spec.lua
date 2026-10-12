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

-- Confirm, then post ------------------------------------------------------------

local function newWindow(party)
    local addon = load()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    environment.DetailsFramework = {
        CreateSimplePanel = function()
            local panel = environment.CreateFrame("Frame", nil, nil)
            rawset(panel, "IsShown", function(self) return self.shown end)
            return panel
        end,
    }
    local world = { posted = {} }
    local roles = addon.RoleCatalog.For("forever")
    world.session = addon.GroupSession.Create(roles)
    world.window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES }) end,
        playerLevel = function() return 20 end,
        session = world.session,
        roles = roles,
        syncParty = function()
            if world.session:IsActive() then
                world.session:UpdateParty(party, #party > 1)
            end
        end,
        postToGuild = function(text)
            table.insert(world.posted, text)
        end,
    })
    world.window:Toggle()
    world.window:Pick("dm")
    return world
end

test.test("ask in guild: the button asks first, and Post sends the one line", function()
    local world = newWindow({ member("Me", "WARRIOR", { isPlayer = true }) })
    local window = world.window
    test.assertTrue(window.askButton.shown)
    test.assertFalse(window.confirm.shown)

    window.askButton.scripts.OnClick()

    test.assertEqual(0, #world.posted)
    test.assertTrue(window.confirm.shown)
    test.assertContains(window.confirmText.text, "LF healer and 3 DPS for The Deadmines (17–26), whisper me!")

    window.confirmPost.scripts.OnClick()

    test.assertEqual(1, #world.posted)
    test.assertEqual("LF healer and 3 DPS for The Deadmines (17–26), whisper me!", world.posted[1])
    test.assertFalse(window.confirm.shown)
    -- Posting again needs another confirmation.
    window.confirmPost.scripts.OnClick()
    test.assertEqual(1, #world.posted)
end)

test.test("ask in guild: Cancel posts nothing", function()
    local world = newWindow({ member("Me", "WARRIOR", { isPlayer = true }) })
    local window = world.window

    window.askButton.scripts.OnClick()
    window.confirmCancel.scripts.OnClick()

    test.assertEqual(0, #world.posted)
    test.assertFalse(window.confirm.shown)
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

test.test("ask in guild: the composed add-on posts the line to guild chat", function()
    local world = fixtures.newEnvironment("Forever")
    local addon = fixtures.loadAddon(world)
    local options
    addon.GroupFinderWindow.Create = function(_, given)
        options = given
        return { Toggle = function() return true end, Refresh = function() end }
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.slash(world, "group")

    options.postToGuild("LF healer for The Deadmines (17–26), whisper me!")

    test.assertEqual("LF healer for The Deadmines (17–26), whisper me!", world.chat[1].text)
    test.assertEqual("GUILD", world.chat[1].chatType)
end)
