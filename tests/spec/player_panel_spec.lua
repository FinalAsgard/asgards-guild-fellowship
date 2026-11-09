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
                classToken = entries[index][5],
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
        { "Toolbox-Area52", "@TheTool", 80, nil, "WARRIOR" },
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
        build = function(adStats, wrap, classColor)
            return addon.PlayerPanelViewModel.Build({
                partition = partition,
                playerId = playerId,
                members = members({ guild[1], guild[2] }),
                normalizer = normalizer,
                adStats = adStats,
                wrap = wrap,
                classColor = classColor,
                formatDate = function(timestamp)
                    return "day " .. (timestamp - START) / 86400
                end,
            })
        end,
    }
end

-- The Profile tab's rows of `kind`, or the Log tab's with `list` "logRows".
local function rowsOf(model, kind, list)
    local rows = model[list or "rows"]
    local found = {}
    local index
    for index = 1, #rows do
        if rows[index].kind == kind then
            table.insert(found, rows[index])
        end
    end
    return found
end

test.test("the panel shows the alias, acting main and alts, and the Log tab the history", function()
    local state = setup()

    local model = state.build()

    test.assertEqual("TheTool (Toolbox)", model.label)
    test.assertEqual("TheTool", model.alias)
    test.assertEqual("toolbox-area52", model.main)
    local characters = rowsOf(model, "character")
    test.assertEqual(2, #characters)
    test.assertTrue(characters[1].isMain)
    test.assertEqual("Toolbox", characters[1].name)
    test.assertEqual("Hammer", characters[2].name)
    test.assertEqual("Online, Dornogal", characters[2].status)
    test.assertEqual(0, #rowsOf(model, "history"), "history isn't on the Profile tab")
    local history = rowsOf(model, "history", "logRows")
    test.assertEqual(1, #history)
    -- Shown as the roster spells it, without the home realm.
    test.assertEqual("Wrench", history[1].name)
    test.assertEqual("Alt", history[1].role)
    test.assertEqual("left the guild, purged", history[1].reason)
    test.assertEqual("until day 1", history[1].dates)
end)

test.test("character rows carry the class for the name's color, and Discord moves to the header", function()
    local state = setup()
    state.partition:SetProfileText("toolbox-area52", "discord", "tool#1", 1, "toolbox-area52")

    local model = state.build(nil, nil, function(classToken)
        return classToken == "WARRIOR" and "ffc69b6d" or nil
    end)

    test.assertEqual("tool#1", model.discord)
    local characters = rowsOf(model, "character")
    test.assertEqual("ffc69b6d", characters[1].color)
    test.assertEqual(nil, characters[2].color, "no class known")
    test.assertEqual(0, #rowsOf(model, "about", "bioRows"), "only Discord was set, and it's in the header")
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

    test.assertEqual("No alts", rowsOf(model, "empty")[1].text)
    local logEmpties = rowsOf(model, "empty", "logRows")
    test.assertEqual("Nothing logged yet", logEmpties[1].text)
    test.assertEqual("No former characters", logEmpties[2].text)
    test.assertFalse(rowsOf(model, "character")[1].canDetach)
    test.assertTrue(model.canMerge)
end)

test.test("an out-of-guild main shows in history with its date", function()
    local state = setup()
    state.partition:AddHistory(state.playerId, { name = "Bigmain", role = "main", since = START + 2 * 86400,
        reason = "out of guild" })

    local history = rowsOf(state.build(), "history", "logRows")

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

-- `options.onDiscordChanged` as for the controller; `options.profile` the
-- client (Retail by default); `options.officer` makes the user, logged in
-- on the guild's first member, an officer.
local function controllerSetup(_, options)
    options = options or {}
    local world = fixtures.newEnvironment(options.profile or "Retail")
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
        onDiscordChanged = options.onDiscordChanged,
        onProfileTextChanged = options.onProfileTextChanged,
        isOfficer = function() return options.officer == true end,
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
    local partition = controller.current.partition
    test.assertEqual("manual", partition:GetPlayer(window.player.id).aliasSource)
    test.assertEqual("Tool Time (Toolbox)", window.rows[1].label)

    controller:MakeMain("hammer-area52")
    test.assertEqual("hammer-area52", window.player.main)

    controller:Detach("toolbox-area52")
    test.assertEqual("Tool Time (Hammer)", window.player.label)
    test.assertEqual("No alts", window.player.rows[4].text)
end)

test.test("the panel closes when its player is merged away", function()
    local controller, window = controllerSetup(nil, { officer = true })
    controller:SelectPlayerOf("visitor-stormrage")
    test.assertTrue(window.player ~= nil)

    local toolPlayer = controller.current.partition:GetCharacter("toolbox-area52").player
    controller:SetMainPlayer("visitor-stormrage", toolPlayer)

    test.assertEqual(nil, window.player)
end)

test.test("the panel stays open without the window, and follows changes", function()
    local controller, window = controllerSetup()
    controller:SelectPlayerOf("hammer-area52")

    controller:Toggle()
    test.assertFalse(window:IsShown())
    test.assertTrue(window.player ~= nil)

    local partition = controller.current.partition
    partition:SetAlias(partition:GetCharacter("toolbox-area52").player, "Tool Box", "manual")
    controller:Invalidate()
    test.assertEqual("Tool Box (Toolbox)", window.player.label)
end)

test.test("set discord: the panel carries the player's Discord to prefill the dialog", function()
    local controller, window = controllerSetup()
    controller.current.partition:SetProfileText("hammer-area52", "discord", "hammer#1", 1790000000, "hammer-area52")

    controller:SelectPlayerOf("hammer-area52")

    test.assertEqual("hammer#1", window.player.discord)
end)

test.test("set discord: the edit goes to guild sync and the panel redraws", function()
    local edits = {}
    local controller, window
    controller, window = controllerSetup(nil, {
        onDiscordChanged = function(key, text)
            table.insert(edits, { key = key, text = text })
            controller.current.partition:SetProfileText(key, "discord", text, 1790000000, "toolbox-area52")
            return { {} }
        end,
    })
    controller:SelectPlayerOf("hammer-area52")

    test.assertTrue(controller:SetDiscord(window.player.main, "tool#1"))

    test.assertEqual(1, #edits)
    test.assertEqual(window.player.main, edits[1].key)
    test.assertEqual("tool#1", window.player.discord)
end)

local profile
for _, profile in ipairs({ "Forever", "Retail" }) do
    -- The second and third members: an alt of the user's player, and
    -- someone else's.
    local alt = fixtures.GUILDS[profile].members[2].name
    local other = fixtures.GUILDS[profile].members[3].name

    test.test(profile .. ": a member may edit only their own player's alias and Discord from the panel", function()
        local edits = 0
        local controller, window, client = controllerSetup(nil, { profile = profile,
            onDiscordChanged = function()
                edits = edits + 1
                return { {} }
            end })
        local printed
        client.Print = function(_, message) printed = message end
        local _, partition, normalizer = controller:QuietContext()
        local otherKey = normalizer:Key(other)

        controller:SelectPlayerOf(normalizer:Key(alt))
        test.assertTrue(window.player.canEdit, "their own player")
        test.assertTrue(controller:SetDiscord(window.player.main, "tool#1"))
        test.assertEqual(1, edits)

        controller:SelectPlayerOf(otherKey)
        test.assertFalse(window.player.canEdit, "someone else's player")
        test.assertFalse(window.player.canMerge, "Merge into player... greyed out")
        local index
        for index = 1, #window.player.rows do
            local row = window.player.rows[index]
            if row.kind == "character" then
                test.assertFalse(row.canMakeMain == true or row.canDetach == true, "no Make main or Detach")
            end
        end
        test.assertFalse(controller:SetDiscord(otherKey, "spam#1"))
        test.assertFalse(controller:SetAlias(otherKey, "Spam"))
        test.assertEqual(1, edits, "nothing sent for someone else")
        test.assertEqual(nil, partition:GetPlayer(partition:GetCharacter(otherKey).player).alias)
        test.assertContains(printed, "members can only change their own player")
    end)

    test.test(profile .. ": an officer may edit any player's alias and Discord from the panel", function()
        local edits = 0
        local controller, window = controllerSetup(nil, { profile = profile, officer = true,
            onDiscordChanged = function()
                edits = edits + 1
                return { {} }
            end })
        local _, _, normalizer = controller:QuietContext()
        local otherKey = normalizer:Key(other)

        controller:SelectPlayerOf(otherKey)
        test.assertTrue(window.player.canEdit)
        test.assertTrue(controller:SetDiscord(otherKey, "visitor#1"))
        test.assertTrue(controller:SetAlias(otherKey, "Visi"))
        test.assertEqual(1, edits)
    end)

    test.test(profile .. ": the Bio tab's location and bio are editable for their own player, or by an officer",
        function()
        local sent = {}
        local function record(key, kind, text)
            table.insert(sent, kind .. "=" .. text)
            return { {} }
        end
        local controller, window, client = controllerSetup(nil, { profile = profile,
            onProfileTextChanged = record })
        local printed
        client.Print = function(_, message) printed = message end
        local _, _, normalizer = controller:QuietContext()
        local otherKey = normalizer:Key(other)

        controller:SelectPlayerOf(normalizer:Key(alt))
        test.assertEqual("location", window.player.bioRows[1].field)
        test.assertTrue(controller:SetProfileText(window.player.main, "location", "Ohio"))
        test.assertTrue(controller:SetProfileText(window.player.main, "bio", "Healer"))
        test.assertFalse(controller:SetProfileText(otherKey, "bio", "Spam"))
        test.assertEqual("location=Ohio,bio=Healer", table.concat(sent, ","))
        test.assertContains(printed, "That bio wasn't saved: members can only change their own player")

        local officer = controllerSetup(nil, { profile = profile, officer = true, onProfileTextChanged = record })
        test.assertTrue(officer:SetProfileText(otherKey, "bio", "Raider"))
        test.assertEqual("bio=Raider", sent[3])

        -- 251 accented letters fit 500 letters but not 500 bytes.
        test.assertFalse(controller:SetProfileText(window.player.main, "bio", string.rep("\195\169", 251)))
        test.assertContains(printed, "longer than 500 bytes")
        test.assertEqual(3, #sent, "nothing sent")
    end)
end

test.test("set discord: an edit that couldn't be saved is reported", function()
    local controller, _, client = controllerSetup(nil, {
        onDiscordChanged = function() return nil end,
    })
    local printed
    client.Print = function(_, message) printed = message end

    test.assertFalse(controller:SetDiscord("hammer-area52", "tool#1"))

    test.assertTrue(string.find(printed, "wasn't saved", 1, true) ~= nil)
end)

test.test("dates are formatted by the client", function()
    local _, _, client = controllerSetup()

    test.assertEqual("2026-09-21", client:FormatDate(1790000000))
    test.assertEqual("", client:FormatDate(nil))
end)

test.test("player panel: the ad record leads the Log tab, which says so when there's nothing, then History", function()
    local state = setup()
    local asked
    local model = state.build(function(keys)
        asked = keys
        return "Advertised: 12 (3 in last 30 days)"
    end)

    test.assertEqual("log", model.logRows[1].kind)
    test.assertEqual("Advertised: 12 (3 in last 30 days)", model.logRows[1].text)
    test.assertEqual("section", model.rows[1].kind, "nothing logged on the Profile tab")
    -- Every one of the player's characters is asked about.
    test.assertEqual(2, #asked)

    -- Nothing logged: the note, then the History section.
    local function onlyEmpty(built)
        return built.logRows[1].kind == "empty" and built.logRows[1].text == "Nothing logged yet"
            and built.logRows[2].kind == "section" and built.logRows[2].text == "History"
    end
    test.assertTrue(onlyEmpty(state.build(function()
        return nil
    end)))
    test.assertTrue(onlyEmpty(state.build()))
    test.assertTrue(onlyEmpty(state.build(function() error("boom") end)))
end)

test.test("player panel: long Log lines wrap instead of being cut off", function()
    local state = setup()
    local long = "Advertised: 12 (3 in last 30 days) in Trade, General and every city channel there is"

    local model = state.build(function()
        return long
    end)

    local lines = rowsOf(model, "log", "logRows")
    test.assertTrue(#lines > 1)
    local index
    for index = 1, #lines do
        test.assertTrue(#lines[index].text <= state.addon.PlayerPanelViewModel.BIO_LINE)
    end
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

    local about = rowsOf(model, "about", "bioRows")
    test.assertEqual("[Raid lead on weekends]", about[1].text)

    -- The location is wrapped too.
    state.partition:SetProfileText("toolbox-area52", "location", "Stormwind", START, "toolbox-area52")
    about = rowsOf(state.build(nil, function(text)
        return { "[" .. text .. "]" }
    end), "about", "bioRows")
    test.assertEqual("[Stormwind]", about[1].text)
    test.assertEqual("[Raid lead on weekends]", about[2].text)
end)

test.test("the Bio tab shows Location and Bio headings, each Not set until the player sets it", function()
    local state = setup()

    local model = state.build()
    local function texts(rows)
        local found = {}
        local index
        for index = 1, #rows do
            table.insert(found, rows[index].kind .. ":" .. rows[index].text .. ":" .. tostring(rows[index].field))
        end
        return table.concat(found, "|")
    end
    test.assertEqual("section:Location:location|empty:Not set:nil|section:Bio:bio|empty:Not set:nil",
        texts(model.bioRows))
    test.assertEqual(nil, model.location)
    test.assertEqual(nil, model.bio)
    test.assertEqual(0, #rowsOf(model, "about"), "the Profile tab has no About section")

    state.partition:SetProfileText("toolbox-area52", "location", "Stormwind", START, "toolbox-area52")
    state.partition:SetProfileText("toolbox-area52", "bio", "Tank", START, "toolbox-area52")
    model = state.build()
    test.assertEqual("section:Location:location|about:Stormwind:nil|section:Bio:bio|about:Tank:nil",
        texts(model.bioRows))
    test.assertEqual("Stormwind", model.location)
    test.assertEqual("Tank", model.bio)

    -- Cleared reads as not set.
    state.partition:SetProfileText("toolbox-area52", "location", "", START + 1, "toolbox-area52")
    model = state.build()
    test.assertEqual(nil, model.location)
    test.assertEqual("empty", model.bioRows[2].kind)
end)

test.test("promotion rows go to the panel's Promotion tab, not the profile list", function()
    local context = setup()
    local promotion = { { kind = "promotion", key = "toolbox-area52", text = "Toolbox: Member", toggle = true } }
    local normalizer = context.addon.NameNormalizer.Create(RULES)
    local model = context.addon.PlayerPanelViewModel.Build({
        partition = context.partition,
        playerId = context.playerId,
        normalizer = normalizer,
        promotion = function()
            return promotion
        end,
    })
    test.assertEqual(promotion, model.promotionRows)
    local index
    for index = 1, #model.rows do
        test.assertTrue(model.rows[index].kind ~= "promotion")
    end
    model = context.addon.PlayerPanelViewModel.Build({ partition = context.partition, playerId = context.playerId,
        normalizer = normalizer })
    test.assertEqual(nil, model.promotionRows, "no tab without promotion rows")
end)
