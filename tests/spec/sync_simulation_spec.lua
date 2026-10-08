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

-- Logs `playerName` in on a fresh install (or `options.database`), lets the
-- first scan finish, and
-- opens the roster window so organizing works.
local function login(channel, playerName, options)
    options = options or {}
    local world = fixtures.newEnvironment(options.profile or "Retail", {
        addonName = options.addonName,
        database = options.database,
        guild = guild(),
        playerName = playerName,
    })
    -- Joined first, so anything sent while logging in is heard.
    fixtures.joinChannel(channel, world)
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
    if options.openRoster ~= false then
        test.assertTrue(controller:Toggle(), playerName .. " opens the roster")
    end
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

test.test("a member's own edit isn't broadcast, and facts by a non-officer or from the future are ignored", function()
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
            -- A member naming themselves as author has no authority.
            { kind = "main", character = "wrench-area52", main = "hammer-area52", at = hammer.time, by = "hammer-area52" },
            -- An officer's name on a fact dated a day ahead would beat
            -- every real edit until then.
            { kind = "main", character = "wrench-area52", main = "hammer-area52", at = hammer.time + 86400,
                by = "toolbox-area52" },
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

-- Catching up at login -------------------------------------------------------

local function logOff(channel, world)
    local index
    for index = #channel.worlds, 1, -1 do
        if channel.worlds[index] == world then
            table.remove(channel.worlds, index)
        end
    end
    world.channel = nil
end

-- Lets a minute pass for `world`, so its announcement goes out.
local function announce(world)
    local sent = #world.sentMessages
    fixtures.runTimers(world, 60)
    test.assertEqual(sent + 1, #world.sentMessages, "one announcement")
    test.assertEqual("digest", decode(world, world.sentMessages[#world.sentMessages]).t)
end

-- The messages `world` sent from the `from`-th on, decoded.
local function sentSince(world, from)
    local messages = {}
    local index
    for index = from + 1, #world.sentMessages do
        table.insert(messages, decode(world, world.sentMessages[index]))
    end
    return messages
end

test.test("an officer's edit reaches a member who logs in after the officer logged off", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    linkAlt(officer, "hammer-area52", "toolbox-area52")
    officer.addon.rosterController:SetAlias("hammer-area52", "The Tool")
    fixtures.deliver(channel)
    logOff(channel, officer)

    local wrench = login(channel, "Wrench-Area52")
    test.assertEqual(0, #wrench.sentMessages, "nothing is sent at login")
    test.assertEqual("hammer-area52", mainOf(wrench, "hammer-area52"))
    announce(wrench)
    fixtures.deliver(channel)
    -- Hammer, a member, answers after a short random wait.
    fixtures.runTimers(hammer, 5)
    fixtures.deliver(channel)

    test.assertEqual("toolbox-area52", mainOf(wrench, "hammer-area52"))
    test.assertEqual("The Tool", aliasOf(wrench, "hammer-area52"))
    test.assertTrue(rosterRow(wrench, "The Tool (Toolbox)") ~= nil, "the roster shows the relayed data")
    local reply = decode(hammer, hammer.sentMessages[#hammer.sentMessages])
    test.assertEqual("facts", reply.t)
    test.assertEqual("wrench-area52", reply.re)
end)

test.test("members who already agree exchange only the announcement", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")
    linkAlt(officer, "hammer-area52", "toolbox-area52")
    fixtures.deliver(channel)
    local before = { #officer.sentMessages, #hammer.sentMessages, #wrench.sentMessages }

    announce(hammer)
    fixtures.deliver(channel)
    fixtures.runTimers(officer, 5)
    fixtures.runTimers(wrench, 5)
    fixtures.deliver(channel)

    test.assertEqual(before[1], #officer.sentMessages)
    test.assertEqual(before[2] + 1, #hammer.sentMessages)
    test.assertEqual(before[3], #wrench.sentMessages)
end)

test.test("one answer is sent per announcement, whoever sends it", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")
    linkAlt(officer, "wrench-area52", "toolbox-area52")
    fixtures.deliver(channel)
    logOff(channel, officer)
    local before = { #hammer.sentMessages, #wrench.sentMessages }

    local leader = login(channel, "Grandmaster-Area52")
    announce(leader)
    fixtures.deliver(channel)
    -- Whoever's wait ends first answers; the other hears it and stays quiet.
    fixtures.runTimers(hammer, 5)
    fixtures.deliver(channel)
    fixtures.runTimers(wrench, 5)
    fixtures.deliver(channel)

    local replies = 0
    local index
    local messages = sentSince(hammer, before[1])
    for index = 1, #messages do
        replies = replies + (messages[index].re == "grandmaster-area52" and 1 or 0)
    end
    messages = sentSince(wrench, before[2])
    for index = 1, #messages do
        replies = replies + (messages[index].re == "grandmaster-area52" and 1 or 0)
    end
    test.assertEqual(1, replies)
    test.assertEqual("toolbox-area52", mainOf(leader, "wrench-area52"))
end)

test.test("a relayed answer naming a non-officer author or dated in the future is refused", function()
    local channel = fixtures.newChannel()
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")

    announce(wrench)
    hammer.addon.comm:Broadcast({
        v = 1,
        t = "facts",
        re = "wrench-area52",
        buckets = { 1 },
        facts = {
            { kind = "main", character = "wrench-area52", main = "hammer-area52", at = hammer.time, by = "hammer-area52" },
            { kind = "alias", character = "wrench-area52", alias = "Forged", at = hammer.time + 86400,
                by = "toolbox-area52" },
        },
    })
    fixtures.deliver(channel)

    test.assertEqual("wrench-area52", mainOf(wrench, "wrench-area52"))
    test.assertEqual(nil, aliasOf(wrench, "wrench-area52"))
end)

-- Aliases ---------------------------------------------------------------------

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

-- Upgrading from before sync --------------------------------------------------

-- Saved data from before guild sync (schema 1): Hammer linked to Toolbox
-- and the player named "Tools" by hand, Wrench seeded from the roster.
local function legacyDatabase()
    return {
        schemaVersion = 1,
        guilds = {
            ["Knights of Camelot-Area52"] = {
                characters = {
                    ["toolbox-area52"] = { player = 1, source = "roster" },
                    ["hammer-area52"] = { player = 1, source = "manual" },
                    ["wrench-area52"] = { player = 2, source = "roster" },
                },
                players = {
                    [1] = { main = "toolbox-area52", alias = "Tools", aliasSource = "manual" },
                    [2] = { main = "wrench-area52" },
                },
                nextPlayerId = 3,
            },
        },
    }
end

test.test("an upgraded officer's edits from before sync reach members", function()
    local channel = fixtures.newChannel()
    local member = login(channel, "Wrench-Area52")
    local officer = login(channel, "Toolbox-Area52", { database = legacyDatabase() })
    fixtures.deliver(channel)

    test.assertEqual(2, officer.database.schemaVersion)
    test.assertEqual("toolbox-area52", mainOf(member, "hammer-area52"))
    test.assertEqual("Tools", aliasOf(member, "hammer-area52"))
    local at, by = partitionOf(officer):GetMainStamp("hammer-area52")
    test.assertEqual(officer.time, at)
    test.assertEqual("toolbox-area52", by)
    test.assertEqual(0, (partitionOf(officer):GetMainStamp("wrench-area52")))

    -- Only once: the next scan finds nothing left to upgrade.
    local sent = #officer.sentMessages
    officer.addon.rosterController:OnScanFinished({}, { mode = "incremental", newCharacters = 0 })
    test.assertEqual(sent, #officer.sentMessages)
end)

test.test("an upgraded member's edits from before sync stay local and unofficial", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    local member = login(channel, "Wrench-Area52", { database = legacyDatabase() })
    fixtures.deliver(channel)

    test.assertEqual(0, #member.sentMessages)
    test.assertEqual("toolbox-area52", mainOf(member, "hammer-area52"))
    test.assertEqual("Tools", aliasOf(member, "hammer-area52"))
    test.assertEqual(0, (partitionOf(member):GetMainStamp("hammer-area52")))
    test.assertEqual(0, (partitionOf(member):GetAliasStamp("hammer-area52")))
    test.assertEqual("hammer-area52", mainOf(officer, "hammer-area52"))
end)

test.test("saved data from a newer add-on is never upgraded or sent", function()
    local channel = fixtures.newChannel()
    local database = legacyDatabase()
    database.schemaVersion = 3
    local officer = login(channel, "Toolbox-Area52", { database = database, openRoster = false })

    test.assertEqual(0, #officer.sentMessages)
    test.assertEqual(3, officer.database.schemaVersion)
    test.assertEqual(nil, officer.database.guilds["Knights of Camelot-Area52"].characters["hammer-area52"].mainAt)
end)
