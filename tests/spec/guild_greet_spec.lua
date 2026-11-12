local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local START = 1790000000
local MINUTE = 60

local RULES = {
    Retail = { twoPartNames = false, homeRealm = "Area52" },
    Forever = { twoPartNames = true, homeRealm = "Camelot" },
}

-- Per client: the user (Toolbox) with an alt; Anvil with an alt; Bishop with
-- the alias Rip; Bolt on their own; and Rust, away for two months. Names as
-- each client's roster and system messages spell them.
local NAMES = {
    Retail = {
        me = "Toolbox-Area52", myAlt = "Hammer-Area52", anvil = "Anvil-Area52", tongs = "Tongs-Area52",
        bishop = "Bishop-Area52", bolt = "Bolt-Area52", rust = "Rust-Area52", friend = "Pal-Stormrage",
        newt = "Newt-Area52",
    },
    Forever = {
        me = "Tool Box", myAlt = "Hammer Smith", anvil = "Anvil Stone", tongs = "Tongs Stone",
        bishop = "Bishop Gray", bolt = "Bolt Iron", rust = "Rust Iron", friend = "Pal Friend",
        newt = "Newt Scamander",
    },
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
        "Core/GuildGreet.lua"
    )
end

-- A scanned guild with Guild Greet over it. The world records what was sent
-- and what the prompts view was last asked to show; `world.time` is the
-- clock and `world.timers` the pending timers.
local function setup(profile)
    local addon = load()
    local names = NAMES[profile]
    local rules = RULES[profile]
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)
    local partition = store:Partition({ name = "Knights", realm = rules.homeRealm })
    local normalizer = addon.NameNormalizer.Create(rules)
    local world = {
        addon = addon, names = names, database = database, store = store,
        sent = {}, timers = {}, time = START, shown = {},
    }
    -- Each entry: name, note, and the roster's last-online time ({ years,
    -- months, days, hours }; nil while online). Tongs has been away 45 days,
    -- but its main Anvil logged in 2 days ago.
    local entries = {
        { names.me, "" },
        { names.myAlt, ">" .. names.me, { years = 0, months = 0, days = 0, hours = 3 } },
        { names.anvil, "", { years = 0, months = 0, days = 2, hours = 0 } },
        { names.tongs, ">" .. names.anvil, { years = 0, months = 1, days = 15, hours = 0 } },
        { names.bishop, "@Rip", { years = 0, months = 0, days = 1, hours = 0 } },
        { names.bolt, "", { years = 0, months = 0, days = 0, hours = 5 } },
        { names.rust, "", { years = 0, months = 2, days = 0, hours = 0 } },
    }
    local members = {}
    local index
    for index = 1, #entries do
        members[normalizer:Key(entries[index][1])] = {
            name = entries[index][1], note = entries[index][2], level = 60,
        }
    end
    addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition, members = members, normalizer = normalizer,
        rules = rules, mode = "initial", now = START,
    }))
    world.greet = addon.GuildGreet.Create({
        context = function()
            return partition, normalizer
        end,
        selfKey = function()
            return normalizer:Key(names.me)
        end,
        store = function()
            return store
        end,
        now = function()
            return world.time
        end,
        after = function(seconds, callback)
            table.insert(world.timers, { at = world.time + seconds, callback = callback })
            return true
        end,
        random = function(low)
            return low
        end,
        send = function(text)
            table.insert(world.sent, text)
            return true
        end,
        announce = function(message)
            world.announced = world.announced or {}
            table.insert(world.announced, message)
            return true
        end,
        -- Prompts show at once unless a spec sets `world.showDelay`.
        showDelay = function()
            return world.showDelay or 0
        end,
        inInstance = function()
            return world.inInstance == true
        end,
        -- Unknown (no greet weight delay) unless a spec sets it.
        addonOnline = function()
            return world.addonOnline
        end,
        view = {
            Show = function(_, prompts, handlers, lockedFor)
                world.lockedFor = lockedFor
                world.shown = {}
                local promptIndex
                for promptIndex = 1, #prompts do
                    table.insert(world.shown, prompts[promptIndex])
                end
                world.handlers = handlers
            end,
        },
    })
    world.greet:OnRosterUpdate(function()
        local roster = {}
        local entryIndex
        for entryIndex = 1, #entries do
            table.insert(roster, {
                name = entries[entryIndex][1],
                online = entries[entryIndex][3] == nil,
                lastOnline = entries[entryIndex][3],
            })
        end
        return roster
    end)
    return world
end

local function advance(world, seconds)
    world.time = world.time + seconds
    local index = 1
    while index <= #world.timers do
        if world.timers[index].at <= world.time then
            local timer = table.remove(world.timers, index)
            timer.callback()
        else
            index = index + 1
        end
    end
end

local index
for index = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[index]

    test.test(profile .. ": a guild member logging in gets a prompt, and Greet posts a starter greeting", function()
        local world = setup(profile)

        world.greet:OnPresence("online", world.names.bolt)

        test.assertEqual(1, #world.shown)
        test.assertEqual("login", world.shown[1].category)
        test.assertEqual(string.match(world.names.bolt, "^[^%-]+"), world.shown[1].label)

        world.handlers.greet(world.shown[1].player)

        test.assertEqual("Hey " .. string.match(world.names.bolt, "^[^%-]+") .. "!", world.sent[1])
        test.assertEqual(0, #world.shown)
        test.assertEqual("table", type(world.database.greet.greetings.join))
    end)

    test.test(profile .. ": {name} uses the alias or main, {character} the character that logged in", function()
        local world = setup(profile)
        world.store:GetGreetState().greetings = { login = { "Hi {name} on {character}" } }

        world.greet:OnPresence("online", world.names.tongs)
        world.greet:OnPresence("online", world.names.bishop)
        world.handlers.greet(world.shown[1].player)
        -- Greet unlocks 2 seconds after the first greeting.
        advance(world, 2)
        world.handlers.greet(world.shown[1].player)

        local anvil = string.match(world.names.anvil, "^[^%-]+")
        local tongs = string.match(world.names.tongs, "^[^%-]+")
        local bishop = string.match(world.names.bishop, "^[^%-]+")
        test.assertEqual("Hi " .. anvil .. " on " .. tongs, world.sent[1])
        test.assertEqual("Hi Rip on " .. bishop, world.sent[2])
    end)

    test.test(profile .. ": {main} and the first and last name placeholders", function()
        local world = setup(profile)
        world.store:GetGreetState().greetings = {
            login = { "{main}|{mainFirst}|{MAINLAST}|{characterfirst}|{CharacterLast}|{name}" },
        }

        world.greet:OnPresence("online", world.names.tongs)
        world.greet:OnPresence("online", world.names.bishop)
        world.handlers.greet(world.shown[1].player)
        -- Greet unlocks 2 seconds after the first greeting.
        advance(world, 2)
        world.handlers.greet(world.shown[1].player)

        if profile == "Forever" then
            test.assertEqual("Anvil Stone|Anvil|Stone|Tongs|Stone|Anvil Stone", world.sent[1])
            -- {main} is the main's name even when the player has an alias.
            test.assertEqual("Bishop Gray|Bishop|Gray|Bishop|Gray|Rip", world.sent[2])
        else
            -- Retail names are one word, so first and last are the whole name.
            test.assertEqual("Anvil|Anvil|Anvil|Tongs|Tongs|Anvil", world.sent[1])
            test.assertEqual("Bishop|Bishop|Bishop|Bishop|Bishop|Rip", world.sent[2])
        end
    end)

    test.test(profile .. ": a character the database doesn't know is its own main", function()
        local world = setup(profile)
        local raw = profile == "Forever" and "Newt Scamander" or "Newt-Area52"
        local _, normalizer = world.greet.context()

        local names = world.greet:Names(normalizer:Key(raw), raw)

        local first = "Newt"
        local last = profile == "Forever" and "Scamander" or "Newt"
        test.assertEqual(first, names.mainfirst)
        test.assertEqual(last, names.mainlast)
        test.assertEqual(names.character, names.main)
        test.assertEqual(names.character, names.name)
    end)

    test.test(profile .. ": a welcome back follows a logoff of 15 minutes, and relogs are quiet", function()
        local world = setup(profile)
        world.greet:OnPresence("online", world.names.anvil)
        world.handlers.close(world.shown[1].player)

        world.greet:OnPresence("offline", world.names.anvil)
        advance(world, 5 * MINUTE)
        world.greet:OnPresence("online", world.names.tongs)
        test.assertEqual(0, #world.shown)

        world.greet:OnPresence("offline", world.names.tongs)
        advance(world, 15 * MINUTE)
        world.greet:OnPresence("online", world.names.anvil)
        test.assertEqual("welcomeBack", world.shown[1].category)
        world.handlers.greet(world.shown[1].player)
        test.assertEqual("Welcome back, " .. string.match(world.names.anvil, "^[^%-]+") .. "!", world.sent[1])
    end)

    test.test(profile .. ": no prompts for the user's characters, friends, or players already online", function()
        local world = setup(profile)

        world.greet:OnPresence("online", world.names.myAlt)
        world.greet:OnPresence("online", world.names.friend)
        world.greet:OnPresence("online", world.names.me)

        test.assertEqual(0, #world.shown)
    end)
end

test.test("guild greet: a prompt leaves the screen when its 90 seconds are up", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)

    advance(world, 89)
    test.assertEqual(1, #world.shown)
    advance(world, 1)
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: turning Guild Greet off clears prompts and stops new ones", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)

    world.store:SetGreetEnabled(false)
    world.greet:OnEnabledChanged(false)
    test.assertEqual(0, #world.shown)

    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual(0, #world.shown)
    test.assertEqual(0, #world.sent)
end)

test.test("guild greet: nothing is prompted until the first loaded roster", function()
    local addon = load()
    local greet = addon.GuildGreet.Create({
        context = function() return nil end,
        selfKey = function() return nil end,
        store = function() return nil end,
        now = function() return START end,
        after = function() return true end,
        random = function(low) return low end,
        send = function() return true end,
    })

    greet:OnRosterUpdate(function() return {} end)
    greet:OnPresence("online", "Bolt-Area52")

    test.assertFalse(greet.policy:IsReady())
    test.assertEqual(0, #greet.queue:Visible(START))
end)

test.test("guild greet: the Guild Greet setting is on by default and saved account-wide", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertTrue(store:GreetEnabled())
    test.assertTrue(store:SetGreetEnabled(false))
    test.assertFalse(addon.FellowshipStore.Create(database):GreetEnabled())

    database.greet = { enabled = "off" }
    test.assertTrue(store:GreetEnabled())
    test.assertFalse(store:SetGreetEnabled(false))
    test.assertEqual("off", database.greet.enabled)

    database.greet = "corrupt"
    test.assertEqual(nil, store:GetGreetState())
    test.assertFalse(store:SetGreetEnabled(true))
end)

-- The adapter -----------------------------------------------------------------

local function client(profile)
    local world = fixtures.newEnvironment(profile)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(world.environment), world, addon
end

test.test("presence patterns match the client's online and offline messages", function()
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    local patternFor = addon.Compatibility.PatternFor

    test.assertEqual("Bolt Iron", string.match("|Hplayer:Bolt Iron|h[Bolt Iron]|h has come online.",
        patternFor("|Hplayer:%s|h[%s]|h has come online.")))
    test.assertEqual("Bolt-Area52", string.match("Bolt-Area52 has gone offline.",
        patternFor("%s has gone offline.")))
    test.assertEqual("Bolt", string.match("Bolt ist jetzt offline.", patternFor("%1$s ist jetzt offline.")))
    test.assertEqual(nil, string.match("Bolt has gone offline. Really.", patternFor("%s has gone offline.")))
    test.assertEqual(nil, patternFor(nil))
end)

local profileIndex
for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]

    test.test(profile .. ": system messages become online, offline, and join events", function()
        local compat, world = client(profile)
        world.environment.ERR_FRIEND_ONLINE_SS = "|Hplayer:%s|h[%s]|h has come online."
        world.environment.ERR_FRIEND_OFFLINE_S = "%s has gone offline."
        world.environment.ERR_GUILD_JOIN_S = "%s has joined the guild."
        local heard = {}

        test.assertTrue(compat:ObservePresence(function(kind, name)
            table.insert(heard, kind .. ":" .. name)
        end))
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "|Hplayer:Bolt Iron|h[Bolt Iron]|h has come online.")
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Bolt-Area52 has gone offline.")
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "Bolt Iron has joined the guild.")
        fixtures.fire(world, "CHAT_MSG_SYSTEM", "No player named 'Bolt-Area52' is currently playing.")
        fixtures.fire(world, "CHAT_MSG_SYSTEM", nil)

        test.assertEqual("online:Bolt Iron,offline:Bolt-Area52,join:Bolt Iron,notFound:Bolt-Area52",
            table.concat(heard, ","))
    end)
end

test.test("presence events skip messages the client hides from add-ons", function()
    local compat, world = client("Retail")
    world.environment.issecretvalue = function(value)
        return value == "secret"
    end
    world.environment.ERR_FRIEND_OFFLINE_S = "%s has gone offline."
    local heard = 0
    compat:ObservePresence(function()
        heard = heard + 1
    end)

    fixtures.fire(world, "CHAT_MSG_SYSTEM", "secret")
    test.assertEqual(0, heard)
end)

test.test("greetings are posted to guild chat on either client", function()
    local retail, retailWorld = client("Retail")
    local posted
    retailWorld.environment.C_ChatInfo = {
        SendChatMessage = function(text, channel)
            posted = channel .. ":" .. text
        end,
    }
    test.assertTrue(retail:SendGuildMessage("Hey Bolt!"))
    test.assertEqual("GUILD:Hey Bolt!", posted)

    local forever, foreverWorld = client("Forever")
    foreverWorld.environment.SendChatMessage = function(text, channel)
        posted = channel .. ":" .. text
    end
    test.assertTrue(forever:SendGuildMessage("Hi Bolt!"))
    test.assertEqual("GUILD:Hi Bolt!", posted)

    foreverWorld.environment.SendChatMessage = function()
        error("restricted")
    end
    test.assertFalse(forever:SendGuildMessage("Hi Bolt!"))
    test.assertFalse(forever:SendGuildMessage(""))
end)

-- Joins and long absences ----------------------------------------------------

local function firstWord(name)
    return string.match(name, "^[^%-]+")
end

local joinIndex
for joinIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[joinIndex]

    test.test(profile .. ": a player away 30+ days gets a long-absence prompt and greeting", function()
        local world = setup(profile)

        world.greet:OnPresence("online", world.names.rust)

        test.assertEqual("longAbsence", world.shown[1].category)
        world.handlers.greet(world.shown[1].player)
        test.assertEqual(firstWord(world.names.rust) .. "! Long time no see, welcome back!", world.sent[1])
    end)

    test.test(profile .. ": a long absence counts the latest login on any of the player's characters", function()
        local world = setup(profile)

        -- Tongs was away 45 days, but its main Anvil logged in 2 days ago.
        world.greet:OnPresence("online", world.names.tongs)

        test.assertEqual("login", world.shown[1].category)
    end)

    test.test(profile .. ": someone joining gets a join prompt, and their login no separate one", function()
        local world = setup(profile)

        world.greet:OnPresence("join", world.names.newt)
        world.greet:OnPresence("online", world.names.newt)

        test.assertEqual(1, #world.shown)
        test.assertEqual("join", world.shown[1].category)
        test.assertEqual(firstWord(world.names.newt), world.shown[1].label)
        world.handlers.greet(world.shown[1].player)
        test.assertEqual("Welcome to the guild, " .. firstWord(world.names.newt) .. "!", world.sent[1])
    end)

    test.test(profile .. ": someone not yet in the guild is ignored until their join message", function()
        local world = setup(profile)
        local _, normalizer = world.greet.context()
        world.greet:OnPresence("online", world.names.newt)
        test.assertEqual(0, #world.shown)

        world.greet:OnPresence("join", world.names.newt)
        test.assertEqual("join", world.shown[1].category)
        test.assertEqual("character:" .. normalizer:Key(world.names.newt), world.shown[1].player)
    end)
end

test.test("guild greet: roster last-online times convert to hours away", function()
    local addon = load()
    local hoursAway = addon.GuildGreet.HoursAway

    test.assertEqual(5, hoursAway({ years = 0, months = 0, days = 0, hours = 5 }))
    test.assertEqual(30 * 24, hoursAway({ years = 0, months = 1, days = 0, hours = 0 }))
    test.assertEqual(360 * 24 + 26, hoursAway({ years = 1, months = 0, days = 1, hours = 2 }))
    test.assertEqual(nil, hoursAway(nil))
end)

-- Combat ---------------------------------------------------------------------

test.test("guild greet: prompts wait out combat and appear afterward if still current", function()
    local world = setup("Retail")

    world.greet:OnCombatChanged(true)
    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(0, #world.shown)

    advance(world, 60)
    world.greet:OnPresence("online", world.names.rust)
    advance(world, 61)
    world.greet:OnCombatChanged(false)

    -- Bolt's prompt expired during the fight; Rust's is still current.
    test.assertEqual(1, #world.shown)
    test.assertEqual("longAbsence", world.shown[1].category)
end)

local combatIndex
for combatIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[combatIndex]

    test.test(profile .. ": entering and leaving combat is reported", function()
        local compat, world = client(profile)
        local states = {}

        test.assertEqual(false, compat:ObserveCombat(function(busy)
            table.insert(states, tostring(busy))
        end))
        fixtures.fire(world, "PLAYER_REGEN_DISABLED")
        fixtures.fire(world, "PLAYER_REGEN_ENABLED")
        fixtures.fire(world, "ENCOUNTER_START")
        fixtures.fire(world, "PLAYER_REGEN_DISABLED")
        fixtures.fire(world, "PLAYER_REGEN_ENABLED")
        -- Still in the encounter after combat drops between pulls.
        fixtures.fire(world, "ENCOUNTER_END")

        test.assertEqual("true,false,true,true,true,false", table.concat(states, ","))
    end)
end

test.test("combat that's already under way when Greet starts is reported", function()
    local compat, world = client("Retail")
    world.inCombat = true
    test.assertEqual(true, compat:ObserveCombat(function() end))

    local encounter, encounterWorld = client("Retail")
    encounterWorld.inEncounter = true
    test.assertEqual(true, encounter:ObserveCombat(function() end))
end)

-- Editing greetings -------------------------------------------------------------

test.test("guild greet: a category with no greetings shows no prompts, and restoring brings them back", function()
    local world = setup("Retail")
    local library = world.greet:Library()
    while #library:Greetings("login") > 0 do
        library:Remove("login", 1)
    end

    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(0, #world.shown)
    -- Other categories still prompt.
    world.greet:OnPresence("join", world.names.newt)
    test.assertEqual(1, #world.shown)
    test.assertEqual("join", world.shown[1].category)

    world.greet:Library():Restore("login")
    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual(2, #world.shown)
    test.assertEqual("login", world.shown[2].category)
end)

test.test("guild greet: a greeting added or edited in the window is used by the next greet", function()
    local world = setup("Forever")
    local library = world.greet:Library()
    library:Restore("login")
    library:Remove("login", 3)
    library:Remove("login", 2)
    library:Edit("login", 1, "Ahoy {characterFirst}!")

    world.greet:OnPresence("online", world.names.bolt)
    world.handlers.greet(world.shown[1].player)

    test.assertEqual("Ahoy Bolt!", world.sent[1])
end)

-- Greeter coordination -------------------------------------------------------------

-- The first word of a name as the roster spells it: how guildmates write it
-- in chat ("Anvil" for Anvil-Area52 or Anvil Stone).
local function spoken(name)
    return string.match(name, "^[^%-%s]+")
end

-- `greeter` says `text` in guild chat: by default a greeting naming `name`.
-- Returns whether it counted for any prompt.
local function greeted(world, greeter, name, text)
    return world.greet:OnGuildChat(text or ("Hi " .. spoken(name) .. "!"), world.names[greeter]) > 0
end

local coordinationIndex
for coordinationIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[coordinationIndex]

    test.test(profile .. ": the user's own greeting counts once, even when it shows in guild chat", function()
        local world = setup(profile)
        local _, normalizer = world.greet.context()
        world.store:SetGreetCap(3)
        world.greet:OnPresence("online", world.names.tongs)
        world.greet:OnPresence("online", world.names.bolt)

        world.handlers.greet(world.shown[1].player)
        world.greet:OnGuildChat(world.sent[1], world.names.me)

        local tongs = world.greet.policy:PlayerOf(normalizer:Key(world.names.tongs))
        test.assertEqual(1, world.greet.tally:Count(tongs, world.time))
    end)

    test.test(profile .. ": two greetings in guild chat close the prompt, naming the character or the main", function()
        local world = setup(profile)
        -- Tongs is Anvil's alt.
        world.greet:OnPresence("online", world.names.tongs)

        test.assertTrue(greeted(world, "bishop", world.names.tongs))
        test.assertEqual(1, #world.shown)

        test.assertTrue(greeted(world, "bolt", world.names.anvil, "wb " .. string.lower(spoken(world.names.anvil))))
        test.assertEqual(0, #world.shown)
    end)
end

test.test("guild greet: the cap setting decides when the prompt closes", function()
    local world = setup("Retail")
    world.store:SetGreetCap(1)
    world.greet:OnPresence("online", world.names.anvil)
    greeted(world, "bishop", world.names.anvil)
    test.assertEqual(0, #world.shown)

    world = setup("Retail")
    world.store:SetGreetCap(3)
    world.greet:OnPresence("online", world.names.anvil)
    greeted(world, "bishop", world.names.anvil)
    greeted(world, "bolt", world.names.anvil)
    test.assertEqual(1, #world.shown)
    greeted(world, "rust", world.names.anvil)
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a player greeted enough is prompted again once the welcome-back window passes", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)
    greeted(world, "bishop", world.names.bolt)
    greeted(world, "anvil", world.names.bolt)
    test.assertEqual(0, #world.shown)

    world.greet:OnPresence("offline", world.names.bolt)
    advance(world, 15 * MINUTE)
    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(1, #world.shown)
    test.assertEqual("welcomeBack", world.shown[1].category)
end)

test.test("guild greet: only lines naming the arrival count, once per greeter, never their own", function()
    local world = setup("Retail")
    world.store:SetGreetCap(3)
    world.greet:OnPresence("online", world.names.bishop)

    -- Nameless greetings, and the name inside a longer word, don't count.
    test.assertFalse(greeted(world, "bolt", nil, "wb!"))
    test.assertFalse(greeted(world, "bolt", nil, "hi all"))
    test.assertFalse(greeted(world, "bolt", nil, "who has bishops?"))
    -- The arrival's own lines don't count.
    test.assertFalse(greeted(world, "bishop", world.names.bishop))
    -- Their alias does, in any case, but each greeter only once.
    test.assertTrue(greeted(world, "bolt", nil, "hey RIP"))
    test.assertFalse(greeted(world, "bolt", world.names.bishop))
    -- The user's own typed greeting counts, once for all their characters.
    test.assertTrue(greeted(world, "me", world.names.bishop))
    test.assertFalse(greeted(world, "myAlt", world.names.bishop))
    test.assertEqual(1, #world.shown)
    test.assertTrue(greeted(world, "anvil", world.names.bishop))
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a line naming two arrivals counts for both", function()
    local world = setup("Retail")
    world.store:SetGreetCap(1)
    world.greet:OnPresence("online", world.names.bolt)
    world.greet:OnPresence("online", world.names.rust)

    test.assertTrue(greeted(world, "bishop", nil, "hey Bolt and Rust"))
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a guildmate from a connected realm is named without the realm", function()
    local world = setup("Retail")
    world.store:SetGreetCap(1)
    world.greet:OnPresence("join", "Visitor-Stormrage")
    world.store:SetGreetNumber("welcomeCap", 1)
    test.assertEqual(1, #world.shown)

    test.assertTrue(greeted(world, "bishop", nil, "welcome Visitor!"))
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: someone who just joined is greeted by name before the roster knows them", function()
    local world = setup("Retail")
    world.store:SetGreetNumber("welcomeCap", 1)

    world.greet:OnPresence("join", world.names.newt)
    test.assertEqual(1, #world.shown)
    test.assertTrue(greeted(world, "bishop", world.names.newt))
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a prompt closes when its player goes offline", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.anvil)
    world.greet:OnPresence("online", world.names.bolt)

    world.greet:OnPresence("offline", world.names.anvil)

    test.assertEqual(1, #world.shown)
    test.assertContains(world.shown[1].label, "Bolt")
end)

test.test("guild greet: accented names match whatever their case, but a one-letter name never does", function()
    local world = setup("Retail")
    world.store:SetGreetCap(1)
    local partition, normalizer = world.greet.context()
    local bolt = partition:GetCharacter(normalizer:Key(world.names.bolt)).player
    partition:SetAlias(bolt, "\195\137owyn", "manual")
    world.greet:OnPresence("online", world.names.bolt)

    -- "É" is one letter, two bytes.
    partition:SetAlias(bolt, "\195\137", "manual")
    test.assertFalse(greeted(world, "bishop", nil, "\195\169 verdade"))
    partition:SetAlias(bolt, "\195\137owyn", "manual")
    test.assertTrue(greeted(world, "bishop", nil, "welcome \195\169owyn"))
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: an alias with a dash is matched whole, never cut like a realm", function()
    local world = setup("Retail")
    world.store:SetGreetCap(1)
    local partition, normalizer = world.greet.context()
    local bolt = partition:GetCharacter(normalizer:Key(world.names.bolt)).player
    partition:SetAlias(bolt, "Tank-Healer", "manual")
    world.greet:OnPresence("online", world.names.bolt)

    test.assertFalse(greeted(world, "bishop", nil, "need a tank"))
    test.assertTrue(greeted(world, "bishop", nil, "hey Tank-Healer"))
end)

test.test("guild greet: another character of the player going offline leaves the prompt", function()
    local world = setup("Retail")
    -- Tongs is Anvil's alt: both online at once, Tongs' prompt showing.
    world.greet:OnPresence("online", world.names.tongs)
    test.assertEqual(1, #world.shown)

    world.greet:OnPresence("offline", world.names.anvil)
    test.assertEqual(1, #world.shown)
    world.greet:OnPresence("offline", world.names.tongs)
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a newcomer linked by a scan after joining still can't greet themselves, and going "
    .. "offline closes the prompt", function()
    local world = setup("Retail")
    world.store:SetGreetNumber("welcomeCap", 1)
    world.greet:OnPresence("join", world.names.newt)
    test.assertEqual(1, #world.shown)

    -- The scan records Newt, with a player of their own.
    local partition, normalizer = world.greet.context()
    partition:RecordCharacter(normalizer:Key(world.names.newt), { name = world.names.newt, level = 1 })
    test.assertFalse(greeted(world, "newt", world.names.newt))
    test.assertEqual(1, #world.shown)

    world.greet:OnPresence("offline", world.names.newt)
    test.assertEqual(0, #world.shown)
end)

-- Older versions' "greeted" message (GuildGreet.LEGACY_GREETED) --------------------

-- A "greeted" message from `greeter` about `name`, for an arrival at `at`.
local function legacyGreeted(world, greeter, name, at)
    local _, normalizer = world.greet.context()
    return world.greet:OnGreeted({
        v = world.addon.GuildGreet.PROTOCOL,
        t = world.addon.GuildGreet.TYPE_GREETED,
        c = normalizer:Key(name),
        a = at or world.time,
    }, world.names[greeter])
end

test.test("guild greet: pressing Greet tells older versions, a typed greeting doesn't", function()
    local world = setup("Retail")
    local _, normalizer = world.greet.context()
    world.store:SetGreetCap(3)
    world.greet:OnPresence("online", world.names.tongs)

    test.assertTrue(greeted(world, "me", world.names.tongs))
    test.assertEqual(nil, world.announced, "typed by hand: nothing sent")

    world.greet:OnPresence("online", world.names.bolt)
    world.handlers.greet(world.shown[2].player)
    test.assertEqual(1, #world.announced)
    local message = world.announced[1]
    test.assertEqual(1, message.v)
    test.assertEqual("greeted", message.t)
    test.assertEqual(normalizer:Key(world.names.bolt), message.c)
    test.assertEqual(START, message.a)
end)

test.test("guild greet: an older version's greeted message counts once per greeter and closes the prompt", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.anvil)

    -- Heard in guild chat and as the message: one greeting.
    test.assertTrue(greeted(world, "bishop", world.names.anvil))
    test.assertFalse(legacyGreeted(world, "bishop", world.names.anvil))
    test.assertEqual(1, #world.shown)
    -- The message alone counts, for any of the player's characters.
    test.assertTrue(legacyGreeted(world, "bolt", world.names.tongs))
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: own, late, unplaceable and malformed greeted messages don't count", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.anvil)

    test.assertFalse(legacyGreeted(world, "me", world.names.anvil))
    test.assertFalse(legacyGreeted(world, "myAlt", world.names.anvil))
    test.assertFalse(legacyGreeted(world, "bolt", world.names.anvil, START - 15 * MINUTE))
    test.assertFalse(legacyGreeted(world, "bolt", world.names.friend))
    test.assertFalse(world.greet:OnGreeted({ v = 1, t = "greeted", c = 42, a = START }, world.names.bolt))
    test.assertFalse(world.greet:OnGreeted({ v = 99, t = "greeted", c = "anvil", a = START }, world.names.bolt))
    test.assertEqual(1, #world.shown)
end)

test.test("guild greet: with LEGACY_GREETED off, the greeted message is neither sent nor counted", function()
    local world = setup("Retail")
    world.addon.GuildGreet.LEGACY_GREETED = false
    world.store:SetGreetCap(1)
    world.greet:OnPresence("online", world.names.anvil)

    test.assertFalse(legacyGreeted(world, "bishop", world.names.anvil))
    test.assertEqual(1, #world.shown)
    world.handlers.greet(world.shown[1].player)
    test.assertEqual(nil, world.announced)
end)

test.test("guild greet: the greeting cap is saved account-wide, from 1 to 10, default 2", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertEqual(2, store:GreetCap())
    test.assertTrue(store:SetGreetCap(10))
    test.assertEqual(10, addon.FellowshipStore.Create(database):GreetCap())
    test.assertFalse(store:SetGreetCap(0))
    test.assertFalse(store:SetGreetCap(11))
    test.assertFalse(store:SetGreetCap(2.5))
    test.assertEqual(10, store:GreetCap())

    database.greet.cap = "lots"
    test.assertEqual(2, store:GreetCap())
    test.assertFalse(store:SetGreetCap(3))
    test.assertEqual("lots", database.greet.cap)
end)

-- Settings ------------------------------------------------------------------------

test.test("guild greet settings: categories, thresholds and characters default on, and save account-wide", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertTrue(store:GreetCategoryEnabled("login"))
    test.assertEqual(15, store:GreetNumber("welcomeBackMinutes"))
    test.assertEqual(3, store:GreetNumber("welcomeCap"))
    test.assertEqual(nil, store:GreetNumber("longAbsenceDays"), "a long absence is a fixed 30 days")
    test.assertTrue(store:GreetOnCharacter("toolbox"))

    test.assertTrue(store:SetGreetCategoryEnabled("login", false))
    test.assertTrue(store:SetGreetNumber("welcomeBackMinutes", 120))
    test.assertTrue(store:SetGreetNumber("welcomeCap", 1))
    test.assertTrue(store:SetGreetOnCharacter("toolbox", false))

    local again = addon.FellowshipStore.Create(database)
    test.assertFalse(again:GreetCategoryEnabled("login"))
    test.assertTrue(again:GreetCategoryEnabled("join"))
    test.assertEqual(120, again:GreetNumber("welcomeBackMinutes"))
    test.assertEqual(1, again:GreetNumber("welcomeCap"))
    test.assertFalse(again:GreetOnCharacter("toolbox"))
    test.assertTrue(again:GreetOnCharacter("hammer"))

    test.assertTrue(store:SetGreetOnCharacter("toolbox", true))
    test.assertTrue(store:GreetOnCharacter("toolbox"))
    test.assertEqual(nil, next(database.greet.offCharacters))
end)

test.test("guild greet settings: ranges are enforced and unusable saved values are left alone", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertFalse(store:SetGreetNumber("welcomeBackMinutes", 0))
    test.assertFalse(store:SetGreetNumber("welcomeBackMinutes", 121))
    test.assertFalse(store:SetGreetNumber("welcomeCap", 11))
    test.assertFalse(store:SetGreetNumber("welcomeCap", 1.5))
    test.assertFalse(store:SetGreetNumber("longAbsenceDays", 2))
    test.assertFalse(store:SetGreetNumber("nonsense", 3))
    test.assertEqual(nil, store:GreetNumber("nonsense"))

    database.greet = {
        welcomeBackMinutes = "soon", welcomeCap = -4,
        categories = "corrupt", offCharacters = "corrupt",
    }
    test.assertEqual(15, store:GreetNumber("welcomeBackMinutes"))
    test.assertEqual(3, store:GreetNumber("welcomeCap"))
    test.assertTrue(store:GreetCategoryEnabled("login"))
    test.assertTrue(store:GreetOnCharacter("toolbox"))
    test.assertFalse(store:SetGreetNumber("welcomeBackMinutes", 20))
    test.assertFalse(store:SetGreetCategoryEnabled("login", false))
    test.assertFalse(store:SetGreetOnCharacter("toolbox", false))
    test.assertEqual("soon", database.greet.welcomeBackMinutes)
    test.assertEqual("corrupt", database.greet.categories)
    test.assertEqual("corrupt", database.greet.offCharacters)
end)

test.test("guild greet: turning a category off stops its prompts only, and closes any waiting", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)
    world.greet:OnPresence("online", world.names.rust)

    world.store:SetGreetCategoryEnabled("login", false)
    world.greet:OnCategoryChanged("login", false)

    test.assertEqual(1, #world.shown)
    test.assertEqual("longAbsence", world.shown[1].category)
    world.greet:OnPresence("online", world.names.bishop)
    test.assertEqual(1, #world.shown)
end)

test.test("guild greet: the saved threshold changes the welcome-back boundary; a long absence stays 30 days", function()
    local world = setup("Retail")
    world.store:SetGreetNumber("welcomeBackMinutes", 5)
    -- Older saved data may still hold a long-absence setting; it's ignored.
    world.store:GetGreetState().longAbsenceDays = 2

    -- Anvil last logged in 2 days ago: a plain login.
    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual("login", world.shown[1].category)
    world.handlers.close(world.shown[1].player)

    world.greet:OnPresence("offline", world.names.anvil)
    advance(world, 5 * MINUTE)
    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual("welcomeBack", world.shown[1].category)
end)

test.test("guild greet: turning Greet off on one character keeps it on the others", function()
    local world = setup("Retail")
    local _, normalizer = world.greet.context()
    local me = normalizer:Key(world.names.me)
    world.store:SetGreetOnCharacter(me, false)

    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(0, #world.shown)

    -- The same saved data, logged in on the alt.
    world.greet.selfKey = function()
        return normalizer:Key(world.names.myAlt)
    end
    world.greet:OnPresence("online", world.names.bishop)
    test.assertEqual(1, #world.shown)
    test.assertEqual("table", type(world.store:GetGreetState().greetings))
end)

test.test("leaving an instance mid-encounter releases prompts after the loading screen", function()
    local compat, world = client("Retail")
    local states = {}
    compat:ObserveCombat(function(busy)
        table.insert(states, tostring(busy))
    end)

    world.inEncounter = true
    fixtures.fire(world, "ENCOUNTER_START")
    -- Hearthed out: no ENCOUNTER_END, then a loading screen.
    world.inEncounter = false
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")

    test.assertEqual("true,false", table.concat(states, ","))
end)

test.test("guild greet: greeting still finishes when the guild data is gone", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)
    local player = world.shown[1].player
    world.greet.context = function()
        return nil
    end

    world.handlers.greet(player)

    test.assertEqual(1, #world.sent)
    test.assertEqual(0, #world.shown)
end)

-- Show delay -----------------------------------------------------------------------

test.test("guild greet: a prompt shows 5 to 10 seconds after the arrival, picked at random", function()
    local world = setup("Retail")
    world.greet.showDelay = nil
    local asked
    world.greet.random = function(low, high)
        asked = low .. "-" .. high
        return 8
    end

    world.greet:OnPresence("join", world.names.newt)
    test.assertEqual("5-10", asked)
    test.assertEqual(0, #world.shown)
    advance(world, 7)
    test.assertEqual(0, #world.shown)
    advance(world, 1)
    test.assertEqual(1, #world.shown)
    -- It still gets its full 90 seconds on screen.
    advance(world, 89)
    test.assertEqual(1, #world.shown)
    advance(world, 1)
    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a player greeted enough while their prompt waits never gets one", function()
    local world = setup("Retail")
    world.showDelay = 10
    world.store:SetGreetCap(1)

    world.greet:OnPresence("online", world.names.bolt)
    greeted(world, "bishop", world.names.bolt)
    advance(world, 10)

    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a failing random pick still delays the prompt", function()
    local world = setup("Retail")
    world.greet.showDelay = nil
    world.greet.random = function()
        error("boom")
    end

    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(0, #world.shown)
    advance(world, 5)
    test.assertEqual(1, #world.shown)
end)

test.test("guild greet: without timers, a prompt shows at once instead of never", function()
    local world = setup("Retail")
    world.showDelay = 7
    world.greet.after = function()
        return false
    end

    world.greet:OnPresence("online", world.names.bolt)

    test.assertEqual(1, #world.shown)
end)

test.test("guild greet: each Greet adds weight, and with 3 add-on users online new prompts wait 2.5s a weight", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)
    world.greet:OnPresence("online", world.names.rust)
    world.greet:Greet(world.shown[1].player)
    advance(world, 2)
    world.greet:Greet(world.shown[1].player)
    -- The first press's 1 faded for the 2 seconds before the second.
    test.assertTrue(math.abs(world.store:GreetWeight().weight - (2 - 0.2 * 2 / 60)) < 1e-9)
    world.store:SetGreetWeight({ weight = 2, at = world.time })
    world.addonOnline = 3

    -- 2 weight: 5 seconds on top of the usual delay (0 here).
    advance(world, 30)
    local weight = world.greet:Weight(world.time)
    test.assertEqual(1.9, math.floor(weight * 10 + 0.5) / 10, "0.2 a minute fades 0.1 in 30 seconds")
    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual(0, #world.shown)
    advance(world, 4)
    test.assertEqual(0, #world.shown)
    advance(world, 1)
    test.assertEqual(1, #world.shown)
end)

test.test("guild greet: greet weight never delays with fewer than 3 add-on users online, or when unknown", function()
    local world = setup("Retail")
    world.store:SetGreetWeight({ weight = 6, at = world.time })

    world.addonOnline = 2
    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(1, #world.shown)

    world.addonOnline = nil
    world.greet:OnPresence("online", world.names.rust)
    test.assertEqual(2, #world.shown)
end)

test.test("guild greet: weight caps at 6 (15 seconds) and fades 1 every 5 minutes, also while away", function()
    local world = setup("Retail")
    world.store:SetGreetWeight({ weight = 6, at = world.time })
    world.greet:OnPresence("online", world.names.bolt)
    world.greet:Greet(world.shown[1].player)
    test.assertEqual(6, world.store:GreetWeight().weight, "no more than 6")
    world.addonOnline = 5

    -- Logged out for 10 minutes: 2 faded.
    advance(world, 600)
    test.assertEqual(4, world.greet:Weight(world.time))
    world.greet:OnPresence("online", world.names.rust)
    advance(world, 9)
    test.assertEqual(0, #world.shown)
    advance(world, 1)
    test.assertEqual(1, #world.shown)

    -- Gone entirely after 30 minutes.
    advance(world, 1800)
    test.assertEqual(0, world.greet:Weight(world.time))
end)

test.test("guild greet: others' greetings during the extra wait count, and the prompt never shows once enough", function()
    local world = setup("Retail")
    world.addonOnline = 4
    world.store:SetGreetCap(2)
    world.store:SetGreetWeight({ weight = 6, at = world.time })

    world.greet:OnPresence("online", world.names.bolt)
    test.assertTrue(greeted(world, "bishop", world.names.bolt))
    test.assertTrue(greeted(world, "rust", world.names.bolt))
    advance(world, 15)

    test.assertEqual(0, #world.shown)
end)

test.test("guild greet: a press while Greet is locked adds no weight", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)
    world.greet:OnPresence("online", world.names.rust)
    world.greet:Greet(world.shown[1].player)
    test.assertEqual(nil, world.greet:Greet(world.shown[1].player))

    test.assertEqual(1, world.store:GreetWeight().weight)
end)

test.test("greet: prompts in instances are on by default, and turned off none show inside one", function()
    local world = setup("Retail")
    world.inInstance = true

    -- On by default: inside an instance, arrivals are prompted as anywhere.
    test.assertTrue(world.store:GreetInInstances())
    world.greet:OnPresence("online", world.names.bolt)
    test.assertEqual(1, #world.shown)

    -- Turned off, the waiting prompt closes and new arrivals aren't prompted.
    test.assertTrue(world.store:SetGreetInInstances(false))
    world.greet:OnZoneChanged()
    test.assertEqual(0, #world.shown)
    world.greet:OnPresence("online", world.names.bishop)
    test.assertEqual(0, #world.shown)

    -- Out in the world again, arrivals are prompted, and the ones that came
    -- online inside aren't brought back.
    world.inInstance = false
    world.greet:OnZoneChanged()
    test.assertEqual(0, #world.shown)
    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual(1, #world.shown)

    -- The setting is kept, and an unusable saved value is left alone.
    test.assertFalse(world.store:GreetInInstances())
    world.database.greet.inInstances = "yes"
    test.assertTrue(world.store:GreetInInstances())
    test.assertFalse(world.store:SetGreetInInstances(false))
    test.assertFalse(world.store:SetGreetInInstances("off"))
end)

-- Greet cooldown ---------------------------------------------------------------

-- Bolt, Bishop and Anvil come online.
local function threeArrive(world)
    world.greet:OnPresence("online", world.names.bolt)
    world.greet:OnPresence("online", world.names.bishop)
    world.greet:OnPresence("online", world.names.anvil)
    test.assertEqual(3, #world.shown)
end

test.test("guild greet: Greet locks 2, then 4 seconds after greetings in a row, and resets once a lock ends unused",
    function()
        local world = setup("Retail")
        threeArrive(world)

        test.assertEqual("Hey Bolt!", world.greet:Greet(world.shown[1].player))
        test.assertEqual(2, world.lockedFor)
        -- A press while locked does nothing; the prompt stays.
        test.assertEqual(nil, world.greet:Greet(world.shown[1].player))
        test.assertEqual(2, #world.shown)
        test.assertEqual(1, #world.sent)
        advance(world, 1)
        test.assertEqual(1, world.lockedFor, "the countdown redraws every second")
        advance(world, 1)
        test.assertEqual(0, world.lockedFor)

        test.assertTrue(world.greet:Greet(world.shown[1].player) ~= nil)
        test.assertEqual(4, world.lockedFor, "the second greeting in a row locks for 4")
        advance(world, 4)
        test.assertTrue(world.greet:Greet(world.shown[1].player) ~= nil)
        test.assertEqual(6, world.lockedFor)
        test.assertEqual(3, #world.sent)

        -- The lock ends with no prompt showing, so the next starts at 2.
        advance(world, 6)
        world.greet:OnPresence("online", world.names.rust)
        world.greet:Greet(world.shown[1].player)
        test.assertEqual(4, #world.sent)
        test.assertEqual(2, world.lockedFor)
    end)

test.test("guild greet: a lock that ends with prompts still showing keeps the streak", function()
    local world = setup("Retail")
    threeArrive(world)

    world.greet:Greet(world.shown[1].player)
    advance(world, 30)
    world.greet:Greet(world.shown[1].player)

    test.assertEqual(4, world.lockedFor)
end)

test.test("guild greet: a prompt whose player others greeted enough during the lock closes unposted", function()
    local world = setup("Retail")
    threeArrive(world)
    world.greet:Greet(world.shown[1].player)

    test.assertTrue(greeted(world, "bolt", world.names.bishop))
    test.assertTrue(greeted(world, "rust", world.names.bishop))

    test.assertEqual(1, #world.shown, "only Anvil's prompt is left")
    advance(world, 2)
    world.greet:Greet(world.shown[1].player)
    test.assertEqual(2, #world.sent)
    test.assertContains(world.sent[2], string.match(world.names.anvil, "^[^%-]+"))
end)

test.test("guild greet: without timers, Greet never locks", function()
    local world = setup("Retail")
    world.greet.after = function()
        return false
    end
    world.showDelay = 0
    threeArrive(world)

    local index
    for index = 1, 3 do
        world.greet:Greet(world.shown[1].player)
    end

    test.assertEqual(3, #world.sent)
    test.assertEqual(0, world.lockedFor)
end)
