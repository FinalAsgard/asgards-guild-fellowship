local test = require("tests.test_helper")

-- Manual organization is the source of truth: notes may only suggest a
-- change to it through the conflict queue, even when a scan yields while
-- the player edits, or is cut short.
local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/RosterViewModel.lua",
        "Core/PlayerPanelViewModel.lua"
    )
end

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- Entries are { "Name-Realm", note }.
local function setup()
    local addon = load()
    local database = { schemaVersion = 1, guilds = {} }
    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local state = { addon = addon, partition = partition }

    function state.plan(entries, mode, force)
        local members = {}
        local index
        for index = 1, #entries do
            members[normalizer:Key(entries[index][1])] = {
                name = entries[index][1], note = entries[index][2] or "", classToken = "WARRIOR", level = 10,
            }
        end
        return addon.ReconcileEngine.Plan({
            partition = partition,
            members = members,
            normalizer = normalizer,
            rules = RULES,
            mode = mode or "full",
            force = force,
            now = 1790000000,
        })
    end

    function state.scan(entries, mode, force)
        return addon.ReconcileEngine.Apply(partition, state.plan(entries, mode, force))
    end

    function state.service()
        return addon.PlayerService.Create(partition, { now = function() return 1790000000 end })
    end

    function state.playerOf(key)
        return partition:GetPlayer(partition:GetCharacter(key).player)
    end

    function state.hasConflict(key, kind)
        local conflicts = partition:GetConflicts() or {}
        local index
        for index = 1, #conflicts do
            if conflicts[index].character == key and conflicts[index].kind == kind then
                return true
            end
        end
        return false
    end

    return state
end

local LINKED = {
    { "Toolbox-Area52", "" },
    { "Hammer-Area52", ">Toolbox" },
}

test.test("a detached character is not linked again by its note on a forced rescan", function()
    local state = setup()
    state.scan(LINKED, "initial")
    test.assertTrue(state.service():Detach("hammer-area52"))

    state.scan(LINKED, "full", true)

    test.assertEqual("hammer-area52", state.playerOf("hammer-area52").main)
    test.assertTrue(state.hasConflict("hammer-area52", "main"), "the note becomes a conflict to review")
end)

test.test("a detached character whose note changes gets a conflict, not a new link", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox" }, { "Anvil-Area52", "" } }, "initial")
    test.assertTrue(state.service():Detach("hammer-area52"))

    state.scan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", "Main: Anvil" }, { "Anvil-Area52", "" } })

    test.assertEqual("hammer-area52", state.playerOf("hammer-area52").main)
    test.assertTrue(state.hasConflict("hammer-area52", "main"))
end)

test.test("an alias cleared by hand is not set again by a note", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "@TheTool" } }, "initial")
    test.assertTrue(state.service():SetAlias("toolbox-area52", ""))

    state.scan({ { "Toolbox-Area52", "@TheTool" } }, "full", true)

    test.assertEqual(nil, state.playerOf("toolbox-area52").alias)
    test.assertTrue(state.hasConflict("toolbox-area52", "alias"))
end)

test.test("a link planned before a manual change is not applied over it", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", "" }, { "Anvil-Area52", "" } }, "initial")
    local plan = state.plan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox" }, { "Anvil-Area52", "" } })
    test.assertEqual("toolbox-area52", plan.links["hammer-area52"])

    -- The scan yields; meanwhile the player links Hammer to Anvil.
    local anvil = state.partition:GetCharacter("anvil-area52").player
    test.assertTrue(state.service():SetMainPlayer("hammer-area52", anvil))
    state.addon.ReconcileEngine.Apply(state.partition, plan)

    test.assertEqual("anvil-area52", state.playerOf("hammer-area52").main)
    -- The note still disagrees, so the next ordinary scan queues it.
    state.scan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox" }, { "Anvil-Area52", "" } })
    test.assertEqual("anvil-area52", state.playerOf("hammer-area52").main)
    test.assertTrue(state.hasConflict("hammer-area52", "main"), "the skipped note becomes a conflict")
end)

test.test("an alias planned before a manual alias is not applied over it", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" } }, "initial")
    local plan = state.plan({ { "Toolbox-Area52", "@TheTool" } })
    test.assertEqual("TheTool", plan.aliases["toolbox-area52"])

    test.assertTrue(state.service():SetAlias("toolbox-area52", "Tooly"))
    state.addon.ReconcileEngine.Apply(state.partition, plan)

    test.assertEqual("Tooly", state.playerOf("toolbox-area52").alias)
    state.scan({ { "Toolbox-Area52", "@TheTool" } })
    test.assertEqual("Tooly", state.playerOf("toolbox-area52").alias)
    test.assertTrue(state.hasConflict("toolbox-area52", "alias"), "the skipped note becomes a conflict")
end)

test.test("a scan cut short leaves its notes to be processed by the next scan", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", "" } }, "initial")
    local entries = { { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox" } }

    -- A reload stops the scan at its last yield inside Apply, once both
    -- characters are recorded but before Hammer is linked.
    local yields = 0
    local ok = pcall(state.addon.ReconcileEngine.Apply, state.partition, state.plan(entries), function()
        yields = yields + 1
        if yields == #entries then
            error("interrupted")
        end
    end)
    test.assertFalse(ok)
    test.assertEqual("hammer-area52", state.playerOf("hammer-area52").main)

    state.scan(entries)

    test.assertEqual("toolbox-area52", state.playerOf("hammer-area52").main)
end)

-- History of characters that left a player -----------------------------------

local function historyOf(state, key)
    return state.partition:GetHistory(state.partition:GetCharacter(key).player)
end

test.test("detaching an alt keeps it in its former player's history", function()
    local state = setup()
    state.scan(LINKED, "initial")

    test.assertTrue(state.service():Detach("hammer-area52"))

    local history = historyOf(state, "toolbox-area52")
    test.assertEqual(1, #history)
    test.assertEqual("Hammer-Area52", history[1].name)
    test.assertEqual("alt", history[1].role)
    test.assertEqual("detached", history[1].reason)
    test.assertEqual(1790000000, history[1]["until"])
end)

test.test("moving a character to another player names where it went", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox" }, { "Anvil-Area52", "" } }, "initial")
    local anvil = state.partition:GetCharacter("anvil-area52").player

    test.assertTrue(state.service():SetMainPlayer("hammer-area52", anvil))

    local history = historyOf(state, "toolbox-area52")
    test.assertEqual(1, #history)
    test.assertEqual("moved to Anvil-Area52", history[1].reason)
end)

test.test("a single-character player that is moved leaves no history behind", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" }, { "Anvil-Area52", "" } }, "initial")
    local toolbox = state.partition:GetCharacter("toolbox-area52").player

    test.assertTrue(state.service():SetMainPlayer("anvil-area52", toolbox))

    test.assertEqual(0, #historyOf(state, "toolbox-area52"))
end)

test.test("a character moved back is no longer listed as a former character", function()
    local state = setup()
    state.scan(LINKED, "initial")
    local toolbox = state.partition:GetCharacter("toolbox-area52").player
    test.assertTrue(state.service():Detach("hammer-area52"))

    test.assertTrue(state.service():SetMainPlayer("hammer-area52", toolbox))

    local normalizer = state.addon.NameNormalizer.Create(RULES)
    local model = state.addon.PlayerPanelViewModel.Build({
        partition = state.partition, playerId = toolbox, members = {}, normalizer = normalizer,
    })
    local index
    for index = 1, #model.rows do
        test.assertTrue(model.rows[index].kind ~= "history", "no history row for a current member")
    end
end)

test.test("purging a character that was moved back still records it as purged", function()
    local state = setup()
    state.scan(LINKED, "initial")
    local toolbox = state.partition:GetCharacter("toolbox-area52").player
    test.assertTrue(state.service():Detach("hammer-area52"))
    test.assertTrue(state.service():SetMainPlayer("hammer-area52", toolbox))
    state.scan({ { "Toolbox-Area52", "" } })

    test.assertTrue(state.service():Purge("hammer-area52"))

    local history = state.partition:GetHistory(toolbox)
    test.assertEqual("purged", history[#history].reason)
end)

test.test("a new member whose pickup was cut short is finished by the next pickup", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "" } }, "initial")
    local entries = { { "Toolbox-Area52", "" }, { "Hammer-Area52", ">Toolbox" } }

    -- A reload stops the incremental pickup after Hammer is recorded.
    local ok = pcall(state.addon.ReconcileEngine.Apply, state.partition, state.plan(entries, "incremental"), function()
        error("interrupted")
    end)
    test.assertFalse(ok)
    test.assertTrue(state.partition:GetCharacter("hammer-area52") ~= nil)

    state.scan(entries, "incremental")

    test.assertEqual("toolbox-area52", state.playerOf("hammer-area52").main)
end)

test.test("an alias cleared by an officer's sync is not set again by a note", function()
    local state = setup()
    state.scan({ { "Toolbox-Area52", "@TheTool" } }, "initial")
    local player = state.partition:GetCharacter("toolbox-area52").player
    state.partition:ClearAlias(player, state.addon.FellowshipStore.SOURCE_SYNC)

    state.scan({ { "Toolbox-Area52", "@TheTool" } }, "full", true)

    test.assertEqual(nil, state.playerOf("toolbox-area52").alias)
end)
