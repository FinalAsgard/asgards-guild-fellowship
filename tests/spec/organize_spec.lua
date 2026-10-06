local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua"
    )
end

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- TheTool: Toolbox (main, 80) + Hammer (70) + Wrench (60); Visitor alone.
local function setup()
    local addon = load()
    local database = { schemaVersion = 1, guilds = {} }
    local partition = addon.FellowshipStore.Create(database):Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local function roster(entries)
        local members = {}
        local index
        for index = 1, #entries do
            members[normalizer:Key(entries[index][1])] = {
                name = entries[index][1], note = entries[index][2], level = entries[index][3], classToken = "WARRIOR",
            }
        end
        return members
    end
    local function scan(entries, mode)
        addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
            partition = partition,
            members = roster(entries),
            normalizer = normalizer,
            rules = RULES,
            mode = mode or "full",
            now = 1790000000,
        }))
    end
    scan({
        { "Toolbox-Area52", "@TheTool", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 60 },
        { "Visitor-Area52", "", 30 },
    }, "initial")
    local service = addon.PlayerService.Create(partition, { normalizer = normalizer, now = function()
        return 1790000000
    end })
    return {
        addon = addon,
        partition = partition,
        scan = scan,
        service = service,
        playerOf = function(key)
            return partition:GetPlayer(partition:GetCharacter(key).player)
        end,
        playerIdOf = function(key)
            return partition:GetCharacter(key).player
        end,
    }
end

test.test("set main links a character as an alt of the chosen player, marked manual", function()
    local state = setup()

    test.assertTrue(state.service:SetMainPlayer("visitor-area52", state.playerIdOf("toolbox-area52")))

    test.assertEqual(state.playerOf("toolbox-area52"), state.playerOf("visitor-area52"))
    test.assertEqual("toolbox-area52", state.playerOf("visitor-area52").main)
    test.assertEqual("manual", state.partition:GetCharacter("visitor-area52").source)
end)

test.test("set main on a player's main moves it and its old player keeps a main", function()
    local state = setup()
    local oldPlayer = state.playerIdOf("toolbox-area52")

    test.assertTrue(state.service:SetMainPlayer("toolbox-area52", state.playerIdOf("visitor-area52")))

    test.assertEqual("visitor-area52", state.playerOf("toolbox-area52").main)
    test.assertEqual("hammer-area52", state.partition:GetPlayer(oldPlayer).main)
end)

test.test("make this the main promotes an alt to main, marked manual", function()
    local state = setup()

    test.assertTrue(state.service:MakeMain("wrench-area52"))

    test.assertEqual("wrench-area52", state.playerOf("hammer-area52").main)
    test.assertEqual("manual", state.partition:GetCharacter("wrench-area52").source)
end)

test.test("set alias accepts several words and clears with an empty alias", function()
    local state = setup()

    test.assertTrue(state.service:SetAlias("hammer-area52", "  The   Tool Man  "))
    test.assertEqual("The Tool Man", state.playerOf("toolbox-area52").alias)
    test.assertEqual("manual", state.playerOf("toolbox-area52").aliasSource)

    test.assertTrue(state.service:SetAlias("toolbox-area52", ""))
    test.assertEqual(nil, state.playerOf("toolbox-area52").alias)
    test.assertEqual("manual", state.playerOf("toolbox-area52").aliasSource)
end)

test.test("set alias refuses aliases over the length limit", function()
    local state = setup()

    local ok, reason = state.service:SetAlias("toolbox-area52", string.rep("x", 49))

    test.assertFalse(ok)
    test.assertContains(reason, "at most 48")
    test.assertEqual("TheTool", state.playerOf("toolbox-area52").alias)
end)

test.test("detach moves a character into a new single-character player as its main", function()
    local state = setup()
    local before = state.playerIdOf("hammer-area52")

    test.assertTrue(state.service:Detach("hammer-area52"))

    local player = state.playerOf("hammer-area52")
    test.assertTrue(state.playerIdOf("hammer-area52") ~= before)
    test.assertEqual("hammer-area52", player.main)
    test.assertEqual(nil, player.alias)
    test.assertEqual("manual", state.partition:GetCharacter("hammer-area52").source)
    test.assertEqual(1, #state.partition:CharactersOf(state.playerIdOf("hammer-area52")))
end)

test.test("detaching a player's main hands the main role to the highest-level character left", function()
    local state = setup()
    local oldPlayer = state.playerIdOf("toolbox-area52")

    test.assertTrue(state.service:Detach("toolbox-area52"))

    test.assertEqual("hammer-area52", state.partition:GetPlayer(oldPlayer).main)
    -- The alias stays with the player, not the detached character.
    test.assertEqual("TheTool", state.partition:GetPlayer(oldPlayer).alias)
end)

test.test("detaching a character that is already its own player is refused", function()
    local state = setup()

    local ok, reason = state.service:Detach("visitor-area52")

    test.assertFalse(ok)
    test.assertContains(reason, "already its own player")
end)

test.test("manual changes keep an in-guild acting main", function()
    local state = setup()
    -- Visitor left; Hammer joins Visitor's now in-guild-less player.
    state.scan({
        { "Toolbox-Area52", "@TheTool", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 60 },
    })
    test.assertTrue(state.partition:GetCharacter("visitor-area52").departed ~= nil)

    test.assertTrue(state.service:SetMainPlayer("hammer-area52", state.playerIdOf("visitor-area52")))

    local player = state.playerOf("visitor-area52")
    test.assertEqual("hammer-area52", player.main)
    test.assertEqual("Visitor-Area52", player.history[1].name)
end)

test.test("manual changes settle the matching pending note conflicts", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "@Toolman", 80 },
        { "Hammer-Area52", ">Visitor", 70 },
        { "Wrench-Area52", ">Toolbox", 60 },
        { "Visitor-Area52", "", 30 },
    })
    test.assertEqual(2, #state.partition:GetConflicts())

    state.service:SetMainPlayer("hammer-area52", state.playerIdOf("visitor-area52"))
    state.service:SetAlias("toolbox-area52", "Toolman")

    test.assertEqual(0, #state.partition:GetConflicts())
end)

test.test("lookups give a character's player, display names, and a player's characters", function()
    local state = setup()
    local id, player = state.service:PlayerOf("hammer-area52")

    test.assertEqual(state.playerIdOf("toolbox-area52"), id)
    test.assertEqual("toolbox-area52", player.main)
    test.assertEqual("Hammer", state.service:CharacterName("hammer-area52"))
    test.assertEqual("TheTool (Toolbox)", state.service:PlayerName(id))
    test.assertEqual("TheTool (Toolbox)", state.service:PlayerNameOf("wrench-area52"))
    test.assertEqual("Visitor", state.service:PlayerNameOf("visitor-area52"))
    local characters = state.service:CharactersOf(id)
    test.assertEqual("toolbox-area52", characters[1])
    test.assertEqual(3, #characters)
    test.assertEqual(nil, state.service:PlayerOf("nobody-area52"))
end)

test.test("the set-main picker searches players by alias or character name", function()
    local state = setup()

    local byAlias = state.service:SearchPlayers("thetool")
    test.assertEqual(1, #byAlias)
    test.assertEqual("TheTool (Toolbox)", byAlias[1].label)
    test.assertEqual(nil, byAlias[1].matched)

    local byAlt = state.service:SearchPlayers("WRENCH")
    test.assertEqual(1, #byAlt)
    test.assertEqual("Wrench", byAlt[1].matched)

    test.assertEqual(2, #state.service:SearchPlayers(""))
    test.assertEqual(0, #state.service:SearchPlayers("zzz"))
end)

test.test("the picker leaves out players with nobody in the guild", function()
    local state = setup()
    state.scan({
        { "Toolbox-Area52", "@TheTool", 80 },
        { "Hammer-Area52", ">Toolbox", 70 },
        { "Wrench-Area52", ">Toolbox", 60 },
    })

    test.assertEqual(0, #state.service:SearchPlayers("visitor"))
end)

-- Controller: the menu and immediate refresh -------------------------------

local function controllerSetup()
    local world = fixtures.newEnvironment("Retail")
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
        "Core/ScanScheduler.lua",
        "Core/RosterController.lua"
    )
    local client = addon.Compatibility.Create(world.environment)
    local database = { schemaVersion = 1, guilds = {} }
    local window = { shown = false, rows = {}, conflicts = {} }
    function window:IsShown() return self.shown end
    function window:Show() self.shown = true end
    function window:Hide() self.shown = false end
    function window:SetTitle() end
    function window:SetStatus() end
    function window:SetRows(rows) self.rows = rows return true end
    function window:SetConflicts(rows) self.conflicts = rows return true end
    local controller = addon.RosterController.Create({
        client = client,
        nameRules = client:GetClientProfile().nameRules,
        getDatabase = function() return database end,
        createWindow = function() return window end,
    })
    controller:OnSavedDataReady()
    controller:OnRosterUpdate()
    fixtures.runTimers(world)
    controller:Toggle()
    return controller, window, world
end

local function rowFor(window, name)
    local index
    for index = 1, #window.rows do
        if window.rows[index].name == name or window.rows[index].label == name then
            return window.rows[index]
        end
    end
    return nil
end

local function actions(entries)
    local found = {}
    local index
    for index = 1, #entries do
        found[entries[index].action] = true
    end
    return found
end

test.test("the right-click menu offers the actions that apply to the row", function()
    local controller, window = controllerSetup()

    local alt = actions(controller:MenuFor(rowFor(window, "Hammer")))
    test.assertTrue(alt.setMain and alt.makeMain and alt.alias and alt.detach)

    local main = actions(controller:MenuFor(rowFor(window, "Toolbox")))
    test.assertTrue(main.setMain and main.alias and main.detach)
    test.assertEqual(nil, main.makeMain)

    local single = actions(controller:MenuFor(rowFor(window, "Visitor-Stormrage")))
    test.assertTrue(single.setMain and single.alias)
    test.assertEqual(nil, single.detach)

    local header = controller:MenuFor(rowFor(window, "TheTool (Toolbox)"))
    test.assertEqual(1, #header)
    test.assertEqual("alias", header[1].action)
end)

test.test("organizing from the menu refreshes the roster at once without a scan", function()
    local controller, window, world = controllerSetup()
    local requests = world.rosterRequests

    test.assertTrue(controller:Detach(rowFor(window, "Hammer").key))

    test.assertEqual(requests, world.rosterRequests)
    local hammer = rowFor(window, "Hammer")
    test.assertTrue(hammer.standalone)
    test.assertTrue(controller:SetAlias(hammer.key, "Hammer Time"))
    test.assertEqual("Hammer Time (Hammer)", rowFor(window, "Hammer").label)
end)

test.test("a refused change is reported in chat", function()
    local controller, window, world = controllerSetup()

    test.assertFalse(controller:Detach(rowFor(window, "Visitor-Stormrage").key))

    test.assertContains(world.messages[#world.messages], "That change wasn't made: it is already its own player.")
end)
