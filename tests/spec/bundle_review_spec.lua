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
        review = function(bundle)
            return addon.BundleReviewViewModel.Build({
                partition = partition, normalizer = normalizer, bundle = bundle,
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
    test.assertEqual("2 changes", rows[1].suggests)
    test.assertEqual("suggested main", rows[1].items[1].kind)
    test.assertEqual("hammer-area52", rows[1].items[1].from)
    test.assertEqual("bolt-area52", rows[1].items[2].from)
    test.assertEqual("bundle", rows[2].kind)
    test.assertEqual("Anvil", rows[2].name)
    test.assertEqual("1 change", rows[2].suggests)
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

test.test("the review shows the player before and with every change, and each change in plain words", function()
    local setup = newSetup()
    setup.partition:SetAlias(setup.partition:GetCharacter("hammer-area52").player, "Hammy", "manual")
    -- Wrench joins Hammer, Bolt leaves, and the alias changes.
    setup.service:Queue({
        link("wrench-area52", "hammer-area52", "hammer-area52"),
        link("bolt-area52", "bolt-area52", "hammer-area52"),
        alias("hammer-area52", "Hammers", "hammer-area52"),
    }, "hammer-area52")

    local review = setup.review(setup.rows()[1])

    test.assertEqual("Review: Hammy", review.title)
    test.assertEqual("Main: Hammer", review.before[1])
    test.assertEqual("Alts: Bolt", review.before[2])
    test.assertEqual("Alias: Hammy", review.before[3])
    test.assertEqual("Main: Hammer", review.suggested[1])
    test.assertEqual("Alts: Wrench", review.suggested[2])
    test.assertEqual("Alias: Hammers", review.suggested[3])
    test.assertEqual(3, #review.items)
    test.assertEqual("Wrench: Own player → Alt of Hammer", review.items[1].text)
    test.assertEqual("Bolt: Alt of Hammer → Main of its own player", review.items[2].text)
    test.assertEqual("Alias: Alias \"Hammy\" → Alias \"Hammers\"", review.items[3].text)
    test.assertEqual("wrench-area52", review.items[1].character)
    test.assertEqual("suggested main", review.items[1].kind)
end)

test.test("the review follows a switch of main through every character", function()
    local setup = newSetup()
    -- Hammer makes Bolt the main.
    setup.service:Queue({
        link("hammer-area52", "bolt-area52", "hammer-area52"),
        link("bolt-area52", "bolt-area52", "hammer-area52"),
    }, "hammer-area52")

    local review = setup.review(setup.rows()[1])

    test.assertEqual("Main: Bolt", review.suggested[1])
    test.assertEqual("Alts: Hammer", review.suggested[2])
end)

test.test("the conflict window lists Member changes, Note conflicts and your own suggestions under headings", function()
    local addon = test.newAddon("Core/Identity.lua", "Adapters/MasterFrame.lua", "Adapters/RosterWindow.lua")
    local sections = addon.RosterWindow.ConflictSections({
        { kind = "bundle", name = "Hammer" },
        { kind = "unresolved", name = "Toolbox" },
        { kind = "suggested main", name = "Wrench", pending = true },
    })

    local names = {}
    local index
    for index = 1, #sections do
        names[index] = sections[index].name
    end
    test.assertEqual("Member changes, Hammer, Note conflicts, Toolbox, Your suggestions, Wrench",
        table.concat(names, ", "))
    test.assertEqual("heading", sections[1].kind)
    -- Empty sections get no heading.
    test.assertEqual(2, #addon.RosterWindow.ConflictSections({ { kind = "unresolved", name = "Toolbox" } }))
end)
