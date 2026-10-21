local test = require("tests.test_helper")

-- Officers' review of members' suggestions, one bundle per player.
local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local OFFICER = "toolbox-area52"
local NOW = 1790000000

local function newSetup()
    local addon = test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/SyncFacts.lua",
        "Core/SuggestionService.lua",
        "Core/ConflictViewModel.lua",
        "Core/BundleReviewViewModel.lua"
    )
    local partition = addon.FellowshipStore.Create({ schemaVersion = 4, guilds = {} }):Partition(GUILD)
    local names = { "Toolbox", "Hammer", "Wrench", "Anvil", "Bolt" }
    local index
    for index = 1, #names do
        partition:RecordCharacter(string.lower(names[index]) .. "-area52",
            { name = names[index] .. "-Area52", level = 60 })
    end
    -- Bolt is Hammer's alt.
    partition:JoinPlayerOf("bolt-area52", "hammer-area52", "manual")
    local service = addon.SuggestionService.Create(partition, {
        isOfficer = function(key)
            return key == OFFICER
        end,
        now = function()
            return NOW
        end,
    })
    local normalizer = addon.NameNormalizer.Create({ twoPartNames = false, homeRealm = "Area52" })
    return {
        addon = addon,
        partition = partition,
        service = service,
        rows = function()
            return addon.ConflictViewModel.Build({ partition = partition, normalizer = normalizer })
        end,
        review = function(bundle, members)
            return addon.BundleReviewViewModel.Build({
                partition = partition, normalizer = normalizer, bundle = bundle, members = members,
            })
        end,
    }
end

local function link(character, main, by)
    return { kind = "main", character = character, main = main, at = NOW, by = by }
end

local function alias(character, text, by)
    return { kind = "alias", character = character, alias = text, at = NOW, by = by }
end

local function declare(character, by)
    return { kind = "declared", character = character, declared = true, at = NOW, by = by }
end

local function discord(character, text, by)
    return { kind = "discord", character = character, text = text, at = NOW, by = by }
end

-- One side of a review block in short: each line's text, "-" before a
-- removed line and "+" before an added one, joined by "; ".
local function side(lines)
    local marks = { same = "", removed = "-", added = "+" }
    local texts = {}
    local index
    for index = 1, #lines do
        texts[index] = marks[lines[index].mark] .. lines[index].text
    end
    return table.concat(texts, "; ")
end

test.test("members' suggestions are grouped into one bundle per player, before note conflicts", function()
    local setup = newSetup()
    -- Hammer, from two of their characters; Anvil on their own; and a note
    -- conflict.
    setup.service:Queue({ link("wrench-area52", "hammer-area52", "hammer-area52") }, "hammer-area52")
    setup.service:Queue({ alias("hammer-area52", "Hammers", "bolt-area52") }, "bolt-area52")
    setup.service:Queue({ link("anvil-area52", "toolbox-area52", "anvil-area52") }, "anvil-area52")
    local conflicts = setup.partition:GetConflicts()
    table.insert(conflicts, { character = "toolbox-area52", kind = "unresolved" })
    setup.partition:SetConflicts(conflicts)

    local rows = setup.rows()

    test.assertEqual(3, #rows)
    test.assertEqual("bundle", rows[1].kind)
    test.assertEqual("Hammer", rows[1].name)
    test.assertEqual(2, rows[1].count)
    test.assertEqual("2 changes", rows[1].changes)
    test.assertEqual("suggested main", rows[1].items[1].kind)
    test.assertEqual("hammer-area52", rows[1].items[1].from)
    test.assertEqual("bolt-area52", rows[1].items[2].from)
    test.assertEqual("bundle", rows[2].kind)
    test.assertEqual("Anvil", rows[2].name)
    test.assertEqual("1 change", rows[2].changes)
    test.assertEqual("unresolved", rows[3].kind)
    -- Counted once per bundle, plus each note conflict.
    test.assertEqual(3, setup.addon.ConflictViewModel.CountToReview(rows))
    test.assertEqual(3, setup.addon.ConflictViewModel.CountQueue(setup.partition))
end)

test.test("a member this client doesn't know still gets a bundle of their own", function()
    local setup = newSetup()
    local conflicts = {
        { character = "wrench-area52", kind = "suggested main", suggestion = { main = "toolbox-area52" },
            from = "stranger-area52", at = NOW },
    }
    setup.partition:SetConflicts(conflicts)

    local rows = setup.rows()

    test.assertEqual("bundle", rows[1].kind)
    test.assertEqual("member:stranger-area52", rows[1].group)
    test.assertEqual(1, setup.addon.ConflictViewModel.CountQueue(setup.partition))
end)

test.test("the review says who suggested it and shows every changed player before and after, alts one per line", function()
    local setup = newSetup()
    setup.partition:SetAlias(setup.partition:GetCharacter("hammer-area52").player, "Hammy", "manual")
    -- From Bolt, Hammer's alt: Wrench joins Hammer, Bolt leaves, and the alias changes.
    setup.service:Queue({
        link("wrench-area52", "hammer-area52", "bolt-area52"),
        link("bolt-area52", "bolt-area52", "bolt-area52"),
        alias("hammer-area52", "Hammers", "bolt-area52"),
    }, "bolt-area52")

    local review = setup.review(setup.rows()[1])

    test.assertEqual("Review: Hammy", review.title)
    test.assertEqual("Suggested by Bolt (Hammy)", review.suggestedBy)
    test.assertEqual(3, #review.players)
    local hammy = review.players[1]
    test.assertEqual("Hammy", hammy.name)
    test.assertEqual("Main: Hammer; -Alias: Hammy; Discord: none; -Alt: Bolt", side(hammy.before))
    test.assertEqual("Main: Hammer; +Alias: Hammers; Discord: none; +Alt: Wrench", side(hammy.after))
    -- Wrench's own player joins Hammer's, taking its alias.
    local wrench = review.players[2]
    test.assertEqual("Wrench", wrench.name)
    test.assertEqual("-Main: Wrench; -Alias: none; Discord: none; -Alts: none", side(wrench.before))
    test.assertEqual("+Main: Hammer; +Alias: Hammers; Discord: none; +Alt: Wrench", side(wrench.after))
    -- Bolt becomes a player of its own.
    local bolt = review.players[3]
    test.assertEqual("Bolt", bolt.name)
    test.assertEqual("", side(bolt.before))
    test.assertEqual("+Main: Bolt; +Alias: none; +Discord: none; +Alts: none", side(bolt.after))

    test.assertEqual(3, #review.items)
    test.assertEqual("Wrench: Own player → Alt of Hammer", review.items[1].text)
    test.assertEqual("Bolt: Alt of Hammer → Main of its own player", review.items[2].text)
    test.assertEqual("Alias: Alias \"Hammy\" → Alias \"Hammers\"", review.items[3].text)
    test.assertEqual("wrench-area52", review.items[1].character)
    test.assertEqual("suggested main", review.items[1].kind)
end)

test.test("a member linking their character under someone else's main shows both players", function()
    local setup = newSetup()
    -- Anvil puts their own character under Toolbox's main.
    setup.service:Queue({ link("anvil-area52", "toolbox-area52", "anvil-area52") }, "anvil-area52")

    local review = setup.review(setup.rows()[1])

    test.assertEqual("Suggested by Anvil", review.suggestedBy)
    test.assertEqual(2, #review.players)
    test.assertEqual("Anvil", review.players[1].name)
    test.assertEqual("-Main: Anvil; Alias: none; Discord: none; -Alts: none", side(review.players[1].before))
    test.assertEqual("+Main: Toolbox; Alias: none; Discord: none; +Alt: Anvil", side(review.players[1].after))
    test.assertEqual("Toolbox", review.players[2].name)
    test.assertEqual("Main: Toolbox; Alias: none; Discord: none; -Alts: none", side(review.players[2].before))
    test.assertEqual("Main: Toolbox; Alias: none; Discord: none; +Alt: Anvil", side(review.players[2].after))
end)

test.test("the review follows a switch of main through every character", function()
    local setup = newSetup()
    -- Hammer makes Bolt the main.
    setup.service:Queue({
        link("hammer-area52", "bolt-area52", "hammer-area52"),
        link("bolt-area52", "bolt-area52", "hammer-area52"),
    }, "hammer-area52")

    local review = setup.review(setup.rows()[1])

    -- One player, its main switched, and no new player for Bolt.
    test.assertEqual(1, #review.players)
    test.assertEqual("-Main: Hammer; Alias: none; Discord: none; -Alt: Bolt", side(review.players[1].before))
    test.assertEqual("+Main: Bolt; Alias: none; Discord: none; +Alt: Hammer", side(review.players[1].after))
end)

test.test("changed declared main and Discord lines are marked, and unchanged players are left out", function()
    local setup = newSetup()
    setup.partition:SetProfileText("wrench-area52", "discord", "old#1", NOW - 10, "wrench-area52")
    -- Hammer declares their main and suggests a Discord for Wrench's player.
    setup.service:Queue({
        declare("hammer-area52", "hammer-area52"),
        discord("wrench-area52", "wrench#1", "hammer-area52"),
    }, "hammer-area52")

    local review = setup.review(setup.rows()[1])

    test.assertEqual(2, #review.players)
    test.assertEqual("-Main: Hammer; Alias: none; Discord: none; Alt: Bolt", side(review.players[1].before))
    test.assertEqual("+Main: Hammer (declared); Alias: none; Discord: none; Alt: Bolt", side(review.players[1].after))
    test.assertEqual("Wrench", review.players[2].name)
    test.assertEqual("Main: Wrench; Alias: none; -Discord: old#1; Alts: none", side(review.players[2].before))
    test.assertEqual("Main: Wrench; Alias: none; +Discord: wrench#1; Alts: none", side(review.players[2].after))
end)

test.test("the review shows the live guild note of each character involved, unhighlighted", function()
    local setup = newSetup()
    setup.service:Queue({ link("wrench-area52", "hammer-area52", "bolt-area52") }, "bolt-area52")

    local review = setup.review(setup.rows()[1], {
        ["bolt-area52"] = { name = "Bolt-Area52", note = ">Hammer" },
        ["wrench-area52"] = { name = "Wrench-Area52", note = "healer" },
    })

    -- The suggesting character, the one the change is about, and the main it names.
    test.assertEqual(3, #review.notes)
    test.assertEqual("Bolt", review.notes[1].name)
    test.assertEqual(">Hammer", review.notes[1].note)
    test.assertEqual("Wrench", review.notes[2].name)
    test.assertEqual("healer", review.notes[2].note)
    test.assertEqual("Hammer", review.notes[3].name)
    test.assertEqual(nil, review.notes[3].note)

    -- The window lists each block's sides in red and green, then the notes plain.
    local addon = test.newAddon("Core/Identity.lua", "Adapters/MasterFrame.lua", "Adapters/RosterWindow.lua")
    local lines = addon.RosterWindow.ReviewLines(review)
    test.assertEqual("|cffffd100Hammer|r", lines[1].before)
    local colored = {}
    local index
    for index = 1, #lines do
        colored[index] = lines[index].before .. " | " .. lines[index].after
    end
    local all = table.concat(colored, "\n")
    test.assertContains(all, "|cff40ff40Alt: Wrench|r")
    test.assertContains(all, "|cffff4040Main: Wrench|r")
    test.assertContains(all, "|cffffd100Guild notes|r")
    test.assertContains(all, "Wrench: healer | ")
end)

test.test("the conflict window lists Changes to Player, Note conflicts and your own suggestions under headings", function()
    local addon = test.newAddon("Core/Identity.lua", "Adapters/MasterFrame.lua", "Adapters/RosterWindow.lua")
    local sections = addon.RosterWindow.ConflictSections({
        { section = "changes", kind = "bundle", name = "Hammer" },
        { section = "notes", kind = "unresolved", name = "Toolbox" },
        { section = "yours", kind = "suggested main", name = "Wrench", pending = true },
    })

    local names = {}
    local index
    for index = 1, #sections do
        names[index] = sections[index].name
    end
    test.assertEqual("Changes to Player, Hammer, Note conflicts, Toolbox, Your suggestions, Wrench",
        table.concat(names, ", "))
    test.assertEqual("heading", sections[1].kind)
    -- Each heading carries its section, so its line names that section's columns.
    test.assertEqual("changes", sections[1].section)
    test.assertEqual("notes", sections[3].section)
    test.assertEqual("yours", sections[5].section)
    -- Empty sections get no heading.
    test.assertEqual(2, #addon.RosterWindow.ConflictSections({ { kind = "unresolved", name = "Toolbox" } }))
end)
