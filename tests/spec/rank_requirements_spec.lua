local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- Each rank's promotion requirements, and the officers' editor for them.
local NOW = 1790000000
local OFFICER = "toolbox-area52"
local OTHER_OFFICER = "gm-area52"
local MEMBER = "hammer-area52"
local RANKS = { "Guild Master", "Officer", "Veteran", "Member", "Initiate" }

local function load()
    return test.newAddon("Core/SyncFacts.lua", "Core/RankRequirements.lua", "Core/PromotionsViewModel.lua")
end

local function isOfficer(key)
    return key == OFFICER or key == OTHER_OFFICER
end

local function newRequirements(saved)
    local addon = load()
    return addon.RankRequirements.Create(saved or {}, { isOfficer = isOfficer }), addon
end

local function labels(requirements, rank)
    local list = {}
    local items = requirements:Items(rank)
    local index
    for index = 1, #items do
        list[index] = items[index].label
    end
    return table.concat(list, ",")
end

test.test("every rank starts with no requirements", function()
    local requirements = newRequirements()

    test.assertEqual("", labels(requirements, 3))
    test.assertEqual(0, #requirements:Ranks())
    test.assertEqual(0, #requirements:Snapshot())
    test.assertEqual(nil, requirements:RankName(3))
end)

test.test("an officer adds, renames, reorders, and deletes items", function()
    local requirements, addon = newRequirements()
    local kinds = addon.RankRequirements

    local added = requirements:Add(4, "Attend an event", kinds.KIND_CHECK_NOTE, "Initiate", OFFICER, NOW)
    test.assertEqual(2, #added, "the item and the rank's name")
    requirements:Add(4, "Read the rules", kinds.KIND_CHECK, "Initiate", OFFICER, NOW)
    requirements:Add(4, " Say hi ", kinds.KIND_CHECK, "Initiate", OFFICER, NOW + 1)
    test.assertEqual("Attend an event,Read the rules,Say hi", labels(requirements, 4))
    local items = requirements:Items(4)
    test.assertEqual("check-note", items[1].kind)
    test.assertTrue(items[1].id ~= items[2].id, "ids stay apart within one second")

    test.assertTrue(requirements:Rename(items[2].id, "Read the guild rules", OFFICER, NOW + 2) ~= nil)
    test.assertTrue(requirements:Move(items[3].id, -1, OFFICER, NOW + 3) ~= nil)
    test.assertEqual("Attend an event,Say hi,Read the guild rules", labels(requirements, 4))
    test.assertEqual(nil, (requirements:Move(items[1].id, -1, OFFICER, NOW + 4)))
    test.assertTrue(requirements:Delete(items[1].id, OFFICER, NOW + 5) ~= nil)
    test.assertEqual("Say hi,Read the guild rules", labels(requirements, 4))
    test.assertEqual(4, requirements:Ranks()[1])
    test.assertEqual("Initiate", requirements:RankName(4))
end)

test.test("the newest change wins, with a fixed tie-break, and a delete beats older edits", function()
    local requirements = newRequirements()
    local item = { t = "item", id = "a", rank = 3, label = "First", kind = "check", position = 1, at = NOW, by = OFFICER }

    test.assertTrue(requirements:Apply(item))
    local renamed = { t = "item", id = "a", rank = 3, label = "Second", kind = "check", position = 1, at = NOW + 5,
        by = OFFICER }
    local older = { t = "item", id = "a", rank = 3, label = "Older", kind = "check", position = 1, at = NOW + 2,
        by = OFFICER }
    test.assertTrue(requirements:Apply(renamed))
    test.assertFalse(requirements:Apply(older))
    test.assertEqual("Second", labels(requirements, 3))
    -- Same second: the author settles it, the same way everywhere.
    local tie = { t = "item", id = "a", rank = 3, label = "Tie", kind = "check", position = 1, at = NOW + 5,
        by = OFFICER .. "z" }
    test.assertFalse(requirements:Apply(tie), "not an officer")
    local tieOther = { t = "item", id = "a", rank = 3, label = "Tie", kind = "check", position = 1, at = NOW + 5,
        by = OTHER_OFFICER }
    test.assertEqual(OTHER_OFFICER > OFFICER, requirements:Apply(tieOther))

    local tombstone = { t = "item", id = "a", rank = 3, label = "Second", kind = "check", position = 1, deleted = true,
        at = NOW + 10, by = OFFICER }
    test.assertTrue(requirements:Apply(tombstone))
    test.assertEqual("", labels(requirements, 3))
    test.assertFalse(requirements:Apply({ t = "item", id = "a", rank = 3, label = "Late edit", kind = "check",
        position = 1, at = NOW + 9, by = OTHER_OFFICER }))
    test.assertEqual("", labels(requirements, 3))
    test.assertEqual(1, #requirements:Snapshot(), "the tombstone is kept")
end)

test.test("changes by non-officers, oversized labels, and too many items are refused", function()
    local requirements, addon = newRequirements()
    local long = string.rep("x", addon.RankRequirements.MAX_LABEL + 1)

    local records, reason = requirements:Add(3, "Hi", "check", "Veteran", MEMBER, NOW)
    test.assertEqual(nil, records)
    test.assertEqual("only officers can change promotion requirements", reason)
    test.assertEqual(nil, (requirements:Add(3, long, "check", "Veteran", OFFICER, NOW)))
    test.assertEqual(nil, (requirements:Add(3, "   ", "check", "Veteran", OFFICER, NOW)))
    test.assertEqual(nil, (requirements:Add(3, "Hi", "dance", "Veteran", OFFICER, NOW)))
    test.assertFalse(requirements:Apply({ t = "item", id = "b", rank = 3, label = "Hi", kind = "check", position = 1,
        at = NOW, by = MEMBER }))
    test.assertFalse(requirements:Apply({ t = "item", id = "b", rank = 3, label = long, kind = "check", position = 1,
        at = NOW, by = OFFICER }))
    test.assertFalse(requirements:Apply("junk"))
    local index
    for index = 1, addon.RankRequirements.MAX_ITEMS do
        test.assertTrue(requirements:Add(3, "Item " .. index, "check", "Veteran", OFFICER, NOW + index) ~= nil)
    end
    test.assertEqual(nil, (requirements:Add(3, "One more", "check", "Veteran", OFFICER, NOW + 100)))
end)

test.test("the editor warns when the game's rank name no longer matches the one stored", function()
    local requirements, addon = newRequirements()
    requirements:Add(3, "Hi", "check", "Veteran", OFFICER, NOW)

    test.assertFalse(requirements:Mismatch(3, "Veteran"))
    test.assertTrue(requirements:Mismatch(3, "Raider"))
    test.assertFalse(requirements:Mismatch(2, "Anything"), "a rank with no requirements has nothing to warn about")

    local model = addon.PromotionsViewModel.Editor({
        requirements = requirements, rank = 3, rankNames = { "Guild Master", "Officer", "Member", "Raider", "Initiate" },
    })
    test.assertContains(model.mismatch, "\"Veteran\"")
    test.assertContains(model.mismatch, "\"Raider\"")
end)

test.test("a snapshot covers what's held only when it has every record, as new or newer", function()
    local requirements = newRequirements()
    local other = newRequirements()
    requirements:Add(3, "Hi", "check", "Veteran", OFFICER, NOW)

    test.assertTrue(requirements:CoveredBy(requirements:Snapshot()))
    test.assertFalse(requirements:CoveredBy(other:Snapshot()))
    test.assertTrue(other:CoveredBy(requirements:Snapshot()))
    local index
    local snapshot = requirements:Snapshot()
    for index = 1, #snapshot do
        test.assertTrue(other:Apply(snapshot[index]))
    end
    test.assertTrue(requirements:CoveredBy(other:Snapshot()))
    requirements:Rename(requirements:Items(3)[1].id, "Hello", OFFICER, NOW + 1)
    test.assertFalse(requirements:CoveredBy(snapshot))
    test.assertFalse(requirements:CoveredBy("junk"))
end)

test.test("the editor shows the picked rank, what it promotes to, and a clear message when empty", function()
    local requirements, addon = newRequirements()
    local Model = addon.PromotionsViewModel

    local model = Model.Editor({ requirements = requirements, rankNames = RANKS })
    test.assertEqual(4, model.rank, "the newest members' rank first")
    test.assertEqual("Initiate (rank 4)", model.rankText)
    test.assertEqual("Promotes to Member", model.nextText)
    test.assertEqual(Model.NONE_ANYWHERE, model.empty)
    -- The guild master's rank has nothing above it.
    test.assertEqual(4, Model.StepRank(1, -1, RANKS))
    test.assertEqual(1, Model.StepRank(4, 1, RANKS))

    requirements:Add(2, "Lead a raid", "check", "Veteran", OFFICER, NOW)
    requirements:Add(2, "Write a guide", "check-note", "Veteran", OFFICER, NOW + 1)
    model = Model.Editor({ requirements = requirements, rankNames = RANKS })
    test.assertEqual(2, model.rank, "a rank with requirements first")
    test.assertEqual(nil, model.empty)
    test.assertEqual("Lead a raid", model.items[1].label)
    test.assertFalse(model.items[1].canUp)
    test.assertTrue(model.items[1].canDown)
    test.assertEqual("Checkbox, needs a note", model.items[2].kindText)
    test.assertEqual(Model.NONE_HERE, Model.Editor({ requirements = requirements, rank = 3, rankNames = RANKS }).empty)
    test.assertEqual(Model.NO_RANKS, Model.Editor({ requirements = requirements, rankNames = {} }).empty)
end)

test.test("automated items carry their number, which an officer can change", function()
    local requirements, addon = newRequirements()
    local Requirements = addon.RankRequirements

    local _, reason = requirements:Add(4, "", "rank-days", "Initiate", OFFICER, NOW)
    test.assertEqual("a number of days needs to be 1 to 3650", reason)
    test.assertEqual("a level needs to be 1 to 100",
        select(2, requirements:Add(4, "", "level", "Initiate", OFFICER, NOW, 101)))
    local days = requirements:Add(4, "", "char-guild-days", "Initiate", OFFICER, NOW, 7)[1]
    local named = requirements:Add(4, "Two weeks at rank", "rank-days", "Initiate", OFFICER, NOW, 14)[1]
    local player = requirements:Add(4, "", "player-guild-days", "Initiate", OFFICER, NOW, 30)[1]
    local level = requirements:Add(4, "", "level", "Initiate", OFFICER, NOW, 50)[1]
    local plain = requirements:Add(4, "Read the rules", "check", "Initiate", OFFICER, NOW, 9)[1]
    test.assertEqual("In the guild 7 days", days.label)
    test.assertEqual("Player in the guild 30 days", player.label)
    test.assertEqual("Level 50", level.label)
    test.assertEqual(nil, plain.n, "a checkbox has no number")
    test.assertTrue(Requirements.IsAutomated("level"))
    test.assertFalse(Requirements.IsAutomated("check-note"))

    test.assertTrue(requirements:SetNumber(days.id, 10, OFFICER, NOW) ~= nil)
    test.assertEqual(10, requirements:Item(days.id).n)
    test.assertEqual("In the guild 10 days", requirements:Item(days.id).label, "a default label follows the number")
    requirements:SetNumber(named.id, 21, OFFICER, NOW)
    test.assertEqual("Two weeks at rank", requirements:Item(named.id).label, "a label the officer typed stays")
    test.assertEqual("only an automated item has a number", select(2, requirements:SetNumber(plain.id, 3, OFFICER, NOW)))
    test.assertEqual(nil, (requirements:SetNumber(level.id, 0, OFFICER, NOW)))
    test.assertEqual(nil, (requirements:SetNumber(level.id, 60, MEMBER, NOW)), "officers only")

    -- A record without its number, or a checkbox with one, is refused.
    test.assertFalse(Requirements.IsRecord({ t = "item", id = "x", rank = 4, label = "Level", kind = "level",
        position = 9, at = NOW, by = OFFICER }))
    test.assertFalse(Requirements.IsRecord({ t = "item", id = "x", rank = 4, label = "Read", kind = "check", n = 3,
        position = 9, at = NOW, by = OFFICER }))

    local model = addon.PromotionsViewModel.Editor({ requirements = requirements, rank = 4, rankNames = RANKS })
    test.assertEqual("Character days in guild: 10", model.items[1].kindText)
    test.assertEqual(10, model.items[1].n)
end)

-- Sharing -----------------------------------------------------------------------

-- Add-ons named in `names` on one fake guild channel; timers wait for
-- `hub:runTimers()`, delivering after each.
local function newHub(names)
    local addon = load()
    local hub = { queue = {}, timers = {}, nodes = {}, sent = 0 }
    local index
    for index = 1, #names do
        local node = { key = names[index], saved = {}, changes = 0 }
        node.requirements = function()
            return addon.RankRequirements.Create(node.saved, { isOfficer = isOfficer })
        end
        node.sync = addon.RankRequirements.CreateSync({
            store = node.requirements,
            selfKey = function()
                return node.key
            end,
            senderKey = function(sender)
                return sender
            end,
            isOfficer = isOfficer,
            announce = function(message)
                hub.sent = hub.sent + 1
                table.insert(hub.queue, { from = node.key, message = message })
            end,
            after = function(_, callback)
                table.insert(hub.timers, callback)
                return true
            end,
            onChange = function()
                node.changes = node.changes + 1
            end,
        })
        hub.nodes[names[index]] = node
        table.insert(hub.nodes, node)
    end
    function hub:deliver()
        while self.queue[1] ~= nil do
            local item = table.remove(self.queue, 1)
            local nodeIndex
            for nodeIndex = 1, #self.nodes do
                self.nodes[nodeIndex].sync:OnMessage(item.message, item.from)
            end
        end
    end
    function hub:runTimers()
        self:deliver()
        while self.timers[1] ~= nil do
            table.remove(self.timers, 1)()
            self:deliver()
        end
    end
    return hub
end

test.test("a change reaches every add-on, and one that logs in later catches up", function()
    local hub = newHub({ OFFICER, OTHER_OFFICER, MEMBER })
    local officer = hub.nodes[OFFICER]

    officer.sync:Share(officer.requirements():Add(3, "Hi", "check", "Veteran", OFFICER, NOW))
    hub:deliver()
    test.assertEqual("Hi", labels(hub.nodes[MEMBER].requirements(), 3))
    test.assertEqual(1, hub.nodes[MEMBER].changes)

    -- Someone with nothing asks; one answer covers it.
    local late = newHub({ OFFICER, OTHER_OFFICER, "late-area52" })
    late.nodes[OFFICER].saved = officer.saved
    late.nodes[OTHER_OFFICER].saved = hub.nodes[OTHER_OFFICER].saved
    late.nodes["late-area52"].sync:AskOnce()
    late:runTimers()
    test.assertEqual("Hi", labels(late.nodes["late-area52"].requirements(), 3))
    test.assertEqual(2, late.sent, "one ask and one answer: the first answer covered the second officer's")
    test.assertFalse(late.nodes["late-area52"].sync:AskOnce(), "once a session")
end)

-- In the composed add-on -----------------------------------------------------------

local NAMES = {
    Forever = { "Tool Box", "Hammer Smith" },
    Retail = { "Toolbox-Area52", "Hammer-Area52" },
}

local function guild(profile)
    local names = NAMES[profile]
    return {
        name = "Knights of Camelot",
        realm = profile == "Retail" and "Area 52" or "Camelot",
        members = {
            { name = names[1], class = "WARRIOR", level = 60, rank = 1, rankName = "Officer", online = true,
                zone = "Ironforge" },
            { name = names[2], class = "MAGE", level = 42, rank = 3, rankName = "Member", online = true,
                zone = "Ironforge" },
        },
    }
end

local function login(profile, channel, playerName)
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = playerName })
    world.time = channel.time or world.time
    channel.time = world.time
    fixtures.joinChannel(channel, world)
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world
end

local function settle(channel, seconds)
    local step
    for step = 1, seconds do
        local index
        for index = 1, #channel.worlds do
            fixtures.runTimers(channel.worlds[index], 1)
        end
        fixtures.deliver(channel)
    end
end

local function hasTab(addon, id)
    local tabs = addon.pages:Tabs()
    local index
    for index = 1, #tabs do
        if tabs[index].id == id then
            return true
        end
    end
    return false
end

for profileIndex = 1, #fixtures.PROFILES do
    local profile = fixtures.PROFILES[profileIndex]
    local names = NAMES[profile]

    test.test(profile .. " officers edit requirements on the officer-only Promotions tab, and members get them", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, names[1])
        local hammer = login(profile, channel, names[2])
        settle(channel, 5)

        test.assertTrue(hasTab(tool.addon, "promotions"))
        test.assertFalse(hasTab(hammer.addon, "promotions"))
        local model = tool.addon.promotions.view()
        test.assertEqual(tool.addon.PromotionsViewModel.NONE_ANYWHERE, model.empty)

        test.assertTrue(tool.addon.promotions.add("Attend an event", true))
        test.assertTrue(tool.addon.promotions.add("Read the rules", false))
        model = tool.addon.promotions.view()
        test.assertEqual(2, #model.items)
        test.assertTrue(tool.addon.promotions.move(model.items[2].id, -1))
        model = tool.addon.promotions.view()
        test.assertEqual("Attend an event", model.items[2].label)
        test.assertTrue(tool.addon.promotions.rename(model.items[2].id, "Attend a guild event"))
        settle(channel, 5)

        local memberView = hammer.addon.promotions.view()
        test.assertEqual(model.rank, memberView.rank)
        test.assertEqual("Read the rules", memberView.items[1].label)
        test.assertEqual("Attend a guild event", memberView.items[2].label)
        local ok, reason = hammer.addon.promotions.add("Sneaky", false)
        test.assertFalse(ok)
        test.assertEqual("only officers can change promotion requirements", reason)

        test.assertTrue(tool.addon.promotions.delete(memberView.items[1].id))
        settle(channel, 5)
        test.assertEqual(1, #hammer.addon.promotions.view().items)

        -- A member who logs in later catches up.
        channel.time = tool.time
        local late = login(profile, channel, names[2])
        test.assertEqual(0, #late.addon.promotions.view().items)
        settle(channel, 200)
        test.assertEqual("Attend a guild event", late.addon.promotions.view().items[1].label)
    end)
end
