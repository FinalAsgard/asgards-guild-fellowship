local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000
local DEADMINES = { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 }

local function load()
    return test.newAddon("Core/FellowshipStore.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Core/GroupFinderProtocol.lua", "Core/JoinRequests.lua")
end

local function member(key, classToken, fields)
    local made = { key = key, name = key, classToken = classToken, inGuild = true }
    local name, value
    for name, value in pairs(fields or {}) do
        made[name] = value
    end
    return made
end

-- The protocol -------------------------------------------------------------------

test.test("competing requests protocol: slots, withdraw and joined-elsewhere are checked", function()
    local protocol = load().GroupFinderProtocol

    test.assertTrue(protocol.IsValid(protocol.Slots("hammer", "1-1", { "dps" })))
    test.assertFalse(protocol.IsValid(protocol.Slots("hammer", "1-1", {})))
    test.assertTrue(protocol.IsValid(protocol.Withdraw("hammer", "1-1")))
    test.assertTrue(protocol.IsValid(protocol.JoinedElsewhere("toolbox", "1-1")))
    local nothingLeft = protocol.Answer("toolbox", "1-1", nil, true)
    test.assertTrue(protocol.IsValid(nothingLeft))
    test.assertTrue(nothingLeft.w)
    -- "Nothing left" only goes with a decline.
    test.assertFalse(protocol.IsValid({ v = 1, t = "gf-answer", to = "toolbox", id = "1-1", ok = true, w = true,
        role = "dps", c = "hammer", n = "Hammer", l = 20 }))
end)

-- The organizer's side ---------------------------------------------------------

local HAMMER = { playerId = 2, key = "hammer", label = "Hammer" }
local ANVIL = { playerId = 3, key = "anvil", label = "Anvil" }

test.test("group session: a filled slot sends pending requests the roles still open", function()
    local addon = load()
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    local party = { member("Me", "WARRIOR", { isPlayer = true }) }
    session:UpdateParty(party, false)
    local hammer = session:Request(HAMMER, NOW)
    test.assertEqual("healer,dps", table.concat(hammer.roles, ","))
    local updates = session:SlotChanges()
    test.assertEqual(0, #updates)

    table.insert(party, member("Cleric", "PRIEST"))
    session:UpdateParty(party, true)
    updates = session:SlotChanges()

    test.assertEqual(1, #updates)
    test.assertEqual(hammer, updates[1])
    test.assertEqual("dps", table.concat(hammer.roles, ","))
    -- Nothing new the second time.
    test.assertEqual(0, #session:SlotChanges())
end)

test.test("group session: a request with nothing left to fill is withdrawn", function()
    local addon = load()
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    session:UpdateParty({ member("Me", "WARRIOR", { isPlayer = true }) }, false)
    local hammer = session:Request(HAMMER, NOW)

    session:UpdateParty({
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Cleric", "PRIEST"),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
        member("Shot", "HUNTER"),
    }, true)
    local updates, withdrawals = session:SlotChanges()

    test.assertEqual(0, #updates)
    test.assertEqual(hammer, withdrawals[1])
    test.assertEqual("withdrawn", hammer.state)
end)

test.test("group session: an invitee with no option left shows as withdrawn; one who went elsewhere too", function()
    local addon = load()
    local session = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    session:Start("dm")
    local hammer = session:Request(HAMMER, NOW)
    local anvil = session:Request(ANVIL, NOW)

    test.assertEqual("withdrawn", session:Answer(hammer.id, "hammer", nil, true))
    test.assertFalse(session:JoinedElsewhere(anvil.id, "hammer"))
    test.assertTrue(session:JoinedElsewhere(anvil.id, "anvil"))
    test.assertEqual("joined-elsewhere", anvil.state)
end)

-- The invitee's side ------------------------------------------------------------

local function newInvitee()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter("hammer", { name = "Hammer", classToken = "PALADIN", level = 24 })
    partition:RecordCharacter("bolt", { name = "Bolt", classToken = "SHAMAN", level = 22 })
    partition:JoinPlayerOf("bolt", "hammer", "manual")
    local world = { addon = addon, partition = partition }
    world.requests = addon.JoinRequests.Create({
        partition = function() return partition end,
        roles = addon.RoleCatalog.For("forever"),
        selfKey = function() return "hammer" end,
    })
    world.protocol = addon.GroupFinderProtocol
    return world
end

local function optionLabels(prompt)
    local labels = {}
    local index
    for index = 1, #prompt.options do
        labels[index] = prompt.options[index].role .. ":" .. prompt.options[index].name
    end
    return table.concat(labels, ", ")
end

test.test("join requests: a slot update drops the options for roles that filled", function()
    local world = newInvitee()
    world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES, { "tank", "healer", "dps" }),
        "toolbox", "Toolbox", NOW)

    test.assertEqual("updated", world.requests:OnSlots("1-1", "toolbox", { "dps" }))

    test.assertEqual("dps:Bolt, dps:Hammer", optionLabels(world.requests:Pending()[1]))
    -- Only the organizer that sent the request can change it.
    test.assertEqual(nil, world.requests:OnSlots("1-1", "wrench", { "tank" }))
end)

test.test("join requests: a prompt with no option left closes", function()
    local world = newInvitee()
    world.partition:SetRoles("hammer", { "healer" }, NOW, "hammer")
    world.partition:SetRoles("bolt", { "healer" }, NOW, "bolt")
    world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES, { "healer", "dps" }),
        "toolbox", "Toolbox", NOW)

    test.assertEqual("closed", world.requests:OnSlots("1-1", "toolbox", { "dps" }))
    test.assertEqual(0, #world.requests:Pending())
end)

test.test("join requests: requests from two organizers stack, and accepting one declines the other", function()
    local world = newInvitee()
    world.requests:OnRequest(world.protocol.Request("hammer", "1-1", DEADMINES, { "healer" }), "toolbox", "Toolbox", NOW)
    world.requests:OnRequest(world.protocol.Request("hammer", "2-1", DEADMINES, { "dps" }), "wrench", "Wrench", NOW)
    test.assertEqual(2, #world.requests:Pending())

    local prompt, option, others = world.requests:Accept("2-1", 1)

    test.assertEqual("wrench", prompt.organizer)
    test.assertEqual("dps", option.role)
    test.assertEqual(1, #others)
    test.assertEqual("toolbox", others[1].organizer)
    test.assertEqual(0, #world.requests:Pending())
end)

-- Organizers and invitees in the composed add-on -----------------------------------

local TEST_DUNGEON = { id = "test", name = "Test Dungeon", minLevel = 60, maxLevel = 80 }

local function guild()
    local function m(name, class)
        return { name = name, class = class, level = 70, rank = 3, rankName = "Member", online = true, zone = "Dornogal" }
    end
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            m("Toolbox-Area52", "WARRIOR"),
            m("Hammer-Area52", "PALADIN"),
            m("Wrench-Area52", "MAGE"),
            m("Anvil-Area52", "PRIEST"),
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Retail", { guild = guild(), playerName = playerName })
    fixtures.joinChannel(channel, world)
    local addon = fixtures.loadAddon(world)
    world.window = { open = false }
    function world.window:Toggle()
        self.open = not self.open
        return self.open
    end
    function world.window:Refresh() end
    function world.window:Picked() return TEST_DUNGEON end
    addon.GroupFinderWindow.Create = function(_, options)
        world.window.options = options
        return world.window
    end
    world.shown = {}
    addon.joinPrompts.Show = function(_, prompts, handlers)
        world.shown = prompts
        world.handlers = handlers
        return true
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

local function startGroup(organizer)
    fixtures.slash(organizer, "group")
    organizer.addon.groupSession:Start("test")
end

local function request(organizer, key, name)
    organizer.window.options.request({ id = key, label = name, current = { key = key, name = name } })
end

local function partitionOf(world)
    local _, partition = world.addon.rosterController:QuietContext()
    return partition
end

test.test("composed: when a slot fills, the other invitee's prompt drops it, or closes and shows withdrawn", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    local anvil = login(channel, "Anvil-Area52")
    fixtures.deliver(channel)
    -- Hammer only heals.
    partitionOf(hammer):SetRoles("hammer-area52", { "healer" }, NOW, "hammer-area52")
    startGroup(organizer)
    request(organizer, "hammer-area52", "Hammer")
    request(organizer, "anvil-area52", "Anvil")
    fixtures.deliver(channel)
    test.assertEqual(1, #hammer.shown)
    test.assertEqual(1, #hammer.shown[1].options)

    -- Anvil takes the healer slot (a priest's options: healer, then DPS).
    anvil.handlers.accept(anvil.shown[1].id, 1)
    fixtures.deliver(channel)

    local requests = organizer.addon.groupSession:Requests()
    test.assertEqual("accepted", requests[2].state)
    -- Healing was all Hammer offered, so the prompt closed and the
    -- organizer sees the request withdrawn.
    test.assertEqual(0, #hammer.shown)
    test.assertEqual("withdrawn", requests[1].state)
end)

test.test("composed: an invitee asked by two organizers sees both; accepting one tells the other", function()
    local channel = fixtures.newChannel()
    local toolbox = login(channel, "Toolbox-Area52")
    local wrench = login(channel, "Wrench-Area52")
    local hammer = login(channel, "Hammer-Area52")
    fixtures.deliver(channel)
    startGroup(toolbox)
    startGroup(wrench)
    request(toolbox, "hammer-area52", "Hammer")
    request(wrench, "hammer-area52", "Hammer")
    fixtures.deliver(channel)
    test.assertEqual(2, #hammer.shown)

    local fromWrench = hammer.shown[1].organizer == "wrench-area52" and hammer.shown[1] or hammer.shown[2]
    hammer.handlers.accept(fromWrench.id, 1)
    fixtures.deliver(channel)

    test.assertEqual(0, #hammer.shown)
    test.assertEqual("accepted", wrench.addon.groupSession:Requests()[1].state)
    test.assertEqual("joined-elsewhere", toolbox.addon.groupSession:Requests()[1].state)
end)

test.test("the window says joined another group", function()
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/GroupCandidates.lua", "Adapters/GroupFinderWindow.lua")
    local items = addon.GroupFinderWindow.SuggestionItems({
        { role = "dps", players = {
            { id = 2, label = "Hammer", addon = true, current = { name = "Hammer" }, fitting = { { name = "Hammer", level = 70 } } },
        } },
    }, function()
        return { state = "joined-elsewhere" }
    end)

    test.assertContains(items[2].text, "[joined another group]")
end)
