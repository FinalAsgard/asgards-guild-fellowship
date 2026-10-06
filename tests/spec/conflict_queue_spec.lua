local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/ConflictViewModel.lua"
    )
end

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- A guild partition with a scan helper. Notes are given as
-- { "Name-Realm", "note" } pairs, in the order the roster reports them.
local function setup()
    local addon = load()
    local database = { schemaVersion = 1, guilds = {} }
    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local state = { addon = addon, partition = partition, database = database, normalizer = normalizer }

    function state.roster(entries)
        local members = {}
        local index
        for index = 1, #entries do
            members[normalizer:Key(entries[index][1])] = {
                name = entries[index][1],
                note = entries[index][2],
                classToken = "WARRIOR",
                level = entries[index][3] or 10,
            }
        end
        return members
    end

    function state.scan(entries, mode, force)
        local members = state.roster(entries)
        local plan = addon.ReconcileEngine.Plan({
            partition = partition,
            members = members,
            normalizer = normalizer,
            rules = RULES,
            mode = mode or "full",
            force = force,
        })
        return addon.ReconcileEngine.Apply(partition, plan), members
    end

    function state.service()
        return addon.PlayerService.Create(partition)
    end

    function state.playerOf(key)
        return partition:GetPlayer(partition:GetCharacter(key).player)
    end

    function state.conflicts()
        return partition:GetConflicts()
    end

    return state
end

-- Toolbox (alias TheTool) with alt Hammer, plus Visitor on its own.
local SEEDED = {
    { "Toolbox-Area52", "@TheTool" },
    { "Hammer-Area52", ">Toolbox" },
    { "Visitor-Area52", "" },
}

local function seeded()
    local state = setup()
    state.scan(SEEDED, "initial")
    return state
end

test.test("a note that moves an organized alt to another main becomes a conflict, changing nothing", function()
    local state = seeded()
    local before = fixtures.snapshot(state.database)

    local result = state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    })

    test.assertEqual(1, result.conflicts)
    local conflict = state.conflicts()[1]
    test.assertEqual("hammer-area52", conflict.character)
    test.assertEqual("main", conflict.kind)
    test.assertEqual("visitor-area52", conflict.suggestion.main)
    test.assertEqual(state.playerOf("toolbox-area52"), state.playerOf("hammer-area52"))
    -- Only the note fingerprint and the queue changed.
    before.guilds["Knights-Area52"].characters["hammer-area52"].note =
        state.partition:GetCharacter("hammer-area52").note
    before.guilds["Knights-Area52"].conflicts = state.conflicts()
    fixtures.assertSameData(before, state.database)
end)

test.test("a note with a different alias for an organized player becomes a conflict", function()
    local state = seeded()

    state.scan({
        { "Toolbox-Area52", "@Toolman" },
        { "Hammer-Area52", ">Toolbox" },
        { "Visitor-Area52", "" },
    })

    local conflict = state.conflicts()[1]
    test.assertEqual("alias", conflict.kind)
    test.assertEqual("Toolman", conflict.suggestion.alias)
    test.assertEqual("TheTool", state.playerOf("toolbox-area52").alias)
end)

test.test("an alias on a new alt that matches its main's player raises no conflict", function()
    local state = seeded()

    local result = state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox" },
        { "Visitor-Area52", "" },
        { "Wrench-Area52", ">Toolbox @thetool" },
    }, "incremental")

    test.assertEqual(0, result.conflicts)
    test.assertEqual(state.playerOf("toolbox-area52"), state.playerOf("wrench-area52"))
end)

test.test("each unusable marker kind becomes a conflict in full and incremental scans", function()
    local state = seeded()

    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Nobody" },
        { "Visitor-Area52", ">Visitor" },
    })
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Nobody" },
        { "Visitor-Area52", ">Visitor" },
        { "Loop1-Area52", ">Loop2" },
        { "Loop2-Area52", ">Loop1" },
    }, "incremental")

    local kinds = {}
    local index
    for index = 1, #state.conflicts() do
        kinds[state.conflicts()[index].character] = state.conflicts()[index].kind
    end
    test.assertEqual("unresolved", kinds["hammer-area52"])
    test.assertEqual("self reference", kinds["visitor-area52"])
    test.assertEqual("cycle", kinds["loop1-area52"])
    test.assertEqual("cycle", kinds["loop2-area52"])
end)

test.test("accepting a main conflict moves the character through PlayerService", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    })

    test.assertTrue(state.service():AcceptConflict("hammer-area52", "main"))

    test.assertEqual(state.playerOf("visitor-area52"), state.playerOf("hammer-area52"))
    test.assertEqual("note", state.partition:GetCharacter("hammer-area52").source)
    test.assertEqual(0, #state.conflicts())
end)

test.test("accepting an alias conflict renames the player", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@Toolman" },
        { "Hammer-Area52", ">Toolbox" },
        { "Visitor-Area52", "" },
    })

    test.assertTrue(state.service():AcceptConflict("toolbox-area52", "alias"))

    test.assertEqual("Toolman", state.playerOf("hammer-area52").alias)
    test.assertEqual(0, #state.conflicts())
end)

test.test("moving a player's main to another player promotes the highest-level character left", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "", 30 },
        { "Hammer-Area52", ">Toolbox", 60 },
        { "Wrench-Area52", ">Toolbox", 40 },
        { "Visitor-Area52", "" },
    }, "initial")
    state.scan({
        { "Toolbox-Area52", ">Visitor", 30 },
        { "Hammer-Area52", ">Toolbox", 60 },
        { "Wrench-Area52", ">Toolbox", 40 },
        { "Visitor-Area52", "" },
    })

    test.assertTrue(state.service():AcceptConflict("toolbox-area52", "main"))

    test.assertEqual(state.playerOf("visitor-area52"), state.playerOf("toolbox-area52"))
    test.assertEqual("hammer-area52", state.playerOf("wrench-area52").main)
end)

test.test("unusable markers can't be accepted, only dismissed", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox" },
        { "Visitor-Area52", ">Visitor" },
    })

    local accepted, reason = state.service():AcceptConflict("visitor-area52", "self reference")

    test.assertFalse(accepted)
    test.assertContains(reason, "dismiss")
    test.assertEqual(1, #state.conflicts())
end)

test.test("a rejected suggestion keeps the database and never returns for the same note", function()
    local state = seeded()
    local changed = {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    }
    state.scan(changed)

    test.assertTrue(state.service():RejectConflict("hammer-area52", "main"))
    test.assertEqual(state.playerOf("toolbox-area52"), state.playerOf("hammer-area52"))
    test.assertEqual(0, #state.conflicts())

    -- Neither a routine scan nor a forced rescan of the same note brings it back.
    state.scan(changed)
    state.scan(changed, "full", true)
    test.assertEqual(0, #state.conflicts())
end)

test.test("a rejected suggestion returns when the note changes again", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    })
    state.service():RejectConflict("hammer-area52", "main")

    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", "healer >Visitor" },
        { "Visitor-Area52", "" },
    })

    test.assertEqual(1, #state.conflicts())
    test.assertEqual("main", state.conflicts()[1].kind)
end)

test.test("rejecting one kind of conflict doesn't hide another from the same note", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor @Hammertime" },
        { "Visitor-Area52", "" },
    })
    test.assertEqual(2, #state.conflicts())

    state.service():RejectConflict("hammer-area52", "alias")
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor @Hammertime" },
        { "Visitor-Area52", "" },
    }, "full", true)

    test.assertEqual(1, #state.conflicts())
    test.assertEqual("main", state.conflicts()[1].kind)
end)

test.test("accept all applies every suggestion and dismisses the rest", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@Toolman" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", ">Visitor" },
    })
    test.assertEqual(3, #state.conflicts())

    local accepted, dismissed = state.service():AcceptAll()

    test.assertEqual(2, accepted)
    test.assertEqual(1, dismissed)
    test.assertEqual(0, #state.conflicts())
    test.assertEqual(state.playerOf("visitor-area52"), state.playerOf("hammer-area52"))
    test.assertEqual("Toolman", state.playerOf("toolbox-area52").alias)
end)

test.test("reject all keeps the database and clears the queue", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@Toolman" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    })

    test.assertEqual(2, state.service():RejectAll())

    test.assertEqual(0, #state.conflicts())
    test.assertEqual("TheTool", state.playerOf("toolbox-area52").alias)
    test.assertEqual(state.playerOf("toolbox-area52"), state.playerOf("hammer-area52"))
end)

test.test("accepting a main that is no longer known keeps the conflict", function()
    local state = seeded()
    state.scan({
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Visitor" },
        { "Visitor-Area52", "" },
    })
    state.partition:GetConflicts()[1].suggestion.main = "gone-area52"

    local accepted, reason = state.service():AcceptConflict("hammer-area52", "main")

    test.assertFalse(accepted)
    test.assertContains(reason, "no longer known")
    test.assertEqual(1, #state.conflicts())
end)

test.test("review rows show the character, live note, suggestion, current state, and source", function()
    local state = seeded()
    local _, members = state.scan({
        { "Toolbox-Area52", "@Toolman raid lead" },
        { "Hammer-Area52", "healer >Visitor" },
        { "Visitor-Area52", ">Nobody" },
    })

    local rows = state.addon.ConflictViewModel.Build({
        partition = state.partition,
        members = members,
        normalizer = state.normalizer,
    })

    local byKind = {}
    local index
    for index = 1, #rows do
        byKind[rows[index].kind] = rows[index]
    end
    test.assertEqual("Hammer", byKind.main.name)
    test.assertEqual("healer >Visitor", byKind.main.note)
    test.assertEqual("Alt of Visitor", byKind.main.suggests)
    test.assertEqual("Alt of Toolbox", byKind.main.current)
    test.assertEqual("From a note", byKind.main.source)
    test.assertTrue(byKind.main.canAccept)
    test.assertEqual("Alias \"Toolman\"", byKind.alias.suggests)
    test.assertEqual("Alias \"TheTool\"", byKind.alias.current)
    test.assertEqual("Main \"Nobody\", not in the guild", byKind.unresolved.suggests)
    test.assertEqual("Own player", byKind.unresolved.current)
    test.assertTrue(byKind.unresolved.canAccept)

    -- A character missing from the live roster has no note to show.
    rows = state.addon.ConflictViewModel.Build({ partition = state.partition, normalizer = state.normalizer })
    test.assertEqual(nil, rows[1].note)
end)

test.test("markers saved as unapplied by an earlier build load as conflicts", function()
    local addon = load()
    local database = { schemaVersion = 1, guilds = {
        ["Knights-Area52"] = {
            characters = { ["hammer-area52"] = { player = 1 } },
            players = { [1] = { main = "hammer-area52" } },
            unapplied = {
                { character = "hammer-area52", fingerprint = "0000abcd", reason = "unresolved" },
                { character = "hammer-area52", fingerprint = "0000abcd", reason = "player already organized" },
            },
        },
    } }

    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = "Area52" })

    test.assertEqual(1, #partition:GetConflicts())
    test.assertEqual("unresolved", partition:GetConflicts()[1].kind)
    test.assertEqual(nil, database.guilds["Knights-Area52"].unapplied)
end)

test.test("the add-on never writes guild notes", function()
    local forbidden = { "GuildRosterSetPublicNote", "GuildRosterSetOfficerNote", "SetPublicNote",
        "SetOfficerNote", "C_GuildInfo.SetNote" }
    local listing = io.popen("ls Core Adapters")
    local files = { "AsgardsGuildFellowship.lua" }
    local directory
    local line
    for line in listing:lines() do
        if string.match(line, ":$") then
            directory = string.sub(line, 1, -2)
        elseif string.match(line, "%.lua$") then
            table.insert(files, directory .. "/" .. line)
        end
    end
    listing:close()
    test.assertTrue(#files > 5, "found the source files")

    local index, termIndex
    for index = 1, #files do
        local handle = assert(io.open(files[index], "r"))
        local source = handle:read("*a")
        handle:close()
        for termIndex = 1, #forbidden do
            test.assertEqual(nil, string.find(source, forbidden[termIndex], 1, true),
                files[index] .. " uses " .. forbidden[termIndex])
        end
    end
end)
