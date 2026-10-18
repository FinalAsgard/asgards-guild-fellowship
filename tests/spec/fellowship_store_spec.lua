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

test.test("master frame geometry is saved account-wide and an unusable value is kept", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertEqual(nil, store:GetFrameState())
    test.assertTrue(store:SetFrameState({ point = "CENTER", x = 1, y = 2, width = 800, height = 600 }))
    test.assertEqual(800, store:GetFrameState().width)

    database.frame = "corrupt"
    test.assertEqual(nil, store:GetFrameState())
    test.assertFalse(store:SetFrameState({ width = 1 }))
    test.assertEqual("corrupt", database.frame)
end)

test.test("the master frame starts where the roster window was saved, at its own size", function()
    local database = foundationRoot()
    database.window = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 40, y = -60, width = 640, height = 440 }
    local store = newStore(database)

    local state = store:GetFrameState()

    test.assertEqual("TOPLEFT", state.point)
    test.assertEqual("TOPLEFT", state.relativePoint)
    test.assertEqual(40, state.x)
    test.assertEqual(-60, state.y)
    test.assertEqual(nil, state.width)
    test.assertEqual(nil, state.height)

    -- Once the frame saves its own geometry, that wins.
    store:SetFrameState({ point = "CENTER", relativePoint = "CENTER", x = 0, y = 0, width = 760, height = 560 })
    test.assertEqual("CENTER", store:GetFrameState().point)
end)

test.test("chat tags are on by default and the choice is saved account-wide", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertTrue(store:ChatTagsEnabled())
    test.assertTrue(store:SetChatTagsEnabled(false))
    test.assertFalse(store:ChatTagsEnabled())
    test.assertEqual(false, database.chatTags)

    -- Another session (or character) reading the same saved data.
    test.assertFalse(newStore(database):ChatTagsEnabled())
    test.assertTrue(store:SetChatTagsEnabled(true))
    test.assertTrue(newStore(database):ChatTagsEnabled())
end)

test.test("an unusable chat tags value is left alone and counts as on", function()
    local database = foundationRoot()
    database.chatTags = "corrupt"
    local store = newStore(database)

    test.assertTrue(store:ChatTagsEnabled())
    test.assertFalse(store:SetChatTagsEnabled(false))
    test.assertEqual("corrupt", database.chatTags)
    test.assertFalse(store:SetChatTagsEnabled("off"))
end)

-- Guild sync stamps (schema 2) ------------------------------------------------

test.test("an unstamped main link is the oldest possible and stamps are kept", function()
    local database = foundationRoot()
    local partition = newStore(database):Partition(GUILD)
    partition:RecordCharacter("hammer-area52", MEMBER)

    local at, by = partition:GetMainStamp("hammer-area52")
    test.assertEqual(0, at)
    test.assertEqual(nil, by)

    test.assertTrue(partition:SetMainStamp("hammer-area52", 1790000000, "toolbox-area52"))
    at, by = partition:GetMainStamp("hammer-area52")
    test.assertEqual(1790000000, at)
    test.assertEqual("toolbox-area52", by)
    test.assertEqual(1790000000, database.guilds["Knights of Camelot-Area52"].characters["hammer-area52"].mainAt)

    test.assertFalse(partition:SetMainStamp("hammer-area52", 1.5, "toolbox-area52"))
    test.assertFalse(partition:SetMainStamp("hammer-area52", 1790000001, ""))
    test.assertFalse(partition:SetMainStamp("nobody-area52", 1790000001, "toolbox-area52"))
    test.assertEqual(nil, partition:GetMainStamp("nobody-area52"))
end)

test.test("a stored stamp of the wrong type quarantines its character intact", function()
    local database = foundationRoot()
    database.guilds["Knights of Camelot-Area52"] = {
        characters = {
            ["hammer-area52"] = { player = 1, mainAt = "yesterday" },
            ["wrench-area52"] = { player = 2, mainAt = 1790000000, mainBy = 7 },
            ["toolbox-area52"] = { player = 3, mainAt = 1790000000, mainBy = "toolbox-area52", source = "sync" },
        },
        players = {
            [1] = { main = "hammer-area52" },
            [2] = { main = "wrench-area52" },
            [3] = { main = "toolbox-area52" },
        },
    }

    local partition = newStore(database):Partition(GUILD)

    test.assertEqual(nil, partition:GetCharacter("hammer-area52"))
    test.assertEqual(nil, partition:GetCharacter("wrench-area52"))
    test.assertEqual("sync", partition:GetCharacter("toolbox-area52").source)
    local quarantined = database.guilds["Knights of Camelot-Area52"].quarantine
    test.assertEqual(2, #quarantined)
end)

test.test("an unstamped alias is the oldest possible and stamps are kept with the player", function()
    local database = foundationRoot()
    local partition = newStore(database):Partition(GUILD)
    partition:RecordCharacter("hammer-area52", MEMBER)
    local playerId = partition:GetCharacter("hammer-area52").player

    local at, by = partition:GetAliasStamp("hammer-area52")
    test.assertEqual(0, at)
    test.assertEqual(nil, by)

    test.assertTrue(partition:SetAliasStamp("hammer-area52", 1790000000, "toolbox-area52"))
    at, by = partition:GetAliasStamp("hammer-area52")
    test.assertEqual(1790000000, at)
    test.assertEqual("toolbox-area52", by)
    test.assertEqual(1790000000, database.guilds["Knights of Camelot-Area52"].players[playerId].aliasAt)

    test.assertFalse(partition:SetAliasStamp("hammer-area52", 1.5, "toolbox-area52"))
    test.assertFalse(partition:SetAliasStamp("hammer-area52", 1790000001, ""))
    test.assertFalse(partition:SetAliasStamp("nobody-area52", 1790000001, "toolbox-area52"))
    test.assertEqual(nil, partition:GetAliasStamp("nobody-area52"))
end)

test.test("a stored alias stamp of the wrong type quarantines its player intact", function()
    local database = foundationRoot()
    database.guilds["Knights of Camelot-Area52"] = {
        characters = {
            ["hammer-area52"] = { player = 1 },
            ["wrench-area52"] = { player = 2 },
            ["toolbox-area52"] = { player = 3 },
        },
        players = {
            [1] = { main = "hammer-area52", alias = "Hammer", aliasAt = "yesterday" },
            [2] = { main = "wrench-area52", alias = "Wrench", aliasAt = 1790000000, aliasBy = 7 },
            [3] = { main = "toolbox-area52", alias = "Tools", aliasAt = 1790000000, aliasBy = "toolbox-area52" },
        },
    }

    local partition = newStore(database):Partition(GUILD)

    test.assertEqual(nil, partition:GetPlayer(1))
    test.assertEqual(nil, partition:GetPlayer(2))
    test.assertEqual("Tools", partition:GetPlayer(3).alias)
    local quarantined = database.guilds["Knights of Camelot-Area52"].quarantine
    local players = 0
    local index
    for index = 1, #quarantined do
        if quarantined[index].collection == "players" then
            players = players + 1
        end
    end
    test.assertEqual(2, players)
end)

test.test("don't sync is kept on the player record, and an unusable flag quarantines the player", function()
    local database = foundationRoot()
    database.guilds["Knights of Camelot-Area52"] = {
        characters = {
            ["hammer-area52"] = { player = 1 },
            ["toolbox-area52"] = { player = 2 },
        },
        players = {
            [1] = { main = "hammer-area52", noSync = "yes" },
            [2] = { main = "toolbox-area52" },
        },
    }

    local partition = newStore(database):Partition(GUILD)

    test.assertEqual(nil, partition:GetPlayer(1))
    test.assertFalse(partition:IsNoSync(2))
    test.assertTrue(partition:SetNoSync(2, true))
    test.assertTrue(partition:IsNoSync(2))
    test.assertEqual(true, database.guilds["Knights of Camelot-Area52"].players[2].noSync)
    test.assertTrue(partition:SetNoSync(2, false))
    test.assertFalse(partition:IsNoSync(2))
    test.assertEqual(nil, database.guilds["Knights of Camelot-Area52"].players[2].noSync)
    test.assertFalse(partition:SetNoSync(99, true))
end)

test.test("guild recruit: the ad is account-wide and the opt-in is kept per character", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertEqual("", store:RecruitAd())
    test.assertFalse(store:RecruitOptedIn("Toolbox-Area52"))
    test.assertTrue(store:SetRecruitAd("Join us!"))
    test.assertFalse(store:SetRecruitAd(string.rep("x", 256)))
    test.assertTrue(store:SetRecruitOptIn("Toolbox-Area52", true))

    local reloaded = newStore(database)
    test.assertEqual("Join us!", reloaded:RecruitAd())
    test.assertTrue(reloaded:RecruitOptedIn("Toolbox-Area52"))
    test.assertFalse(reloaded:RecruitOptedIn("Hammer-Area52"))
end)

test.test("guild mail: the draft is saved account-wide and read back", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertEqual(nil, store:GuildMailDraft())
    test.assertTrue(store:SetGuildMailDraft({
        subject = "Launch night", body = "Hi {name}!", ranks = { 0, 2 },
        mode = "recent", skipDiscord = true, activeOnly = false,
    }))

    local draft = newStore(database):GuildMailDraft()
    test.assertEqual("Launch night", draft.subject)
    test.assertEqual("Hi {name}!", draft.body)
    test.assertEqual("0,2", table.concat(draft.ranks, ","))
    test.assertEqual("recent", draft.mode)
    test.assertTrue(draft.skipDiscord)
    test.assertFalse(draft.activeOnly)
end)

test.test("guild mail: unusable saved draft fields are dropped", function()
    local database = foundationRoot()
    database.guildMail = { subject = 5, body = "Hi", ranks = { 1, "x", 2.5, 3 }, mode = {}, skipDiscord = "yes" }

    local draft = newStore(database):GuildMailDraft()

    test.assertEqual(nil, draft.subject)
    test.assertEqual("Hi", draft.body)
    test.assertEqual("1,3", table.concat(draft.ranks, ","))
    test.assertEqual(nil, draft.mode)
    test.assertEqual(nil, draft.skipDiscord)
end)

test.test("guild mail: an unusable saved draft is left alone", function()
    local database = foundationRoot()
    database.guildMail = "broken"
    local store = newStore(database)

    test.assertEqual(nil, store:GuildMailDraft())
    test.assertFalse(store:SetGuildMailDraft({ subject = "Hi" }))
    test.assertEqual("broken", database.guildMail)
end)

test.test("guild recruit: unusable saved recruit state is left alone", function()
    local database = foundationRoot()
    database.recruit = "broken"
    local store = newStore(database)

    test.assertEqual("", store:RecruitAd())
    test.assertFalse(store:SetRecruitAd("Join us!"))
    test.assertFalse(store:SetRecruitOptIn("Toolbox-Area52", true))
    test.assertEqual("broken", database.recruit)
end)

test.test("guild recruit: ad times are kept per guild", function()
    local database = foundationRoot()
    local store = newStore(database)

    store:Partition(GUILD):GetRecruitLedger()["general:map:2339"] = 1790000000

    test.assertEqual(1790000000, newStore(database):Partition(GUILD):GetRecruitLedger()["general:map:2339"])
    test.assertEqual(nil, next(newStore(database):Partition(OTHER_GUILD):GetRecruitLedger()))
end)

test.test("guild recruit: the opt-in is undecided, true or false, and resetting one character leaves the rest", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertEqual(nil, store:RecruitOptIn("Toolbox-Area52"))
    test.assertTrue(store:SetRecruitOptIn("Toolbox-Area52", false))
    test.assertTrue(store:SetRecruitOptIn("Hammer-Area52", true))
    test.assertFalse(store:RecruitOptIn("Toolbox-Area52"))
    test.assertFalse(store:RecruitOptedIn("Toolbox-Area52"))
    test.assertTrue(store:RecruitOptedIn("Hammer-Area52"))

    test.assertTrue(store:SetRecruitOptIn("Toolbox-Area52", nil))
    test.assertEqual(nil, store:RecruitOptIn("Toolbox-Area52"))
    test.assertEqual(nil, database.recruit.optIn["Toolbox-Area52"])
    test.assertTrue(store:RecruitOptIn("Hammer-Area52"))
    test.assertFalse(store:SetRecruitOptIn("Toolbox-Area52", "yes"))

    database.recruit.optIn["Toolbox-Area52"] = "maybe"
    test.assertEqual(nil, store:RecruitOptIn("Toolbox-Area52"))
end)

test.test("guild recruit: posting the officer ad is on by default and saved account-wide", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertTrue(store:RecruitUseOfficerAd())
    test.assertTrue(store:SetRecruitUseOfficerAd(false))
    test.assertFalse(newStore(database):RecruitUseOfficerAd())
    test.assertFalse(store:SetRecruitUseOfficerAd("no"))
end)

test.test("guild recruit: the user's own timers default to 60 minutes and save account-wide", function()
    local database = foundationRoot()
    local store = newStore(database)

    test.assertEqual(60, store:RecruitMyGap("general"))
    test.assertEqual(60, store:RecruitMyGap("trade"))
    test.assertTrue(store:SetRecruitMyGap("trade", 25))
    test.assertEqual(25, newStore(database):RecruitMyGap("trade"))
    test.assertEqual(60, newStore(database):RecruitMyGap("general"))

    test.assertFalse(store:SetRecruitMyGap("trade", 4))
    test.assertFalse(store:SetRecruitMyGap("trade", 241))
    test.assertFalse(store:SetRecruitMyGap("elsewhere", 30))
    database.recruit.myGeneralGapMinutes = "often"
    test.assertEqual(60, store:RecruitMyGap("general"))
end)

test.test("a partition looks up its players by alias, ignoring case", function()
    local store = newStore(foundationRoot())
    local partition = store:Partition(GUILD)
    partition:RecordCharacter("toolbox-area52", MEMBER)
    partition:RecordCharacter("hammer-area52", MEMBER)
    partition:RecordCharacter("wrench-area52", MEMBER)
    local tool = partition:GetCharacter("toolbox-area52").player
    local hammer = partition:GetCharacter("hammer-area52").player
    partition:SetAlias(tool, "Tool", "manual")
    partition:SetAlias(hammer, "TOOL", "note")
    partition:SetAlias(partition:GetCharacter("wrench-area52").player, "The Tool", "manual")

    local found = partition:PlayersWithAlias("tool")

    test.assertEqual(2, #found)
    test.assertEqual(math.min(tool, hammer), found[1])
    test.assertEqual(math.max(tool, hammer), found[2])
    test.assertEqual(0, #partition:PlayersWithAlias("Nobody"))
    test.assertEqual(0, #partition:PlayersWithAlias(nil))
end)

test.test("an ignored out-of-date note is kept on the character across reloads", function()
    local database = foundationRoot()
    local partition = newStore(database):Partition(GUILD)
    partition:RecordCharacter("hammer-area52", MEMBER)

    test.assertEqual(nil, partition:GetIgnoredNote("hammer-area52"))
    test.assertTrue(partition:IgnoreNote("hammer-area52", "0badf00d", ">Tinker Healer"))
    test.assertFalse(partition:IgnoreNote("nobody-area52", "0badf00d", ">Tinker"))
    test.assertFalse(partition:IgnoreNote("hammer-area52", "", ">Tinker"))

    local reloaded = newStore(database):Partition(GUILD)
    local note, suggested = reloaded:GetIgnoredNote("hammer-area52")
    test.assertEqual("0badf00d", note)
    test.assertEqual(">Tinker Healer", suggested)
    test.assertEqual(0, #(database.guilds["Knights of Camelot-Area52"].quarantine or {}))
end)

test.test("an unreadable ignored note quarantines its character intact", function()
    local database = foundationRoot()
    database.guilds["Knights of Camelot-Area52"] = {
        characters = {
            ["hammer-area52"] = { player = 1, noteIgnored = { note = "0badf00d" } },
            ["toolbox-area52"] = { player = 2, noteIgnored = { note = "0badf00d", suggested = "" } },
        },
        players = {
            [1] = { main = "hammer-area52" },
            [2] = { main = "toolbox-area52" },
        },
    }

    local partition = newStore(database):Partition(GUILD)

    test.assertEqual(nil, partition:GetCharacter("hammer-area52"))
    test.assertEqual("0badf00d", partition:GetIgnoredNote("toolbox-area52"))
    local quarantined = database.guilds["Knights of Camelot-Area52"].quarantine
    test.assertEqual("character ignored note is invalid", quarantined[1].reason)
end)
