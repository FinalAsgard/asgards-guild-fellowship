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

-- The pop-up ---------------------------------------------------------------------

local function newWindow(party)
    local addon = load()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local world = { posted = {} }
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
        postToGuild = function(text)
            table.insert(world.posted, text)
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

test.test("ask in guild: the button opens a pop-up with the line in a text box, and posts nothing yet", function()
    local world = solo()
    local window = world.window
    test.assertTrue(window.askButton.shown)
    test.assertFalse(window:IsAsking())

    window.askButton.scripts.OnClick()

    test.assertTrue(window:IsAsking())
    test.assertTrue(window.ask.frame.shown)
    test.assertEqual(LINE, window.ask.box:GetText())
    -- The cursor waits at the end, ready to add to the line.
    test.assertEqual(string.len(LINE), window.ask.box.cursor)
    -- Letters, not bytes: the range's dash is one letter.
    test.assertEqual("58/255", window.ask.count.text)
    local addon = load()
    test.assertEqual(5, addon.GroupFinderWindow.Letters("Zélie"))
    test.assertEqual(3, addon.GroupFinderWindow.Letters("1–2"))
    test.assertTrue(window.ask.canPost)
    test.assertEqual(0, #world.posted)
end)

test.test("ask in guild: Post sends the line as edited, once", function()
    local world = solo()
    local window = world.window
    window.askButton.scripts.OnClick()

    window.ask.box:SetText("LF healer for Deadmines, ask Toolbox!")
    window.ask.box.scripts.OnTextChanged()
    test.assertEqual("37/255", window.ask.count.text)
    window.ask.post.scripts.OnClick()

    test.assertEqual(1, #world.posted)
    test.assertEqual("LF healer for Deadmines, ask Toolbox!", world.posted[1])
    test.assertFalse(window:IsAsking())
    test.assertFalse(window.ask.frame.shown)
    -- Posting again needs the pop-up again.
    test.assertFalse(window:PostAsk())
    window.ask.box.scripts.OnEnterPressed()
    test.assertEqual(1, #world.posted)
end)

test.test("ask in guild: Enter posts and Escape cancels", function()
    local world = solo()
    local window = world.window

    window.askButton.scripts.OnClick()
    window.ask.box.scripts.OnEscapePressed()
    test.assertFalse(window:IsAsking())
    test.assertEqual(0, #world.posted)

    window.askButton.scripts.OnClick()
    window.ask.box.scripts.OnEnterPressed()
    test.assertEqual(LINE, world.posted[1])
    test.assertFalse(window:IsAsking())
end)

test.test("ask in guild: Cancel posts nothing", function()
    local world = solo()
    local window = world.window

    window.askButton.scripts.OnClick()
    window.ask.cancel.scripts.OnClick()

    test.assertEqual(0, #world.posted)
    test.assertFalse(window:IsAsking())
    test.assertFalse(window.ask.frame.shown)
end)

test.test("ask in guild: an empty line can't be posted, and line breaks become spaces", function()
    local world = solo()
    local window = world.window
    window.askButton.scripts.OnClick()

    window.ask.box:SetText("   ")
    window.ask.box.scripts.OnTextChanged()
    test.assertFalse(window.ask.canPost)
    test.assertFalse(window:PostAsk())
    test.assertTrue(window:IsAsking())
    test.assertEqual(0, #world.posted)

    -- A pasted line break is taken out as the text changes.
    window.ask.box:SetText("LF tank\nfor Deadmines")
    window.ask.box.scripts.OnTextChanged()
    test.assertEqual("LF tank for Deadmines", window.ask.box:GetText())
    window.ask.post.scripts.OnClick()
    test.assertEqual("LF tank for Deadmines", world.posted[1])

    local addon = load()
    test.assertEqual("a b", addon.GroupFinderWindow.ChatLine("  a\r\n\nb  "))
    test.assertEqual(nil, addon.GroupFinderWindow.ChatLine("\n \n"))
end)

test.test("ask in guild: each opening starts from a fresh line", function()
    local world = solo()
    local window = world.window
    window.askButton.scripts.OnClick()
    window.ask.box:SetText("something else")
    window.ask.cancel.scripts.OnClick()

    window.askButton.scripts.OnClick()

    test.assertEqual(LINE, window.ask.box:GetText())
end)

test.test("ask in guild: the pop-up closes when the group ends or the window closes", function()
    local world = solo()
    local window = world.window

    window.askButton.scripts.OnClick()
    window.endButton.scripts.OnClick()
    test.assertFalse(window:IsAsking())

    window:Pick("dm")
    window.askButton.scripts.OnClick()
    window.panel.hooks.OnHide()
    test.assertFalse(window:IsAsking())
    test.assertEqual(0, #world.posted)
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
    addon.GroupFinderWindow.Create = function(_, _, given)
        options = given
        return { Toggle = function() return true end, Refresh = function() end }
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.openGroupFinder(world)

    options.postToGuild("LF healer for The Deadmines (17–26), whisper me!")

    test.assertEqual("LF healer for The Deadmines (17–26), whisper me!", world.chat[1].text)
    test.assertEqual("GUILD", world.chat[1].chatType)
end)
