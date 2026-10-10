local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Guild Greet users in one guild, each running the whole add-on in its own
-- fake client, joined by one fake guild add-on channel. Grandmaster is
-- offline when they log in, then comes online.

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
            { name = "Wrench-Area52", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
            { name = "Grandmaster-Area52", class = "WARRIOR", level = 80, rank = 0, rankName = "Guild Master",
                online = false, lastOnline = { 0, 0, 0, 5 } },
        },
    }
end

local function login(channel, playerName, options)
    options = options or {}
    local world = fixtures.newEnvironment("Retail", {
        guild = guild(),
        playerName = playerName,
        missingLibraries = options.missingLibraries,
    })
    world.posted = {}
    world.environment.SendChatMessage = function(text, chatType)
        table.insert(world.posted, chatType .. ":" .. text)
    end
    world.environment.ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
    if channel ~= nil then
        fixtures.joinChannel(channel, world)
    end
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

-- Someone comes online, and the 5 to 10 seconds before their prompt shows
-- pass.
local function comesOnline(world, name)
    fixtures.fire(world, "CHAT_MSG_SYSTEM", "|Hplayer:" .. name .. "|h[" .. name .. "]|h has come online.")
    fixtures.runTimers(world, 10)
end

local function waiting(world)
    local greet = world.addon.guildGreet
    return greet.queue:Visible(world.time)
end

test.test("greeter coordination: two greetings close everyone else's prompt", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")
    fixtures.deliver(channel)

    local index
    for index = 1, #channel.worlds do
        comesOnline(channel.worlds[index], "Grandmaster-Area52")
        test.assertEqual(1, #waiting(channel.worlds[index]))
    end

    toolbox.addon.guildGreet:Greet(waiting(toolbox)[1].player)
    fixtures.deliver(channel)
    -- One greeting isn't enough to close the others' prompts.
    test.assertEqual(1, #waiting(wrench))
    test.assertEqual(1, #toolbox.posted)

    -- The "greeted" message goes out at normal priority, not sync's bulk.
    local last = toolbox.sentMessages[#toolbox.sentMessages]
    test.assertEqual("NORMAL", last.priority)

    hammer.addon.guildGreet:Greet(waiting(hammer)[1].player)
    fixtures.deliver(channel)
    test.assertEqual(0, #waiting(wrench))
    test.assertEqual(0, #wrench.posted)
end)

test.test("greeter coordination: without the comm libraries, Greet still works", function()
    local world = login(nil, "Toolbox-Area52", { missingLibraries = { "AceComm-3.0" } })

    comesOnline(world, "Grandmaster-Area52")
    test.assertEqual(1, #waiting(world))
    world.addon.guildGreet:Greet(waiting(world)[1].player)

    -- The greeting is picked at random; it names Grandmaster in guild chat.
    test.assertEqual(1, #world.posted)
    test.assertEqual("GUILD:", string.sub(world.posted[1], 1, 6))
    test.assertContains(world.posted[1], "Grandmaster")
    test.assertEqual(0, #waiting(world))
end)
