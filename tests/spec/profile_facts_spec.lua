local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Role preferences: the first player profile data, written only by the
-- character it describes and synced to the guild.
local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local RULES = { twoPartNames = false, homeRealm = "Area52" }
local NOW = 1790000000
local OFFICER = "toolbox-area52"
local MEMBER = "hammer-area52"

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua",
        "Core/SyncDigest.lua",
        "Core/SuggestionService.lua",
        "Core/SyncLedger.lua",
        "Core/SyncSession.lua",
        "Core/RoleCatalog.lua"
    )
end

local function newPartition(addon)
    local normalizer = addon.NameNormalizer.Create(RULES)
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter(OFFICER, { name = "Toolbox-Area52", classToken = "WARRIOR", level = 80 })
    partition:RecordCharacter(MEMBER, { name = "Hammer-Area52", classToken = "PALADIN", level = 70 })
    partition:RecordCharacter("wrench-area52", { name = "Wrench-Area52", classToken = "MAGE", level = 70 })
    partition:MarkScanned(NOW)
    return partition, normalizer
end

local function newFacts(addon, partition, now)
    return addon.SyncFacts.Create(partition, {
        isOfficer = function(key)
            return key == OFFICER
        end,
        now = function()
            return now or NOW
        end,
    })
end

local function roles(at, by, character, list)
    return { kind = "roles", character = character or by, roles = list or { "tank" }, at = at, by = by }
end

-- Store ---------------------------------------------------------------------

test.test("profile store: role preferences are kept on the character with their stamp", function()
    local addon = load()
    local partition = newPartition(addon)

    test.assertEqual(nil, partition:GetRoles(MEMBER))
    test.assertEqual(0, (partition:GetRolesStamp(MEMBER)))
    test.assertTrue(partition:SetRoles(MEMBER, { "tank", "dps" }, NOW, MEMBER))

    test.assertEqual("tank,dps", table.concat(partition:GetRoles(MEMBER), ","))
    local at, by = partition:GetRolesStamp(MEMBER)
    test.assertEqual(NOW, at)
    test.assertEqual(MEMBER, by)
    -- An empty list is "none", and still a choice.
    test.assertTrue(partition:SetRoles(MEMBER, {}, NOW + 1, MEMBER))
    test.assertEqual(0, #partition:GetRoles(MEMBER))
    test.assertFalse(partition:SetRoles(MEMBER, { "bard" }, NOW, MEMBER))
    test.assertFalse(partition:SetRoles(MEMBER, { "tank", "tank" }, NOW, MEMBER))
    test.assertFalse(partition:SetRoles("nobody-area52", { "tank" }, NOW, "nobody-area52"))
    test.assertEqual(nil, partition:GetRolesStamp("nobody-area52"))
end)

test.test("profile store: a character with unreadable role preferences is set aside intact", function()
    local addon = load()
    local database = {
        schemaVersion = 3,
        guilds = {
            ["Knights of Camelot-Area52"] = {
                characters = {
                    [MEMBER] = { player = 1, roles = { "bard" } },
                    [OFFICER] = { player = 2, roles = { "tank" }, rolesAt = NOW, rolesBy = OFFICER },
                },
                players = { [1] = { main = MEMBER }, [2] = { main = OFFICER } },
                nextPlayerId = 3,
            },
        },
    }

    local partition = addon.FellowshipStore.Create(database):Partition(GUILD)

    test.assertEqual(nil, partition:GetCharacter(MEMBER))
    test.assertEqual("tank", partition:GetRoles(OFFICER)[1])
    local quarantined = database.guilds["Knights of Camelot-Area52"].quarantine[1]
    test.assertEqual("character role preferences are invalid", quarantined.reason)
    test.assertEqual("bard", quarantined.record.roles[1])
end)

test.test("profile store: saved data from schema 2 migrates to schema 3 without losing anything", function()
    local partitionKey = "Knights of Camelot-Camelot"
    local database = {
        schemaVersion = 2,
        guilds = {
            [partitionKey] = {
                characters = {
                    ["tool box"] = { player = 1, name = "Tool Box", class = "WARRIOR", mainAt = 5, mainBy = "tool box" },
                },
                players = { [1] = { main = "tool box", alias = "TheTool", aliasAt = 6, aliasBy = "tool box" } },
                nextPlayerId = 2,
            },
        },
    }
    local before = fixtures.snapshot(database)
    local world = fixtures.newEnvironment("Forever", { database = database })
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")

    test.assertEqual(3, world.database.schemaVersion)
    local character = world.database.guilds[partitionKey].characters["tool box"]
    test.assertEqual("Tool Box", character.name)
    test.assertEqual(5, character.mainAt)
    test.assertEqual("TheTool", world.database.guilds[partitionKey].players[1].alias)
    test.assertEqual(before.guilds[partitionKey].players[1].aliasAt,
        world.database.guilds[partitionKey].players[1].aliasAt)
end)

-- RoleCatalog preferences -----------------------------------------------------

test.test("role preferences default to the class's roles until the character sets its own", function()
    local addon = load()
    local partition = newPartition(addon)
    local catalog = addon.RoleCatalog.For("retail")

    test.assertEqual("tank,healer,dps", table.concat(catalog:PreferencesOf(partition, MEMBER), ","))
    test.assertEqual("dps", table.concat(catalog:PreferencesOf(partition, "wrench-area52"), ","))
    partition:SetRoles(MEMBER, { "dps", "tank" }, NOW, MEMBER)
    test.assertEqual("tank,dps", table.concat(catalog:PreferencesOf(partition, MEMBER), ","))
    test.assertEqual(nil, catalog:PreferencesOf(partition, "nobody-area52"))
    test.assertEqual("Tank, DPS", addon.RoleCatalog.Describe({ "dps", "tank" }))
    test.assertEqual("None", addon.RoleCatalog.Describe({}))
end)

-- The profile fact rules --------------------------------------------------------

test.test("profile facts: a roles fact is accepted only from the character it describes", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)

    -- A member, not an officer, writes their own.
    test.assertEqual(nil, facts:Refusal(roles(NOW, MEMBER)))
    -- Nobody else may, officers included.
    test.assertEqual("not the character's own", facts:Refusal(roles(NOW, OFFICER, MEMBER)))
    test.assertEqual("not the character's own", facts:Refusal(roles(NOW, "wrench-area52", MEMBER)))
    test.assertEqual("malformed", facts:Refusal(roles(NOW, MEMBER, MEMBER, { "bard" })))
    test.assertEqual("malformed", facts:Refusal({ kind = "roles", character = MEMBER, at = NOW, by = MEMBER }))
    test.assertEqual("unknown character", facts:Refusal(roles(NOW, "nobody-area52")))
    test.assertEqual("from the future", facts:Refusal(roles(NOW + 3600, MEMBER)))

    test.assertEqual(1, facts:ApplyAll({ roles(NOW, MEMBER, MEMBER, { "healer" }), roles(NOW, OFFICER, MEMBER) }))
    test.assertEqual("healer", table.concat(partition:GetRoles(MEMBER), ","))
end)

test.test("profile facts: newer roles facts replace older ones", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)

    facts:ApplyAll({ roles(NOW - 10, MEMBER, MEMBER, { "healer" }) })
    test.assertEqual(0, facts:ApplyAll({ roles(NOW - 20, MEMBER, MEMBER, { "dps" }) }))
    test.assertEqual("not newer", facts:Refusal(roles(NOW - 10, MEMBER, MEMBER, { "dps" })))
    test.assertEqual(1, facts:ApplyAll({ roles(NOW - 5, MEMBER, MEMBER, { "tank", "dps" }) }))

    test.assertEqual("tank,dps", table.concat(partition:GetRoles(MEMBER), ","))
    test.assertEqual(NOW - 5, (partition:GetRolesStamp(MEMBER)))
end)

test.test("profile facts: Don't sync doesn't hold back a character's own role preferences", function()
    local addon = load()
    local partition = newPartition(addon)
    partition:SetNoSync(partition:GetCharacter(MEMBER).player, true)

    test.assertEqual(1, newFacts(addon, partition):ApplyAll({ roles(NOW, MEMBER) }))
end)

test.test("profile facts are part of the digest and catch-up, after officer facts", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)
    local before = addon.SyncDigest.Of(facts:SharedFacts())

    partition:SetRoles(MEMBER, { "healer" }, NOW, MEMBER)
    -- Stored roles someone else wrote (never accepted, but kept) aren't passed on.
    partition:SetRoles("wrench-area52", { "dps" }, NOW, OFFICER)
    partition:SetMainStamp(OFFICER, NOW, OFFICER)

    local shared = facts:SharedFacts()
    test.assertEqual(2, #shared)
    test.assertEqual("main", shared[1].kind)
    test.assertEqual("roles", shared[2].kind)
    test.assertEqual(MEMBER, shared[2].character)
    test.assertEqual("healer", shared[2].roles[1])
    test.assertEqual(1, #facts:ProfileFacts())

    local after = addon.SyncDigest.Of(shared)
    local changed = addon.SyncDigest.Differing(before, after)
    test.assertTrue(#changed >= 1)
    -- A different choice changes the digest too.
    partition:SetRoles(MEMBER, { "tank" }, NOW, MEMBER)
    test.assertTrue(#addon.SyncDigest.Differing(after, addon.SyncDigest.Of(facts:SharedFacts())) >= 1)
end)

-- Guild sync ------------------------------------------------------------------

-- Clients on one guild channel, all knowing the same characters. Without
-- timers, every message is worked on as soon as it's heard.
local function newNetwork()
    return { addon = load(), clients = {}, queue = {} }
end

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    local key, item
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

local function newClient(network, key, name)
    local addon = network.addon
    local partition, normalizer = newPartition(addon)
    local client = { key = key, name = name, partition = partition, sent = {}, forgeries = {}, time = NOW }
    local catalog = addon.RoleCatalog.For("retail")
    client.session = addon.SyncSession.Create({
        comm = {
            Broadcast = function(_, message)
                table.insert(client.sent, copy(message))
                table.insert(network.queue, { from = client, message = copy(message) })
                return true
            end,
        },
        context = function()
            return partition, normalizer
        end,
        selfKey = function()
            return client.key
        end,
        isOfficer = function(other)
            return other == OFFICER
        end,
        now = function()
            return client.time
        end,
        onForgery = function(count, relayedBy)
            table.insert(client.forgeries, { count = count, relayedBy = relayedBy })
        end,
        rolesOf = function(other)
            return catalog:PreferencesOf(partition, other)
        end,
    })
    table.insert(network.clients, client)
    return client
end

local function deliver(network)
    while network.queue[1] ~= nil do
        local entry = table.remove(network.queue, 1)
        local index
        for index = 1, #network.clients do
            local client = network.clients[index]
            if client ~= entry.from then
                client.session:Receive(entry.message, entry.from.name)
            end
        end
    end
end

test.test("guild sync: changing role preferences sends a roles fact that others apply", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local other = newClient(network, "wrench-area52", "Wrench-Area52")

    local fact = member.session:LocalRolesEdit({ "dps", "healer" })

    test.assertEqual("roles", fact.kind)
    test.assertEqual(MEMBER, fact.by)
    test.assertEqual("healer,dps", table.concat(member.partition:GetRoles(MEMBER), ","))
    test.assertEqual("facts", member.sent[1].t)
    test.assertEqual("healer,dps", table.concat(member.sent[1].facts[1].roles, ","))
    deliver(network)
    test.assertEqual("healer,dps", table.concat(other.partition:GetRoles(MEMBER), ","))

    -- A second change in the same second still wins everywhere.
    member.session:LocalRolesEdit({ "tank" })
    deliver(network)
    test.assertEqual("tank", table.concat(other.partition:GetRoles(MEMBER), ","))
    -- A member's own data is never a suggestion.
    test.assertEqual(0, #member.session:Suggestions(member.partition):Pending())
end)

test.test("guild sync: an offline character's role preferences reach a client through catch-up", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    member.session:LocalRolesEdit({ "healer" })
    -- That message never reached the latecomer.
    network.queue = {}
    local latecomer = newClient(network, "wrench-area52", "Wrench-Area52")

    latecomer.session:SendDigest()
    deliver(network)

    test.assertEqual("healer", table.concat(latecomer.partition:GetRoles(MEMBER), ","))
end)

test.test("guild sync: the owner's client corrects a forged roles fact in its name", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local bystander = newClient(network, "wrench-area52", "Wrench-Area52")
    local forger = newClient(network, OFFICER, "Toolbox-Area52")
    member.session:LocalRolesEdit({ "healer" })
    deliver(network)

    -- The forger relays a newer fact claiming the member gave up healing.
    forger.session:Send({ t = "facts", facts = { roles(NOW + 5, MEMBER, MEMBER, { "dps" }) } })
    deliver(network)

    -- The member's own data stands, and went out stamped newer, so the
    -- bystander ends up with it too.
    test.assertEqual("healer", table.concat(member.partition:GetRoles(MEMBER), ","))
    test.assertEqual("healer", table.concat(bystander.partition:GetRoles(MEMBER), ","))
    test.assertTrue((member.partition:GetRolesStamp(MEMBER)) > NOW + 5)
    test.assertEqual(1, #member.forgeries)
    test.assertEqual("Toolbox-Area52", member.forgeries[1].relayedBy)
    test.assertEqual("dps", member.partition:GetForgeries()[1].roles[1])
    -- The officer's own forgery check leaves profile facts to their owner.
    test.assertEqual(0, #forger.forgeries)
end)

test.test("guild sync: a roles fact from before this login is a real edit made elsewhere, and is applied", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local relay = newClient(network, "wrench-area52", "Wrench-Area52")

    -- The player changed roles on another computer, ten minutes before
    -- logging in here, where saved data never saw it.
    relay.session:Send({ t = "facts", facts = { roles(NOW - 600, MEMBER, MEMBER, { "healer" }) } })
    deliver(network)

    test.assertEqual("healer", table.concat(member.partition:GetRoles(MEMBER), ","))
    test.assertEqual(0, #member.forgeries)
    test.assertEqual(0, #member.sent)
end)

test.test("guild sync: a forged roles fact for a character who never set any is corrected with the class's roles", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local forger = newClient(network, "wrench-area52", "Wrench-Area52")

    forger.session:Send({ t = "facts", facts = { roles(NOW, MEMBER, MEMBER, {}) } })
    deliver(network)

    test.assertEqual("tank,healer,dps", table.concat(member.partition:GetRoles(MEMBER), ","))
    test.assertEqual("tank,healer,dps", table.concat(forger.partition:GetRoles(MEMBER), ","))
end)

-- The player panel ------------------------------------------------------------

test.test("player panel: each character shows its role preferences", function()
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/RosterViewModel.lua",
        "Core/PlayerPanelViewModel.lua", "Core/RoleCatalog.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter(MEMBER, { name = "Hammer-Area52", classToken = "PALADIN" })
    partition:SetRoles(MEMBER, { "healer" }, NOW, MEMBER)
    local catalog = addon.RoleCatalog.For("retail")

    local model = addon.PlayerPanelViewModel.Build({
        partition = partition,
        playerId = partition:GetCharacter(MEMBER).player,
        normalizer = addon.NameNormalizer.Create(RULES),
        rolesOf = function(key)
            return addon.RoleCatalog.Describe(catalog:PreferencesOf(partition, key))
        end,
    })

    local row
    local index
    for index = 1, #model.rows do
        if model.rows[index].kind == "character" then
            row = model.rows[index]
        end
    end
    test.assertEqual("Healer", row.roles)
end)

-- Settings, in the composed add-on --------------------------------------------

local function loggedIn(profile)
    local world = fixtures.newEnvironment(profile)
    local addon = fixtures.loadAddon(world)
    addon.RosterWindow.Create = function()
        return nil
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    -- The roster is scanned, so the logged-in character is known.
    addon.rosterController:Rescan()
    fixtures.runTimers(world, 60)
    return world, addon
end

local function registerProfileTests(profile)
    test.test(profile .. " settings: the logged-in character's roles default to its class and can be turned off", function()
        local world, addon = loggedIn(profile)
        local settings = addon.settings
        -- The first member is a warrior: tank and DPS, never healer.
        test.assertTrue(settings:IsShown("role_tank"))
        test.assertFalse(settings:IsShown("role_healer"))
        test.assertTrue(settings:IsShown("role_dps"))
        test.assertTrue(settings:Get("role_tank"))
        test.assertTrue(settings:Get("role_dps"))

        world.sentMessages = {}
        test.assertTrue(settings:Set("role_tank", false))

        test.assertFalse(settings:Get("role_tank"))
        test.assertTrue(settings:Get("role_dps"))
        local selfKey = addon.rosterController:SelfKey()
        local _, partition = addon.rosterController:QuietContext()
        test.assertEqual("dps", table.concat(partition:GetRoles(selfKey), ","))
        -- The change went to the guild as the character's own fact.
        local sent = world.sentMessages[#world.sentMessages]
        local _, message = world.environment.LibStub.libs["AceSerializer-3.0"]:Deserialize(sent.text)
        test.assertEqual("facts", message.t)
        test.assertEqual("roles", message.facts[1].kind)
        test.assertEqual(selfKey, message.facts[1].by)
        test.assertEqual("dps", table.concat(message.facts[1].roles, ","))

        test.assertTrue(settings:Set("role_tank", true))
        test.assertEqual("tank,dps", table.concat(partition:GetRoles(selfKey), ","))
    end)
end

registerProfileTests("Forever")
registerProfileTests("Retail")
