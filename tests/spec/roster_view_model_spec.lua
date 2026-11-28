local test = require("tests.test_helper")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/RosterViewModel.lua"
    )
end

local function setup(addon)
    local store = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
    local partition = store:Partition({ name = "Knights", realm = "Camelot" })
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = true, homeRealm = "Camelot" })
    return partition, normalizer
end

test.test("last online text uses the largest unit", function()
    local format = load().RosterViewModel.FormatLastOnline

    test.assertEqual("1 year ago", format({ years = 1, months = 3, days = 0, hours = 0 }))
    test.assertEqual("2 months ago", format({ years = 0, months = 2, days = 5, hours = 0 }))
    test.assertEqual("1 hour ago", format({ years = 0, months = 0, days = 0, hours = 1 }))
    test.assertEqual("less than an hour ago", format({ years = 0, months = 0, days = 0, hours = 0 }))
    test.assertEqual(nil, format(nil))
end)

test.test("elapsed time uses the largest unit, and the footer says when this client last synced", function()
    local model = load().RosterViewModel
    local now = 1790000000

    test.assertEqual("just now", model.Ago(59))
    test.assertEqual("1 minute ago", model.Ago(60))
    test.assertEqual("59 minutes ago", model.Ago(3599))
    test.assertEqual("2 hours ago", model.Ago(7200))
    test.assertEqual("3 days ago", model.Ago(3 * 86400 + 5))

    test.assertEqual("Not synced yet", model.SyncText(nil, now))
    test.assertEqual("Synced just now", model.SyncText(now - 10, now))
    test.assertEqual("Synced 5 minutes ago", model.SyncText(now - 300, now))
    test.assertEqual("Synced just now", model.SyncText(now + 30, now), "a clock that runs a little behind")
end)

test.test("/agf sync says whether sync runs or is paused, when it last synced, and what's pending", function()
    local model = load().RosterViewModel
    local now = 1790000000

    local lines = model.SyncStatusLines({ on = true, paused = false, lastSync = now - 120, pending = 2 }, now)
    test.assertEqual(2, #lines)
    test.assertEqual("Guild sync is running. Synced 2 minutes ago.", lines[1])
    test.assertEqual("2 suggestions of yours are waiting for an officer.", lines[2])

    lines = model.SyncStatusLines({ on = true, paused = true, pending = 1 }, now)
    test.assertEqual("Guild sync is paused while you're in combat, a boss encounter or a keystone run." ..
        " Not synced yet.", lines[1])
    test.assertEqual("1 suggestion of yours is waiting for an officer.", lines[2])

    lines = model.SyncStatusLines({ on = true, paused = false, lastSync = now, pending = 0 }, now)
    test.assertEqual("None of your suggestions are waiting for an officer.", lines[2])
    -- An officer has no suggestions of their own.
    test.assertEqual(1, #model.SyncStatusLines({ on = true, paused = false, lastSync = now }, now))

    test.assertContains(model.SyncStatusLines({ on = false }, now)[1], "Guild sync is off")
    test.assertContains(model.SyncStatusLines(nil, now)[1], "isn't available")
end)

-- Guild-size counts ----------------------------------------------------------

local function record(partition, name)
    local key = string.lower(name) .. "-camelot"
    partition:RecordCharacter(key, { name = name, classToken = "MAGE", level = 10 })
    return key
end

-- `expected.known` players are known; every unlinked character is a player
-- of its own too.
local function assertCounts(expected, counts)
    test.assertEqual(expected.known, counts.known, "known")
    test.assertEqual(expected.alts, counts.alts, "alts")
    test.assertEqual(expected.unlinked, counts.unlinked, "unlinked")
    test.assertEqual(expected.characters, counts.characters, "characters")
    test.assertEqual(counts.known + counts.unlinked, counts.players, "players are known plus unlinked")
    test.assertEqual(counts.characters, counts.players + counts.alts, "the invariant")
end

test.test("counts an empty guild as nothing", function()
    local addon = load()
    local partition = setup(addon)

    assertCounts({ known = 0, alts = 0, unlinked = 0, characters = 0 }, addon.RosterViewModel.Counts(partition))
end)

test.test("lone characters with no alias or declared main are all unlinked", function()
    local addon = load()
    local partition = setup(addon)
    record(partition, "Anna")
    record(partition, "Bert")
    record(partition, "Cleo")

    assertCounts({ known = 0, alts = 0, unlinked = 3, characters = 3 }, addon.RosterViewModel.Counts(partition))
end)

test.test("a player counts with alts, an alias, or a declared main; alts are the rest", function()
    local addon = load()
    local partition = setup(addon)
    -- Three characters for one player: one player, two alts.
    local anna = record(partition, "Anna")
    partition:JoinPlayerOf(record(partition, "Anna Two"), anna, "note")
    partition:JoinPlayerOf(record(partition, "Anna Three"), anna, "note")
    -- One character with an alias, and one declared main: two players.
    local bert = record(partition, "Bert")
    partition:SetAlias(partition:GetCharacter(bert).player, "Bertie", "note")
    partition:SetDeclared(record(partition, "Cleo"), true, "manual")
    -- And one nobody has organized.
    record(partition, "Dora")

    assertCounts({ known = 3, alts = 2, unlinked = 1, characters = 6 }, addon.RosterViewModel.Counts(partition))
end)

test.test("departed characters are never counted", function()
    local addon = load()
    local partition = setup(addon)
    -- A main who left, with two alts still here: still a player, one alt.
    local anna = record(partition, "Anna")
    partition:JoinPlayerOf(record(partition, "Anna Two"), anna, "note")
    partition:JoinPlayerOf(record(partition, "Anna Three"), anna, "note")
    partition:MarkDeparted(anna, 1790000000)
    -- A player whose characters have all left is ignored.
    local bert = record(partition, "Bert")
    partition:JoinPlayerOf(record(partition, "Bert Two"), bert, "note")
    partition:MarkDeparted(bert, 1790000000)
    partition:MarkDeparted("bert two-camelot", 1790000000)
    -- A declared main who left leaves its alt on its own: unlinked.
    local cleo = record(partition, "Cleo")
    partition:SetDeclared(cleo, true, "manual")
    partition:JoinPlayerOf(record(partition, "Cleo Two"), cleo, "note")
    partition:MarkDeparted(cleo, 1790000000)

    assertCounts({ known = 1, alts = 1, unlinked = 1, characters = 3 }, addon.RosterViewModel.Counts(partition))
end)

test.test("counts who is online, aliases and declared mains, with unlinked characters as players", function()
    local addon = load()
    local partition = setup(addon)
    -- Anna has an alt online; Bert has an alias and is offline; Cleo
    -- declared her main and is online; Dora and Eve are unlinked, Eve online.
    local anna = record(partition, "Anna")
    local annaTwo = record(partition, "Anna Two")
    partition:JoinPlayerOf(annaTwo, anna, "note")
    local bert = record(partition, "Bert")
    partition:SetAlias(partition:GetCharacter(bert).player, "Bertie", "note")
    local cleo = record(partition, "Cleo")
    partition:SetDeclared(cleo, true, "manual")
    record(partition, "Dora")
    local eve = record(partition, "Eve")
    -- A departed character online elsewhere is still not counted.
    local fred = record(partition, "Fred")
    partition:MarkDeparted(fred, 1790000000)
    local members = {
        [annaTwo] = { online = true },
        [anna] = { online = false },
        [cleo] = { online = true },
        [eve] = { online = true },
        [fred] = { online = true },
    }

    local counts = addon.RosterViewModel.Counts(partition, members)

    assertCounts({ known = 3, alts = 1, unlinked = 2, characters = 6 }, counts)
    -- Anna (by her alt), Cleo, and unlinked Eve.
    test.assertEqual(3, counts.playersOnline)
    test.assertEqual(3, counts.charactersOnline)
    test.assertEqual(1, counts.withAlias)
    test.assertEqual(1, counts.declared)
end)

test.test("players are active within 7, 30 and 90 days by their most recent character", function()
    local addon = load()
    local partition = setup(addon)
    local function away(days)
        return { online = false, lastOnline = { years = 0, months = 0, days = days, hours = 0 } }
    end
    -- Anna's main was away 60 days, but her alt is online: active in all.
    local anna = record(partition, "Anna")
    local annaTwo = record(partition, "Anna Two")
    partition:JoinPlayerOf(annaTwo, anna, "note")
    -- Unlinked characters count as players: Bert 3 days, Cleo 20 days, Dora
    -- 2 months (60 days), Eve a year, and Fred with no last-online time.
    local bert, cleo, dora, eve = record(partition, "Bert"), record(partition, "Cleo"), record(partition, "Dora"),
        record(partition, "Eve")
    record(partition, "Fred")
    -- Exactly 7 days away is outside the 7-day window.
    local gus = record(partition, "Gus")
    local members = {
        [anna] = away(60),
        [annaTwo] = { online = true },
        [bert] = away(3),
        [cleo] = away(20),
        [dora] = { online = false, lastOnline = { years = 0, months = 2, days = 0, hours = 0 } },
        [eve] = { online = false, lastOnline = { years = 1, months = 0, days = 0, hours = 0 } },
        [gus] = away(7),
    }

    local counts = addon.RosterViewModel.Counts(partition, members)

    test.assertEqual(7, counts.players)
    test.assertEqual(2, counts.active[7])
    test.assertEqual(4, counts.active[30])
    test.assertEqual(5, counts.active[90])
end)

test.test("the counts tooltip gives known and unlinked players, who is active, and explains unlinked", function()
    local model = load().RosterViewModel

    local lines = model.CountsTooltip({ known = 27, unlinked = 293, players = 320, alts = 31, characters = 351,
        playersOnline = 9, charactersOnline = 11, withAlias = 18, declared = 21,
        active = { [7] = 45, [30] = 120, [90] = 180 } })

    test.assertEqual(9, #lines)
    test.assertEqual("Guild size", lines[1])
    test.assertEqual("320 players: 27 known + 293 unlinked", lines[2])
    test.assertEqual("Active players: 45 in 7 days, 120 in 30 days, 180 in 90 days", lines[3])
    test.assertEqual("9 of 320 players online", lines[4])
    test.assertEqual("11 of 351 characters online", lines[5])
    test.assertEqual("18 players have an alias", lines[6])
    test.assertEqual("21 mains declared", lines[7])
    test.assertEqual("  Unlinked: a lone character with no alias or declared main.", lines[8])
    test.assertEqual("  It counts as a player until it's linked, but may be someone's alt.", lines[9])
end)

test.test("the counts tooltip uses singular wording and leaves out unlinked at zero", function()
    local model = load().RosterViewModel

    local lines = model.CountsTooltip({ known = 1, unlinked = 0, players = 1, alts = 0, characters = 1,
        playersOnline = 1, charactersOnline = 1, withAlias = 1, declared = 1,
        active = { [7] = 1, [30] = 1, [90] = 1 } })

    test.assertEqual(7, #lines)
    test.assertEqual("1 player, all known", lines[2])
    test.assertEqual("1 of 1 player online", lines[4])
    test.assertEqual("1 of 1 character online", lines[5])
    test.assertEqual("1 player has an alias", lines[6])
    test.assertEqual("1 main declared", lines[7])
end)
