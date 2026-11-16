local test = require("tests.test_helper")

-- Several guildmates running Guild Greet on one shared clock, with guild
-- chat and the add-on channel between them. Each greeter presses Greet as
-- soon as a prompt of theirs unlocks, so the specs see what anti-spam mode
-- does to a busy night: when it turns on and off on each add-on, and how
-- often greetings go out.

local START = 1790000000
local RULES = { twoPartNames = false, homeRealm = "Area52" }
local GREETERS = { "Alpha", "Bravo", "Charlie", "Delta", "Echo" }
local ARRIVALS = {
    "Ash", "Birch", "Cedar", "Dogwood", "Elm", "Fir", "Ginkgo", "Hazel", "Ivy", "Juniper", "Kapok", "Larch",
    "Maple", "Nutmeg", "Oak", "Pine",
}

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/GreetPolicy.lua",
        "Core/GreetingLibrary.lua",
        "Core/GreetPromptQueue.lua",
        "Core/GreetTally.lua",
        "Core/GreetWeight.lua",
        "Core/AntiSpamMonitor.lua",
        "Core/GreetStats.lua",
        "Core/GuildGreet.lua"
    )
end

local function full(name)
    return name .. "-Area52"
end

-- The shared world: the clock, guild chat lines and add-on messages
-- waiting to be heard, and every greeting posted.
local function newWorld()
    return { time = START, add_ons = {}, chat = {}, messages = {}, posted = {} }
end

-- Greeter `name`'s add-on. Its roster loads at the current time; until
-- then it hears nothing. `stagger` is the random wait it draws.
local function join(world, name, stagger)
    local addon = load()
    local store = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
    local partition = store:Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local members = {}
    local _, member
    for _, member in ipairs(GREETERS) do
        members[normalizer:Key(full(member))] = { name = full(member), note = "", level = 60 }
    end
    for _, member in ipairs(ARRIVALS) do
        members[normalizer:Key(full(member))] = { name = full(member), note = "", level = 60 }
    end
    addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition, members = members, normalizer = normalizer,
        rules = RULES, mode = "initial", now = world.time,
    }))
    local client = { name = name, timers = {}, shown = {}, greeted = 0 }
    client.greet = addon.GuildGreet.Create({
        context = function()
            return partition, normalizer
        end,
        selfKey = function()
            return normalizer:Key(full(name))
        end,
        store = function()
            return store
        end,
        now = function()
            return world.time
        end,
        after = function(seconds, callback)
            table.insert(client.timers, { at = world.time + seconds, callback = callback })
            return true
        end,
        random = function(low, high)
            if low == 0 and high == addon.GuildGreet.STAGGER_MAX_SECONDS then
                return stagger
            end
            return low
        end,
        send = function(text)
            table.insert(world.chat, { text = text, sender = full(name) })
            table.insert(world.posted, { at = world.time, by = name, text = text })
            return true
        end,
        announce = function(message)
            table.insert(world.messages, { message = message, sender = full(name) })
            return true
        end,
        showDelay = function()
            return 0
        end,
        view = {
            Show = function(_, prompts, handlers)
                client.shown = prompts
                client.handlers = handlers
            end,
        },
    })
    client.greet:OnRosterUpdate(function()
        local roster = {}
        local _, other
        for _, other in ipairs(GREETERS) do
            -- The greeters already playing are online.
            local online = world.add_ons[other] ~= nil or other == name
            table.insert(roster, { name = full(other), online = online,
                lastOnline = not online and { years = 0, months = 0, days = 2, hours = 0 } or nil })
        end
        for _, other in ipairs(ARRIVALS) do
            table.insert(roster, { name = full(other), online = false,
                lastOnline = { years = 0, months = 0, days = 2, hours = 0 } })
        end
        return roster
    end)
    world.add_ons[name] = client
    table.insert(world.add_ons, client)
    return client
end

-- Everyone hears the chat lines and add-on messages sent so far.
local function deliver(world)
    while world.chat[1] ~= nil or world.messages[1] ~= nil do
        local line = table.remove(world.chat, 1)
        if line ~= nil then
            local index
            for index = 1, #world.add_ons do
                world.add_ons[index].greet:OnGuildChat(line.text, line.sender)
            end
        end
        local sent = table.remove(world.messages, 1)
        if sent ~= nil then
            local index
            for index = 1, #world.add_ons do
                world.add_ons[index].greet:OnGreeted(sent.message, sent.sender)
            end
        end
    end
end

local function arrive(world, name)
    local index
    for index = 1, #world.add_ons do
        world.add_ons[index].greet:OnPresence("online", full(name))
    end
end

-- One second passes: timers run, then each greeter with an unlocked prompt
-- presses Greet on the top one, and everyone hears it at once.
local function tick(world)
    world.time = world.time + 1
    local index
    for index = 1, #world.add_ons do
        local client = world.add_ons[index]
        local timerIndex = 1
        while timerIndex <= #client.timers do
            if client.timers[timerIndex].at <= world.time then
                table.remove(client.timers, timerIndex).callback()
            else
                timerIndex = timerIndex + 1
            end
        end
    end
    for index = 1, #world.add_ons do
        local client = world.add_ons[index]
        local prompt = client.shown[1]
        if prompt ~= nil and (prompt.lockedFor or 0) == 0 and client.handlers ~= nil then
            client.handlers.greet(prompt.player)
            deliver(world)
        end
    end
end

-- `seconds` pass, with arrivals from `schedule` ({ [second] = name }) at
-- their seconds. Returns, per add-on, when anti-spam mode turned on and off.
local function run(world, seconds, schedule, onSecond)
    local changes = {}
    local second
    for second = 1, seconds do
        if schedule ~= nil and schedule[second] ~= nil then
            arrive(world, schedule[second])
            deliver(world)
        end
        tick(world)
        if onSecond ~= nil then
            onSecond(second)
        end
        local index
        for index = 1, #world.add_ons do
            local client = world.add_ons[index]
            local on = client.greet:AntiSpamOn()
            if on ~= (client.wasOn or false) then
                changes[client.name] = changes[client.name] or {}
                table.insert(changes[client.name], { on = on, at = world.time })
            end
            client.wasOn = on
        end
    end
    return changes
end

-- Long before the busy stretch: four greeters whose rosters have loaded.
local function established()
    local world = newWorld()
    world.time = START - 600
    join(world, "Alpha", 0)
    join(world, "Bravo", 1)
    join(world, "Charlie", 2)
    join(world, "Delta", 1)
    world.time = START
    return world
end

-- The 16 arrivals, one every `gap` seconds from second 1.
local function every(gap)
    local schedule = {}
    local index
    for index = 1, #ARRIVALS do
        schedule[1 + (index - 1) * gap] = ARRIVALS[index]
    end
    return schedule
end

test.test("anti-spam simulation: a busy stretch turns every add-on on, then off at about the same time", function()
    local world = established()

    local changes = run(world, 600, every(5))

    local _, name
    local offs = {}
    for _, name in ipairs({ "Alpha", "Bravo", "Charlie", "Delta" }) do
        local list = changes[name]
        test.assertTrue(list ~= nil and list[1].on, name .. " turned on")
        -- The 8th arrival, 35 seconds in.
        test.assertEqual(START + 36, list[1].at, name)
        test.assertEqual(false, list[2].on, name .. " turned off")
        table.insert(offs, list[2].at)
    end
    table.sort(offs)
    test.assertTrue(offs[#offs] - offs[1] <= 5, "they leave within seconds of each other")
end)

test.test("anti-spam simulation: in anti-spam mode only one add-on greets per guild cooldown", function()
    local world = established()
    local onAt

    run(world, 600, every(5), function()
        if onAt == nil and world.add_ons.Alpha.greet:AntiSpamOn() then
            onAt = world.time
        end
    end)

    local during = {}
    local _, post
    for _, post in ipairs(world.posted) do
        if post.at > onAt then
            table.insert(during, post)
        end
    end
    test.assertTrue(#during >= 4, "greetings went on")
    local index
    for index = 2, #during do
        test.assertTrue(during[index].at - during[index - 1].at >= 15,
            "greetings at " .. during[index - 1].at - START .. " and " .. during[index].at - START)
    end
    -- More than one greeter took a turn.
    local greeters = {}
    for _, post in ipairs(during) do
        greeters[post.by] = true
    end
    local count = 0
    for _ in pairs(greeters) do
        count = count + 1
    end
    test.assertTrue(count >= 2)
end)

test.test("anti-spam simulation: a late add-on waits, catches up from a flagged greeting, and leaves with the rest", function()
    local world = established()
    local late
    local changes = run(world, 600, every(5), function(second)
        -- Echo logs in with the stretch well under way: it sees too few
        -- arrivals itself to turn on.
        if second == 50 then
            late = join(world, "Echo", 2)
        end
        if second == 52 then
            -- Its startup lock holds its prompts back.
            arrive(world, "Larch")
            test.assertTrue(late.shown[1] ~= nil and late.shown[1].lockedFor > 0)
        end
    end)

    test.assertTrue(changes.Echo ~= nil, "Echo turned on")
    test.assertTrue(changes.Echo[1].at - START < 50 + 120, "from a flagged greeting, within its first window")
    test.assertEqual(false, changes.Echo[2].on)
    test.assertTrue(math.abs(changes.Echo[2].at - changes.Alpha[2].at) <= 30,
        "Echo off at " .. (changes.Echo[2].at - START) .. ", Alpha at " .. (changes.Alpha[2].at - START))
end)

test.test("anti-spam simulation: a quiet night never turns it on", function()
    local world = established()

    local changes = run(world, 16 * 60, every(60))

    test.assertEqual(nil, next(changes))
    -- Greetings went out as usual: each arrival got the greeting cap of 2.
    test.assertEqual(2 * #ARRIVALS, #world.posted)
end)
