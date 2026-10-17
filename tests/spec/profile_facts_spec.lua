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
        "Core/RoleCatalog.lua",
        "Core/PlayerService.lua",
        "Core/ConflictViewModel.lua",
        "Core/BundleReviewViewModel.lua",
        "Core/SuggestionBundles.lua",
        "Core/ScanScheduler.lua",
        "Core/RosterController.lua"
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

    test.assertEqual(4, world.database.schemaVersion)
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
    test.test(profile .. " role preferences: the logged-in character's default to its class and can be turned off", function()
        local world, addon = loggedIn(profile)
        local settings = addon.settings
        -- The first member is a warrior: tank and DPS, never healer.
        -- Changed on My Profile only: no settings panel shows them.
        test.assertFalse(settings:IsShown("role_tank"))
        test.assertFalse(settings:IsShown("role_healer"))
        test.assertFalse(settings:IsShown("role_dps"))
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

test.test("guild sync: a correction for a forgery dated as far ahead as allowed waits until others accept it", function()
    local addon = load()
    local partition, normalizer = newPartition(addon)
    local sent, waits = {}, {}
    local session = addon.SyncSession.Create({
        comm = { Broadcast = function(_, message) table.insert(sent, message) return true end },
        context = function() return partition, normalizer end,
        selfKey = function() return MEMBER end,
        isOfficer = function() return false end,
        now = function() return NOW end,
        after = function(seconds, callback)
            table.insert(waits, { seconds = seconds, callback = callback })
            return true
        end,
        rolesOf = function(key) return addon.RoleCatalog.For("retail"):PreferencesOf(partition, key) end,
    })
    session.startedAt = NOW
    local farthest = NOW + addon.SyncFacts.MAX_FUTURE_SECONDS

    local kept = session:CatchProfileForgeries({ roles(farthest, MEMBER, MEMBER, { "dps" }) }, partition, MEMBER,
        "wrench-area52", "Wrench-Area52")

    test.assertEqual(0, #kept)
    -- Stamped one second past the forgery: sent once that's no longer
    -- too far ahead for others.
    test.assertEqual(farthest + 1, (partition:GetRolesStamp(MEMBER)))
    test.assertEqual(0, #sent)
    test.assertEqual(1, waits[#waits].seconds)
    waits[#waits].callback()
    test.assertEqual(1, #sent)
    test.assertEqual(farthest + 1, sent[1].facts[1].at)
end)

test.test("guild sync: a role change made while a correction waits goes out with it, never overwritten", function()
    local addon = load()
    local partition, normalizer = newPartition(addon)
    local sent, waits = {}, {}
    local session = addon.SyncSession.Create({
        comm = { Broadcast = function(_, message) table.insert(sent, message) return true end },
        context = function() return partition, normalizer end,
        selfKey = function() return MEMBER end,
        isOfficer = function() return false end,
        now = function() return NOW end,
        after = function(seconds, callback)
            table.insert(waits, { seconds = seconds, callback = callback })
            return true
        end,
        rolesOf = function(key) return addon.RoleCatalog.For("retail"):PreferencesOf(partition, key) end,
    })
    session.startedAt = NOW
    local farthest = NOW + addon.SyncFacts.MAX_FUTURE_SECONDS
    session:CatchProfileForgeries({ roles(farthest, MEMBER, MEMBER, { "dps" }) }, partition, MEMBER,
        "wrench-area52", "Wrench-Area52")

    -- The player turns healing off before the correction goes out.
    local edit = session:LocalRolesEdit({ "tank", "dps" })

    -- The edit is stamped after the correction, so it waits too.
    test.assertEqual(farthest + 2, edit.at)
    test.assertEqual(0, #sent)
    test.assertEqual(2, #waits)
    test.assertEqual(2, waits[2].seconds)
    -- Whichever goes out first carries the edit, not what it replaced.
    waits[1].callback()
    waits[2].callback()
    test.assertEqual(2, #sent)
    local index
    for index = 1, #sent do
        test.assertEqual("tank,dps", table.concat(sent[index].facts[1].roles, ","))
        test.assertEqual(farthest + 2, sent[index].facts[1].at)
    end
end)

test.test("guild sync: an ordinary role change goes out at once", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")

    member.session:LocalRolesEdit({ "healer" })

    test.assertEqual(1, #member.sent)
end)

-- Discord, location and bio ------------------------------------------------------

local function text(kind, at, by, character, value)
    return { kind = kind, character = character or by, text = value, at = at, by = by }
end

-- Hammer and Wrench, one player with Hammer as main.
local function onePlayer(partition)
    partition:JoinPlayerOf("wrench-area52", MEMBER, "manual")
end

test.test("profile store: Discord, location and bio are kept on the character with their stamp", function()
    local addon = load()
    local partition = newPartition(addon)

    test.assertEqual(nil, partition:GetProfileText(MEMBER, "discord"))
    test.assertEqual(0, (partition:GetProfileStamp(MEMBER, "discord")))
    test.assertTrue(partition:SetProfileText(MEMBER, "discord", "hammer#1", NOW, MEMBER))
    test.assertEqual("hammer#1", partition:GetProfileText(MEMBER, "discord"))
    local at, by = partition:GetProfileStamp(MEMBER, "discord")
    test.assertEqual(NOW, at)
    test.assertEqual(MEMBER, by)

    -- Longest values: 32, 40 and 500 bytes; one more is refused.
    test.assertTrue(partition:SetProfileText(MEMBER, "discord", string.rep("d", 32), NOW, MEMBER))
    test.assertFalse(partition:SetProfileText(MEMBER, "discord", string.rep("d", 33), NOW, MEMBER))
    test.assertTrue(partition:SetProfileText(MEMBER, "location", string.rep("l", 40), NOW, MEMBER))
    test.assertFalse(partition:SetProfileText(MEMBER, "location", string.rep("l", 41), NOW, MEMBER))
    test.assertTrue(partition:SetProfileText(MEMBER, "bio", string.rep("b", 500), NOW, MEMBER))
    test.assertFalse(partition:SetProfileText(MEMBER, "bio", string.rep("b", 501), NOW, MEMBER))
    test.assertFalse(partition:SetProfileText(MEMBER, "pronouns", "they", NOW, MEMBER))

    -- Empty clears: the player then has no value.
    test.assertTrue(partition:SetProfileText(MEMBER, "discord", "", NOW + 1, MEMBER))
    test.assertEqual(nil, (partition:PlayerProfileText(partition:GetCharacter(MEMBER).player, "discord")))
end)

test.test("profile store: a character with an unreadable bio is set aside intact", function()
    local addon = load()
    local database = { schemaVersion = 4, guilds = { ["Knights of Camelot-Area52"] = {
        characters = { [MEMBER] = { player = 1, name = "Hammer-Area52", bio = string.rep("b", 501) } },
        players = { [1] = { main = MEMBER } },
        nextPlayerId = 2,
    } } }

    local partition = addon.FellowshipStore.Create(database):Partition(GUILD)

    test.assertEqual(nil, partition:GetCharacter(MEMBER))
    local quarantined = database.guilds["Knights of Camelot-Area52"].quarantine[1]
    test.assertEqual("character bio is invalid", quarantined.reason)
    test.assertEqual(501, #quarantined.record.bio)
end)

test.test("profile store: the player's value is the newest across its characters", function()
    local addon = load()
    local partition = newPartition(addon)
    onePlayer(partition)
    local playerId = partition:GetCharacter(MEMBER).player

    partition:SetProfileText(MEMBER, "location", "Ohio", NOW, MEMBER)
    partition:SetProfileText("wrench-area52", "location", "Ohio, evenings", NOW + 10, "wrench-area52")
    test.assertEqual("Ohio, evenings", (partition:PlayerProfileText(playerId, "location")))

    -- Editing again on Hammer is newer than Wrench's, whatever the clock says.
    local facts = newFacts(addon, partition)
    local fact = facts:StampText(MEMBER, "location", "Texas", NOW)
    test.assertEqual(NOW + 11, fact.at)
    test.assertEqual("Texas", (partition:PlayerProfileText(playerId, "location")))
end)

test.test("profile facts: Discord, location and bio are accepted only from the character, within their length", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)

    -- An officer can't edit or clear a member's location or bio.
    test.assertEqual("not the character's own", facts:Refusal(text("bio", NOW, OFFICER, MEMBER, "")))
    test.assertEqual("not the character's own", facts:Refusal(text("location", NOW, OFFICER, MEMBER, "x")))
    -- Nor can a member set someone else's Discord.
    test.assertEqual("not an officer", facts:Refusal(text("discord", NOW, "wrench-area52", MEMBER, "x")))
    test.assertEqual("malformed", facts:Refusal(text("discord", NOW, MEMBER, MEMBER, string.rep("d", 33))))
    test.assertEqual("malformed", facts:Refusal(text("bio", NOW, MEMBER, MEMBER, nil)))
    test.assertEqual(nil, facts:Refusal(text("bio", NOW, MEMBER, MEMBER, "Hi there")))

    test.assertEqual(1, facts:ApplyAll({ text("bio", NOW, MEMBER, MEMBER, "Hi there") }))
    test.assertEqual("Hi there", partition:GetProfileText(MEMBER, "bio"))
    -- Older loses; newer wins; "" clears.
    test.assertEqual(0, facts:ApplyAll({ text("bio", NOW - 1, MEMBER, MEMBER, "Old") }))
    test.assertEqual(1, facts:ApplyAll({ text("bio", NOW + 1, MEMBER, MEMBER, "") }))
    test.assertEqual("", partition:GetProfileText(MEMBER, "bio"))
end)

test.test("profile facts: Discord, location and bio are part of the digest and catch-up", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)
    local before = addon.SyncDigest.Of(facts:SharedFacts())

    partition:SetProfileText(MEMBER, "discord", "hammer#1", NOW, MEMBER)
    partition:SetProfileText(MEMBER, "bio", "Hi", NOW, MEMBER)
    -- Text someone else wrote isn't passed on.
    partition:SetProfileText("wrench-area52", "bio", "Forged", NOW, OFFICER)

    local shared = facts:SharedFacts()
    test.assertEqual(2, #shared)
    test.assertEqual("discord", shared[1].kind)
    test.assertEqual("hammer#1", shared[1].text)
    test.assertEqual("bio", shared[2].kind)
    local after = addon.SyncDigest.Of(shared)
    test.assertTrue(#addon.SyncDigest.Differing(before, after) >= 1)
    partition:SetProfileText(MEMBER, "bio", "Hello", NOW, MEMBER)
    test.assertTrue(#addon.SyncDigest.Differing(after, addon.SyncDigest.Of(facts:SharedFacts())) >= 1)
end)

test.test("guild sync: profile text is sent at once and others apply it", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local other = newClient(network, "wrench-area52", "Wrench-Area52")
    local bio = string.rep("A long bio. ", 16)
    bio = string.sub(string.rep(bio, 3), 1, 500)

    local fact = member.session:LocalProfileEdit("bio", bio)

    test.assertEqual("bio", fact.kind)
    test.assertEqual(MEMBER, fact.by)
    test.assertEqual("facts", member.sent[1].t)
    deliver(network)
    test.assertEqual(bio, other.partition:GetProfileText(MEMBER, "bio"))
    -- Never a suggestion, and too long is never stored or sent.
    test.assertEqual(0, #member.session:Suggestions(member.partition):Pending())
    test.assertEqual(nil, member.session:LocalProfileEdit("discord", string.rep("d", 33)))
    test.assertEqual(1, #member.sent)
end)

test.test("guild sync: an offline character's profile text reaches a client through catch-up", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    member.session:LocalProfileEdit("discord", "hammer#1")
    network.queue = {}
    local latecomer = newClient(network, "wrench-area52", "Wrench-Area52")

    latecomer.session:SendDigest()
    deliver(network)

    test.assertEqual("hammer#1", latecomer.partition:GetProfileText(MEMBER, "discord"))
end)

test.test("guild sync: the owner's client corrects forged profile text in its name", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local bystander = newClient(network, "wrench-area52", "Wrench-Area52")
    local forger = newClient(network, OFFICER, "Toolbox-Area52")
    member.session:LocalProfileEdit("location", "Ohio")
    deliver(network)

    forger.session:Send({ t = "facts", facts = {
        text("location", NOW + 5, MEMBER, MEMBER, "Nowhere"),
        -- Never set: corrected by clearing it.
        text("discord", NOW + 5, MEMBER, MEMBER, "spam"),
    } })
    deliver(network)

    test.assertEqual("Ohio", member.partition:GetProfileText(MEMBER, "location"))
    test.assertEqual("Ohio", bystander.partition:GetProfileText(MEMBER, "location"))
    test.assertEqual("", bystander.partition:GetProfileText(MEMBER, "discord"))
    test.assertTrue((member.partition:GetProfileStamp(MEMBER, "location")) > NOW + 5)
    test.assertEqual(1, #member.forgeries)
end)

-- An officer's Discord for a guildmate ------------------------------------------

test.test("profile facts: an officer's Discord for a guildmate is accepted when newer, unless Don't sync", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)
    local playerId = partition:GetCharacter(MEMBER).player

    test.assertEqual(nil, facts:Refusal(text("discord", NOW, OFFICER, MEMBER, "hammer#1")))
    test.assertEqual(1, facts:ApplyAll({ text("discord", NOW, OFFICER, MEMBER, "hammer#1") }))
    test.assertEqual("hammer#1", (partition:PlayerProfileText(playerId, "discord")))
    -- Not newer than what's held.
    test.assertEqual("not newer", facts:Refusal(text("discord", NOW - 1, OFFICER, MEMBER, "old")))
    -- Clearing it is an edit like any other.
    test.assertEqual(1, facts:ApplyAll({ text("discord", NOW + 1, OFFICER, MEMBER, "") }))
    test.assertEqual(nil, (partition:PlayerProfileText(playerId, "discord")))

    -- A "Don't sync" player keeps this client's value.
    partition:SetNoSync(playerId, true)
    test.assertEqual("don't sync", facts:Refusal(text("discord", NOW + 2, OFFICER, MEMBER, "new")))
    -- The player's own edit is still theirs to make.
    test.assertEqual(nil, facts:Refusal(text("discord", NOW + 2, MEMBER, MEMBER, "mine")))
end)

test.test("profile facts: the player's own newer Discord replaces an officer's, an older one doesn't", function()
    local addon = load()
    local partition = newPartition(addon)
    onePlayer(partition)
    local facts = newFacts(addon, partition)
    local playerId = partition:GetCharacter(MEMBER).player

    facts:ApplyAll({ text("discord", NOW, OFFICER, MEMBER, "officer#1") })
    -- Written on an alt before the officer's: older, so the officer's shows.
    test.assertEqual(1, facts:ApplyAll({ text("discord", NOW - 10, "wrench-area52", "wrench-area52", "old#1") }))
    test.assertEqual("officer#1", (partition:PlayerProfileText(playerId, "discord")))
    -- Written later: the player's own wins.
    test.assertEqual(1, facts:ApplyAll({ text("discord", NOW + 10, "wrench-area52", "wrench-area52", "mine#1") }))
    test.assertEqual("mine#1", (partition:PlayerProfileText(playerId, "discord")))
end)

test.test("profile facts: an officer's Discord is part of the digest, unless Don't sync", function()
    local addon = load()
    local partition = newPartition(addon)
    local facts = newFacts(addon, partition)

    partition:SetProfileText(MEMBER, "discord", "hammer#1", NOW, OFFICER)
    -- Text a member wrote for someone else isn't passed on.
    partition:SetProfileText("wrench-area52", "discord", "spam", NOW, MEMBER)

    local shared = facts:SharedFacts()
    test.assertEqual(1, #shared)
    test.assertEqual(OFFICER, shared[1].by)
    test.assertEqual("hammer#1", shared[1].text)
    partition:SetNoSync(partition:GetCharacter(MEMBER).player, true)
    test.assertEqual(0, #facts:SharedFacts())
end)

test.test("guild sync: an officer sets a guildmate's Discord on their main, and others apply it", function()
    local network = newNetwork()
    local officer = newClient(network, OFFICER, "Toolbox-Area52")
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local other = newClient(network, "wrench-area52", "Wrench-Area52")
    local index
    for index = 1, #network.clients do
        onePlayer(network.clients[index].partition)
    end
    -- The player wrote their own on the alt earlier.
    other.session:LocalProfileEdit("discord", "old#1")
    deliver(network)
    local playerId = officer.partition:GetCharacter(MEMBER).player

    -- Set from the alt's row: stored on the main, as the officer's.
    local facts = officer.session:LocalDiscordEdit("wrench-area52", "hammer#1")

    test.assertEqual(1, #facts)
    test.assertEqual(MEMBER, facts[1].character)
    test.assertEqual(OFFICER, facts[1].by)
    test.assertTrue(facts[1].at > NOW)
    deliver(network)
    for index = 1, #network.clients do
        local client = network.clients[index]
        test.assertEqual("hammer#1", (client.partition:PlayerProfileText(playerId, "discord")))
    end
    -- Not a forgery on the owner's client, and nothing was reverted.
    test.assertEqual(0, #member.forgeries)
    test.assertEqual(0, #officer.forgeries)

    -- Clearing it.
    officer.session:LocalDiscordEdit(MEMBER, "")
    deliver(network)
    test.assertEqual(nil, (member.partition:PlayerProfileText(playerId, "discord")))

    -- The player's own later edit wins everywhere.
    member.time = NOW + 60
    member.session:LocalProfileEdit("discord", "mine#1")
    deliver(network)
    test.assertEqual("mine#1", (officer.partition:PlayerProfileText(playerId, "discord")))
    test.assertEqual("mine#1", (other.partition:PlayerProfileText(playerId, "discord")))
end)

-- An officer, the member suggesting, and the guildmate (Wrench) it's about.
local function suggestionNetwork()
    local network = newNetwork()
    local officer = newClient(network, OFFICER, "Toolbox-Area52")
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local guildmate = newClient(network, "wrench-area52", "Wrench-Area52")
    member.session.officerOnline = function()
        return true
    end
    return network, officer, member, guildmate
end

local function discordOf(client, key)
    return (client.partition:PlayerProfileText(client.partition:GetCharacter(key).player, "discord"))
end

test.test("discord suggestions: a member's edit stays theirs and reaches officers' queues", function()
    local network, officer, member, guildmate = suggestionNetwork()
    guildmate.session:LocalProfileEdit("discord", "old#1")
    deliver(network)

    local facts = member.session:LocalDiscordEdit("wrench-area52", "wrench#1")
    deliver(network)

    test.assertEqual(MEMBER, facts[1].by)
    -- The member's own view shows it, pending.
    test.assertEqual("wrench#1", discordOf(member, "wrench-area52"))
    local pending = member.session:Suggestions(member.partition):Pending()
    test.assertEqual(1, #pending)
    test.assertEqual("discord", pending[1].kind)
    test.assertEqual("old#1", pending[1].was.text)
    -- Sent as a suggestion, never applied elsewhere.
    test.assertEqual("suggest", member.sent[1].t)
    test.assertEqual("old#1", discordOf(guildmate, "wrench-area52"))
    test.assertEqual("old#1", discordOf(officer, "wrench-area52"))
    local entry = officer.partition:GetConflicts()[1]
    test.assertEqual("suggested discord", entry.kind)
    test.assertEqual("wrench-area52", entry.character)
    test.assertEqual("wrench#1", entry.suggestion.text)
    test.assertEqual(MEMBER, entry.from)
end)

test.test("discord suggestions: approving syncs it as the officer's", function()
    local network, officer, member, guildmate = suggestionNetwork()
    member.session:LocalDiscordEdit("wrench-area52", "wrench#1")
    deliver(network)

    test.assertTrue(officer.session:Decide("wrench-area52", "suggested discord", true))
    deliver(network)

    local at, by = guildmate.partition:GetProfileStamp("wrench-area52", "discord")
    test.assertEqual(OFFICER, by)
    test.assertEqual("wrench#1", discordOf(guildmate, "wrench-area52"))
    test.assertEqual("wrench#1", discordOf(member, "wrench-area52"))
    test.assertEqual(0, #officer.partition:GetConflicts())
    test.assertEqual(0, #member.session:Suggestions(member.partition):Pending())
    -- The guildmate's client doesn't take the officer's edit for a forgery.
    test.assertEqual(0, #guildmate.forgeries)
end)

test.test("discord suggestions: denying drops it and the member's view reverts", function()
    local network, officer, member, guildmate = suggestionNetwork()
    guildmate.session:LocalProfileEdit("discord", "old#1")
    deliver(network)
    member.session:LocalDiscordEdit("wrench-area52", "spam#1")
    deliver(network)

    test.assertTrue(officer.session:Decide("wrench-area52", "suggested discord", false))
    deliver(network)

    test.assertEqual("old#1", discordOf(member, "wrench-area52"))
    test.assertEqual("old#1", discordOf(guildmate, "wrench-area52"))
    test.assertEqual(0, #officer.partition:GetConflicts())
    test.assertEqual(0, #member.session:Suggestions(member.partition):Pending())
end)

test.test("discord suggestions: one the player's own newer edit overtakes is settled", function()
    local network, officer, member, guildmate = suggestionNetwork()
    member.session:LocalDiscordEdit("wrench-area52", "wrench#1")
    deliver(network)
    test.assertEqual(1, #officer.partition:GetConflicts())

    guildmate.time = NOW + 60
    guildmate.session:LocalProfileEdit("discord", "mine#1")
    deliver(network)

    test.assertEqual(0, #officer.partition:GetConflicts())
    test.assertEqual(0, #member.session:Suggestions(member.partition):Pending())
    test.assertEqual("mine#1", discordOf(member, "wrench-area52"))
end)

test.test("discord suggestions: changing it back withdraws it", function()
    local network, officer, member = suggestionNetwork()
    member.session:LocalDiscordEdit("wrench-area52", "wrench#1")
    deliver(network)

    member.session:LocalDiscordEdit("wrench-area52", "")
    deliver(network)

    test.assertEqual(0, #member.session:Suggestions(member.partition):Pending())
    test.assertEqual(nil, discordOf(member, "wrench-area52"))
    test.assertEqual(0, #officer.partition:GetConflicts())
end)

local function decideAll(network, officer, approved)
    local addon = network.addon
    local controller = addon.RosterController.Create({
        client = { Print = function() end },
        onDecideSuggestion = function(character, kind, decision)
            return officer.session:Decide(character, kind, decision)
        end,
    })
    controller.current = { partition = officer.partition }
    return controller:DecideBundle(addon.ConflictViewModel.GroupOf(officer.partition, MEMBER), approved)
end

test.test("discord suggestions: Approve all and Deny all include them", function()
    local network, officer, member, guildmate = suggestionNetwork()
    member.session:LocalDiscordEdit("wrench-area52", "wrench#1")
    member.session:LocalDiscordEdit(OFFICER, "toolbox#1")
    deliver(network)
    test.assertEqual(2, #officer.partition:GetConflicts())

    test.assertEqual(2, decideAll(network, officer, true))
    deliver(network)

    test.assertEqual("wrench#1", discordOf(guildmate, "wrench-area52"))
    test.assertEqual("toolbox#1", discordOf(guildmate, OFFICER))

    member.session:LocalDiscordEdit("wrench-area52", "spam#1")
    deliver(network)
    test.assertEqual(1, decideAll(network, officer, false))
    deliver(network)
    test.assertEqual("wrench#1", discordOf(member, "wrench-area52"))
    test.assertEqual(0, #officer.partition:GetConflicts())
end)

test.test("discord suggestions: the conflict queue and the review word them like aliases", function()
    local network, officer, member, guildmate = suggestionNetwork()
    guildmate.session:LocalProfileEdit("discord", "old#1")
    deliver(network)
    member.session:LocalDiscordEdit("wrench-area52", "wrench#1")
    deliver(network)
    local addon = network.addon
    local normalizer = addon.NameNormalizer.Create(RULES)

    local rows = addon.ConflictViewModel.Build({ partition = officer.partition, normalizer = normalizer })
    local item = rows[1].items[1]
    test.assertEqual("Discord \"old#1\"", item.current)
    test.assertEqual("Discord \"wrench#1\"", item.suggests)
    local review = addon.BundleReviewViewModel.Build({ partition = officer.partition, normalizer = normalizer,
        bundle = rows[1] })
    test.assertEqual("Wrench's Discord: Discord \"old#1\" → Discord \"wrench#1\"", review.items[1].text)

    -- The member's own pending list.
    local own = addon.ConflictViewModel.Build({ partition = member.partition, normalizer = normalizer,
        pending = member.session:Suggestions(member.partition):Pending() })
    test.assertEqual("suggested discord", own[1].kind)
    test.assertTrue(own[1].pending)
    test.assertEqual("Wrench's Discord: wrench#1",
        addon.SuggestionBundles.Describe(member.partition, normalizer, member.session:Suggestions(member.partition):Pending()[1]))
end)

test.test("guild sync: an officer's Discord reaches a latecomer through catch-up", function()
    local network = newNetwork()
    local officer = newClient(network, OFFICER, "Toolbox-Area52")
    officer.session:LocalDiscordEdit(MEMBER, "hammer#1")
    network.queue = {}
    local latecomer = newClient(network, "wrench-area52", "Wrench-Area52")

    latecomer.session:SendDigest()
    deliver(network)

    test.assertEqual("hammer#1", latecomer.partition:GetProfileText(MEMBER, "discord"))
end)

test.test("guild sync: a forged Discord in an officer's name is caught by that officer's ledger", function()
    local network = newNetwork()
    local officer = newClient(network, OFFICER, "Toolbox-Area52")
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local forger = newClient(network, "wrench-area52", "Wrench-Area52")
    officer.session:LocalDiscordEdit(MEMBER, "hammer#1")
    deliver(network)

    forger.session:Send({ t = "facts", facts = { text("discord", NOW + 5, OFFICER, MEMBER, "spam") } })
    deliver(network)

    test.assertEqual(1, #officer.forgeries)
    local log = network.addon.SyncLedger.Create(officer.partition):Forgeries()
    test.assertEqual("discord", log[1].kind)
    test.assertEqual("spam", log[1].text)
    -- The officer's correction puts it back everywhere.
    test.assertEqual("hammer#1", officer.partition:GetProfileText(MEMBER, "discord"))
    test.assertEqual("hammer#1", member.partition:GetProfileText(MEMBER, "discord"))
    test.assertEqual("hammer#1", forger.partition:GetProfileText(MEMBER, "discord"))
    -- The officer's own Discord stays the officer's own business.
    test.assertEqual(0, #member.forgeries)
end)

test.test("guild sync: a fact of a kind this version doesn't know is ignored, as older versions ignore these", function()
    local network = newNetwork()
    local member = newClient(network, MEMBER, "Hammer-Area52")
    local relay = newClient(network, "wrench-area52", "Wrench-Area52")

    relay.session:Send({ t = "facts", facts = {
        { kind = "pronouns", character = "wrench-area52", text = "they", at = NOW, by = "wrench-area52" },
        roles(NOW, "wrench-area52", "wrench-area52", { "dps" }),
    } })
    deliver(network)

    test.assertEqual("dps", table.concat(member.partition:GetRoles("wrench-area52"), ","))
    test.assertEqual(nil, member.partition:GetCharacter("wrench-area52").pronouns)
end)

test.test("player panel: shows the player's Discord, location and bio when set", function()
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/RosterViewModel.lua",
        "Core/PlayerPanelViewModel.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 4, guilds = {} }):Partition(GUILD)
    partition:RecordCharacter(MEMBER, { name = "Hammer-Area52", classToken = "PALADIN" })
    local playerId = partition:GetCharacter(MEMBER).player
    local function build()
        local model = addon.PlayerPanelViewModel.Build({
            partition = partition, playerId = playerId, normalizer = addon.NameNormalizer.Create(RULES),
        })
        local lines = {}
        local index
        for index = 1, #model.rows do
            local row = model.rows[index]
            if row.kind == "about" or (row.kind == "section" and row.text == "About") then
                table.insert(lines, row.text)
            end
        end
        return lines
    end

    test.assertEqual(0, #build())

    partition:SetProfileText(MEMBER, "discord", "hammer#1", NOW, MEMBER)
    partition:SetProfileText(MEMBER, "bio", "I heal dungeons most evenings and love a good keystone run with friends",
        NOW, MEMBER)
    local lines = build()
    test.assertEqual("About", lines[1])
    test.assertEqual("Discord: hammer#1", lines[2])
    -- No location; the bio is wrapped to the panel.
    test.assertEqual("I heal dungeons most evenings and love a good", lines[3])
    test.assertEqual("keystone run with friends", lines[4])
    test.assertEqual(4, #lines)

    -- A line break the player typed starts a new line.
    partition:SetProfileText(MEMBER, "bio", "Healer.\nEvenings only.", NOW + 1, MEMBER)
    lines = build()
    test.assertEqual("Healer.", lines[3])
    test.assertEqual("Evenings only.", lines[4])
end)
