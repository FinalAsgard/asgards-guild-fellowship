local test = require("tests.test_helper")

local START = 1790000000
local MINUTE = 60

-- A policy over a fixed world: `players` maps character keys to player ids
-- (a key left out is unknown to the database), `members` lists who is in the
-- guild, and `own` lists the user's characters.
local function newPolicy(world)
    local addon = test.newAddon("Core/GreetPolicy.lua")
    world.enabled = world.enabled ~= false
    return addon.GreetPolicy.Create({
        playerOf = function(key)
            return world.players[key]
        end,
        isMember = function(key)
            return world.members[key] == true
        end,
        isOwn = function(key)
            return world.own ~= nil and world.own[key] == true
        end,
        enabled = function()
            return world.enabled
        end,
    }), addon
end

local function guild()
    return {
        players = { me = 1, myalt = 1, anvil = 2, tongs = 2, bolt = 3 },
        members = { me = true, myalt = true, anvil = true, tongs = true, bolt = true, stranger = true },
        own = { me = true, myalt = true },
    }
end

local function category(prompt)
    return prompt and prompt.category or nil
end

test.test("greet policy: nothing is prompted before the roster first loads", function()
    local policy = newPolicy(guild())

    test.assertEqual(nil, policy:CameOnline("anvil", START))
    policy:Seed({ "me" })
    -- The early login wasn't recorded, so the next one is still a first.
    test.assertEqual("login", category(policy:CameOnline("anvil", START + 1)))
end)

test.test("greet policy: the first login seen this session gets a login prompt", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me" })

    local prompt = policy:CameOnline("bolt", START)

    test.assertEqual("login", prompt.category)
    test.assertEqual(3, prompt.player)
    test.assertEqual("bolt", prompt.key)
    -- Coming online again without going offline isn't a new arrival.
    test.assertEqual(nil, policy:CameOnline("bolt", START + 5))
end)

test.test("greet policy: players online when the roster loads are never prompted for logging in", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me", "anvil" })

    test.assertEqual(nil, policy:CameOnline("anvil", START))
    test.assertEqual(nil, policy:CameOnline("tongs", START))
end)

test.test("greet policy: back 15 minutes after logging off is a welcome back; sooner is a relog", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me", "anvil", "bolt" })

    policy:WentOffline("anvil", START)
    test.assertEqual(nil, policy:CameOnline("anvil", START + 15 * MINUTE - 1))

    policy:WentOffline("bolt", START)
    test.assertEqual("welcomeBack", category(policy:CameOnline("bolt", START + 15 * MINUTE)))

    -- The relog is over; a later return is measured from the next logoff.
    policy:WentOffline("anvil", START + 20 * MINUTE)
    test.assertEqual("welcomeBack", category(policy:CameOnline("anvil", START + 40 * MINUTE)))
end)

test.test("greet policy: switching to an alt counts as the same player", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me", "anvil" })

    policy:WentOffline("anvil", START)
    test.assertEqual(nil, policy:CameOnline("tongs", START + 2 * MINUTE))

    policy:WentOffline("tongs", START + 10 * MINUTE)
    test.assertEqual("welcomeBack", category(policy:CameOnline("anvil", START + 30 * MINUTE)))
end)

test.test("greet policy: a first login seen on an alt prompts once for the player", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me" })

    test.assertEqual("login", category(policy:CameOnline("tongs", START)))
    test.assertEqual(nil, policy:CameOnline("anvil", START + MINUTE))
end)

test.test("greet policy: the user's own characters, and people outside the guild, are never prompted", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me" })

    test.assertEqual(nil, policy:CameOnline("myalt", START))
    test.assertEqual(nil, policy:CameOnline("friend", START))
end)

test.test("greet policy: a character the database doesn't know is its own player", function()
    local policy = newPolicy(guild())
    policy:Seed({ "me" })

    local prompt = policy:CameOnline("stranger", START)

    test.assertEqual("login", prompt.category)
    test.assertEqual("character:stranger", prompt.player)
end)

test.test("greet policy: with Guild Greet off nobody is prompted, but logins are still recorded", function()
    local world = guild()
    world.enabled = false
    local policy = newPolicy(world)
    policy:Seed({ "me" })

    test.assertEqual(nil, policy:CameOnline("bolt", START))
    world.enabled = true
    -- Bolt's login was seen while it was off, so it isn't a first login now.
    test.assertEqual(nil, policy:CameOnline("bolt", START + MINUTE))
end)

test.test("greet policy: a failing lookup never raises", function()
    local addon = test.newAddon("Core/GreetPolicy.lua")
    local policy = addon.GreetPolicy.Create({
        playerOf = function() error("boom") end,
        isMember = function() return true end,
        isOwn = function() error("boom") end,
        enabled = function() error("boom") end,
    })
    policy:Seed({ "me" })

    local ok, prompt = pcall(policy.CameOnline, policy, "bolt", START)

    test.assertTrue(ok)
    test.assertEqual(nil, prompt)
end)
