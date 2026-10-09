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
        view = {
            Show = function(_, prompts, handlers)
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

test.test("guild greet: a prompt leaves the screen when its 2 minutes are up", function()
    local world = setup("Retail")
    world.greet:OnPresence("online", world.names.bolt)

    advance(world, 119)
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
        fixtures.fire(world, "CHAT_MSG_SYSTEM", nil)

        test.assertEqual("online:Bolt Iron,offline:Bolt-Area52,join:Bolt Iron", table.concat(heard, ","))
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
