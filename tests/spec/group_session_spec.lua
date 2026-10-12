local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local function newModules()
    return test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua")
end

-- RoleCatalog ---------------------------------------------------------------

test.test("role catalog: WoW Forever has the Classic nine classes and their roles", function()
    local roles = newModules().RoleCatalog.For("forever")

    test.assertEqual("tank,dps", table.concat(roles:RolesFor("WARRIOR"), ","))
    test.assertEqual("tank,healer,dps", table.concat(roles:RolesFor("PALADIN"), ","))
    test.assertEqual("healer,dps", table.concat(roles:RolesFor("PRIEST"), ","))
    test.assertEqual("dps", table.concat(roles:RolesFor("MAGE"), ","))
    test.assertTrue(roles:Can("DRUID", "healer"))
    test.assertFalse(roles:Can("ROGUE", "tank"))
    -- Retail's newer classes aren't on Forever.
    test.assertEqual(0, #roles:RolesFor("DEATHKNIGHT"))
    test.assertFalse(roles:Can("MONK", "healer"))
end)

test.test("role catalog: WoW Retail has every Retail class", function()
    local roles = newModules().RoleCatalog.For("retail")

    test.assertEqual("tank,dps", table.concat(roles:RolesFor("DEATHKNIGHT"), ","))
    test.assertEqual("tank,healer,dps", table.concat(roles:RolesFor("MONK"), ","))
    test.assertEqual("tank,dps", table.concat(roles:RolesFor("DEMONHUNTER"), ","))
    test.assertEqual("healer,dps", table.concat(roles:RolesFor("EVOKER"), ","))
    test.assertEqual("tank,dps", table.concat(roles:RolesFor("WARRIOR"), ","))
    -- An unknown class or client can fill nothing.
    test.assertEqual(0, #roles:RolesFor("BARD"))
    test.assertFalse(newModules().RoleCatalog.For("other"):Can("WARRIOR", "tank"))
end)

-- GroupSession --------------------------------------------------------------

local function member(key, classToken, fields)
    local made = { key = key, name = key, classToken = classToken, inGuild = true }
    local name, value
    for name, value in pairs(fields or {}) do
        made[name] = value
    end
    return made
end

local function newSession(clientId)
    local addon = newModules()
    return addon.GroupSession.Create(addon.RoleCatalog.For(clientId or "forever"))
end

-- Each slot as "id=key" (or "id=" when open).
local function layout(session)
    local parts = {}
    local slots = session:Slots()
    local index
    for index = 1, #slots do
        table.insert(parts, slots[index].id .. "=" .. (slots[index].member and slots[index].member.key or ""))
    end
    return table.concat(parts, " ")
end

test.test("group session: a new group has 1 tank, 1 healer and 3 DPS slots, all open", function()
    local session = newSession()

    test.assertFalse(session:IsActive())
    test.assertTrue(session:Start("dm"))
    test.assertTrue(session:IsActive())
    test.assertEqual("dm", session:Dungeon())
    test.assertEqual("tank= healer= dps1= dps2= dps3=", layout(session))
    local slots = session:Slots()
    test.assertEqual("tank", slots[1].role)
    test.assertEqual("healer", slots[2].role)
    test.assertEqual("dps", slots[5].role)
    test.assertFalse(session:IsComplete())
end)

test.test("group session: party members take the role the game assigned them", function()
    local session = newSession("retail")
    session:Start("dm")

    session:UpdateParty({
        member("Me", "PALADIN", { isPlayer = true, assignedRole = "healer" }),
        member("Wall", "DRUID", { assignedRole = "tank" }),
        member("Zap", "MAGE", { assignedRole = "dps" }),
    }, true)

    test.assertEqual("tank=Wall healer=Me dps1=Zap dps2= dps3=", layout(session))
    test.assertEqual("accepted", session:Slots()[1].state)
end)

test.test("group session: without assigned roles, members default from class to the first open role", function()
    local session = newSession()
    session:Start("dm")

    session:UpdateParty({
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Cleric", "PRIEST"),
        member("Zap", "MAGE"),
        member("Shield", "WARRIOR"),
    }, true)

    -- The second warrior finds the tank slot taken, so goes DPS.
    test.assertEqual("tank=Me healer=Cleric dps1=Zap dps2=Shield dps3=", layout(session))
end)

test.test("group session: the organizer picks their own role and assigns party members", function()
    local session = newSession()
    session:Start("dm")
    local party = {
        member("Me", "PALADIN", { isPlayer = true }),
        member("Bear", "DRUID"),
    }
    session:UpdateParty(party, true)
    test.assertEqual("tank=Me healer=Bear dps1= dps2= dps3=", layout(session))

    test.assertTrue(session:Assign("Me", "healer"))
    test.assertTrue(session:Assign("Bear", "tank"))

    test.assertEqual("tank=Bear healer=Me dps1= dps2= dps3=", layout(session))
    test.assertFalse(session:Assign("Bear", "bard"))
    -- Assignments hold as the party changes.
    table.insert(party, member("Zap", "MAGE"))
    session:UpdateParty(party, true)
    test.assertEqual("tank=Bear healer=Me dps1=Zap dps2= dps3=", layout(session))
end)

test.test("group session: chosen roles win over defaults", function()
    local session = newSession("retail")
    session:Start("dm")

    -- The warrior comes first but has no role; the paladin was assigned tank.
    session:UpdateParty({
        member("Shield", "WARRIOR"),
        member("Holy", "PALADIN", { assignedRole = "tank" }),
    }, true)

    test.assertEqual("tank=Holy healer= dps1=Shield dps2= dps3=", layout(session))
end)

test.test("group session: party members outside the guild take slots too", function()
    local session = newSession()
    session:Start("dm")

    session:UpdateParty({
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Stranger", "PRIEST", { inGuild = false }),
    }, true)

    local healer = session:Slots()[2].member
    test.assertEqual("Stranger", healer.key)
    test.assertFalse(healer.inGuild)
end)

test.test("group session: a member with no slot left is listed as unplaced", function()
    local session = newSession()
    session:Start("dm")

    session:UpdateParty({
        member("Me", "PRIEST", { isPlayer = true, assignedRole = nil }),
        member("Cleric", "PRIEST"),
    }, true)
    session:Assign("Cleric", "healer")
    session:Assign("Me", "healer")

    test.assertEqual("healer=Me", "healer=" .. session:Slots()[2].member.key)
    test.assertEqual("Cleric", session:Unplaced()[1].key)
end)

test.test("group session: Group complete once all five slots are filled", function()
    local session = newSession()
    session:Start("dm")
    local party = {
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Cleric", "PRIEST"),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
    }
    session:UpdateParty(party, true)
    test.assertFalse(session:IsComplete())

    table.insert(party, member("Shot", "HUNTER"))
    session:UpdateParty(party, true)

    test.assertTrue(session:IsComplete())
end)

test.test("group session: changing the dungeon keeps every filled slot", function()
    local session = newSession()
    session:Start("dm")
    session:UpdateParty({ member("Me", "WARRIOR", { isPlayer = true }) }, false)

    test.assertTrue(session:SetDungeon("sfk"))
    -- Starting again while a group is going also just changes the dungeon.
    test.assertTrue(session:Start("wc"))

    test.assertEqual("wc", session:Dungeon())
    test.assertEqual("tank=Me healer= dps1= dps2= dps3=", layout(session))
end)

test.test("group session: End group, or leaving the party, ends it", function()
    local session = newSession()
    session:Start("dm")
    session:End()
    test.assertFalse(session:IsActive())
    test.assertEqual(nil, session:Dungeon())
    test.assertFalse(session:SetDungeon("dm"))

    -- Solo at the start isn't leaving: the organizer hasn't had a party yet.
    session:Start("dm")
    test.assertTrue(session:UpdateParty({ member("Me", "WARRIOR", { isPlayer = true }) }, false))
    test.assertTrue(session:IsActive())
    session:UpdateParty({ member("Me", "WARRIOR", { isPlayer = true }), member("Cleric", "PRIEST") }, true)

    test.assertFalse(session:UpdateParty({ member("Me", "WARRIOR", { isPlayer = true }) }, false))

    test.assertFalse(session:IsActive())
    test.assertEqual("tank= healer= dps1= dps2= dps3=", layout(session))
    -- A new group starts fresh.
    session:Start("sfk")
    test.assertEqual("tank= healer= dps1= dps2= dps3=", layout(session))
end)

-- The WoW adapter's party additions -----------------------------------------

local function newClient(world)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(world.environment)
end

-- Unit APIs for `units` (unit -> { name, guid, class, level, role, guild }).
local function installParty(environment, units, grouped)
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit) return units[unit] and units[unit].name end
    environment.UnitGUID = function(unit) return units[unit] and units[unit].guid end
    environment.UnitClass = function(unit)
        if units[unit] == nil then
            return nil
        end
        return "Localized", units[unit].class, 1
    end
    environment.UnitLevel = function(unit) return units[unit] and units[unit].level end
    environment.UnitIsInMyGuild = function(unit) return units[unit] and units[unit].guild end
    environment.IsInGroup = function() return grouped end
end

test.test("Retail adapter reads the party with the game's assigned roles", function()
    local world = fixtures.newEnvironment("Retail")
    installParty(world.environment, {
        player = { name = "Toolbox", guid = "Player-1", class = "WARRIOR", level = 80, guild = true },
        party1 = { name = "Hammer", guid = "Player-2", class = "PALADIN", level = 79, guild = true },
        party2 = { name = "Visitor", guid = "Player-3", class = "MAGE", level = 80, guild = false },
    }, true)
    local roles = { player = "TANK", party1 = "HEALER", party2 = "DAMAGER" }
    world.environment.UnitGroupRolesAssigned = function(unit) return roles[unit] end
    local client = newClient(world)

    local members = client:GetPartyMembers()

    test.assertTrue(client:IsInGroup())
    test.assertEqual(3, #members)
    test.assertEqual("Player-1", members[1].key)
    test.assertTrue(members[1].isPlayer)
    test.assertEqual("tank", members[1].assignedRole)
    test.assertEqual("Hammer", members[2].name)
    test.assertEqual("PALADIN", members[2].classToken)
    test.assertEqual(79, members[2].level)
    test.assertEqual("healer", members[2].assignedRole)
    test.assertTrue(members[2].inGuild)
    test.assertEqual("dps", members[3].assignedRole)
    test.assertFalse(members[3].inGuild)

    -- "NONE" is no role.
    roles.party1 = "NONE"
    test.assertEqual(nil, client:GetPartyMembers()[2].assignedRole)
end)

test.test("Forever adapter reads the party without assigned roles", function()
    local world = fixtures.newEnvironment("Forever")
    installParty(world.environment, {
        player = { name = "Tool", guid = "Player-1", class = "WARRIOR", level = 60, guild = true },
        party1 = { name = "Hammer", guid = "Player-2", class = "PALADIN", level = 42, guild = true },
    }, nil)
    world.environment.IsInGroup = nil
    world.environment.GetNumPartyMembers = function() return 1 end
    local client = newClient(world)

    local members = client:GetPartyMembers()

    test.assertTrue(client:IsInGroup())
    test.assertEqual(2, #members)
    test.assertEqual(nil, members[1].assignedRole)
    test.assertEqual(nil, members[2].assignedRole)

    world.environment.GetNumPartyMembers = function() return 0 end
    test.assertFalse(client:IsInGroup())
end)

test.test("adapter reports party changes", function()
    local world = fixtures.newEnvironment("Retail")
    local client = newClient(world)
    local changes = 0

    test.assertTrue(client:ObserveParty(function()
        changes = changes + 1
    end))
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
    fixtures.fire(world, "PLAYER_ROLES_ASSIGNED")

    test.assertEqual(2, changes)
end)

-- The window's slots, drawn with fake frames ----------------------------------

local SAMPLE = {
    { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 },
    { id = "sfk", name = "Shadowfang Keep", minLevel = 22, maxLevel = 30 },
}

local function newScreen()
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local framework = { FrameWorkVersion = "746" }
    function framework:CreateSimplePanel(_, _, _, title, name)
        local panel = environment.CreateFrame("Frame", name, nil)
        rawset(panel, "title", title)
        rawset(panel, "IsShown", function(self) return self.shown end)
        return panel
    end
    environment.DetailsFramework = framework
    return environment
end

local function newWindow(party, inGroup)
    local addon = test.newAddon("Core/DungeonCatalog.lua", "Core/RoleCatalog.lua", "Core/GroupSession.lua",
        "Adapters/GroupFinderWindow.lua")
    local environment = newScreen()
    local world = { party = party, inGroup = inGroup }
    local roles = addon.RoleCatalog.For("forever")
    world.session = addon.GroupSession.Create(roles)
    world.window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, {
        dungeons = function() return addon.DungeonCatalog.Create(SAMPLE) end,
        playerLevel = function() return 20 end,
        session = world.session,
        roles = roles,
        syncParty = function()
            if world.session:IsActive() then
                world.session:UpdateParty(world.party, world.inGroup)
            end
        end,
    })
    world.window:Toggle()
    return world
end

local function slotTexts(window)
    local texts = {}
    local index
    for index = 1, #window.slotRows do
        table.insert(texts, window.slotRows[index].text.text)
    end
    return table.concat(texts, " | ")
end

test.test("group finder window: picking a dungeon shows the slots filled from the party", function()
    local world = newWindow({
        member("Me", "WARRIOR", { isPlayer = true, level = 20 }),
        member("Stranger", "PRIEST", { inGuild = false, level = 21 }),
    }, true)
    local window = world.window
    test.assertTrue(window.picker.shown)
    test.assertFalse(window.group.shown)

    window:Pick("dm")

    test.assertFalse(window.picker.shown)
    test.assertTrue(window.group.shown)
    test.assertEqual("Dungeon: The Deadmines (17–26)", window.dungeonText.text)
    test.assertEqual("Me (20) | Stranger (21, not in guild) | open | open | open", slotTexts(window))
    test.assertFalse(window.completeText.shown)
end)

test.test("group finder window: role buttons assign party members the game gave no role", function()
    local world = newWindow({
        member("Me", "PALADIN", { isPlayer = true }),
        member("Bear", "DRUID"),
        member("Zap", "MAGE"),
        member("Wall", "WARRIOR", { assignedRole = "tank" }),
    }, true)
    local window = world.window
    window:Pick("dm")

    -- Wall's role came from the game, so only three rows have buttons.
    test.assertTrue(window.partyRows[3].frame.shown)
    test.assertEqual(nil, window.partyRows[4])
    -- A mage can only be DPS.
    test.assertFalse(window.partyRows[3].buttons.tank.shown)
    test.assertTrue(window.partyRows[3].buttons.dps.shown)

    -- Bear heals, and the organizer goes DPS.
    window.partyRows[2].buttons.healer.scripts.OnClick()
    window.partyRows[1].buttons.dps.scripts.OnClick()

    test.assertEqual("Wall | Bear | Me | Zap | open", slotTexts(window))
end)

test.test("group finder window: Group complete shows once all five slots are filled", function()
    local world = newWindow({
        member("Me", "WARRIOR", { isPlayer = true }),
        member("Cleric", "PRIEST"),
        member("Zap", "MAGE"),
        member("Stab", "ROGUE"),
        member("Shot", "HUNTER"),
    }, true)

    world.window:Pick("dm")

    test.assertTrue(world.window.completeText.shown)
end)

test.test("group finder window: Change dungeon keeps the slots; End group goes back to the picker", function()
    local world = newWindow({ member("Me", "WARRIOR", { isPlayer = true }) }, false)
    local window = world.window
    window:Pick("dm")

    window.changeButton.scripts.OnClick()
    test.assertTrue(window.picker.shown)
    window:Pick("sfk")

    test.assertTrue(window.group.shown)
    test.assertEqual("Dungeon: Shadowfang Keep (22–30)", window.dungeonText.text)
    test.assertEqual("Me | open | open | open | open", slotTexts(window))

    -- Closing the window keeps the group.
    window:Toggle()
    test.assertTrue(world.session:IsActive())
    window:Toggle()
    test.assertTrue(window.group.shown)

    window.endButton.scripts.OnClick()
    test.assertFalse(world.session:IsActive())
    test.assertTrue(window.picker.shown)
    test.assertEqual("Pick a dungeon", window.dungeonText.text)
end)

-- The composed add-on ---------------------------------------------------------

test.test("Forever party changes refill the Group Finder's slots, and leaving the party ends it", function()
    local world = fixtures.newEnvironment("Forever")
    local units = {
        player = { name = "Tool", guid = "Player-1", class = "WARRIOR", level = 60, guild = true },
    }
    local grouped = false
    installParty(world.environment, units, false)
    world.environment.IsInGroup = function() return grouped end
    local addon = fixtures.loadAddon(world)
    local window = { refreshes = 0 }
    function window:Toggle() end
    function window:Refresh() self.refreshes = self.refreshes + 1 end
    addon.GroupFinderWindow.Create = function(_, options)
        window.options = options
        return window
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.slash(world, "group")
    local session = addon.groupSession
    session:Start("dm")
    window.options.syncParty()
    test.assertEqual("Player-1", session:Slots()[1].member.key)

    units.party1 = { name = "Cleric", guid = "Player-2", class = "PRIEST", level = 58, guild = false }
    grouped = true
    fixtures.fire(world, "PARTY_MEMBERS_CHANGED")

    test.assertEqual("Player-2", session:Slots()[2].member.key)
    test.assertEqual(1, window.refreshes)

    units.party1 = nil
    grouped = false
    fixtures.fire(world, "PARTY_MEMBERS_CHANGED")
    test.assertFalse(session:IsActive())
end)
