local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local NOW = 1790000000

local function load()
    return test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/GroupFinderProtocol.lua",
        "Core/GroupBoard.lua", "Core/JoinRequests.lua", "Core/GroupCandidates.lua", "Adapters/GroupFinderWindow.lua")
end

local function slots(filled)
    local list = {
        { r = "tank" }, { r = "healer" }, { r = "dps" }, { r = "dps" }, { r = "dps" },
    }
    local index
    for index = 1, #(filled or {}) do
        local entry = filled[index]
        list[entry.at] = { r = list[entry.at].r, n = entry.n, l = entry.l, k = entry.k, c = entry.c, w = entry.w }
    end
    return list
end

local DEADMINES = { name = "The Deadmines", minLevel = 17, maxLevel = 26 }
local STRAT = { name = "Stratholme", minLevel = 58, maxLevel = 60 }

-- The protocol ----------------------------------------------------------------

test.test("protocol: a group, its end, offers, answers, role changes and alts are checked", function()
    local protocol = load().GroupFinderProtocol
    local group = protocol.Group(DEADMINES, slots({ { at = 1, n = "Tool", l = 24, k = "tool", c = "WARRIOR" } }))
    test.assertTrue(protocol.IsValid(group))
    test.assertTrue(protocol.IsValid(protocol.GroupEnd()))
    local option = { role = "tank", key = "hammer", name = "Hammer", level = 22 }
    test.assertTrue(protocol.IsValid(protocol.Offer("tool", "hammer:offer:1", option)))
    test.assertTrue(protocol.IsValid(protocol.OfferAnswer("hammer", "hammer:offer:1", true)))
    test.assertTrue(protocol.IsValid(protocol.Role("tool", "healer")))
    test.assertTrue(protocol.IsValid(protocol.Alt("tool", option)))

    -- Four slots, an unknown role, or an open slot carrying a name's details.
    local short = protocol.Group(DEADMINES, slots())
    table.remove(short.s)
    test.assertFalse(protocol.IsValid(short))
    local badRole = protocol.Group(DEADMINES, slots())
    badRole.s[1].r = "bard"
    test.assertFalse(protocol.IsValid(badRole))
    local stray = protocol.Group(DEADMINES, slots())
    stray.s[2].l = 20
    test.assertFalse(protocol.IsValid(stray))
    test.assertFalse(protocol.IsValid(protocol.Role("tool", "bard")))
    test.assertFalse(protocol.IsValid(protocol.Offer("tool", "id", { role = "tank", key = "hammer", name = "Hammer" })))
end)

-- GroupBoard --------------------------------------------------------------------

test.test("board: groups heard are listed near the level first, grey ones after, until they end or go stale", function()
    local addon = load()
    local protocol = addon.GroupFinderProtocol
    local board = addon.GroupBoard.Create()
    board:OnGroup(protocol.Group(STRAT, slots({ { at = 1, n = "Zap", l = 60 } })), "zap", "Zap-Area52", NOW)
    board:OnGroup(protocol.Group(DEADMINES, slots({ { at = 3, n = "Tool", l = 22 }, { at = 1, n = "Bolt", l = 23 } })),
        "tool", "Tool-Area52", NOW)

    local groups = board:Groups(25, NOW + 10)
    test.assertEqual(2, #groups)
    test.assertEqual("Tool", groups[1].label)
    test.assertEqual(2, addon.GroupBoard.Filled(groups[1]))
    test.assertTrue(addon.GroupBoard.Near(groups[1], 25))
    -- Within two levels of the range is near too.
    test.assertTrue(addon.GroupBoard.Near(groups[1], 28))
    test.assertFalse(addon.GroupBoard.Near(groups[1], 29))
    test.assertFalse(addon.GroupBoard.Near(groups[2], 25))

    board:OnEnd("zap")
    test.assertEqual(1, #board:Groups(25, NOW + 10))
    test.assertEqual(nil, board:Get("tool", NOW + addon.GroupBoard.STALE_SECONDS))
end)

test.test("board: an offer waits for the organizer's answer, and goes unanswered after a while", function()
    local addon = load()
    local board = addon.GroupBoard.Create()
    local option = { role = "tank", key = "hammer", name = "Hammer", level = 22 }
    board:Offer("tool", "offer-1", option, NOW)

    test.assertEqual(addon.GroupBoard.SENT, board:OfferFor("tool", NOW).state)
    -- An answer for another offer, or from another organizer, is ignored.
    test.assertEqual(nil, board:OnOfferAnswer("offer-2", "tool", true))
    test.assertEqual(nil, board:OnOfferAnswer("offer-1", "zap", true))
    test.assertEqual(addon.GroupBoard.ACCEPTED, board:OnOfferAnswer("offer-1", "tool", true).state)

    board:Offer("zap", "offer-3", option, NOW)
    test.assertEqual(addon.GroupBoard.EXPIRED, board:OfferFor("zap", NOW + addon.GroupBoard.OFFER_SECONDS).state)
end)

test.test("board: an accepted offer is withdrawn once the group no longer holds its character", function()
    local addon = load()
    local board = addon.GroupBoard.Create()
    local option = { role = "healer", key = "hammer", name = "Hammer", level = 22 }
    board:Offer("tool", "offer-1", option, NOW)
    board:OnOfferAnswer("offer-1", "tool", true)
    local group = addon.GroupFinderProtocol.Group(DEADMINES, slots({ { at = 2, n = "Hammer", l = 22, k = "hammer", w = true } }))
    board:OnGroup(group, "tool", "Tool", NOW)
    test.assertEqual(addon.GroupBoard.ACCEPTED, board:OfferFor("tool", NOW).state)

    -- The organizer cancelled it: the next announcement drops Hammer.
    board:OnGroup(addon.GroupFinderProtocol.Group(DEADMINES, slots({})), "tool", "Tool", NOW + 1)
    test.assertEqual(addon.GroupBoard.WITHDRAWN, board:OfferFor("tool", NOW + 1).state)

    -- An announcement sent before the accept, arriving late, doesn't stick.
    board:OnGroup(group, "tool", "Tool", NOW + 2)
    test.assertEqual(addon.GroupBoard.ACCEPTED, board:OfferFor("tool", NOW + 2).state)
end)

-- GroupSession -------------------------------------------------------------------

local ME = { key = "Player-1", name = "Me", classToken = "WARRIOR", inGuild = true, isPlayer = true, rosterKey = "me" }

local function session(addon)
    local made = addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    made:Start("dm")
    return made
end

test.test("session: an accepted offer takes its slot as an invitee; one for a filled role is turned down", function()
    local addon = load()
    local group = session(addon)
    group:UpdateParty({ ME }, false)

    local offer = group:Offer({ id = "o1", from = "hammer", sender = "Hammer", role = "healer",
        character = { key = "hammer", name = "Hammer", level = 22 } }, NOW)
    test.assertTrue(offer ~= nil)
    test.assertEqual(1, #group:Offers())
    local taken, request = group:AcceptOffer("o1", NOW, "me", 7)
    test.assertEqual(offer, taken)
    test.assertEqual(addon.GroupSession.ACCEPTED, request.state)
    test.assertEqual(7, request.playerId)
    test.assertEqual("Hammer", group:Slots()[2].member.name)
    test.assertEqual(0, #group:Offers())

    -- The healer slot is taken now: another offer for it is refused.
    test.assertEqual(nil, group:Offer({ id = "o2", from = "wrench", sender = "Wrench", role = "healer",
        character = { key = "wrench", name = "Wrench", level = 22 } }, NOW))
    -- An offer left too long is dropped, and so is one whose role fills
    -- while it waits.
    group:Offer({ id = "o3", from = "zap", sender = "Zap", role = "dps",
        character = { key = "zap", name = "Zap", level = 22 } }, NOW)
    test.assertEqual(0, #group:ExpireOffers(NOW + 1))
    test.assertEqual("o3", group:ExpireOffers(NOW + addon.GroupSession.REQUEST_SECONDS)[1].id)
    group:Offer({ id = "o4", from = "zap", sender = "Zap", role = "dps",
        character = { key = "zap", name = "Zap", level = 22 } }, NOW)
    local index
    for index = 1, 3 do
        group:Accept({ key = "dps" .. index }, { role = "dps", key = "dps" .. index, name = "D" .. index, level = 22 },
            NOW, "me")
    end
    test.assertEqual("o4", group:ExpireOffers(NOW + 1)[1].id)
end)

test.test("session: a party member can change to an open role their class fills, and come as an alt", function()
    local addon = load()
    local group = session(addon)
    local hammer = { key = "Player-2", name = "Hammer", classToken = "PALADIN", inGuild = true, rosterKey = "hammer" }
    group:UpdateParty({ ME, hammer }, true)
    -- The paladin defaulted to healer (the warrior took tank).
    test.assertEqual("Hammer", group:Slots()[2].member.name)

    test.assertTrue(group:MemberByRosterKey("hammer") == hammer)
    test.assertTrue(group:ChangeRole("Player-2", "dps"))
    test.assertEqual("Hammer", group:Slots()[3].member.name)
    -- Not to a taken role (tank), nor to one the class can't fill (a
    -- warrior healing).
    test.assertFalse(group:ChangeRole("Player-2", "tank"))
    test.assertFalse(group:ChangeRole("Player-1", "healer"))

    -- Hammer will come as their alt Bolt instead, as DPS: Bolt holds the
    -- slot, waiting, and Hammer takes none.
    local request = group:Accept({ playerId = 3, key = "hammer", label = "Hammer" },
        { role = "dps", key = "bolt", name = "Bolt", level = 23 }, NOW, "me", "Player-2")
    test.assertTrue(request ~= nil)
    local names = {}
    local index
    for index, slot in ipairs(group:Slots()) do
        names[index] = slot.member and slot.member.name or "open"
    end
    test.assertEqual("Me,open,Bolt,open,open", table.concat(names, ","))
    test.assertEqual("waiting", group:InviteState(group:Slots()[3], function() return false end))

    -- Once Bolt joins, Hammer (still listed, offline) takes no slot.
    group:UpdateParty({ ME, hammer, { key = "Player-3", name = "Bolt", classToken = "SHAMAN", rosterKey = "bolt" } }, true)
    test.assertEqual("Player-3", group:Slots()[3].member.key)
    test.assertEqual(nil, group:Slots()[2].member)
end)

test.test("session: the guild hears each slot's name, level, key, class, and whether they're still coming", function()
    local addon = load()
    local group = session(addon)
    group:UpdateParty({ ME }, false)
    group:Accept({ key = "hammer", label = "Hammer" }, { role = "healer", key = "hammer", name = "Hammer", level = 22 },
        NOW, "me")

    local summary = group:Summary()
    test.assertEqual("tank", summary[1].r)
    test.assertEqual("Me", summary[1].n)
    test.assertEqual("me", summary[1].k)
    test.assertEqual("WARRIOR", summary[1].c)
    test.assertEqual(nil, summary[1].w)
    test.assertEqual("hammer", summary[2].k)
    test.assertEqual(true, summary[2].w)
    test.assertEqual(nil, summary[3].n)
    test.assertTrue(addon.GroupFinderProtocol.IsValid(addon.GroupFinderProtocol.Group(DEADMINES, summary)))
end)

-- The window ----------------------------------------------------------------------

local function newWindow(addon, options)
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    options.dungeons = function() return addon.DungeonCatalog.Create({}) end
    options.playerLevel = function() return 24 end
    options.session = options.session or addon.GroupSession.Create(addon.RoleCatalog.For("forever"))
    options.roles = addon.RoleCatalog.For("forever")
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), options)
    window:Opened()
    return window
end

local function boardGroup(addon, filled, dungeon)
    local board = addon.GroupBoard.Create()
    board:OnGroup(addon.GroupFinderProtocol.Group(dungeon or DEADMINES, slots(filled)), "tool", "Tool-Area52", NOW)
    return board:Get("tool", NOW)
end

test.test("group finder window: groups being formed head the column, far ones grey, and a click shows one", function()
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/GroupFinderProtocol.lua",
        "Core/GroupBoard.lua", "Core/JoinRequests.lua", "Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    local near = boardGroup(addon, { { at = 1, n = "Tool", l = 24, k = "tool" } })
    local far = boardGroup(addon, {}, STRAT)
    far.id, far.label = "zap", "Zap"
    local offers = {}
    local window = newWindow(addon, {
        groups = function() return { near, far } end,
        boardGroup = function(id) return id == "tool" and near or nil end,
        selfKey = function() return "hammer" end,
        fillOptions = function(_, role)
            if role == "healer" then
                return { { role = "healer", key = "spark", name = "Spark", level = 23 },
                    { role = "healer", key = "hammer", name = "Hammer", level = 24 } }
            end
            return {}
        end,
        offer = function(group, option) table.insert(offers, group.id .. " " .. option.key) end,
    })

    local lines = window.suggestionLines
    test.assertContains(lines[1].text, "Groups forming")
    test.assertEqual("Tool: The Deadmines (17–26), 1/5", lines[2].text)
    test.assertContains(lines[3].text, "|cff808080Zap: Stratholme")

    window.suggestionHovers[2].frame.scripts.OnMouseUp()
    test.assertFalse(window.picker.shown)
    test.assertTrue(window.board.shown)
    test.assertEqual("Tool's group", window.boardOwner.text)
    test.assertEqual("Dungeon: The Deadmines (17–26)", window.dungeonText.text)
    test.assertTrue(window.backButton.shown)
    -- Only the open healer slot the player could fill offers Fill Slot, on
    -- the character they're on.
    test.assertFalse(window.boardRows[1].fill.shown)
    test.assertTrue(window.boardRows[2].fill.shown)
    test.assertEqual("Fill Slot", window.boardRows[2].fill.text)
    -- Its label stays on one line inside the button.
    test.assertEqual(false, window.boardRows[2].fill:GetFontString().wordWrap)
    test.assertFalse(window.boardRows[3].fill.shown)
    -- No role or alt buttons: the player isn't in this group.
    test.assertFalse(window.roleButtons.tank.shown)
    test.assertFalse(window.altLabel.shown)

    window.boardRows[2].fill.scripts.OnClick()
    test.assertEqual("tool hammer", offers[1])

    window.backButton.scripts.OnClick()
    test.assertTrue(window.picker.shown)
    test.assertFalse(window.board.shown)
end)

test.test("group finder window: a slot only alts fit offers Fill as Alt, with a menu of those alts", function()
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/GroupFinderProtocol.lua",
        "Core/GroupBoard.lua", "Core/JoinRequests.lua", "Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    local group = boardGroup(addon, { { at = 1, n = "Tool", l = 24, k = "tool" } })
    local offers = {}
    local window = newWindow(addon, {
        groups = function() return { group } end,
        boardGroup = function() return group end,
        selfKey = function() return "hammer" end,
        fillOptions = function(_, role)
            if role == "healer" then
                return { { role = "healer", key = "spark", name = "Sparkleshine", level = 23 },
                    { role = "healer", key = "bolt", name = "Bolt", level = 22 } }
            end
            return {}
        end,
        offer = function(shown, option) table.insert(offers, shown.id .. " " .. option.key) end,
    })
    -- The game's menu, recorded: its title and buttons.
    local menu
    window.environment.MenuUtil = {
        CreateContextMenu = function(_, build)
            menu = { buttons = {} }
            build(nil, {
                CreateTitle = function(_, title) menu.title = title end,
                CreateButton = function(_, text, onClick)
                    table.insert(menu.buttons, { text = text, onClick = onClick })
                end,
            })
        end,
    }

    window.suggestionHovers[2].frame.scripts.OnMouseUp()
    -- The player's character doesn't fit, so no name goes on the button.
    test.assertTrue(window.boardRows[2].fill.shown)
    test.assertEqual("Fill as Alt", window.boardRows[2].fill.text)

    window.boardRows[2].fill.scripts.OnClick()
    test.assertEqual(0, #offers)
    test.assertEqual("Fill as", menu.title)
    test.assertEqual("Sparkleshine (23)", menu.buttons[1].text)
    test.assertEqual("Bolt (22)", menu.buttons[2].text)

    menu.buttons[2].onClick()
    test.assertEqual("tool bolt", offers[1])
end)

test.test("group finder window: an offer waiting for an answer hides Fill Slot and says so", function()
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/GroupFinderProtocol.lua",
        "Core/GroupBoard.lua", "Core/JoinRequests.lua", "Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    local group = boardGroup(addon, {})
    local window = newWindow(addon, {
        groups = function() return { group } end,
        boardGroup = function() return group end,
        fillOptions = function(_, role) return { { role = role, key = "bolt", name = "Bolt", level = 23 } } end,
        offerFor = function() return { state = addon.GroupBoard.SENT, name = "Bolt" } end,
    })
    window:ViewGroup("tool")

    test.assertFalse(window.boardRows[1].fill.shown)
    test.assertEqual("Offer sent to Tool. Waiting for their answer.", window.offerText.text)
end)

test.test("group finder window: a player already holding a slot, not in the party yet, gets no Fill Slot", function()
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/GroupFinderProtocol.lua",
        "Core/GroupBoard.lua", "Core/JoinRequests.lua", "Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    -- Their slot comes after the open ones.
    local group = boardGroup(addon, { { at = 5, n = "Hammer", l = 24, k = "hammer", w = true } })
    local window = newWindow(addon, {
        groups = function() return { group } end,
        boardGroup = function() return group end,
        selfKey = function() return "hammer" end,
        fillOptions = function(_, role) return { { role = role, key = "hammer", name = "Hammer", level = 24 } } end,
    })
    window:ViewGroup("tool")

    local index
    for index = 1, 4 do
        test.assertFalse(window.boardRows[index].fill.shown)
    end
end)

test.test("group finder window: in the organizer's party, the group shows with role and alt buttons only", function()
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/GroupSession.lua", "Core/GroupFinderProtocol.lua",
        "Core/GroupBoard.lua", "Core/JoinRequests.lua", "Core/DungeonCatalog.lua", "Adapters/GroupFinderWindow.lua")
    local group = boardGroup(addon, {
        { at = 1, n = "Tool", l = 24, k = "tool", c = "WARRIOR" },
        { at = 2, n = "Hammer", l = 24, k = "hammer", c = "PALADIN" },
    })
    local actions = {}
    local window = newWindow(addon, {
        partyGroup = function() return group end,
        selfKey = function() return "hammer" end,
        fillOptions = function(_, role) return { { role = role, key = "hammer", name = "Hammer", level = 24 } } end,
        setRole = function(_, role) table.insert(actions, "role " .. role) end,
        altOptions = function() return { { role = "dps", key = "bolt", name = "Bolt", level = 23 } } end,
        joinAsAlt = function(_, option) table.insert(actions, "alt " .. option.key) end,
    })

    test.assertTrue(window.board.shown)
    test.assertEqual("Tool's group, which you're in", window.boardOwner.text)
    test.assertFalse(window.backButton.shown)
    test.assertFalse(window.boardRows[3].fill.shown)
    -- A paladin: healer (theirs, can't be picked again) and DPS (open);
    -- tank is taken.
    test.assertFalse(window.roleButtons.tank.shown)
    test.assertTrue(window.roleButtons.healer.shown)
    test.assertTrue(window.roleButtons.dps.shown)
    window.roleButtons.dps.scripts.OnClick()
    test.assertEqual("role dps", actions[1])

    test.assertTrue(window.altLabel.shown)
    test.assertEqual("DPS — Bolt (23)", window.altButtons[1].button.text)
    test.assertFalse(window.altButtons[2].button.shown)
    window.altButtons[1].button.scripts.OnClick()
    test.assertEqual("alt bolt", actions[2])
end)

-- The composed add-on --------------------------------------------------------------

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box", class = "WARRIOR", level = 60, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge" },
            { name = "Zap Arcane", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
            { name = "Spark Arcane", class = "MAGE", level = 59, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 0, 1, 0 }, note = ">Zap Arcane" },
            { name = "Hammer Smith", class = "PALADIN", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Forever", { guild = guild(), playerName = playerName })
    fixtures.joinChannel(channel, world)
    world.grouped = false
    world.environment.IsInGroup = function() return world.grouped end
    local addon = fixtures.loadAddon(world)
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

-- Puts `units` (unit -> { name, guid, class }) in the world's party.
local function joinParty(world, units)
    local environment = world.environment
    environment.UnitExists = function(unit) return units[unit] ~= nil end
    environment.UnitName = function(unit) return units[unit] and units[unit].name end
    environment.UnitGUID = function(unit) return units[unit] and units[unit].guid end
    environment.UnitClass = function(unit)
        return "Localized", units[unit] and units[unit].class, 1
    end
    environment.UnitLevel = function() return 60 end
    environment.UnitIsInMyGuild = function(unit) return units[unit] ~= nil end
    world.grouped = true
    fixtures.fire(world, "GROUP_ROSTER_UPDATE")
end

-- The organizer starts a group for Stratholme and the guild hears of it.
local function startGroup(channel, organizer)
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("strat")
    organizer.groupFinderOptions.refresh()
    fixtures.deliver(channel)
end

test.test("composed: a guildmate sees the group being formed, offers to fill a slot, and the organizer accepts", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    fixtures.deliver(channel)
    startGroup(channel, organizer)
    fixtures.openGroupFinder(hammer)
    fixtures.deliver(channel)

    local options = hammer.groupFinderOptions
    local groups = options.groups()
    test.assertEqual(1, #groups)
    test.assertEqual("Tool Box", groups[1].label)
    test.assertEqual("Stratholme", groups[1].dungeon.name)

    -- Hammer offers to heal.
    local fill = options.fillOptions(groups[1], "healer")
    test.assertEqual("hammer smith-camelot", fill[1].key)
    options.offer(groups[1], fill[1])
    fixtures.deliver(channel)

    test.assertEqual(1, #organizer.shown)
    test.assertEqual("Hammer Smith offers to fill your Healer slot", organizer.shown[1].heading)
    organizer.handlers.accept(organizer.shown[1].id, 1)
    fixtures.deliver(channel)

    local slot = organizer.addon.groupSession:Slots()[2]
    test.assertEqual("Hammer Smith", slot.member.name)
    test.assertEqual("ready", organizer.addon.groupSession:InviteState(slot, organizer.groupFinderOptions.isOnline))
    test.assertEqual(0, #organizer.shown)
    test.assertEqual(hammer.addon.GroupBoard.ACCEPTED, options.offerFor(groups[1]).state)
    test.assertContains(hammer.messages[#hammer.messages], "Tool Box accepted your offer. They'll invite you.")
    -- The guild hears the slot is taken, still coming.
    local heard = options.groups()[1]
    test.assertEqual("Hammer Smith", heard.slots[2].name)
    test.assertTrue(heard.slots[2].coming)

    -- Ending the group takes it off the board.
    organizer.addon.groupSession:End()
    organizer.groupFinderOptions.changed()
    fixtures.deliver(channel)
    test.assertEqual(0, #options.groups())
end)

test.test("composed: an accepted offer the organizer cancels can be made again", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    fixtures.deliver(channel)
    startGroup(channel, organizer)
    fixtures.openGroupFinder(hammer)
    fixtures.deliver(channel)

    local options = hammer.groupFinderOptions
    local group = options.groups()[1]
    options.offer(group, options.fillOptions(group, "healer")[1])
    fixtures.deliver(channel)
    organizer.handlers.accept(organizer.shown[1].id, 1)
    fixtures.deliver(channel)

    local slot = organizer.addon.groupSession:Slots()[2]
    organizer.groupFinderOptions.cancelRequest(slot.request)
    organizer.groupFinderOptions.changed()
    fixtures.deliver(channel)

    group = options.groups()[1]
    test.assertEqual(nil, group.slots[2].name)
    test.assertEqual(hammer.addon.GroupBoard.WITHDRAWN, options.offerFor(group).state)
    test.assertEqual(1, #options.fillOptions(group, "healer"))
end)

test.test("composed: a turned-down offer says so, and the organizer's prompt closes", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    fixtures.deliver(channel)
    startGroup(channel, organizer)
    fixtures.openGroupFinder(hammer)
    fixtures.deliver(channel)

    local options = hammer.groupFinderOptions
    local group = options.groups()[1]
    options.offer(group, options.fillOptions(group, "dps")[1])
    fixtures.deliver(channel)
    organizer.handlers.decline(organizer.shown[1].id)
    fixtures.deliver(channel)

    test.assertEqual(0, #organizer.shown)
    test.assertEqual(hammer.addon.GroupBoard.DECLINED, options.offerFor(group).state)
    test.assertContains(hammer.messages[#hammer.messages], "Tool Box turned down your offer.")
end)

test.test("composed: in the organizer's party, a member sees the group, changes role, and comes as an alt", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Tool Box")
    local hammer = login(channel, "Hammer Smith")
    local zap = login(channel, "Zap Arcane")
    fixtures.deliver(channel)
    fixtures.openGroupFinder(organizer)
    organizer.addon.groupSession:Start("strat")
    joinParty(organizer, {
        player = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
        party1 = { name = "Hammer", guid = "Player-1-Hammer Smith", class = "PALADIN" },
        party2 = { name = "Zap", guid = "Player-1-Zap Arcane", class = "MAGE" },
    })
    fixtures.deliver(channel)
    local partyOf = {
        party1 = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
    }
    partyOf.player = { name = "Hammer", guid = "Player-1-Hammer Smith", class = "PALADIN" }
    joinParty(hammer, partyOf)
    joinParty(zap, {
        player = { name = "Zap", guid = "Player-1-Zap Arcane", class = "MAGE" },
        party1 = { name = "Tool", guid = "Player-1-Tool Box", class = "WARRIOR" },
    })
    fixtures.openGroupFinder(hammer)
    fixtures.openGroupFinder(zap)
    fixtures.deliver(channel)

    -- Hammer, a paladin, healing by default, moves to DPS.
    local group = hammer.groupFinderOptions.partyGroup()
    test.assertEqual("Tool Box", group.label)
    test.assertEqual("Hammer", group.slots[2].name)
    hammer.groupFinderOptions.setRole(group, "dps")
    fixtures.deliver(channel)
    local names = {}
    local index
    for index, slot in ipairs(organizer.addon.groupSession:Slots()) do
        names[index] = slot.member and slot.member.name or "open"
    end
    test.assertEqual("Tool,open,Hammer,Zap,open", table.concat(names, ","))
    test.assertEqual("Hammer", hammer.groupFinderOptions.partyGroup().slots[3].name)

    -- Zap will come as their alt Spark instead.
    local alts = zap.groupFinderOptions.altOptions(zap.groupFinderOptions.partyGroup())
    test.assertEqual("spark arcane-camelot", alts[1].key)
    zap.groupFinderOptions.joinAsAlt(zap.groupFinderOptions.partyGroup(), alts[1])
    fixtures.deliver(channel)
    local slot = organizer.addon.groupSession:Slots()[3]
    test.assertEqual("Spark Arcane", slot.member.name)
    test.assertEqual("waiting", organizer.addon.groupSession:InviteState(slot, organizer.groupFinderOptions.isOnline))
    test.assertContains(organizer.messages[#organizer.messages], "Zap Arcane will come as Spark Arcane")
    test.assertContains(zap.messages[#zap.messages], "Log over to Spark Arcane")
end)

test.test("composed: a guildmate holding a slot on an alt is offered nothing to fill", function()
    local channel = fixtures.newChannel()
    local organizer = login(channel, "Tool Box")
    local zap = login(channel, "Zap Arcane")
    fixtures.deliver(channel)
    startGroup(channel, organizer)
    organizer.addon.groupSession:Accept({ key = "zap arcane-camelot", label = "Zap" },
        { role = "dps", key = "spark arcane-camelot", name = "Spark Arcane", level = 59 }, 0, "tool box-camelot")
    organizer.groupFinderOptions.changed()
    fixtures.openGroupFinder(zap)
    fixtures.deliver(channel)

    local options = zap.groupFinderOptions
    local group = options.groups()[1]
    test.assertEqual("spark arcane-camelot", group.slots[3].key)
    test.assertEqual(0, #options.fillOptions(group, "dps"))
end)
