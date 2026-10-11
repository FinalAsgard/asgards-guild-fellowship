local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local HOUR = 60 * 60
local AD = "Knights of Camelot is recruiting! Whisper me for an invite."

-- The whole add-on logged in on `profile`, with the roster scanned, and the
-- recruit prompts it last drew in `world.shown` (Post through
-- `world.handlers.post`).
local function login(profile, options)
    local world = fixtures.newEnvironment(profile, options)
    if options and options.time then
        world.time = options.time
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
    world.channels = { [1] = "General - " .. name, [2] = "Trade - City" }
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
    world.channels = { [2] = "Trade - City" }
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
