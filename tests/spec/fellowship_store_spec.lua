local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local OTHER_GUILD = { name = "Knights of Camelot", realm = "Stormrage" }

local function newStore(database)
    local addon = test.newAddon("Core/FellowshipStore.lua")
    return addon.FellowshipStore.Create(database), addon
end

-- The root the foundation (PRD #2) writes on a fresh install.
local function foundationRoot()
    return { schemaVersion = 1, guilds = {} }
end

local MEMBER = { name = "Toolbox-Area52", classToken = "WARRIOR", level = 80, rankIndex = 1,
    online = true, zone = "Dornogal",
    rankName = "Officer", lastOnline = { 0, 0, 1, 0 } }

test.test("store migrates the foundation's root by creating a partition on first use", function()
    local database = foundationRoot()
    local store = newStore(database)

    local partition = store:Partition(GUILD)

    test.assertTrue(partition ~= nil)
    test.assertEqual(1, database.schemaVersion)
    test.assertEqual("table", type(database.guilds["Knights of Camelot-Area52"]))
    test.assertFalse(partition:HasBeenScanned())
end)

test.test("partitions are per guild name plus realm", function()
    local database = foundationRoot()
    local store = newStore(database)

    store:Partition(GUILD):RecordCharacter("toolbox-area52", MEMBER)
    store:Partition(OTHER_GUILD):RecordCharacter("hammer-stormrage", MEMBER)

    test.assertTrue(database.guilds["Knights of Camelot-Area52"].characters["toolbox-area52"] ~= nil)
    test.assertEqual(nil, database.guilds["Knights of Camelot-Area52"].characters["hammer-stormrage"])
    test.assertTrue(database.guilds["Knights of Camelot-Stormrage"].characters["hammer-stormrage"] ~= nil)
end)

test.test("a character with no relationships becomes the main of its own player", function()
    local store = newStore(foundationRoot())
    local partition = store:Partition(GUILD)

    local first = partition:RecordCharacter("toolbox-area52", MEMBER)
    local second = partition:RecordCharacter("hammer-area52", MEMBER)

    test.assertTrue(first.player ~= second.player)
    test.assertEqual("toolbox-area52", partition:GetPlayer(first.player).main)
    test.assertEqual("hammer-area52", partition:GetPlayer(second.player).main)
    test.assertEqual("roster", first.source)
end)

test.test("only lasting facts are persisted for a character", function()
    local store = newStore(foundationRoot())
    local character = store:Partition(GUILD):RecordCharacter("toolbox-area52", MEMBER)

    local allowed = { class = true, level = true, name = true, note = true, player = true, rank = true,
        source = true }
    local field
    for field in pairs(character) do
        test.assertTrue(allowed[field], "unexpected persisted field " .. tostring(field))
    end
    -- The name is kept exactly as the roster spells it.
    test.assertEqual("Toolbox-Area52", character.name)
    test.assertEqual("WARRIOR", character.class)
    test.assertEqual(80, character.level)
    test.assertEqual(1, character.rank)
end)

test.test("recording a character again refreshes facts without a new player", function()
    local store = newStore(foundationRoot())
    local partition = store:Partition(GUILD)
    local first = partition:RecordCharacter("toolbox-area52", MEMBER)
    local player = first.player

    local again = partition:RecordCharacter("toolbox-area52", { level = 81, classToken = "WARRIOR" })

    test.assertEqual(player, again.player)
    test.assertEqual(81, again.level)
    test.assertEqual(1, again.rank)
end)

test.test("a repeat load of a scanned partition is stable", function()
    local database = foundationRoot()
    local first = newStore(database):Partition(GUILD)
    first:RecordCharacter("toolbox-area52", MEMBER)
    first:RecordCharacter("hammer-area52", MEMBER)
    first:MarkScanned(1790000000)
    local before = fixtures.snapshot(database)

    local again = newStore(database):Partition(GUILD)

    fixtures.assertSameData(before, database)
    test.assertTrue(again:HasBeenScanned())
    test.assertEqual(1790000000, again:GetLastScan())
    -- New players keep counting up after a reload.
    local third = again:RecordCharacter("visitor-area52", MEMBER)
    test.assertEqual(3, third.player)
end)

test.test("unreadable records are quarantined intact and the rest stays usable", function()
    local database = foundationRoot()
    database.guilds["Knights of Camelot-Area52"] = {
        characters = {
            ["toolbox-area52"] = { player = 1, class = "WARRIOR" },
            ["broken-area52"] = "not a record",
            ["orphan-area52"] = { player = 9 },
            ["badlevel-area52"] = { player = 1, level = "eighty" },
            ["badname-area52"] = { player = 1, name = 42 },
        },
        players = {
            [1] = { main = "toolbox-area52" },
            [2] = { alias = "no main" },
        },
        nextPlayerId = 3,
        futureField = { kept = true },
    }

    local partition = newStore(database):Partition(GUILD)
    local data = database.guilds["Knights of Camelot-Area52"]

    test.assertTrue(partition ~= nil)
    test.assertTrue(partition:GetCharacter("toolbox-area52") ~= nil)
    test.assertEqual(nil, partition:GetCharacter("broken-area52"))
    test.assertEqual(nil, partition:GetPlayer(2))
    test.assertEqual(5, #data.quarantine)
    test.assertTrue(data.futureField.kept)
    local quarantined = {}
    local index
    for index = 1, #data.quarantine do
        quarantined[data.quarantine[index].key] = data.quarantine[index]
    end
    test.assertEqual("not a record", quarantined["broken-area52"].record)
    test.assertEqual("character's player is missing", quarantined["orphan-area52"].reason)
    test.assertEqual("eighty", quarantined["badlevel-area52"].record.level)
    test.assertEqual("character name is invalid", quarantined["badname-area52"].reason)
    test.assertEqual("no main", quarantined[2].record.alias)
end)

test.test("a partition of the wrong shape is left unchanged and reported", function()
    local CORRUPT = {
        { name = "not a table", value = "oops" },
        { name = "characters not a table", value = { characters = "oops" } },
        { name = "invalid next player id", value = { nextPlayerId = -1 } },
    }
    local index
    for index = 1, #CORRUPT do
        local database = foundationRoot()
        database.guilds["Knights of Camelot-Area52"] = CORRUPT[index].value
        local before = fixtures.snapshot(database)

        local partition, reason = newStore(database):Partition(GUILD)

        test.assertEqual(nil, partition, CORRUPT[index].name)
        test.assertContains(reason, "left unchanged")
        fixtures.assertSameData(before, database)
    end
end)

test.test("the store reports unavailable saved data and guild identity", function()
    local partition, reason = newStore(nil):Partition(GUILD)
    test.assertEqual(nil, partition)
    test.assertContains(reason, "saved data is unavailable")

    partition, reason = newStore(foundationRoot()):Partition({ name = "No realm" })
    test.assertEqual(nil, partition)
    test.assertContains(reason, "guild identity is unavailable")
end)

test.test("window geometry is saved account-wide and an unusable value is kept", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertEqual(nil, store:GetWindowState())
    test.assertTrue(store:SetWindowState({ point = "CENTER", x = 1, y = 2, width = 500, height = 300 }))
    test.assertEqual(500, store:GetWindowState().width)

    database.window = "corrupt"
    test.assertEqual(nil, store:GetWindowState())
    test.assertFalse(store:SetWindowState({ width = 1 }))
    test.assertEqual("corrupt", database.window)
end)
