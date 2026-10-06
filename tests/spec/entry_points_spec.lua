local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua", "Adapters/EntryPoints.lua")
end

-- A frame that records what an entry point does with it.
local function fakeFrame(name)
    local frame = { name = name, scripts = {}, points = {} }
    function frame:SetText(text) self.text = text end
    function frame:SetWidth(width) self.width = width end
    function frame:SetHeight(height) self.height = height end
    function frame:GetHeight() return 22 end
    function frame:SetPoint(...) table.insert(self.points, { ... }) end
    function frame:SetScript(script, handler) self.scripts[script] = handler end
    function frame:GetParent() return self.parent end
    function frame:RegisterEvent(event) self.registered = (self.registered or {}) self.registered[event] = true end
    return frame
end

-- Fake LibDataBroker and LibDBIcon registered with the fixture's LibStub.
local function installMinimapLibraries(environment)
    local broker = { objects = {} }
    function broker:NewDataObject(name, object)
        self.objects[name] = object
        return object
    end
    local icon = { registered = {} }
    function icon:Register(name, object, state)
        self.registered[name] = { object = object, state = state }
    end
    environment.LibStub.libs["LibDataBroker-1.1"] = broker
    environment.LibStub.libs["LibDBIcon-1.0"] = icon
    return broker, icon
end

local function build(world, options)
    options = options or {}
    local addon = load()
    local client = addon.Compatibility.Create(world.environment)
    local toggles = { count = 0 }
    local state = options.minimapState
    local points = addon.EntryPoints.Create({
        client = client,
        toggle = function()
            toggles.count = toggles.count + 1
        end,
        conflictCount = function()
            return options.conflicts or 0
        end,
        minimapState = function()
            return state
        end,
    })
    return points, toggles, addon
end

-- Gives the world a guild window shaped like each client's: Retail's
-- Communities frame keeps Invite Member as a child, and the Forever guild
-- window is modelled the same way (the maintainer described an Invite Member
-- button on its first tab).
local function installGuildWindow(world)
    local communities = fakeFrame("CommunitiesFrame")
    communities.InviteButton = fakeFrame("InviteButton")
    communities.InviteButton.parent = communities
    world.environment.CommunitiesFrame = communities
    return communities
end

local function registerProfileTests(profile)
    test.test(profile .. " minimap button toggles the roster and shows the conflict count", function()
        local world = fixtures.newEnvironment(profile)
        local broker, icon = installMinimapLibraries(world.environment)
        local saved = { minimapPos = 200 }
        local points, toggles = build(world, { minimapState = saved, conflicts = 3 })

        test.assertTrue(points:StartMinimap())

        local name = "AsgardsGuildFellowship"
        local launcher = broker.objects[name]
        test.assertEqual("launcher", launcher.type)
        test.assertEqual(saved, icon.registered[name].state)
        launcher.OnClick()
        test.assertEqual(1, toggles.count)
        local lines = {}
        launcher.OnTooltipShow({ AddLine = function(_, text) table.insert(lines, text) end })
        test.assertEqual("Asgard's Guild Fellowship", lines[1])
        test.assertEqual("3 conflicts to review", lines[3])
    end)

    test.test(profile .. " guild window button sits left of Invite Member and opens the roster", function()
        local world = fixtures.newEnvironment(profile)
        local communities = installGuildWindow(world)
        local created
        world.environment.CreateFrame = function(_, name, parent)
            created = fakeFrame(name)
            created.parent = parent
            return created
        end
        local points, toggles = build(world)

        test.assertTrue(points:AttachGuildButton())

        test.assertEqual(communities, created.parent)
        test.assertEqual("Guild Fellowship", created.text)
        local point = created.points[1]
        test.assertEqual("RIGHT", point[1])
        test.assertEqual(communities.InviteButton, point[2])
        test.assertEqual("LEFT", point[3])
        created.scripts.OnClick()
        test.assertEqual(1, toggles.count)
        -- Attaching again doesn't create a second button.
        created = nil
        test.assertTrue(points:AttachGuildButton())
        test.assertEqual(nil, created)
    end)

    test.test(profile .. " without a guild window anchor the button is skipped without errors", function()
        local world = fixtures.newEnvironment(profile)
        local points = build(world)

        local ok, attached = pcall(points.AttachGuildButton, points)

        test.assertTrue(ok)
        test.assertFalse(attached)
    end)

    test.test(profile .. " the guild button is attached when the guild window loads later", function()
        local world = fixtures.newEnvironment(profile)
        local points = build(world)
        points:Start()
        test.assertEqual(nil, points.guildButton)

        -- Start() already made its event frame; from here on CreateFrame only
        -- builds the button.
        installGuildWindow(world)
        world.environment.CreateFrame = function(_, name, parent)
            local frame = fakeFrame(name)
            frame.parent = parent
            return frame
        end
        fixtures.fire(world, "ADDON_LOADED", "Blizzard_Communities")

        test.assertTrue(points.guildButton ~= nil)
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("missing LibDataBroker or LibDBIcon disables the minimap button without errors", function()
    local world = fixtures.newEnvironment("Retail")
    local points = build(world)

    local ok, started = pcall(points.StartMinimap, points)
    test.assertTrue(ok)
    test.assertFalse(started)

    local noStub = fixtures.newEnvironment("Retail", { libStub = false })
    local bare = build(noStub)
    ok, started = pcall(bare.StartMinimap, bare)
    test.assertTrue(ok)
    test.assertFalse(started)
end)

test.test("a library that raises disables the minimap button without errors", function()
    local world = fixtures.newEnvironment("Retail")
    local _, icon = installMinimapLibraries(world.environment)
    function icon:Register()
        error("LibDBIcon failed")
    end
    local points = build(world, { minimapState = {} })

    local ok, started = pcall(points.StartMinimap, points)

    test.assertTrue(ok)
    test.assertFalse(started)
end)

test.test("the add-on compartment entry toggles the roster where the client has one", function()
    local world = fixtures.newEnvironment("Retail")
    local entry
    world.environment.AddonCompartmentFrame = {
        RegisterAddon = function(_, info)
            entry = info
        end,
    }
    local points, toggles = build(world)

    test.assertTrue(points:StartCompartment())
    test.assertEqual("Asgard's Guild Fellowship", entry.text)
    entry.func()
    test.assertEqual(1, toggles.count)

    local forever = build(fixtures.newEnvironment("Forever"))
    test.assertFalse(forever:StartCompartment())
end)

test.test("older guild frames are used as an anchor when there is no Communities frame", function()
    local world = fixtures.newEnvironment("Forever")
    world.environment.GuildFrameAddMemberButton = fakeFrame("GuildFrameAddMemberButton")
    local points = build(world)

    test.assertEqual(world.environment.GuildFrameAddMemberButton, points:FindGuildAnchor())
end)

test.test("the minimap state is saved account-wide and an unusable value is left alone", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    local state = store:GetMinimapState()
    state.hide = true
    test.assertTrue(database.minimap.hide)

    database.minimap = "corrupt"
    test.assertEqual(nil, store:GetMinimapState())
    test.assertEqual("corrupt", database.minimap)
end)
