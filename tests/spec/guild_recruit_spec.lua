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

test.test("guild recruit: staying put, each channel is prompted again when its timer runs out", function()
    local world = login("Retail")
    optIn(world)
    -- Trade on a 20-minute timer of the user's own; General on the default
    -- 60 minutes.
    test.assertTrue(world.addon.settings:Set("recruitMyTradeGap", 20))
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
    world.environment.math = setmetatable({ random = function() return 3 end }, { __index = math })

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
    test.assertTrue(officer.addon.settings:Set("recruitGuildAd", "Knights recruit!"))

    local member = login("Retail", { playerName = MEMBER })
    test.assertFalse(member.addon.settings:IsShown("recruitGuildAd"))
    test.assertTrue(member.addon.settings:IsShown("recruitUseOfficerAd"))
    local changed, reason = member.addon.settings:Set("recruitGuildAd", "Forged")
    test.assertEqual(nil, changed)
    test.assertEqual("only officers can change it", reason)
end)

test.test("officer guild ad: a change is saved per guild with when and by whom, and broadcast", function()
    local world = login("Retail", { playerName = OFFICER })

    test.assertTrue(world.addon.settings:Set("recruitGuildAd", "Knights recruit!"))

    local partition = select(2, world.addon.rosterController:QuietContext())
    local saved = partition:GetRecruitConfig()
    test.assertEqual("Knights recruit!", saved.guildAd.value)
    test.assertEqual(world.time, saved.guildAd.at)
    test.assertEqual(world.addon.rosterController:SelfKey(), saved.guildAd.by)
    local configs = sentOfType(world, "config")
    test.assertEqual(1, #configs)
    test.assertEqual("Knights recruit!", configs[1].s.guildAd.value)

    local reloaded = login("Retail", { playerName = OFFICER, database = world.database })
    test.assertEqual("Knights recruit!", reloaded.addon.settings:Get("recruitGuildAd"))
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
    world.environment.math = setmetatable({ random = function(low) return low + 1 end }, { __index = math })
    world.handlers.post(world.shown[1].key)
    test.assertEqual("My own ad", world.chat[1].text)

    world.environment.math = setmetatable({ random = function(low) return low end }, { __index = math })
    inCity(world, "Dornogal")
    world.handlers.post(promptFor(world, "Advertise in Trade?").key)
    test.assertEqual("Knights recruit!", world.chat[2].text)
end)

test.test("officer guild ad: unchecking use officer ad, or the guild ad being cleared, posts only the user's own", function()
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
    -- Clearing the guild ad is how officers turn it off.
    world.addon.settings:Set("recruitGuildAd", "")
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
    officer.environment.math = setmetatable({ random = function() return 2 end }, { __index = math })
    test.assertTrue(officer.addon.guildRecruit:OnMessage({ v = 1, t = "ask-config" }, "Anvil-Area52"))
    fixtures.runTimers(officer, 2)
    test.assertEqual(before + 1, #sentOfType(officer, "config"))
end)

test.test("officer gaps and pause: only officers see them, and gaps under the minimum are refused", function()
    local officer = login("Retail", { playerName = OFFICER })
    local ids = { "recruitGeneralGap", "recruitTradeGap", "recruitPaused" }
    local index
    for index = 1, #ids do
        test.assertTrue(officer.addon.settings:IsShown(ids[index]), ids[index])
    end
    test.assertEqual(30, officer.addon.settings:Get("recruitGeneralGap"))
    test.assertEqual(10, officer.addon.settings:Get("recruitTradeGap"))
    test.assertEqual(nil, officer.addon.settings:Set("recruitGeneralGap", 14))
    test.assertEqual(nil, officer.addon.settings:Set("recruitTradeGap", 4))
    -- Gaps go in 5-minute steps, up to 4 hours.
    test.assertEqual(nil, officer.addon.settings:Set("recruitTradeGap", 7))
    test.assertEqual(nil, officer.addon.settings:Set("recruitTradeGap", 245))
    test.assertTrue(officer.addon.settings:Set("recruitTradeGap", 5))
    test.assertTrue(officer.addon.settings:Set("recruitGeneralGap", 240))

    local member = login("Retail", { playerName = MEMBER })
    for index = 1, #ids do
        test.assertFalse(member.addon.settings:IsShown(ids[index]), ids[index])
    end
    test.assertEqual(nil, member.addon.settings:Set("recruitGeneralGap", 30))
end)

test.test("officer gaps and pause: the guild's gap is a floor no member's own timer goes below", function()
    local world = login("Retail", { playerName = OFFICER })
    optIn(world)
    test.assertTrue(world.addon.settings:Set("recruitGeneralGap", 20))
    -- The user's own timer is shorter than the guild allows.
    test.assertTrue(world.addon.settings:Set("recruitMyGeneralGap", 5))
    world.handlers.post(world.shown[1].key)
    test.assertEqual(0, #world.shown)

    fixtures.runTimers(world, 20 * 60 - 1)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 1)
    test.assertEqual(1, #world.shown)
end)

test.test("guild recruit: a member's own longer timer means they're asked less often", function()
    local world = login("Retail")
    optIn(world)
    test.assertEqual(60, world.addon.settings:Get("recruitMyGeneralGap"))
    test.assertTrue(world.addon.settings:Set("recruitMyGeneralGap", 90))
    test.assertEqual(90, world.database.recruit.myGeneralGapMinutes)
    world.handlers.post(world.shown[1].key)

    -- The guild's 30-minute floor has long passed, but not the user's 90.
    fixtures.runTimers(world, 90 * 60 - 1)
    test.assertEqual(0, #world.shown)
    fixtures.runTimers(world, 1)
    test.assertEqual(1, #world.shown)
end)

test.test("guild recruit: a time only the user's own longer timer keeps isn't sent to others", function()
    local world = login("Retail")
    optIn(world)
    world.handlers.post(world.shown[1].key)
    local recruit = world.addon.guildRecruit

    -- 40 minutes on: past the guild's 30, inside the user's own 60.
    fixtures.runTimers(world, 40 * 60)
    test.assertFalse(recruit:OnMessage({ v = 1, t = "ask-channel", k = "general:map:2339" }, "Anvil-Area52"))
    -- Inside the guild's gap, it answers.
    world.time = world.time - 20 * 60
    test.assertTrue(recruit:OnMessage({ v = 1, t = "ask-channel", k = "general:map:2339" }, "Anvil-Area52"))
end)

test.test("officer gaps and pause: a member goes by the floor an officer sends", function()
    local world = login("Retail", { playerName = MEMBER })
    optIn(world)
    test.assertTrue(world.addon.settings:Set("recruitMyTradeGap", 5))
    inCity(world, "Dornogal")
    world.handlers.post(promptFor(world, "Advertise in Trade?").key)

    world.addon.guildRecruit:OnMessage({ v = 1, t = "config", s = {
        tradeGapMinutes = { value = 15, at = world.time, by = "toolbox-area52" },
    } }, OFFICER)
    fixtures.runTimers(world, 15 * 60 - 1)
    test.assertEqual(nil, promptFor(world, "Advertise in Trade?"))
    fixtures.runTimers(world, 1)

    test.assertTrue(promptFor(world, "Advertise in Trade?") ~= nil)
end)

test.test("guild recruit: timers read as minutes and hours", function()
    local recruit = login("Retail").addon.GuildRecruit
    test.assertEqual("45 min", recruit.FormatMinutes(45))
    test.assertEqual("1 h", recruit.FormatMinutes(60))
    test.assertEqual("2 h 15 min", recruit.FormatMinutes(135))
    test.assertEqual("", recruit.FormatMinutes(nil))
end)

test.test("recruitment settings: the page says what floor the guild sets", function()
    local world = login("Retail")
    test.assertEqual("The guild asks for at least 30 min in General and 10 min in Trade; a shorter timer of yours"
        .. " waits that long.", world.addon.settings:Get("recruitGuildFloor"))
end)

test.test("officer gaps and pause: pausing closes everyone's prompts, and lifting it brings due ones back", function()
    local officer = login("Retail", { playerName = OFFICER })
    optIn(officer)
    local member = login("Retail", { playerName = MEMBER })
    optIn(member)
    test.assertEqual(1, #officer.shown)
    test.assertEqual(1, #member.shown)

    test.assertTrue(officer.addon.settings:Set("recruitPaused", true))
    test.assertEqual(0, #officer.shown)
    local paused = sentOfType(officer, "config")
    member.addon.guildRecruit:OnMessage(paused[#paused], OFFICER)
    test.assertEqual(0, #member.shown)
    test.assertEqual(nil, member.addon.guildRecruit:Post("general:map:2339"))
    fixtures.runTimers(member, 2 * 60 * 60)
    test.assertEqual(0, #member.shown)

    officer.time = member.time
    test.assertTrue(officer.addon.settings:Set("recruitPaused", false))
    local resumed = sentOfType(officer, "config")
    member.addon.guildRecruit:OnMessage(resumed[#resumed], OFFICER)
    test.assertEqual(1, #member.shown)
    test.assertEqual(1, #officer.shown)
end)

test.test("ad stats: each post counts in the user's own record, sent with the advertised message", function()
    local world = login("Retail")
    optIn(world)

    world.handlers.post(world.shown[1].key)

    test.assertEqual(1, world.database.recruit.stats.n)
    test.assertEqual(world.time, world.database.recruit.stats.t[1])
    local messages = sentOfType(world, "advertised")
    test.assertEqual(1, messages[1].r.n)
    test.assertEqual(world.time, messages[1].r.t[1])
    -- The user's own player shows the own record.
    local selfKey = world.addon.rosterController:SelfKey()
    test.assertEqual("Advertised: 1 (1 in last 30 days)", world.addon.guildRecruit:StatsLine({ selfKey }))
end)

test.test("ad stats: a heard report is kept under the poster, highest total winning, across their characters", function()
    local world = login("Retail", { playerName = MEMBER })
    local recruit = world.addon.guildRecruit
    local function advertised(sender, total, at)
        return recruit:OnMessage({
            v = 1, t = "advertised", k = "trade", n = "Trade", a = at, r = { n = total, t = { at } },
        }, sender)
    end

    advertised("Toolbox-Area52", 4, world.time)
    -- Hammer is Toolbox's alt: the same player, a newer report.
    advertised("Hammer-Area52", 5, world.time + 1)
    advertised("Toolbox-Area52", 3, world.time + 2)

    local partition = select(2, world.addon.rosterController:QuietContext())
    test.assertEqual(4, partition:GetRecruitStats()["toolbox-area52"].n)
    test.assertEqual("Advertised: 5 (1 in last 30 days)",
        recruit:StatsLine({ "toolbox-area52", "hammer-area52" }))
    test.assertEqual(nil, recruit:StatsLine({ "nobody-area52" }))
end)

test.test("ad stats: a player who has never advertised shows no line", function()
    local world = login("Retail")
    local selfKey = world.addon.rosterController:SelfKey()

    test.assertEqual(nil, world.addon.guildRecruit:StatsLine({ selfKey }))
end)

-- A roster window that records what it was last told about Recruiters.
local function recruitersWindow(world)
    local window = {}
    function window:IsShown()
        return true
    end
    function window:SetRecruiters(rows)
        self.rows = rows
    end
    world.addon.rosterController.window = window
    return window
end

test.test("recruiters: an officer's open view updates when new stats arrive, ranked", function()
    local world = login("Retail", { playerName = OFFICER })
    local window = recruitersWindow(world)
    local recruit = world.addon.guildRecruit

    recruit:OnMessage({ v = 1, t = "advertised", k = "trade", n = "Trade", a = world.time,
        r = { n = 2, t = { world.time, world.time } } }, MEMBER)
    test.assertEqual(1, #window.rows)
    test.assertEqual("Visitor-Stormrage", window.rows[1].label)
    test.assertEqual(2, window.rows[1].recent)

    -- The officer's own posts count too, under their alias.
    optIn(world)
    world.handlers.post(world.shown[1].key)
    test.assertEqual(2, #window.rows)
    test.assertEqual("Visitor-Stormrage", window.rows[1].label)
    test.assertEqual("TheTool", window.rows[2].label)
    test.assertEqual(1, window.rows[2].total)
end)

test.test("recruiters: a regular member can't open the view", function()
    local world = login("Retail", { playerName = MEMBER })
    local window = recruitersWindow(world)

    test.assertEqual(nil, world.addon.rosterController:Recruiters())
    world.addon.rosterController:RefreshRecruiters()
    test.assertEqual(nil, window.rows)
end)

for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]
    local zones = ZONES[profile]

    test.test(profile .. ": out in the world with Trade greyed out, there's no Trade prompt", function()
        local world = login(profile)
        optIn(world)
        inCity(world, zones.here[2])
        test.assertTrue(promptFor(world, "Advertise in Trade?") ~= nil)

        -- Leaving the city: the client keeps the player in Trade but
        -- disables it until they're back in one.
        world.zone = { mapID = zones.there[1], name = zones.there[2] }
        world.channels = { [1] = "General - " .. zones.there[2], [2] = "Trade - City" }
        world.disabledChannels = { [2] = true }
        fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")

        test.assertEqual(nil, promptFor(world, "Advertise in Trade?"))
        test.assertEqual(1, #world.shown)
        test.assertEqual("Advertise in " .. zones.there[2] .. " General?", world.shown[1].text)
        test.assertEqual(nil, world.addon.guildRecruit:Post("trade"))
        test.assertEqual(0, #world.chat)
    end)
end

test.test("recruitment settings: the use-officer-ad info shows the guild ad, or that there isn't one", function()
    local officer = login("Retail", { playerName = OFFICER })
    test.assertEqual("The officers haven't set a guild ad yet.", officer.addon.settings:Info("recruitUseOfficerAd"))

    officer.addon.settings:Set("recruitGuildAd", "Knights recruit! Whisper for an invite.")

    test.assertEqual("Knights recruit! Whisper for an invite.", officer.addon.settings:Info("recruitUseOfficerAd"))
end)

-- The channels a tester's Retail client listed out in the world: Trade,
-- Services and TradeLocal are there but disabled.
local function outInTheWorld(world, zoneName)
    world.channels = {
        [1] = "General - " .. zoneName,
        [2] = "Trade - City",
        [3] = "LocalDefense - " .. zoneName,
        [4] = "Services - City",
        [5] = "TradeLocal - City",
    }
    world.disabledChannels = { [2] = true, [4] = true, [5] = true }
end

test.test("guild recruit: with the channel list a tester's client gave out in the world, there's no Trade prompt", function()
    local world = login("Retail")
    optIn(world)
    outInTheWorld(world, "Dornogal")
    fixtures.fire(world, "CHANNEL_UI_UPDATE")

    test.assertEqual(1, #world.shown)
    test.assertEqual("Advertise in Dornogal General?", world.shown[1].text)
end)

test.test("guild recruit: Trade disabled a moment after leaving a city closes its prompt", function()
    local world = login("Retail")
    optIn(world)
    inCity(world, "Dornogal")
    test.assertTrue(promptFor(world, "Advertise in Trade?") ~= nil)

    -- The new zone is reported while Trade still looks usable...
    world.zone = { mapID = 2248, name = "Isle of Dorn" }
    world.channels = { [1] = "General - Isle of Dorn", [2] = "Trade - City" }
    fixtures.fire(world, "ZONE_CHANGED_NEW_AREA")
    test.assertTrue(promptFor(world, "Advertise in Trade?") ~= nil)

    -- ...and the client disables it a moment later, with a channel notice.
    world.disabledChannels = { [2] = true }
    fixtures.fire(world, "CHAT_MSG_CHANNEL_NOTICE", "SUSPENDED", "", "", "2. Trade - City")

    test.assertEqual(nil, promptFor(world, "Advertise in Trade?"))
    test.assertEqual("Advertise in Isle of Dorn General?", world.shown[1].text)
end)
