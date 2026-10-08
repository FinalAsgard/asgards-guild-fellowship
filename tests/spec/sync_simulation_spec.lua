local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Several add-on users in one guild, each running the whole add-on in its
-- own fake client, joined by one fake guild add-on channel.

-- Nobody's note says anything, so every relationship comes from sync.
local function guild(realm)
    return {
        name = "Knights of Camelot",
        realm = realm or "Area 52",
        members = {
            { name = "Grandmaster-Area52", class = "WARRIOR", level = 80, rank = 0, rankName = "Guild Master",
                online = true, zone = "Dornogal" },
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
            { name = "Wrench-Area52", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal" },
        },
    }
end

local function newWindow()
    local window = { shown = false }
    function window:IsShown()
        return self.shown
    end
    function window:Show()
        self.shown = true
    end
    function window:Hide()
        self.shown = false
    end
    function window:SetTitle() end
    function window:SetStatus() end
    function window:SetRows(rows)
        self.rows = rows
        return true
    end
    function window:SetConflicts()
        return true
    end
    function window:ShowPlayer() end
    function window:HidePlayer() end
    return window
end

-- Logs `playerName` in on a fresh install, lets the first scan finish, and
-- opens the roster window so organizing works.
local function login(channel, playerName, options)
    options = options or {}
    local world = fixtures.newEnvironment(options.profile or "Retail", {
        addonName = options.addonName,
        guild = guild(),
        playerName = playerName,
    })
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    local controller = world.addon.rosterController
    controller.createWindow = function()
        return newWindow()
    end
    test.assertTrue(controller:Toggle(), playerName .. " opens the roster")
    fixtures.joinChannel(channel, world)
    return world
end

local function partitionOf(world)
    local _, partition = world.addon.rosterController:QuietContext()
    return partition
end

local function mainOf(world, key)
    local partition = partitionOf(world)
    return partition:GetPlayer(partition:GetCharacter(key).player).main
end

local function playerIdOf(world, key)
    return partitionOf(world):GetCharacter(key).player
end

-- `world` links `alt` as an alt of `main`'s player, through the roster's
-- "Set main..." action.
local function linkAlt(world, alt, main)
    test.assertTrue(world.addon.rosterController:SetMainPlayer(alt, playerIdOf(world, main)))
end

local function decode(world, sent)
    local serializer = world.environment.LibStub:GetLibrary("AceSerializer-3.0")
    local ok, message = serializer:Deserialize(sent.text)
    test.assertTrue(ok, "a sent message deserializes")
    return message
end

test.test("an officer's edit reaches every online member and only sends main links", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")

    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertEqual("toolbox-area52", mainOf(hammer, "hammer-area52"))
    test.assertEqual("toolbox-area52", mainOf(wrench, "hammer-area52"))
    test.assertEqual("toolbox-area52", mainOf(officer, "hammer-area52"))

    test.assertEqual(1, #officer.sentMessages)
    local sent = officer.sentMessages[1]
    test.assertEqual("AGFSync", sent.prefix)
    test.assertEqual("GUILD", sent.distribution)
    test.assertEqual("BULK", sent.priority)
    local message = decode(officer, sent)
    test.assertEqual(1, message.v)
    test.assertEqual("facts", message.t)
    local key
    for key in pairs(message) do
        test.assertTrue(key == "v" or key == "t" or key == "facts", "message field " .. tostring(key))
    end
    -- Hammer's former single-character player and the officer's player.
    test.assertEqual(2, #message.facts)
    local index
    for index = 1, #message.facts do
        for key in pairs(message.facts[index]) do
            test.assertTrue(key == "kind" or key == "character" or key == "main" or key == "at" or key == "by",
                "fact field " .. tostring(key))
        end
        test.assertEqual("toolbox-area52", message.facts[index].by)
    end
end)

test.test("make this the main and detach reach members too", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")
    linkAlt(officer, "hammer-area52", "toolbox-area52")
    linkAlt(officer, "wrench-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertTrue(officer.addon.rosterController:MakeMain("hammer-area52"))
    fixtures.deliver(channel)
    test.assertEqual("hammer-area52", mainOf(member, "toolbox-area52"))
    test.assertEqual("hammer-area52", mainOf(member, "wrench-area52"))

    test.assertTrue(officer.addon.rosterController:Detach("wrench-area52"))
    fixtures.deliver(channel)
    test.assertEqual("wrench-area52", mainOf(member, "wrench-area52"))
    test.assertEqual(1, #partitionOf(member):CharactersOf(playerIdOf(member, "wrench-area52")))
    test.assertEqual("hammer-area52", mainOf(member, "toolbox-area52"))
end)

test.test("a member's own edit isn't broadcast, and a forged member broadcast is ignored", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")

    linkAlt(hammer, "wrench-area52", "hammer-area52")
    test.assertEqual(0, #hammer.sentMessages)
    test.assertEqual("hammer-area52", mainOf(hammer, "wrench-area52"))

    hammer.addon.comm:Broadcast({
        v = 1,
        t = "facts",
        facts = {
            { kind = "main", character = "wrench-area52", main = "hammer-area52", at = hammer.time, by = "hammer-area52" },
            -- Claiming to be the officer doesn't help: it isn't their message.
            { kind = "main", character = "wrench-area52", main = "hammer-area52", at = hammer.time, by = "toolbox-area52" },
        },
    })
    fixtures.deliver(channel)

    test.assertEqual("wrench-area52", mainOf(wrench, "wrench-area52"))
    test.assertEqual("wrench-area52", mainOf(officer, "wrench-area52"))
end)

test.test("when two officers disagree, the newest edit wins everywhere", function()
    local channel = fixtures.newChannel()
    local leader = login(channel, "Grandmaster-Area52")
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")

    -- The guild master's edit is newer, but it's sent and delivered first.
    leader.time = leader.time + 60
    linkAlt(leader, "hammer-area52", "grandmaster-area52")
    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertEqual("grandmaster-area52", mainOf(leader, "hammer-area52"))
    test.assertEqual("grandmaster-area52", mainOf(officer, "hammer-area52"))
    test.assertEqual("grandmaster-area52", mainOf(member, "hammer-area52"))
end)

test.test("an officer demoted to a member rank no longer has authority", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")
    member.officerRanks[1] = nil

    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertEqual("hammer-area52", mainOf(member, "hammer-area52"))
end)

test.test("a message from another protocol version is ignored without errors", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")
    local printed = #member.messages

    officer.addon.comm:Broadcast({
        v = 2,
        t = "facts",
        facts = {
            { kind = "main", character = "hammer-area52", main = "toolbox-area52", at = officer.time, by = "toolbox-area52" },
        },
    })
    officer.addon.comm:Broadcast({ v = 1, t = "something new" })
    fixtures.deliver(channel)

    test.assertEqual("hammer-area52", mainOf(member, "hammer-area52"))
    test.assertEqual(printed, #member.messages)
end)

test.test("production and development builds never exchange data", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local devMember = login(channel, "Wrench-Area52", { addonName = "AsgardsGuildFellowshipDev" })

    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertEqual("hammer-area52", mainOf(devMember, "hammer-area52"))
    test.assertEqual("AGFSyncDev", devMember.addon.Identity.commPrefix)
end)

test.test("sync works the same on WoW Forever", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52", { profile = "Forever" })
    local member = login(channel, "Wrench-Area52", { profile = "Forever" })

    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertEqual("toolbox-area52", mainOf(member, "hammer-area52"))
end)

-- Aliases ---------------------------------------------------------------------

local function aliasOf(world, key)
    local partition = partitionOf(world)
    return partition:GetPlayer(partition:GetCharacter(key).player).alias
end

-- The roster row labeled `label` in `world`'s open window, or nil.
local function rosterRow(world, label)
    local rows = world.addon.rosterController.window.rows or {}
    local index
    for index = 1, #rows do
        if rows[index].label == label then
            return rows[index]
        end
    end
    return nil
end

test.test("an officer's alias shows in members' roster and chat tags", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")
    linkAlt(officer, "hammer-area52", "toolbox-area52")

    test.assertTrue(officer.addon.rosterController:SetAlias("hammer-area52", "The Tool"))
    fixtures.deliver(channel)

    test.assertEqual("The Tool", aliasOf(member, "hammer-area52"))
    test.assertTrue(rosterRow(member, "The Tool (Toolbox)") ~= nil, "the roster shows the synced alias")
    local tag = member.addon.chatAnnotator:TagFor("Hammer-Area52")
    test.assertEqual("The Tool", tag.text)
    test.assertEqual("alias", tag.kind)

    local sent = decode(officer, officer.sentMessages[#officer.sentMessages])
    test.assertEqual(1, #sent.facts)
    test.assertEqual("alias", sent.facts[1].kind)
    test.assertEqual("toolbox-area52", sent.facts[1].character)
    test.assertEqual("The Tool", sent.facts[1].alias)
end)

test.test("an officer clearing an alias clears it for members", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")
    officer.addon.rosterController:SetAlias("hammer-area52", "Hammy")
    fixtures.deliver(channel)
    test.assertEqual("Hammy", aliasOf(member, "hammer-area52"))

    test.assertTrue(officer.addon.rosterController:SetAlias("hammer-area52", ""))
    fixtures.deliver(channel)

    test.assertEqual(nil, aliasOf(member, "hammer-area52"))
    test.assertEqual(nil, member.addon.chatAnnotator:TagFor("Hammer-Area52"))
end)

test.test("a member's own alias isn't broadcast", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")

    test.assertTrue(member.addon.rosterController:SetAlias("wrench-area52", "Sparky"))
    fixtures.deliver(channel)

    test.assertEqual(0, #member.sentMessages)
    test.assertEqual("Sparky", aliasOf(member, "wrench-area52"))
    test.assertEqual(nil, aliasOf(officer, "wrench-area52"))
end)

test.test("when two officers set different aliases, the newest wins everywhere", function()
    local channel = fixtures.newChannel()
    local leader = login(channel, "Grandmaster-Area52")
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")

    leader.time = leader.time + 60
    leader.addon.rosterController:SetAlias("hammer-area52", "Newer")
    officer.addon.rosterController:SetAlias("hammer-area52", "Older")
    fixtures.deliver(channel)

    test.assertEqual("Newer", aliasOf(leader, "hammer-area52"))
    test.assertEqual("Newer", aliasOf(officer, "hammer-area52"))
    test.assertEqual("Newer", aliasOf(member, "hammer-area52"))
end)

test.test("an alias set after a main change lands on the right player", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52")
    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)

    test.assertTrue(officer.addon.rosterController:MakeMain("hammer-area52"))
    test.assertTrue(officer.addon.rosterController:SetAlias("toolbox-area52", "Smith"))
    fixtures.deliver(channel)

    test.assertEqual("hammer-area52", mainOf(member, "toolbox-area52"))
    test.assertEqual("Smith", aliasOf(member, "toolbox-area52"))
    test.assertEqual("Smith", aliasOf(member, "hammer-area52"))
    test.assertEqual(nil, aliasOf(member, "wrench-area52"))
end)
