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
    -- Guild chat reaches everyone in the guild who's on the channel, the
    -- sender included, as the game echoes it.
    world.environment.SendChatMessage = function(text, chatType)
        table.insert(world.posted, chatType .. ":" .. text)
        if chatType == "GUILD" then
            local index
            for index = 1, #(channel and channel.worlds or { world }) do
                local listener = channel and channel.worlds[index] or world
                fixtures.fire(listener, "CHAT_MSG_GUILD", text, playerName)
            end
        end
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

    local before = #toolbox.sentMessages
    toolbox.addon.guildGreet:Greet(waiting(toolbox)[1].player)
    -- The "greeted" message goes out at once, at normal priority, not
    -- sync's bulk: under the live prefix and, for older versions, the sync
    -- prefix.
    test.assertEqual(before + 2, #toolbox.sentMessages)
    test.assertEqual("NORMAL", toolbox.sentMessages[before + 1].priority)
    test.assertEqual("NORMAL", toolbox.sentMessages[before + 2].priority)
    test.assertTrue(toolbox.sentMessages[before + 1].prefix ~= toolbox.sentMessages[before + 2].prefix)
    fixtures.deliver(channel)
    -- One greeting isn't enough to close the others' prompts, though each
    -- hears it twice: in guild chat and as the "greeted" message older
    -- versions need.
    test.assertEqual(1, #waiting(wrench))
    test.assertEqual(1, #toolbox.posted)
    local grandmaster = waiting(wrench)[1].player
    test.assertEqual(1, wrench.addon.guildGreet.tally:Count(grandmaster, wrench.time))

    hammer.addon.guildGreet:Greet(waiting(hammer)[1].player)
    fixtures.deliver(channel)
    test.assertEqual(0, #waiting(wrench))
    test.assertEqual(0, #wrench.posted)
end)

test.test("greeter coordination: a newcomer's prompt closes after the welcome cap, once the roster knows them", function()
    local channel = fixtures.newChannel()
    local names = { "Toolbox-Area52", "Hammer-Area52", "Wrench-Area52", "Grandmaster-Area52" }
    local worlds = {}
    local index
    for index = 1, #names do
        worlds[index] = login(channel, names[index])
    end
    fixtures.deliver(channel)

    -- Newt joins: everyone gets a prompt, then the roster update that comes
    -- with the join puts Newt in each user's database.
    for index = 1, #worlds do
        local world = worlds[index]
        table.insert(world.guild.members, { name = "Newt-Area52", class = "MAGE", level = 10, rank = 3,
            rankName = "Member", online = true, zone = "Dornogal" })
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Newt-Area52 has joined the guild.")
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world, 10)
        test.assertEqual(1, #waiting(world))
        test.assertEqual("join", waiting(world)[1].category)
    end
    local last = worlds[4]

    -- Two welcomes reach the greeting cap (2) but not the welcome cap (3).
    for index = 1, 2 do
        worlds[index].addon.guildGreet:Greet(waiting(worlds[index])[1].player)
        fixtures.deliver(channel)
    end
    test.assertEqual(1, #waiting(last))

    worlds[3].addon.guildGreet:Greet(waiting(worlds[3])[1].player)
    fixtures.deliver(channel)
    test.assertEqual(0, #waiting(last))
    test.assertEqual(0, #last.posted)
end)

test.test("greeter coordination: greetings typed by hand, with or without the add-on, close prompts", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    comesOnline(toolbox, "Grandmaster-Area52")
    comesOnline(hammer, "Grandmaster-Area52")

    -- Wrench has no add-on running here; Hammer types a greeting by hand.
    local index
    for index = 1, #channel.worlds do
        fixtures.fire(channel.worlds[index], "CHAT_MSG_GUILD", "welcome back grandmaster!", "Wrench-Area52")
        fixtures.fire(channel.worlds[index], "CHAT_MSG_GUILD", "o/ Grandmaster", "Hammer-Area52")
    end

    test.assertEqual(0, #waiting(toolbox))
    test.assertEqual(0, #waiting(hammer))
    test.assertEqual(0, #toolbox.posted)
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
