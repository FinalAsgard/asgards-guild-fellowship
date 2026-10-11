local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Guild Recruit users in one guild, each running the whole add-on in its own
-- fake client, joined by one fake guild add-on channel. Every one of them can
-- invite, has opted in, and has an ad.

local AD = "Knights of Camelot is recruiting!"

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Anvil-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
            { name = "Wrench-Area52", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Isle of Dorn" },
        },
    }
end

-- Logs `playerName` in at `zone` ({ mapID, name }), in Trade when `inCity`,
-- `secondsLater` after the channel's clock (`channel.time`). Asks wait
-- `askWait` seconds (none when nil). The prompts the add-on last drew are in
-- `world.shown`.
local function login(channel, playerName, zone, inCity, askWait, secondsLater, guildData)
    local world = fixtures.newEnvironment("Retail", { guild = guildData or guild(), playerName = playerName })
    world.time = (channel.time or world.time) + (secondsLater or 0)
    channel.time = world.time
    world.askWait = askWait
    world.zone = { mapID = zone[1], name = zone[2] }
    world.channels = { [1] = "General - " .. zone[2] }
    if inCity then
        world.channels[2] = "Trade - City"
    end
    fixtures.joinChannel(channel, world)
    fixtures.loadAddon(world)
    world.addon.guildRecruit.showDelay = function()
        return 0
    end
    world.addon.guildRecruit.askWait = function()
        return world.askWait or 0
    end
    world.shown = {}
    world.addon.guildRecruit.view = {
        Show = function(_, prompts, handlers)
            world.shown = prompts
            world.handlers = handlers
        end,
    }
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    world.addon.settings:Set("recruitAd", AD)
    world.addon.settings:Set("recruitOptIn", true)
    return world
end

local function promptFor(world, key)
    local index
    for index = 1, #world.shown do
        if world.shown[index].key == key then
            return world.shown[index]
        end
    end
    return nil
end

local DORNOGAL = { 2339, "Dornogal" }
local ISLE = { 2248, "Isle of Dorn" }

test.test("recruit coordination: the first post closes the other user's prompt, and nobody double-posts", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52", DORNOGAL, true)
    local anvil = login(channel, "Anvil-Area52", DORNOGAL, true)
    fixtures.deliver(channel)

    test.assertTrue(promptFor(toolbox, "trade") ~= nil)
    test.assertTrue(promptFor(anvil, "trade") ~= nil)

    toolbox.handlers.post("trade")
    fixtures.deliver(channel)

    test.assertEqual(nil, promptFor(toolbox, "trade"))
    test.assertEqual(nil, promptFor(anvil, "trade"))
    -- A late press on the closed prompt posts nothing.
    test.assertEqual(nil, anvil.addon.guildRecruit:Post("trade"))
    test.assertEqual(1, #toolbox.chat)
    test.assertEqual(0, #anvil.chat)
    -- Both still have their General prompt.
    test.assertTrue(promptFor(anvil, "general:map:2339") ~= nil)
end)

test.test("recruit coordination: an ad heard in another zone is remembered for when the user goes there", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52", DORNOGAL, false)
    local wrench = login(channel, "Wrench-Area52", ISLE, false)
    fixtures.deliver(channel)

    toolbox.handlers.post("general:map:2339")
    fixtures.deliver(channel)

    test.assertEqual(1, #wrench.shown)
    wrench.zone = { mapID = DORNOGAL[1], name = DORNOGAL[2] }
    wrench.channels = { [1] = "General - Dornogal" }
    fixtures.fire(wrench, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual(0, #wrench.shown)
end)

test.test("recruit coordination: every user posting what's due leaves each channel posted once", function()
    local channel = fixtures.newChannel()
    local users = {
        login(channel, "Toolbox-Area52", DORNOGAL, true),
        login(channel, "Anvil-Area52", DORNOGAL, true),
        login(channel, "Wrench-Area52", DORNOGAL, true),
    }
    fixtures.deliver(channel)

    -- Each user in turn presses Post on everything still on screen.
    local index
    for index = 1, #users do
        local user = users[index]
        while #user.shown > 0 do
            user.handlers.post(user.shown[1].key)
            fixtures.deliver(channel)
        end
    end

    local posts = 0
    for index = 1, #users do
        posts = posts + #users[index].chat
        test.assertEqual(0, #users[index].shown)
    end
    test.assertEqual(2, posts)
end)

-- Moves every world's clock on by one second at a time, delivering add-on
-- messages after each step, for `seconds` seconds.
local function tick(channel, seconds)
    local step, index
    for step = 1, seconds do
        for index = 1, #channel.worlds do
            fixtures.runTimers(channel.worlds[index], 1)
        end
        fixtures.deliver(channel)
    end
end

-- Answers from this world wait `seconds` seconds.
local function answersAfter(world, seconds)
    world.environment.math = setmetatable({ random = function() return seconds end }, { __index = math })
end

local function channelTimes(channel)
    local count = 0
    local index, sentIndex
    for index = 1, #channel.worlds do
        local world = channel.worlds[index]
        local serializer = world.environment.LibStub.libs["AceSerializer-3.0"]
        for sentIndex = 1, #world.sentMessages do
            local _, message = serializer:Deserialize(world.sentMessages[sentIndex].text)
            if type(message) == "table" and message.t == "channel-time" then
                count = count + 1
            end
        end
    end
    return count
end

test.test("recruit coordination: logging in where someone just posted asks, hears back, and isn't prompted", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52", DORNOGAL, false)
    fixtures.deliver(channel)
    toolbox.handlers.post("general:map:2339")
    fixtures.deliver(channel)

    local anvil = login(channel, "Anvil-Area52", DORNOGAL, false, 8, 60)
    toolbox.time = anvil.time
    tick(channel, 10)

    test.assertEqual(0, #anvil.shown)
    test.assertEqual(0, #anvil.chat)
    test.assertEqual(1, channelTimes(channel))
end)

test.test("recruit coordination: with several add-on users holding the time, only the first answers", function()
    local channel = fixtures.newChannel()
    local holders = {
        login(channel, "Toolbox-Area52", DORNOGAL, false),
        login(channel, "Wrench-Area52", DORNOGAL, false),
    }
    fixtures.deliver(channel)
    holders[1].handlers.post("general:map:2339")
    fixtures.deliver(channel)
    answersAfter(holders[1], 4)
    answersAfter(holders[2], 2)

    local anvil = login(channel, "Anvil-Area52", DORNOGAL, false, 8)
    tick(channel, 10)

    test.assertEqual(1, channelTimes(channel))
    test.assertEqual(0, #anvil.shown)
end)

test.test("recruit coordination: when nobody holds a fresh time, the asker is prompted after the wait", function()
    local channel = fixtures.newChannel()
    login(channel, "Toolbox-Area52", ISLE, false)
    fixtures.deliver(channel)

    local anvil = login(channel, "Anvil-Area52", DORNOGAL, false, 8)
    tick(channel, 7)
    test.assertEqual(0, #anvil.shown)
    tick(channel, 1)

    test.assertEqual(1, #anvil.shown)
    test.assertEqual(0, channelTimes(channel))
end)

local function sentConfigs(channel)
    local count = 0
    local index, sentIndex
    for index = 1, #channel.worlds do
        local world = channel.worlds[index]
        local serializer = world.environment.LibStub.libs["AceSerializer-3.0"]
        for sentIndex = 1, #world.sentMessages do
            local _, message = serializer:Deserialize(world.sentMessages[sentIndex].text)
            if type(message) == "table" and message.t == "config" then
                count = count + 1
            end
        end
    end
    return count
end

-- Toolbox and Wrench are both officers here.
local function twoOfficers()
    local data = guild()
    data.members[3].rank = 1
    data.members[3].rankName = "Officer"
    return data
end

test.test("recruit coordination: an officer's guild ad reaches members online now", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52", DORNOGAL, false)
    local anvil = login(channel, "Anvil-Area52", DORNOGAL, false)
    fixtures.deliver(channel)

    toolbox.addon.settings:Set("recruitGuildAd", "Knights recruit!")
    fixtures.deliver(channel)

    test.assertEqual("Knights recruit!", anvil.addon.guildRecruit:Config():Get("guildAd"))
end)

test.test("recruit coordination: a member logging in later catches up on the guild ad, from one officer", function()
    local channel = fixtures.newChannel()
    local officers = {
        login(channel, "Toolbox-Area52", ISLE, false, nil, nil, twoOfficers()),
        login(channel, "Wrench-Area52", ISLE, false, nil, nil, twoOfficers()),
    }
    fixtures.deliver(channel)
    officers[1].addon.settings:Set("recruitGuildAd", "Knights recruit!")
    fixtures.deliver(channel)
    test.assertEqual("Knights recruit!", officers[2].addon.guildRecruit:Config():Get("guildAd"))
    answersAfter(officers[1], 4)
    answersAfter(officers[2], 2)
    local before = sentConfigs(channel)

    local anvil = login(channel, "Anvil-Area52", DORNOGAL, false, nil, nil, twoOfficers())
    tick(channel, 10)

    test.assertEqual("Knights recruit!", anvil.addon.guildRecruit:Config():Get("guildAd"))
    test.assertEqual(before + 1, sentConfigs(channel))
end)
