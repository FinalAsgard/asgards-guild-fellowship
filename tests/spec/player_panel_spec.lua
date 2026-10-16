local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local RULES = { twoPartNames = false, homeRealm = "Area52" }
local START = 1790000000

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

-- TheTool: Toolbox (main) + Hammer + Wrench; Wrench then leaves and is
-- purged, so the player has a history entry.
local function setup()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local function members(entries)
        local result = {}
        local index
        for index = 1, #entries do
            result[normalizer:Key(entries[index][1])] = {
                name = entries[index][1], note = entries[index][2], level = entries[index][3],
                online = entries[index][4] == "online", zone = entries[index][4] == "online" and "Dornogal" or nil,
            }
        end
        return result
    end
    local function scan(entries, mode, now)
        addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
            partition = partition, members = members(entries), normalizer = normalizer,
            rules = RULES, mode = mode or "full", now = now or START,
        }))
    end
    local guild = {
        { "Toolbox-Area52", "@TheTool", 80 },
        { "Hammer-Area52", ">Toolbox", 70, "online" },
        { "Wrench-Area52", ">Toolbox", 60 },
    }
    scan(guild, "initial")
    scan({ guild[1], guild[2] }, "full", START + 86400)
    addon.PlayerService.Create(partition):Purge("wrench-area52")
    local playerId = partition:GetCharacter("toolbox-area52").player
    return {
        addon = addon,
        partition = partition,
        playerId = playerId,
        -- `adStats`, when given, answers the panel's ad count line; `wrap`
        -- wraps the bio.
        build = function(adStats, wrap)
            return addon.PlayerPanelViewModel.Build({
                partition = partition,
                playerId = playerId,
                members = members({ guild[1], guild[2] }),
                normalizer = normalizer,
                adStats = adStats,
                wrap = wrap,
                formatDate = function(timestamp)
                    return "day " .. (timestamp - START) / 86400
                end,
            })
        end,
        summary = function()
            return addon.PlayerPanelViewModel.Summary({
                partition = partition,
                playerId = playerId,
                members = members({ guild[1], guild[2] }),
                normalizer = normalizer,
            })
        end,
    }
end

local function rowsOf(model, kind)
    local found = {}
    local index
    for index = 1, #model.rows do
        if model.rows[index].kind == kind then
            table.insert(found, model.rows[index])
        end
    end
    return found
end

test.test("the panel shows the alias, acting main, alts, and history", function()
    local state = setup()

    local model = state.build()

    test.assertEqual("TheTool (Toolbox)", model.label)
    test.assertEqual("TheTool", model.alias)
    test.assertEqual("from a note", model.aliasSource)
    test.assertEqual("toolbox-area52", model.main)
    local characters = rowsOf(model, "character")
    test.assertEqual(2, #characters)
    test.assertTrue(characters[1].isMain)
    test.assertEqual("Toolbox", characters[1].name)
    test.assertEqual("Hammer", characters[2].name)
    test.assertEqual("Online, Dornogal", characters[2].status)
    local history = rowsOf(model, "history")
    test.assertEqual(1, #history)
    -- Shown as the roster spells it, without the home realm.
    test.assertEqual("Wrench", history[1].name)
    test.assertEqual("Alt", history[1].role)
    test.assertEqual("left the guild, purged", history[1].reason)
    test.assertEqual("until day 1", history[1].dates)
end)

test.test("the panel says whether the player is marked don't sync", function()
    local state = setup()
    test.assertFalse(state.build().dontSync)

    state.partition:SetNoSync(state.playerId, true)

    test.assertTrue(state.build().dontSync)
end)

test.test("panel rows offer the same actions as the right-click menu", function()
    local state = setup()

    local characters = rowsOf(state.build(), "character")

    test.assertFalse(characters[1].canMakeMain)
    test.assertTrue(characters[1].canDetach)
    test.assertTrue(characters[2].canMakeMain)
    test.assertTrue(characters[2].canDetach)
    -- With alts, the player can't be merged into another.
    test.assertFalse(state.build().canMerge)
end)

test.test("a player with no alts or history says so", function()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    partition:RecordCharacter("solo-area52", { name = "Solo" })

    local model = addon.PlayerPanelViewModel.Build({
        partition = partition,
        playerId = partition:GetCharacter("solo-area52").player,
        normalizer = addon.NameNormalizer.Create(RULES),
    })

    local empties = rowsOf(model, "empty")
    test.assertEqual("No alts", empties[1].text)
    test.assertEqual("No former characters", empties[2].text)
    test.assertFalse(rowsOf(model, "character")[1].canDetach)
    test.assertTrue(model.canMerge)
end)

test.test("an out-of-guild main shows in history with its date", function()
    local state = setup()
    state.partition:AddHistory(state.playerId, { name = "Bigmain", role = "main", since = START + 2 * 86400,
        reason = "out of guild" })

    local history = rowsOf(state.build(), "history")

    test.assertEqual("Bigmain", history[1].name)
    test.assertEqual("Main", history[1].role)
    test.assertEqual("not in the guild", history[1].reason)
    test.assertEqual("since day 2", history[1].dates)
end)

test.test("the panel is gone when its player no longer exists", function()
    local state = setup()

    local model = state.addon.PlayerPanelViewModel.Build({
        partition = state.partition,
        playerId = 999,
        normalizer = state.addon.NameNormalizer.Create(RULES),
    })

    test.assertEqual(nil, model)
end)

-- Controller: selecting and editing ------------------------------------------

local function controllerSetup(onSyncResumed)
    local world = fixtures.newEnvironment("Retail")
    world.environment.date = function(format, timestamp)
        return os.date("!" .. format, timestamp)
    end
    local addon = test.newAddon(
        "Adapters/ClientProfile.lua",
        "Adapters/WoW.lua",
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/RosterViewModel.lua",
        "Core/ConflictViewModel.lua",
        "Core/PlayerPanelViewModel.lua",
        "Core/ScanScheduler.lua",
        "Core/RosterController.lua"
    )
    local client = addon.Compatibility.Create(world.environment)
    local database = { schemaVersion = 1, guilds = {} }
    local window = { shown = false, rows = {}, player = nil }
    function window:IsShown() return self.shown end
    function window:Show() self.shown = true end
    function window:Hide() self.shown = false end
    function window:SetTitle() end
    function window:SetStatus() end
    function window:SetRows(rows) self.rows = rows return true end
    function window:SetConflicts() return true end
    function window:ShowPlayer(model) self.player = model return true end
    function window:HidePlayer() self.player = nil return true end
    local controller = addon.RosterController.Create({
        client = client,
        nameRules = client:GetClientProfile().nameRules,
        getDatabase = function() return database end,
        createWindow = function() return window end,
        onSyncResumed = onSyncResumed,
    })
    controller:OnSavedDataReady()
    controller:OnRosterUpdate()
    fixtures.runTimers(world)
    controller:Toggle()
    return controller, window, client, addon
end

test.test("selecting a character opens its player's panel", function()
    local controller, window = controllerSetup()

    test.assertTrue(controller:SelectPlayerOf("hammer-area52"))

    test.assertEqual("TheTool (Toolbox)", window.player.label)
end)

test.test("panel edits are manual and refresh the roster and the panel at once", function()
    local controller, window = controllerSetup()
    controller:SelectPlayerOf("hammer-area52")

    controller:SetAlias(window.player.main, "Tool Time")
    test.assertEqual("Tool Time (Toolbox)", window.player.label)
    test.assertEqual("set by hand", window.player.aliasSource)
    test.assertEqual("Tool Time (Toolbox)", window.rows[1].label)

    controller:MakeMain("hammer-area52")
    test.assertEqual("hammer-area52", window.player.main)

    controller:Detach("toolbox-area52")
    test.assertEqual("Tool Time (Hammer)", window.player.label)
    test.assertEqual("No alts", window.player.rows[4].text)
end)

test.test("the panel closes when its player is merged away", function()
    local controller, window = controllerSetup()
    controller:SelectPlayerOf("visitor-stormrage")
    test.assertTrue(window.player ~= nil)

    local toolPlayer = controller.current.partition:GetCharacter("toolbox-area52").player
    controller:SetMainPlayer("visitor-stormrage", toolPlayer)

    test.assertEqual(nil, window.player)
end)

test.test("don't sync is toggled from the panel, marked there, and turning it off resumes sync", function()
    local resumed = {}
    local controller, window = controllerSetup(function(key)
        table.insert(resumed, key)
    end)
    controller:SelectPlayerOf("hammer-area52")
    test.assertFalse(window.player.dontSync)

    test.assertTrue(controller:SetDontSync(window.player.main, true))
    test.assertTrue(window.player.dontSync, "the panel shows the player is pinned")
    test.assertTrue(controller.current.partition:IsNoSync(window.player.id))
    test.assertEqual(0, #resumed)

    test.assertTrue(controller:SetDontSync(window.player.main, false))
    test.assertFalse(window.player.dontSync)
    test.assertFalse(controller.current.partition:IsNoSync(window.player.id))
    test.assertEqual(1, #resumed)
    test.assertEqual("toolbox-area52", resumed[1])
end)

test.test("dates are formatted by the client", function()
    local _, _, client = controllerSetup()

    test.assertEqual("2026-09-21", client:FormatDate(1790000000))
    test.assertEqual("", client:FormatDate(nil))
end)

test.test("player panel: a player with an ad record shows it first, and one without shows nothing", function()
    local state = setup()
    local asked
    local model = state.build(function(keys)
        asked = keys
        return "Advertised: 12 (3 in last 30 days)"
    end)

    test.assertEqual("stat", model.rows[1].kind)
    test.assertEqual("Advertised: 12 (3 in last 30 days)", model.rows[1].text)
    test.assertEqual("section", model.rows[2].kind)
    -- Every one of the player's characters is asked about.
    test.assertEqual(2, #asked)

    local none = state.build(function()
        return nil
    end)
    test.assertEqual("section", none.rows[1].kind)
    test.assertEqual(0, #rowsOf(none, "stat"))
    test.assertEqual(0, #rowsOf(state.build(), "stat"))
    test.assertEqual(0, #rowsOf(state.build(function() error("boom") end), "stat"))
end)

test.test("the bio wraps at spaces to a measured width, never inside a character", function()
    local addon = load()
    -- Each byte measures 5 wide, as in a fixed-width font.
    local function measure(text)
        return #text * 5
    end

    local lines = addon.PlayerPanelViewModel.Wrap("I heal dungeons most evenings", 60, measure)
    test.assertEqual("I heal", lines[1])
    test.assertEqual("dungeons", lines[2])
    test.assertEqual("most", lines[3])
    test.assertEqual("evenings", lines[4])

    -- A word wider than a line is split, keeping each character whole.
    lines = addon.PlayerPanelViewModel.Wrap("ééééé", 20, measure)
    test.assertEqual("éé", lines[1])
    test.assertEqual("éé", lines[2])
    test.assertEqual("é", lines[3])

    -- Malformed text (a byte no character starts with) still gets split,
    -- one byte at a time, never looping forever.
    lines = addon.PlayerPanelViewModel.Wrap("\128\128\128\128\128", 10, measure)
    test.assertEqual("\128\128", lines[1])
    test.assertEqual("\128\128", lines[2])
    test.assertEqual("\128", lines[3])
end)

test.test("a blank line typed in the bio stays; one at the very end doesn't", function()
    local addon = load()
    local lines = addon.PlayerPanelViewModel.Wrap("Healer.\n\nEvenings only.\n", 48)
    test.assertEqual(3, #lines)
    test.assertEqual("Healer.", lines[1])
    test.assertEqual("", lines[2])
    test.assertEqual("Evenings only.", lines[3])
end)

test.test("the panel model wraps the bio with the window's wrapper when given", function()
    local state = setup()
    state.partition:SetProfileText("toolbox-area52", "bio", "Raid lead on weekends", START, "toolbox-area52")

    local model = state.build(nil, function(text)
        return { "[" .. text .. "]" }
    end)

    local about = rowsOf(model, "about")
    test.assertEqual("[Raid lead on weekends]", about[1].text)

    -- Discord and Location are wrapped too, with their labels.
    state.partition:SetProfileText("toolbox-area52", "location", "Stormwind", START, "toolbox-area52")
    about = rowsOf(state.build(nil, function(text)
        return { "[" .. text .. "]" }
    end), "about")
    test.assertEqual("[Location: Stormwind]", about[1].text)
end)

test.test("the mini profile lists the main, then Discord and location, alts, and the bio", function()
    local state = setup()

    -- Nothing set: the labels stay, left blank.
    local summary = state.summary()
    test.assertEqual("TheTool (Toolbox)", summary.title)
    test.assertEqual(table.concat({
        "Main: Toolbox (80)",
        "",
        "Discord:",
        "Location:",
        "",
        "Alts:",
        "Hammer (70)",
        "",
        "Personal Bio",
        "",
    }, "|"), table.concat(summary.lines, "|"))

    state.partition:SetProfileText("toolbox-area52", "discord", "thetool", START, "toolbox-area52")
    state.partition:SetProfileText("toolbox-area52", "location", "Stormwind", START, "toolbox-area52")
    state.partition:SetProfileText("toolbox-area52", "bio", "Raid lead on weekends", START, "toolbox-area52")
    test.assertEqual(table.concat({
        "Main: Toolbox (80)",
        "",
        "Discord: thetool",
        "Location: Stormwind",
        "",
        "Alts:",
        "Hammer (70)",
        "",
        "Personal Bio",
        "Raid lead on weekends",
    }, "|"), table.concat(state.summary().lines, "|"))
end)

test.test("the mini profile leaves Alts blank for a player without alts, and is nil for one that's gone", function()
    local state = setup()
    state.addon.PlayerService.Create(state.partition):Detach("hammer-area52")

    local lines = state.summary().lines
    test.assertEqual("Alts:", lines[6])
    test.assertEqual("", lines[7])
    test.assertEqual("Personal Bio", lines[8])

    local addon = state.addon
    test.assertEqual(nil, addon.PlayerPanelViewModel.Summary({ partition = state.partition, playerId = "nobody" }))
end)
