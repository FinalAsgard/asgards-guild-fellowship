local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local HOUR = 60 * 60
local AD = "Knights of Camelot is recruiting! Whisper me for an invite."

-- The whole add-on logged in on `profile`, with the roster scanned, and the
-- recruit prompts it last drew in `world.shown` (Post through
-- `world.handlers.post`), and the login question in `world.question`
-- (answered through `world.answers`). `options.before(world)` runs before
-- the add-on loads.
local function login(profile, options)
    local world = fixtures.newEnvironment(profile, options)
    if options and options.time then
        world.time = options.time
    end
    if options and options.before then
        options.before(world)
    end
    fixtures.loadAddon(world)
    world.shown = {}
    world.addon.guildRecruit.view = {
        Show = function(_, prompts, handlers)
            world.shown = {}
            local index
            for index = 1, #prompts do
                table.insert(world.shown, prompts[index])
            end
            world.handlers = handlers
        end,
        Ask = function(_, question, handlers)
            world.question = question
            world.answers = handlers
        end,
    }
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

-- Turns prompts on and saves an ad, as the user would in the settings panel.
local function optIn(world, ad)
    test.assertTrue(world.addon.settings:Set("recruitAd", ad or AD))
    test.assertTrue(world.addon.settings:Set("recruitOptIn", true))
end

-- Moves the player to another zone, in its General channel.
local function travel(world, mapID, name)
    world.zone = { mapID = mapID, name = name }
    world.channels = { [1] = "General - " .. name }
    fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
end

local ZONES = {
    Forever = { here = { 1455, "Ironforge" }, there = { 1426, "Dun Morogh" } },
    Retail = { here = { 2339, "Dornogal" }, there = { 2248, "Isle of Dorn" } },
}

local index
for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]
    local zones = ZONES[profile]

    test.test(profile .. ": an opted-in member is prompted for the zone's General, and Post sends the ad", function()
        local world = login(profile)
        optIn(world)

        test.assertEqual(1, #world.shown)
        test.assertEqual("Advertise in " .. zones.here[2] .. " General?", world.shown[1].text)

        world.handlers.post(world.shown[1].key)

        test.assertEqual(1, #world.chat)
        test.assertEqual(AD, world.chat[1].text)
        test.assertEqual("CHANNEL", world.chat[1].chatType)
        test.assertEqual(1, world.chat[1].target)
        test.assertEqual(0, #world.shown)
    end)

    test.test(profile .. ": entering an unadvertised zone prompts, and each zone has its own time", function()
        local world = login(profile)
        optIn(world)
        world.handlers.post(world.shown[1].key)

        travel(world, zones.there[1], zones.there[2])
        test.assertEqual(1, #world.shown)
        test.assertEqual("Advertise in " .. zones.there[2] .. " General?", world.shown[1].text)

        -- Leaving the zone closes its prompt, and the first zone is still
        -- advertised.
        travel(world, zones.here[1], zones.here[2])
        test.assertEqual(0, #world.shown)
    end)

    test.test(profile .. ": ad times are saved per guild, and a stale one counts as unknown", function()
        local first = login(profile)
        optIn(first)
        first.handlers.post(first.shown[1].key)

        local again = login(profile, { database = first.database })
        test.assertEqual(0, #again.shown)

        local later = login(profile, { database = first.database, time = first.time + HOUR })
        test.assertEqual(1, #later.shown)
    end)
end

test.test("guild recruit: a failed send records nothing and keeps the prompt", function()
    local world = login("Retail")
    optIn(world)
    world.chatFails = true

    test.assertEqual(nil, world.addon.guildRecruit:Post(world.shown[1].key))

    test.assertEqual(1, #world.shown)
    local partition = select(2, world.addon.rosterController:QuietContext())
    test.assertEqual(nil, next(partition:GetRecruitLedger()))

    world.chatFails = false
    world.handlers.post(world.shown[1].key)
    test.assertEqual(0, #world.shown)
    test.assertEqual(world.time, partition:GetRecruitLedger()["general:map:2339"])
end)

test.test("guild recruit: no prompts until opted in, with an ad, and able to invite", function()
    local world = login("Retail")
    test.assertEqual(0, #world.shown)

    world.addon.settings:Set("recruitOptIn", true)
    test.assertEqual(0, #world.shown)
    world.addon.settings:Set("recruitAd", "   ")
    test.assertEqual(0, #world.shown)
    world.addon.settings:Set("recruitAd", AD)
    test.assertEqual(1, #world.shown)

    local stranger = login("Retail")
    stranger.canInvite = false
    test.assertEqual(nil, stranger.addon.settings:Set("recruitOptIn", true))
    test.assertEqual(0, #stranger.shown)
end)

test.test("guild recruit: losing invite permission or opting out closes the prompt", function()
    local world = login("Retail")
    optIn(world)
    test.assertEqual(1, #world.shown)

    world.canInvite = false
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    test.assertEqual(0, #world.shown)
    test.assertEqual(nil, world.addon.guildRecruit:Post("general:map:2339"))
    test.assertEqual(0, #world.chat)

    world.canInvite = true
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    test.assertEqual(1, #world.shown)
    test.assertTrue(world.addon.settings:Set("recruitOptIn", false))
    test.assertEqual(0, #world.shown)
end)

test.test("guild recruit: no prompt outside the zone's General channel", function()
    local world = login("Retail")
    world.channels = {}
    optIn(world)

    test.assertEqual(0, #world.shown)
end)

test.test("guild recruit: Post goes to the channel the user is in now", function()
    local world = login("Retail")
    optIn(world)
    local key = world.shown[1].key
    -- The client renumbered the channels since the prompt appeared.
    world.channels = { [4] = "General - Dornogal" }

    world.handlers.post(key)

    test.assertEqual(4, world.chat[1].target)
end)

test.test("recruitment settings: a fresh install has opt-in off and no ad", function()
    local world = login("Retail")
    local section
    local sections = world.addon.settings:Sections()
    local sectionIndex
    for sectionIndex = 1, #sections do
        if sections[sectionIndex].id == "recruitment" then
            section = sections[sectionIndex]
        end
    end

    test.assertEqual("Recruitment", section.label)
    test.assertEqual("recruitOptIn", section.entries[1].id)
    test.assertEqual("recruitAd", section.entries[2].id)
    test.assertFalse(world.addon.settings:Get("recruitOptIn"))
    test.assertEqual("", world.addon.settings:Get("recruitAd"))
end)

test.test("recruitment settings: opt-in and my ad save and read back", function()
    local world = login("Forever")

    optIn(world, "Join us for raids!")

    test.assertTrue(world.addon.settings:Get("recruitOptIn"))
    test.assertEqual("Join us for raids!", world.addon.settings:Get("recruitAd"))
    test.assertEqual("Join us for raids!", world.database.recruit.ad)
    local selfKey = world.addon.rosterController:SelfKey()
    test.assertTrue(world.database.recruit.optIn[selfKey])

    local again = login("Forever", { database = world.database })
    test.assertTrue(again.addon.settings:Get("recruitOptIn"))
    test.assertEqual("Join us for raids!", again.addon.settings:Get("recruitAd"))
end)

test.test("recruitment settings: an ad longer than 255 characters is refused", function()
    local world = login("Retail")
    world.addon.settings:Set("recruitAd", "Short ad")

    local changed = world.addon.settings:Set("recruitAd", string.rep("x", 256))

    test.assertEqual(nil, changed)
    test.assertEqual("Short ad", world.addon.settings:Get("recruitAd"))
    test.assertTrue(world.addon.settings:Set("recruitAd", string.rep("x", 255)))
end)

test.test("recruitment settings: both are disabled while the character can't invite", function()
    local world = login("Retail")
    world.canInvite = false

    test.assertFalse(world.addon.settings:IsEnabled("recruitOptIn"))
    test.assertFalse(world.addon.settings:IsEnabled("recruitAd"))
    local changed, reason = world.addon.settings:Set("recruitAd", AD)
    test.assertEqual(nil, changed)
    test.assertEqual("this character can't invite to the guild", reason)
    test.assertEqual(nil, world.database.recruit and world.database.recruit.ad)

    world.canInvite = true
    test.assertTrue(world.addon.settings:IsEnabled("recruitOptIn"))
    test.assertTrue(world.addon.settings:IsEnabled("recruitAd"))
end)

-- The logged-in character's saved answer, read straight from saved data.
local function savedAnswer(world)
    local key = world.addon.rosterController:SelfKey()
    return world.database.recruit and world.database.recruit.optIn and world.database.recruit.optIn[key]
end

for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]

    test.test(profile .. ": an undecided member who can invite is asked at login, and Yes turns prompts on", function()
        local world = login(profile)

        test.assertEqual("Help with guild recruitment?", world.question)
        test.assertEqual(nil, savedAnswer(world))
        world.addon.settings:Set("recruitAd", AD)
        test.assertEqual(0, #world.shown)

        world.answers.yes()

        test.assertEqual(nil, world.question)
        test.assertTrue(savedAnswer(world))
        test.assertEqual(1, #world.shown)
    end)

    test.test(profile .. ": No saves false, and the member isn't asked again", function()
        local world = login(profile)
        world.answers.no()

        test.assertEqual(nil, world.question)
        test.assertFalse(savedAnswer(world))

        local again = login(profile, { database = world.database })
        test.assertEqual(nil, again.question)
        test.assertFalse(savedAnswer(again))
    end)

    test.test(profile .. ": closing the question leaves it undecided, so it's asked at the next login", function()
        local world = login(profile)
        world.answers.close()

        test.assertEqual(nil, world.question)
        test.assertEqual(nil, savedAnswer(world))
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        test.assertEqual(nil, world.question)

        local again = login(profile, { database = world.database })
        test.assertEqual("Help with guild recruitment?", again.question)
    end)

    test.test(profile .. ": without invite permission, a saved answer goes back to undecided and nobody is asked", function()
        local answers = { true, false }
        local answerIndex
        for answerIndex = 1, #answers do
            local world = login(profile)
            if answers[answerIndex] then
                world.answers.yes()
            else
                world.answers.no()
            end

            local demoted = login(profile, {
                database = world.database,
                before = function(next)
                    next.canInvite = false
                end,
            })

            test.assertEqual(nil, demoted.question)
            test.assertEqual(nil, savedAnswer(demoted))
        end
    end)
end

test.test("guild recruit: a member who answered and can invite isn't asked, and nothing changes", function()
    local world = login("Retail")
    world.answers.yes()

    local again = login("Retail", { database = world.database })

    test.assertEqual(nil, again.question)
    test.assertTrue(savedAnswer(again))
end)

test.test("guild recruit: resetting one character's answer leaves the others alone", function()
    local main = login("Retail")
    main.answers.yes()

    local alt = login("Retail", {
        database = main.database,
        playerName = "Hammer-Area52",
        before = function(next)
            next.canInvite = false
        end,
    })
    test.assertEqual(nil, savedAnswer(alt))

    local back = login("Retail", { database = main.database })
    test.assertEqual(nil, back.question)
    test.assertTrue(savedAnswer(back))
end)

test.test("guild recruit: the login check waits for the roster, and runs once", function()
    local world = login("Retail", { rosterReady = false })
    test.assertEqual(nil, world.question)

    world.rosterReady = true
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    test.assertEqual("Help with guild recruitment?", world.question)

    world.answers.close()
    world.canInvite = false
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    world.canInvite = true
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    test.assertEqual(nil, world.question)
end)

test.test("guild recruit: losing permission mid-session stops prompts but keeps the answer until next login", function()
    local world = login("Retail")
    optIn(world)
    test.assertEqual(1, #world.shown)

    world.canInvite = false
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")

    test.assertEqual(0, #world.shown)
    test.assertFalse(world.addon.settings:IsEnabled("recruitOptIn"))
    test.assertTrue(savedAnswer(world))
end)

test.test("recruitment settings: undecided shows unchecked, and the checkbox saves true or false", function()
    local world = login("Retail")

    test.assertEqual(nil, savedAnswer(world))
    test.assertFalse(world.addon.settings:Get("recruitOptIn"))

    test.assertTrue(world.addon.settings:Set("recruitOptIn", true))
    test.assertTrue(savedAnswer(world))
    -- Answering in the settings settles the login question.
    test.assertEqual(nil, world.question)
    test.assertTrue(world.addon.settings:Set("recruitOptIn", false))
    test.assertFalse(savedAnswer(world))
    test.assertFalse(world.addon.settings:Get("recruitOptIn"))
end)

-- Puts the player in Trade too, as the client does in a city.
local function inCity(world, zoneName)
    world.channels = { [1] = "General - " .. zoneName, [2] = "Trade - City" }
    fixtures.fire(world, "CHANNEL_UI_UPDATE")
end

local function promptFor(world, text)
    local index
    for index = 1, #world.shown do
        if world.shown[index].text == text then
            return world.shown[index]
        end
    end
    return nil
end

for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]
    local zones = ZONES[profile]

    test.test(profile .. ": in a city, Trade gets its own prompt, and Post sends to Trade", function()
        local world = login(profile)
        optIn(world)
        inCity(world, zones.here[2])

        test.assertEqual(2, #world.shown)
        local trade = promptFor(world, "Advertise in Trade?")
        test.assertTrue(trade ~= nil)
        test.assertTrue(promptFor(world, "Advertise in " .. zones.here[2] .. " General?") ~= nil)

        world.handlers.post(trade.key)

        test.assertEqual(2, world.chat[1].target)
        test.assertEqual(1, #world.shown)
        test.assertEqual("Advertise in " .. zones.here[2] .. " General?", world.shown[1].text)
    end)

    test.test(profile .. ": an ad in one city's Trade makes Trade fresh in every city", function()
        local world = login(profile)
        optIn(world)
        inCity(world, zones.here[2])
        world.handlers.post(promptFor(world, "Advertise in Trade?").key)

        travel(world, zones.there[1], zones.there[2])
        inCity(world, zones.there[2])

        test.assertEqual(1, #world.shown)
        test.assertEqual("Advertise in " .. zones.there[2] .. " General?", world.shown[1].text)
    end)
end

test.test("guild recruit: a failed Trade send records nothing", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")
    world.chatFails = true

    test.assertEqual(nil, world.addon.guildRecruit:Post("trade"))

    test.assertEqual(2, #world.shown)
    local partition = select(2, world.addon.rosterController:QuietContext())
    test.assertEqual(nil, partition:GetRecruitLedger().trade)
end)

test.test("guild recruit: staying put, Trade is prompted again after 20 minutes and General after 60", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")
    world.handlers.post(promptFor(world, "Advertise in Trade?").key)
    world.handlers.post(world.shown[1].key)
    test.assertEqual(0, #world.shown)

    fixtures.runTimers(world, 20 * 60 - 1)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 1)
    test.assertEqual(1, #world.shown)
    test.assertEqual("Advertise in Trade?", world.shown[1].text)

    fixtures.runTimers(world, 40 * 60)
    test.assertEqual(2, #world.shown)
end)

test.test("guild recruit: no Trade prompt where Trade isn't available", function()
    local world = login("Retail")
    optIn(world)

    test.assertEqual(1, #world.shown)
    test.assertEqual(nil, promptFor(world, "Advertise in Trade?"))
end)
