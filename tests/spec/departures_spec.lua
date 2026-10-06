local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/RosterViewModel.lua"
    )
end

local RULES = { twoPartNames = false, homeRealm = "Area52" }
local DAY = 86400
local START = 1790000000

-- Entries are { "Name-Realm", note, level, lastOnline } where lastOnline is
-- { years, months, days, hours } or "online".
local function setup()
    local addon = load()
    local database = { schemaVersion = 1, guilds = {} }
    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local state = { addon = addon, partition = partition, normalizer = normalizer, now = START }

    function state.roster(entries)
        local members = {}
        local index
        for index = 1, #entries do
            local entry = entries[index]
            local member = { name = entry[1], note = entry[2] or "", classToken = "WARRIOR", level = entry[3] or 10 }
            if entry[4] == "online" then
                member.online = true
            elseif type(entry[4]) == "table" then
                member.lastOnline = { years = entry[4][1], months = entry[4][2], days = entry[4][3], hours = entry[4][4] }
            end
            members[normalizer:Key(entry[1])] = member
        end
        return members
    end

    function state.scan(entries, mode)
        local plan = addon.ReconcileEngine.Plan({
            partition = partition,
            members = state.roster(entries),
            normalizer = normalizer,
            rules = RULES,
            mode = mode or "full",
            now = state.now,
        })
        return addon.ReconcileEngine.Apply(partition, plan)
    end

    function state.service()
        return addon.PlayerService.Create(partition, { now = function()
            return state.now
        end })
    end

    function state.playerOf(key)
        return partition:GetPlayer(partition:GetCharacter(key).player)
    end

    function state.conflictsOf(kind)
        local found = {}
        local index
        for index = 1, #partition:GetConflicts() do
            if partition:GetConflicts()[index].kind == kind then
                table.insert(found, partition:GetConflicts()[index])
            end
        end
        return found
    end

    return state
end

local GUILD = {
    { "Toolbox-Area52", "@TheTool", 80 },
    { "Hammer-Area52", ">Toolbox", 70 },
    { "Visitor-Area52", "", 30 },
}

test.test("characters missing from a complete roster are marked departed with a date", function()
    local state = setup()
    state.scan(GUILD, "initial")
    state.now = START + DAY

    local result = state.scan({ GUILD[1], GUILD[2] })

    test.assertEqual(1, result.departed)
    test.assertEqual(START + DAY, state.partition:GetCharacter("visitor-area52").departed)
    test.assertEqual(nil, state.partition:GetCharacter("toolbox-area52").departed)
end)

test.test("incremental checks and empty rosters never mark anyone departed", function()
    local state = setup()
    state.scan(GUILD, "initial")

    state.scan({ GUILD[1] }, "incremental")
    state.scan({})

    test.assertEqual(nil, state.partition:GetCharacter("hammer-area52").departed)
    test.assertEqual(nil, state.partition:GetCharacter("visitor-area52").departed)
end)

test.test("a rejoining character clears its departed flag and keeps its stored player", function()
    local state = setup()
    state.scan(GUILD, "initial")
    local player = state.partition:GetCharacter("hammer-area52").player
    state.scan({ GUILD[1], GUILD[3] })
    test.assertTrue(state.partition:GetCharacter("hammer-area52").departed ~= nil)

    local result = state.scan(GUILD, "incremental")

    test.assertEqual(1, result.rejoined)
    test.assertEqual(nil, state.partition:GetCharacter("hammer-area52").departed)
    test.assertEqual(player, state.partition:GetCharacter("hammer-area52").player)
end)

test.test("when a main departs the highest-level alt becomes acting main and history records it", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 75 },
    }, "initial")
    state.now = START + 2 * DAY

    local result = state.scan({
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 75 },
    })

    test.assertEqual(1, result.promoted)
    local player = state.playerOf("hammer-area52")
    test.assertEqual("wrench-area52", player.main)
    local history = player.history[1]
    test.assertEqual("toolbox-area52", history.character)
    test.assertEqual("Toolbox-Area52", history.name)
    test.assertEqual("main", history.role)
    test.assertEqual(START + 2 * DAY, history["until"])
    test.assertEqual("departed", history.reason)
    local promotions = state.conflictsOf("promotion")
    test.assertEqual(1, #promotions)
    test.assertEqual("wrench-area52", promotions[1].character)
    test.assertEqual("toolbox-area52", promotions[1].suggestion.former)
end)

test.test("ties on level go to whoever is online, then most recently online", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 80 },
        { "Old-Area52", ">Toolbox", 70, { 0, 2, 0, 0 } },
        { "Recent-Area52", ">Toolbox", 70, { 0, 0, 1, 0 } },
        { "Now-Area52", ">Toolbox", 70, "online" },
    }, "initial")

    state.scan({
        { "Old-Area52", ">Toolbox", 70, { 0, 2, 0, 0 } },
        { "Recent-Area52", ">Toolbox", 70, { 0, 0, 1, 0 } },
        { "Now-Area52", ">Toolbox", 70, "online" },
    })
    test.assertEqual("now-area52", state.playerOf("old-area52").main)

    local second = setup()
    second.scan({
        { "Toolbox-Area52", "", 80 },
        { "Old-Area52", ">Toolbox", 70, { 0, 2, 0, 0 } },
        { "Recent-Area52", ">Toolbox", 70, { 0, 0, 1, 0 } },
    }, "initial")
    second.scan({
        { "Old-Area52", ">Toolbox", 70, { 0, 2, 0, 0 } },
        { "Recent-Area52", ">Toolbox", 70, { 0, 0, 1, 0 } },
    })
    test.assertEqual("recent-area52", second.playerOf("old-area52").main)
end)

test.test("a player with any in-guild character always has an in-guild acting main", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Solo-Area52", "", 10 },
    }, "initial")

    state.scan({ { "Hammer-Area52", ">Toolbox", 70 } })

    state.partition:EachPlayer(function(id, player)
        local inGuild = false
        local keys = state.partition:CharactersOf(id)
        local index
        for index = 1, #keys do
            inGuild = inGuild or state.partition:IsInGuild(keys[index])
        end
        if inGuild then
            test.assertTrue(state.partition:IsInGuild(player.main), "player " .. id .. " has an in-guild main")
        end
    end)
    -- Solo left with nobody else, so its player keeps it as main.
    test.assertEqual("solo-area52", state.playerOf("solo-area52").main)
end)

test.test("accepting a main conflict leaves the old player with an in-guild acting main", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Lowbie-Area52", ">Toolbox", 20 },
        { "Other-Area52", "", 60 },
    }, "initial")
    local player = state.partition:GetCharacter("toolbox-area52").player
    -- Hammer leaves, and Toolbox's note now names another main.
    state.scan({
        { "Toolbox-Area52", ">Other", 80 },
        { "Lowbie-Area52", ">Toolbox", 20 },
        { "Other-Area52", "", 60 },
    })
    test.assertEqual(1, #state.conflictsOf("main"))

    test.assertTrue(state.service():AcceptConflict("toolbox-area52", "main"))

    test.assertEqual(state.playerOf("other-area52"), state.playerOf("toolbox-area52"))
    -- The departed Hammer outranks Lowbie by level, but can't lead the player.
    test.assertEqual("lowbie-area52", state.partition:GetPlayer(player).main)
end)

test.test("an alt pointing at a main who left links to that main's player and gets promoted", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "@TheTool", 80 }, { "Visitor-Area52", "", 30 } }, "initial")
    state.scan({ { "Visitor-Area52", "", 30 } })
    test.assertTrue(state.partition:GetCharacter("toolbox-area52").departed ~= nil)

    state.scan({ { "Visitor-Area52", "", 30 }, { "Newalt-Area52", ">Toolbox", 20 } }, "incremental")

    local player = state.playerOf("newalt-area52")
    test.assertEqual(state.playerOf("toolbox-area52"), player)
    test.assertEqual("newalt-area52", player.main)
    test.assertEqual("TheTool", player.alias)
    test.assertEqual("Toolbox-Area52", player.history[1].name)
    test.assertEqual(1, #state.conflictsOf("promotion"))
end)

test.test("accepting an unknown main records it in history as out of guild", function()
    local state = setup()
    state.scan({ { "Hammer-Area52", ">Bigmain", 70 } }, "initial")
    local conflict = state.conflictsOf("unresolved")[1]
    test.assertEqual("Bigmain", conflict.suggestion.outOfGuild)
    state.now = START + DAY

    test.assertTrue(state.service():AcceptConflict("hammer-area52", "unresolved"))

    local player = state.playerOf("hammer-area52")
    test.assertEqual("hammer-area52", player.main)
    test.assertEqual("Bigmain", player.history[1].name)
    test.assertEqual("main", player.history[1].role)
    test.assertEqual("out of guild", player.history[1].reason)
    test.assertEqual(START + DAY, player.history[1].since)
end)

test.test("a promotion can be confirmed or reassigned", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 60 },
    }, "initial")
    state.scan({ { "Hammer-Area52", ">Toolbox", 70 }, { "Wrench-Area52", ">Toolbox", 60 } })

    test.assertTrue(state.service():MakeMain("wrench-area52"))

    test.assertEqual("wrench-area52", state.playerOf("hammer-area52").main)
    test.assertEqual(0, #state.conflictsOf("promotion"))

    local confirm = setup()
    confirm.scan({ { "Toolbox-Area52", "", 80 }, { "Hammer-Area52", ">Toolbox", 70 } }, "initial")
    confirm.scan({ { "Hammer-Area52", ">Toolbox", 70 } })
    test.assertTrue(confirm.service():AcceptConflict("hammer-area52", "promotion"))
    test.assertEqual("hammer-area52", confirm.playerOf("hammer-area52").main)
    test.assertEqual(0, #confirm.conflictsOf("promotion"))
end)

test.test("only characters in the guild can be made main", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "", 80 }, { "Hammer-Area52", ">Toolbox", 70 } }, "initial")
    state.scan({ { "Hammer-Area52", ">Toolbox", 70 } })

    local ok, reason = state.service():MakeMain("toolbox-area52")

    test.assertFalse(ok)
    test.assertContains(reason, "in the guild")
end)

test.test("pending promotions survive later scans until they are resolved", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "", 80 }, { "Hammer-Area52", ">Toolbox", 70 } }, "initial")
    state.scan({ { "Hammer-Area52", ">Toolbox", 70 } })

    state.scan({ { "Hammer-Area52", "changed >Toolbox", 70 } })

    test.assertEqual(1, #state.conflictsOf("promotion"))
end)

test.test("purging a departed character keeps its history entry", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 60 },
    }, "initial")
    state.scan({ { "Toolbox-Area52", "", 80 }, { "Hammer-Area52", ">Toolbox", 70 } })

    test.assertTrue(state.service():Purge("wrench-area52"))

    test.assertEqual(nil, state.partition:GetCharacter("wrench-area52"))
    local history = state.playerOf("toolbox-area52").history
    test.assertEqual("wrench-area52", history[1].character)
    test.assertEqual("alt", history[1].role)
    test.assertEqual("purged", history[1].reason)
end)

test.test("purge all removes every departed character and nobody else", function()
    local state = setup()
    state.scan(GUILD, "initial")
    state.scan({ GUILD[1] })

    test.assertEqual(2, state.service():PurgeAllDeparted())

    test.assertTrue(state.partition:GetCharacter("toolbox-area52") ~= nil)
    test.assertEqual(nil, state.partition:GetCharacter("hammer-area52"))
    test.assertEqual(nil, state.partition:GetCharacter("visitor-area52"))
    -- Toolbox's player keeps Hammer's history; Visitor's empty player is gone.
    test.assertEqual("hammer-area52", state.playerOf("toolbox-area52").history[1].character)
end)

test.test("only departed characters can be purged", function()
    local state = setup()
    state.scan(GUILD, "initial")

    local ok = state.service():Purge("toolbox-area52")

    test.assertFalse(ok)
    test.assertTrue(state.partition:GetCharacter("toolbox-area52") ~= nil)
end)

test.test("departed characters are hidden by default and shown with the toggle", function()
    local state = setup()
    state.scan(GUILD, "initial")
    state.now = START + 3 * DAY
    state.scan({ GUILD[1], GUILD[2] })

    local function build(showDeparted)
        return state.addon.RosterViewModel.Build({
            partition = state.partition,
            members = state.roster({ GUILD[1], GUILD[2] }),
            normalizer = state.normalizer,
            showDeparted = showDeparted,
            now = START + 5 * DAY,
        })
    end

    local hidden = build(false)
    test.assertEqual(3, #hidden)
    local shown = build(true)
    test.assertEqual(4, #shown)
    local visitor = shown[4]
    test.assertTrue(visitor.departed)
    test.assertEqual("Left 2 days ago", visitor.location)
end)

test.test("legacy saved data without departure fields still loads", function()
    local addon = load()
    local database = { schemaVersion = 1, guilds = { ["Knights-Area52"] = {
        characters = { ["toolbox-area52"] = { player = 1, name = "Toolbox" } },
        players = { [1] = { main = "toolbox-area52" } },
    } } }
    local before = fixtures.snapshot(database.guilds["Knights-Area52"].characters)

    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = "Area52" })

    test.assertTrue(partition:IsInGuild("toolbox-area52"))
    fixtures.assertSameData(before, database.guilds["Knights-Area52"].characters)
end)
