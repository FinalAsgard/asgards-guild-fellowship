local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local HOUR = 60 * 60
local AD = "Knights of Camelot is recruiting! Whisper me for an invite."

-- The whole add-on logged in on `profile`, with the roster scanned, and the
-- recruit prompts it last drew in `world.shown` (Post through
-- `world.handlers.post`), and the login question in `world.question`
-- (answered through `world.answers`). `options.before(world)` runs before
-- the add-on loads, and `options.askWait` sets how long asks wait.
local function login(profile, options)
    local world = fixtures.newEnvironment(profile, options)
    if options and options.time then
        world.time = options.time
    end
    if options and options.before then
        options.before(world)
    end
    world.askWait = options and options.askWait
    fixtures.loadAddon(world)
    -- Prompts show at once unless a spec sets `world.showDelay`.
    world.addon.guildRecruit.showDelay = function()
        return world.showDelay or 0
    end
    -- Asks end at once, with nobody answering, unless a spec sets
    -- `world.askWait`.
    world.addon.guildRecruit.askWait = function()
        return world.askWait or 0
    end
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

test.test("guild recruit: Not now hides a channel's prompt for 10 minutes, then it comes back", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")

    world.handlers.notNow(promptFor(world, "Advertise in Trade?").key)
    test.assertEqual(1, #world.shown)
    test.assertEqual("Advertise in Dornogal General?", world.shown[1].text)

    fixtures.runTimers(world, 10 * 60 - 1)
    test.assertEqual(nil, promptFor(world, "Advertise in Trade?"))
    fixtures.runTimers(world, 1)
    test.assertTrue(promptFor(world, "Advertise in Trade?") ~= nil)
end)

test.test("guild recruit: Off here quiets the zone's General and Trade for the session only", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")

    world.handlers.offHere(world.shown[1].key)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 2 * HOUR)
    test.assertEqual(0, #world.shown)

    -- Another zone still prompts, Trade too where the user is in it.
    travel(world, 2248, "Isle of Dorn")
    test.assertEqual(1, #world.shown)
    travel(world, 2339, "Dornogal")
    inCity(world, "Dornogal")
    test.assertEqual(0, #world.shown)

    -- Nothing is saved, so a reload prompts again.
    local reloaded = login("Retail", { database = world.database, time = world.time })
    inCity(reloaded, "Dornogal")
    test.assertEqual(2, #reloaded.shown)
end)

test.test("guild recruit: prompts are held in combat and boss encounters, then appear if still due", function()
    local world = login("Retail")
    optIn(world)

    fixtures.fire(world, "PLAYER_REGEN_DISABLED")
    test.assertEqual(0, #world.shown)
    fixtures.fire(world, "PLAYER_REGEN_ENABLED")
    test.assertEqual(1, #world.shown)

    world.inEncounter = true
    fixtures.fire(world, "ENCOUNTER_START")
    test.assertEqual(0, #world.shown)
    world.inEncounter = false
    fixtures.fire(world, "ENCOUNTER_END")
    test.assertEqual(1, #world.shown)
end)

for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]

    test.test(profile .. ": prompts are held in instances and battlegrounds, then appear once outside", function()
        local world = login(profile)
        optIn(world)
        local kinds = { "party", "raid", "pvp", "arena" }
        local kindIndex
        for kindIndex = 1, #kinds do
            world.inInstance = kinds[kindIndex]
            fixtures.fire(world, "PLAYER_ENTERING_WORLD")
            test.assertEqual(0, #world.shown, kinds[kindIndex])
            world.inInstance = nil
            fixtures.fire(world, "PLAYER_ENTERING_WORLD")
            test.assertEqual(1, #world.shown, kinds[kindIndex])
        end
    end)
end

test.test("guild recruit: prompts are held during a keystone run", function()
    local world = login("Retail")
    optIn(world)
    world.environment.IsInInstance = nil

    world.inKeystone = true
    fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual(0, #world.shown)
    world.inKeystone = false
    fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual(1, #world.shown)
end)

test.test("guild recruit: leaving a zone or city closes the prompts for it", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")
    test.assertEqual(2, #world.shown)

    -- Out of the city: Trade is gone, and the new zone has its own General.
    travel(world, 2248, "Isle of Dorn")
    test.assertEqual(1, #world.shown)
    test.assertEqual("Advertise in Isle of Dorn General?", world.shown[1].text)

    -- Somewhere without a General channel: nothing is left.
    world.channels = {}
    fixtures.fire(world, "CHANNEL_UI_UPDATE")
    test.assertEqual(0, #world.shown)
end)

-- The `advertised` messages the world sent, deserialized, with their
-- priorities.
local function advertised(world)
    local serializer = world.environment.LibStub.libs["AceSerializer-3.0"]
    local found = {}
    local index
    for index = 1, #world.sentMessages do
        local sent = world.sentMessages[index]
        local _, message = serializer:Deserialize(sent.text)
        if type(message) == "table" and message.t == "advertised" then
            message.priority = sent.priority
            table.insert(found, message)
        end
    end
    return found
end

test.test("guild recruit: a successful post tells other add-on users at NORMAL priority", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")

    world.handlers.post(promptFor(world, "Advertise in Dornogal General?").key)
    world.handlers.post(promptFor(world, "Advertise in Trade?").key)

    local messages = advertised(world)
    test.assertEqual(2, #messages)
    test.assertEqual(1, messages[1].v)
    test.assertEqual("general:map:2339", messages[1].k)
    test.assertEqual("Dornogal General", messages[1].n)
    test.assertEqual(world.time, messages[1].a)
    test.assertEqual("NORMAL", messages[1].priority)
    test.assertEqual("trade", messages[2].k)
    test.assertEqual("Trade", messages[2].n)
end)

test.test("guild recruit: a failed post tells nobody", function()
    local world = login("Retail")
    optIn(world)
    world.chatFails = true

    world.handlers.post(world.shown[1].key)

    test.assertEqual(0, #advertised(world))
end)

test.test("guild recruit: an advertised message records the time for any zone and closes the prompt", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")
    local recruit = world.addon.guildRecruit

    test.assertTrue(recruit:OnAdvertised(
        { v = 1, t = "advertised", k = "general:map:2248", n = "Isle of Dorn General", a = world.time },
        "Anvil-Area52"))
    test.assertEqual(2, #world.shown)
    test.assertTrue(recruit:OnAdvertised({ v = 1, t = "advertised", k = "trade", n = "Trade", a = world.time },
        "Anvil-Area52"))
    test.assertEqual(1, #world.shown)
    test.assertEqual("Advertise in Dornogal General?", world.shown[1].text)

    -- An older time than the one known changes nothing.
    test.assertFalse(recruit:OnAdvertised({ v = 1, t = "advertised", k = "trade", n = "Trade", a = world.time - 60 },
        "Anvil-Area52"))

    -- The other zone was recorded too, so travelling there prompts nothing.
    travel(world, 2248, "Isle of Dorn")
    test.assertEqual(0, #world.shown)
end)

test.test("guild recruit: advertised messages from the user's characters, or malformed ones, are ignored", function()
    local world = login("Retail")
    optIn(world)
    local recruit = world.addon.guildRecruit
    local good = { v = 1, t = "advertised", k = "general:map:2339", n = "Dornogal General", a = world.time }

    -- Hammer's note makes it an alt of the user's Toolbox.
    test.assertFalse(recruit:OnAdvertised(good, "Hammer-Area52"))
    test.assertFalse(recruit:OnAdvertised(good, "Toolbox-Area52"))
    local broken = {
        "not a table",
        { v = 2, t = "advertised", k = "trade", a = world.time },
        { v = 1, t = "greeted", k = "trade", a = world.time },
        { v = 1, t = "advertised", k = "elsewhere", a = world.time },
        { v = 1, t = "advertised", k = "general:", a = world.time },
        { v = 1, t = "advertised", k = "trade", a = "now" },
        { v = 1, t = "advertised", k = "trade", n = 7, a = world.time },
    }
    local index
    for index = 1, #broken do
        test.assertFalse(recruit:OnAdvertised(broken[index], "Anvil-Area52"), "message " .. index)
    end
    test.assertFalse(recruit:OnAdvertised(good, nil))
    test.assertEqual(1, #world.shown)
end)

test.test("guild recruit: a prompt waits its show delay, and is dropped if advertised in meanwhile", function()
    local world = login("Retail")
    world.showDelay = 15
    optIn(world)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 14)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 1)
    test.assertEqual(1, #world.shown)

    inCity(world, "Dornogal")
    test.assertEqual(1, #world.shown)
    world.addon.guildRecruit:OnAdvertised({ v = 1, t = "advertised", k = "trade", n = "Trade", a = world.time },
        "Anvil-Area52")
    fixtures.runTimers(world, 15)
    test.assertEqual(1, #world.shown)
    test.assertEqual(nil, promptFor(world, "Advertise in Trade?"))
end)

test.test("guild recruit: the show delay is a random 3 to 20 seconds, and a failing pick still delays", function()
    local addon = test.newAddon("Core/RecruitLedger.lua", "Core/RecruitPolicy.lua", "Core/GuildRecruit.lua")
    local asked = {}
    local recruit = addon.GuildRecruit.Create({
        random = function(low, high)
            asked = { low, high }
            return 12
        end,
    })
    test.assertEqual(12, recruit:ShowDelay())
    test.assertEqual(3, asked[1])
    test.assertEqual(20, asked[2])

    local failing = addon.GuildRecruit.Create({ random = function() error("boom") end })
    test.assertEqual(3, failing:ShowDelay())
end)

for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]

    test.test(profile .. ": without AceComm or AceSerializer, prompts and posting still work", function()
        local missing = { { "AceComm-3.0" }, { "AceSerializer-3.0" } }
        local missingIndex
        for missingIndex = 1, #missing do
            local world = login(profile, { missingLibraries = missing[missingIndex] })
            optIn(world)
            test.assertEqual(1, #world.shown)

            world.handlers.post(world.shown[1].key)

            test.assertEqual(1, #world.chat)
            test.assertEqual(0, #world.shown)
            test.assertEqual(0, #world.sentMessages)
        end
    end)
end

-- Every Guild Recruit message of type `kind` the world sent, deserialized.
local function sentOfType(world, kind)
    local serializer = world.environment.LibStub.libs["AceSerializer-3.0"]
    local found = {}
    local index
    for index = 1, #world.sentMessages do
        local _, message = serializer:Deserialize(world.sentMessages[index].text)
        if type(message) == "table" and message.t == kind then
            table.insert(found, message)
        end
    end
    return found
end

test.test("guild recruit: an unknown channel is asked about, and prompted only after nobody answers", function()
    local world = login("Retail")
    world.askWait = 8
    optIn(world)

    local asks = sentOfType(world, "ask-channel")
    test.assertEqual(1, #asks)
    test.assertEqual("general:map:2339", asks[1].k)
    test.assertEqual(0, #world.shown)

    fixtures.runTimers(world, 7)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 1)
    test.assertEqual(1, #world.shown)
    -- A due channel isn't asked about again.
    fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual(1, #sentOfType(world, "ask-channel"))
end)

test.test("guild recruit: entering a zone or city asks only about the unknown channels there", function()
    local world = login("Retail")
    world.askWait = 8
    optIn(world)
    fixtures.runTimers(world, 8)
    world.handlers.post(world.shown[1].key)

    inCity(world, "Dornogal")
    local asks = sentOfType(world, "ask-channel")
    test.assertEqual(2, #asks)
    test.assertEqual("trade", asks[2].k)

    travel(world, 2248, "Isle of Dorn")
    asks = sentOfType(world, "ask-channel")
    test.assertEqual(3, #asks)
    test.assertEqual("general:map:2248", asks[3].k)
end)

test.test("guild recruit: a channel-time heard while asking prevents the prompt", function()
    local world = login("Retail")
    world.askWait = 8
    optIn(world)

    test.assertTrue(world.addon.guildRecruit:OnMessage(
        { v = 1, t = "channel-time", k = "general:map:2339", a = world.time - 60 }, "Anvil-Area52"))
    fixtures.runTimers(world, 8)

    test.assertEqual(0, #world.shown)
    -- It's prompted once that time goes stale and a new ask gets no answer.
    fixtures.runTimers(world, HOUR - 60 - 8)
    test.assertEqual(0, #world.shown)
    test.assertEqual(2, #sentOfType(world, "ask-channel"))
    fixtures.runTimers(world, 8)
    test.assertEqual(1, #world.shown)
end)

test.test("guild recruit: a saved time older than the gap is asked about, never taken as the last ad", function()
    local first = login("Retail")
    optIn(first)
    first.handlers.post(first.shown[1].key)

    local later = login("Retail", { database = first.database, time = first.time + HOUR, askWait = 8 })

    test.assertEqual(1, #sentOfType(later, "ask-channel"))
    test.assertEqual(0, #later.shown)
    fixtures.runTimers(later, 8)
    test.assertEqual(1, #later.shown)
end)

test.test("guild recruit: only an add-on with a fresh time answers, after a random short wait", function()
    local world = login("Retail")
    optIn(world)
    world.handlers.post(world.shown[1].key)
    local recruit = world.addon.guildRecruit
    world.environment.math = { random = function() return 3 end }

    test.assertFalse(recruit:OnMessage({ v = 1, t = "ask-channel", k = "trade" }, "Anvil-Area52"))
    test.assertTrue(recruit:OnMessage({ v = 1, t = "ask-channel", k = "general:map:2339" }, "Anvil-Area52"))
    fixtures.runTimers(world, 2)
    test.assertEqual(0, #sentOfType(world, "channel-time"))
    fixtures.runTimers(world, 1)

    local answers = sentOfType(world, "channel-time")
    test.assertEqual(1, #answers)
    test.assertEqual("general:map:2339", answers[1].k)
    test.assertEqual(world.time - 3, answers[1].a)
end)

test.test("guild recruit: an answer is dropped when an equal or newer one is heard first", function()
    local world = login("Retail")
    optIn(world)
    world.handlers.post(world.shown[1].key)
    local recruit = world.addon.guildRecruit
    local posted = world.time

    recruit:OnMessage({ v = 1, t = "ask-channel", k = "general:map:2339" }, "Anvil-Area52")
    recruit:OnMessage({ v = 1, t = "channel-time", k = "general:map:2339", a = posted - 1 }, "Wrench-Area52")
    recruit:OnMessage({ v = 1, t = "channel-time", k = "general:map:2339", a = posted }, "Wrench-Area52")
    fixtures.runTimers(world, 20)

    test.assertEqual(0, #sentOfType(world, "channel-time"))
end)

test.test("guild recruit: own and malformed asks and answers are ignored", function()
    local world = login("Retail")
    optIn(world)
    world.handlers.post(world.shown[1].key)
    local recruit = world.addon.guildRecruit

    test.assertFalse(recruit:OnMessage({ v = 1, t = "ask-channel", k = "general:map:2339" }, "Hammer-Area52"))
    test.assertFalse(recruit:OnMessage({ v = 1, t = "ask-channel", k = "nowhere" }, "Anvil-Area52"))
    test.assertFalse(recruit:OnMessage({ v = 2, t = "ask-channel", k = "trade" }, "Anvil-Area52"))
    test.assertFalse(recruit:OnMessage({ v = 1, t = "channel-time", k = "trade" }, "Anvil-Area52"))
    test.assertFalse(recruit:OnMessage({ v = 1, t = "channel-time", k = "trade", a = world.time }, "Hammer-Area52"))
    test.assertFalse(recruit:OnMessage({ v = 1, t = "something", k = "trade", a = world.time }, "Anvil-Area52"))
    test.assertFalse(recruit:OnMessage("ask-channel", "Anvil-Area52"))
end)

-- The fixtures' Retail guild: Toolbox is an officer (rank 1, which can view
-- officer notes), Visitor a member (rank 4).
local OFFICER = "Toolbox-Area52"
local MEMBER = "Visitor-Stormrage"

test.test("officer guild ad: only officers see and can change the guild ad controls", function()
    local officer = login("Retail", { playerName = OFFICER })
    test.assertTrue(officer.addon.settings:IsShown("recruitGuildAd"))
    test.assertTrue(officer.addon.settings:IsShown("recruitGuildAdOn"))
    test.assertTrue(officer.addon.settings:Set("recruitGuildAd", "Knights recruit!"))

    local member = login("Retail", { playerName = MEMBER })
    test.assertFalse(member.addon.settings:IsShown("recruitGuildAd"))
    test.assertFalse(member.addon.settings:IsShown("recruitGuildAdOn"))
    test.assertTrue(member.addon.settings:IsShown("recruitUseOfficerAd"))
    local changed, reason = member.addon.settings:Set("recruitGuildAd", "Forged")
    test.assertEqual(nil, changed)
    test.assertEqual("only officers can change it", reason)
end)

test.test("officer guild ad: a change is saved per guild with when and by whom, and broadcast", function()
    local world = login("Retail", { playerName = OFFICER })

    test.assertTrue(world.addon.settings:Set("recruitGuildAd", "Knights recruit!"))
    test.assertTrue(world.addon.settings:Set("recruitGuildAdOn", false))

    local partition = select(2, world.addon.rosterController:QuietContext())
    local saved = partition:GetRecruitConfig()
    test.assertEqual("Knights recruit!", saved.guildAd.value)
    test.assertEqual(world.time, saved.guildAd.at)
    test.assertEqual(world.addon.rosterController:SelfKey(), saved.guildAd.by)
    local configs = sentOfType(world, "config")
    test.assertEqual(2, #configs)
    test.assertEqual("Knights recruit!", configs[2].s.guildAd.value)
    test.assertFalse(configs[2].s.guildAdOn.value)

    local reloaded = login("Retail", { playerName = OFFICER, database = world.database })
    test.assertEqual("Knights recruit!", reloaded.addon.settings:Get("recruitGuildAd"))
    test.assertFalse(reloaded.addon.settings:Get("recruitGuildAdOn"))
end)

test.test("officer guild ad: a member with only the guild ad is prompted and posts it", function()
    local world = login("Retail", { playerName = OFFICER })
    world.addon.settings:Set("recruitGuildAd", "Knights recruit!")
    world.addon.settings:Set("recruitOptIn", true)

    test.assertEqual(1, #world.shown)
    world.handlers.post(world.shown[1].key)
    test.assertEqual("Knights recruit!", world.chat[1].text)
end)

test.test("officer guild ad: each post picks at random between the guild ad and the user's own", function()
    local world = login("Retail", { playerName = OFFICER })
    world.addon.settings:Set("recruitGuildAd", "Knights recruit!")
    optIn(world, "My own ad")
    world.environment.math = { random = function(low) return low + 1 end }
    world.handlers.post(world.shown[1].key)
    test.assertEqual("My own ad", world.chat[1].text)

    world.environment.math = { random = function(low) return low end }
    inCity(world, "Dornogal")
    world.handlers.post(promptFor(world, "Advertise in Trade?").key)
    test.assertEqual("Knights recruit!", world.chat[2].text)
end)

test.test("officer guild ad: unchecking use officer ad, or the ad being off, posts only the user's own", function()
    local world = login("Retail", { playerName = OFFICER })
    world.addon.settings:Set("recruitGuildAd", "Knights recruit!")
    world.addon.settings:Set("recruitOptIn", true)
    test.assertTrue(world.addon.settings:Get("recruitUseOfficerAd"))

    test.assertTrue(world.addon.settings:Set("recruitUseOfficerAd", false))
    test.assertFalse(world.database.recruit.useOfficerAd)
    -- No usable ad now: no prompts.
    test.assertEqual(0, #world.shown)

    world.addon.settings:Set("recruitAd", "My own ad")
    world.addon.settings:Set("recruitUseOfficerAd", true)
    world.addon.settings:Set("recruitGuildAdOn", false)
    world.handlers.post(world.shown[1].key)
    test.assertEqual("My own ad", world.chat[1].text)
end)

test.test("officer guild ad: config is taken only from officers, newest change winning", function()
    local world = login("Retail", { playerName = MEMBER })
    optIn(world, "My own ad")
    local recruit = world.addon.guildRecruit
    local officerKey = "toolbox-area52"
    local function config(value, at, by)
        return { v = 1, t = "config", s = { guildAd = { value = value, at = at, by = by } } }
    end

    -- A member can't send settings, even naming an officer as the author.
    test.assertFalse(recruit:OnMessage(config("Forged", world.time, officerKey), "Hammer-Area52"))
    -- An officer can't pass on a change by a non-officer.
    test.assertFalse(recruit:OnMessage(config("Relayed", world.time, "visitor-stormrage"), OFFICER))
    test.assertEqual("", recruit:Config():Get("guildAd"))

    test.assertTrue(recruit:OnMessage(config("Knights recruit!", world.time, officerKey), OFFICER))
    test.assertEqual("Knights recruit!", recruit:Config():Get("guildAd"))
    test.assertFalse(recruit:OnMessage(config("Stale", world.time - 1, officerKey), OFFICER))
    test.assertTrue(recruit:OnMessage(config("Newest", world.time + 1, officerKey), OFFICER))
    test.assertEqual("Newest", recruit:Config():Get("guildAd"))
    test.assertFalse(recruit:OnMessage({ v = 1, t = "config", s = "everything" }, OFFICER))
end)

test.test("officer guild ad: with no officer around, ask-config goes unanswered and the user's own ad posts", function()
    local world = login("Retail", { playerName = MEMBER })
    optIn(world, "My own ad")

    test.assertEqual(1, #sentOfType(world, "ask-config"))
    fixtures.runTimers(world, 60)
    test.assertTrue(world.addon.settings:Get("recruitUseOfficerAd"))
    world.handlers.post(world.shown[1].key)
    test.assertEqual("My own ad", world.chat[1].text)
    -- Asked once a session.
    fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
    test.assertEqual(1, #sentOfType(world, "ask-config"))
end)

test.test("officer guild ad: only an officer with settings answers ask-config", function()
    local member = login("Retail", { playerName = MEMBER })
    test.assertFalse(member.addon.guildRecruit:OnMessage({ v = 1, t = "ask-config" }, "Anvil-Area52"))

    local officer = login("Retail", { playerName = OFFICER })
    test.assertFalse(officer.addon.guildRecruit:OnMessage({ v = 1, t = "ask-config" }, "Anvil-Area52"))
    officer.addon.settings:Set("recruitGuildAd", "Knights recruit!")
    local before = #sentOfType(officer, "config")
    officer.environment.math = { random = function() return 2 end }
    test.assertTrue(officer.addon.guildRecruit:OnMessage({ v = 1, t = "ask-config" }, "Anvil-Area52"))
    fixtures.runTimers(officer, 2)
    test.assertEqual(before + 1, #sentOfType(officer, "config"))
end)
