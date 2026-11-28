local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

-- LfgDrawerModel ---------------------------------------------------------------------

local function newModel()
    return test.newAddon("Core/LfgDrawerModel.lua").LfgDrawerModel
end

local function listing(id, listedAt)
    return { id = id, listedAt = listedAt or 1, kind = "dungeon", purpose = id }
end

local function groups(...)
    return { relevant = { ... }, alts = {}, other = {} }
end

test.test("lfg drawer model: the count is the relevant groups, in a party too", function()
    local model = newModel().Create()

    test.assertEqual(0, model:Update({ groups = groups() }).count)
    test.assertEqual(2, model:Update({ groups = groups(listing("a"), listing("b")) }).count)
    test.assertEqual(2, model:Update({ groups = groups(listing("a"), listing("b")), party = { size = 2 } }).count)
end)

test.test("lfg drawer model: a new relevant group glows gold and pulses once, until the drawer opens", function()
    local model = newModel().Create()
    model:Update({ groups = groups() })

    local view = model:Update({ groups = groups(listing("a")) })
    test.assertEqual("gold", view.glow)
    test.assertEqual(1, #view.fresh)

    -- Heard again: still glowing, no new pulse.
    view = model:Update({ groups = groups(listing("a")) })
    test.assertEqual("gold", view.glow)
    test.assertEqual(0, #view.fresh)

    -- Two more: one pulse each.
    view = model:Update({ groups = groups(listing("c"), listing("b"), listing("a")) })
    test.assertEqual(2, #view.fresh)

    model:Seen()
    view = model:Update({ groups = groups(listing("c"), listing("b"), listing("a")) })
    test.assertEqual(nil, view.glow)

    -- A leader listing again later is new again.
    view = model:Update({ groups = groups(listing("a", 50)) })
    test.assertEqual("gold", view.glow)
end)

test.test("lfg drawer model: no glow in a party, in combat, in an instance or in Do Not Disturb", function()
    local Model = newModel()
    local cases = {
        { party = { size = 2 } }, { combat = true }, { instance = true }, { dnd = true },
    }
    local index
    for index = 1, #cases do
        local model = Model.Create()
        local facts = cases[index]
        facts.groups = groups(listing("a"))
        local view = model:Update(facts)
        test.assertEqual(nil, view.glow)
        test.assertEqual(0, #view.fresh)
        test.assertEqual(1, view.count)
    end
end)

test.test("lfg drawer model: a group that appears in combat glows after; one in a party or DND never does", function()
    local Model = newModel()

    local model = Model.Create()
    model:Update({ groups = groups(listing("a")), combat = true })
    test.assertEqual("gold", model:Update({ groups = groups(listing("a")) }).glow)

    model = Model.Create()
    model:Update({ groups = groups(listing("a")), instance = true })
    test.assertEqual("gold", model:Update({ groups = groups(listing("a")) }).glow)

    model = Model.Create()
    model:Update({ groups = groups(listing("a")), party = { size = 3 } })
    test.assertEqual(nil, model:Update({ groups = groups(listing("a")) }).glow)

    model = Model.Create()
    model:Update({ groups = groups(listing("a")), dnd = true })
    test.assertEqual(nil, model:Update({ groups = groups(listing("a")) }).glow)
end)

test.test("lfg drawer model: a group gone from the board stops glowing; orange wins over gold", function()
    local model = newModel().Create()
    model:Update({ groups = groups(listing("a")) })

    test.assertEqual(nil, model:Update({ groups = groups() }).glow)
    test.assertEqual("orange", model:Update({ groups = groups(listing("b")), slotOpen = true }).glow)
    test.assertEqual("gold", model:Update({ groups = groups(listing("b")) }).glow)
end)

test.test("lfg drawer model: the drawer shows the party, else the newest group, else none", function()
    local Model = newModel()
    local model = Model.Create()

    test.assertEqual(Model.NONE, model:Update({ groups = groups() }).top.kind)
    local view = model:Update({ groups = groups(listing("new"), listing("old")) })
    test.assertEqual(Model.NEWEST, view.top.kind)
    test.assertEqual("new", view.top.listing.id)
    view = model:Update({ groups = groups(listing("new")), party = { size = 3, maxSize = 5, label = "Stratholme" } })
    test.assertEqual(Model.PARTY, view.top.kind)
    test.assertEqual("Stratholme", view.top.party.label)
end)

test.test("lfg drawer model: a solo listing is the drawer's top, and still lets groups glow and pulse", function()
    local Model = newModel()
    local model = Model.Create()
    local solo = { solo = true, own = true, size = 1, maxSize = 5, kind = "dungeon", label = "Stratholme" }

    local view = model:Update({ groups = groups(), party = solo })
    test.assertEqual(Model.PARTY, view.top.kind)
    test.assertTrue(view.top.party.solo)
    test.assertEqual("Stratholme", view.top.party.label)

    view = model:Update({ groups = groups(listing("a")), party = solo })
    test.assertEqual("gold", view.glow)
    test.assertEqual(1, #view.fresh)
    -- The drawer still shows the listing, not the newest group.
    test.assertEqual(Model.PARTY, view.top.kind)
    -- Combat still holds a solo lister's pulses back.
    view = model:Update({ groups = groups(listing("b"), listing("a")), party = solo, combat = true })
    test.assertEqual(0, #view.fresh)
    view = model:Update({ groups = groups(listing("b"), listing("a")), party = solo })
    test.assertEqual(1, #view.fresh)
end)

-- The button and its drawer ----------------------------------------------------------

local function newButton()
    local addon = test.newAddon("Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/LfgButton.lua",
        "Core/LfgProtocol.lua", "Core/LfgListing.lua", "Core/LfgDrawerModel.lua")
    local environment = fakeFrames.install({})
    local state = { opened = 0, started = 0, seen = 0 }
    local button = addon.LfgButton.Create({ environment = environment }, {
        frameName = "AgfTestLfgButton",
        shown = function() return true end,
        onOpenBoard = function() state.opened = state.opened + 1 end,
        onHide = function() end,
        onDrawerOpened = function() state.seen = state.seen + 1 end,
        onStartGroup = function() state.started = state.started + 1 end,
        onEditListing = function() state.edited = (state.edited or 0) + 1 end,
        onEndListing = function() state.ended = (state.ended or 0) + 1 end,
        onFindGuildmates = function() state.found = (state.found or 0) + 1 end,
        dungeonIcon = function() return nil end,
    })
    button:Refresh()
    return button, state, addon
end

local NEWEST = {
    id = "tool", kind = "dungeon", purpose = "Stratholme", leader = "Tool", size = 1, maxSize = 5,
    openRoles = { "healer", "dps" },
}

test.test("lfg button: shows the count and the glow it's given, pulsing for each new group", function()
    local button = newButton()
    local pulses = 0
    button.glow.Pulse = function() pulses = pulses + 1 end

    button:Update({ count = 2, glow = "gold", fresh = { NEWEST, NEWEST }, top = { kind = "newest", listing = NEWEST } })

    test.assertEqual(2, button.count.count)
    test.assertTrue(button.count.shown)
    test.assertEqual("gold", button.glow.color)
    test.assertEqual(2, pulses)
    button:Update({ count = 0, fresh = {}, top = { kind = "none" } })
    test.assertFalse(button.count.shown)
    test.assertEqual(nil, button.glow.color)
end)

test.test("lfg button: left-click slides the drawer out and back; its X closes only the drawer", function()
    local button, state = newButton()
    button:Update({ count = 0, fresh = {}, top = { kind = "none" } })

    button.button.scripts.OnClick(button.button, "LeftButton")
    test.assertTrue(button:DrawerOpen())
    test.assertTrue(button.drawer.shown)
    test.assertEqual(1, state.seen)
    button.button.scripts.OnClick(button.button, "LeftButton")
    test.assertFalse(button.drawer.shown)

    button:OpenDrawer()
    button.drawerClose.scripts.OnClick(button.drawerClose)
    test.assertFalse(button.drawer.shown)
    test.assertTrue(button:IsShowing())
    test.assertEqual(0, state.opened)
end)

test.test("lfg button: a click in the drawer that isn't a button opens the board", function()
    local button, state = newButton()
    button:Update({ count = 0, fresh = {}, top = { kind = "none" } })
    button:OpenDrawer()

    button.drawer.scripts.OnMouseUp(button.drawer, "LeftButton")
    test.assertEqual(1, state.opened)

    button.startButton.scripts.OnClick(button.startButton)
    test.assertEqual(1, state.started)
    test.assertEqual(1, state.opened)
end)

test.test("lfg button: the drawer's newest group, none, and the party", function()
    local button, _, addon = newButton()
    button:OpenDrawer()

    button:Update({ count = 1, fresh = {}, top = { kind = "newest", listing = NEWEST } })
    local drawer = button.drawer
    test.assertEqual("NEW FOR YOU", drawer.heading.text)
    test.assertEqual("Stratholme", drawer.purpose.text)
    test.assertEqual("Tool \194\183 1/5 \194\183 needs Healer, DPS", drawer.details.text)
    test.assertEqual(addon.Theme.TEXTURES.dungeon, drawer.iconTexture)
    test.assertTrue(button.askButton.shown)
    -- This leader takes no asks: Whisper instead.
    test.assertEqual("Whisper Tool", button.askButton.label.text)
    test.assertTrue(button.askButton.active)
    test.assertTrue(button.startButton.shown)
    test.assertFalse(drawer.empty.shown)

    button:Update({ count = 0, fresh = {}, top = { kind = "none" } })
    test.assertTrue(drawer.empty.shown)
    test.assertEqual("No groups for you right now", drawer.empty.text)
    test.assertFalse(drawer.purpose.shown)
    test.assertTrue(button.startButton.shown)

    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = {
        kind = "dungeon", label = "Stratholme", size = 3, maxSize = 5, openRoles = { "healer", "dps" },
        note = "Live side", members = { { role = "tank" }, { role = "dps" }, { role = "dps" } },
    } } })
    test.assertEqual("YOUR PARTY", drawer.heading.text)
    test.assertEqual("Stratholme", drawer.party.text)
    test.assertEqual("3/5 \194\183 needs Healer, DPS", drawer.partyDetails.text)
    test.assertEqual("Live side", drawer.note.text)
    -- The slots as the Your listing card shows them: role tiles with their
    -- icons, filled grey, open in color.
    local filled = {}
    local index
    for index = 1, 5 do
        test.assertTrue(drawer.roleTiles[index].shown)
        test.assertTrue(drawer.roleTiles[index].icon.shown)
        filled[index] = drawer.roleTiles[index].filled and "x" or "o"
    end
    test.assertEqual("xoxxo", table.concat(filled))
    test.assertFalse(drawer.anyTiles[1].shown)
    test.assertFalse(button.startButton.shown)

    -- Questing: person tiles, the first `size` filled; a raid: one tile.
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = {
        kind = "questing", label = "Questing in Duskwood", size = 2, maxSize = 5,
    } } })
    test.assertFalse(drawer.roleTiles[1].shown)
    test.assertTrue(drawer.anyTiles[2].filled)
    test.assertFalse(drawer.anyTiles[3].filled)
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = {
        kind = "raid", label = "Raid", size = 12, maxSize = 40,
    } } })
    test.assertTrue(drawer.raidTile.shown)
    test.assertFalse(drawer.raidTile.filled)
    test.assertFalse(drawer.anyTiles[1].shown)

    -- A title too long for one line wraps (at words, within the drawer)
    -- and the drawer grows by the extra line.
    local oneLine = drawer.height
    rawset(drawer.party, "GetNumLines", function() return 2 end)
    rawset(drawer.party, "GetStringHeight", function() return 36 end)
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = {
        kind = "questing", label = "Questing in Stranglethorn Vale", size = 2, maxSize = 5,
    } } })
    test.assertEqual(oneLine + 18, drawer.height)
    test.assertTrue(drawer.party.wordWrap)
end)

test.test("lfg button: a solo listing shows as Open to the guild, with Edit and Stop looking", function()
    local button, state = newButton()
    button:OpenDrawer()
    local drawer = button.drawer
    local party = { kind = "dungeon", label = "Stratholme", size = 1, maxSize = 5, openRoles = { "tank", "healer", "dps" },
        note = "Bring a key", members = { { role = "dps" } }, solo = true, own = true }

    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = party } })
    test.assertEqual("OPEN TO THE GUILD", drawer.heading.text)
    test.assertEqual("Stratholme", drawer.party.text)
    test.assertContains(drawer.partyDetails.text, "1/5")
    test.assertEqual("Bring a key", drawer.note.text)
    test.assertTrue(button.editListingButton.shown)
    test.assertTrue(button.endListingButton.shown)
    test.assertEqual("Stop looking", button.endListingButton.label.text)
    test.assertEqual("Your party stays together but shows as Playing.", button.endListingButton.hint)
    test.assertFalse(button.startButton.shown)

    button.editListingButton.scripts.OnClick(button.editListingButton)
    test.assertEqual(1, state.edited)
    test.assertFalse(button:DrawerOpen())
    button:OpenDrawer()
    button.endListingButton.scripts.OnClick(button.endListingButton)
    test.assertEqual(1, state.ended)

    -- A party that isn't the player's own listing: neither button.
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = { kind = "other", size = 2, maxSize = 5 } } })
    test.assertEqual("YOUR PARTY", drawer.heading.text)
    test.assertFalse(button.editListingButton.shown)
    test.assertFalse(button.endListingButton.shown)
end)

test.test("lfg button: Find guildmates shows for the lister's party, greyed out with the reason", function()
    local button, state = newButton()
    button:OpenDrawer()
    local drawer = button.drawer
    local party = { kind = "dungeon", label = "Stratholme", size = 2, maxSize = 5, members = { { role = "dps" } },
        own = true, find = {} }

    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = party } })
    test.assertTrue(button.findButton.shown)
    test.assertTrue(button.findButton.active)
    local withFind = drawer.height
    button.findButton.scripts.OnClick(button.findButton)
    test.assertEqual(1, state.found)
    test.assertFalse(button:DrawerOpen())

    -- An unlisted party's leader: greyed out, and clicking does nothing.
    button:OpenDrawer()
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = { kind = "other", size = 2, maxSize = 5,
        find = { reason = "List your party to find guildmates" } } } })
    test.assertTrue(button.findButton.shown)
    test.assertFalse(button.findButton.active)
    test.assertEqual("List your party to find guildmates", button.findButton.reason)
    button.findButton.scripts.OnClick(button.findButton)
    test.assertEqual(1, state.found)

    -- Without `find` (not the lister), no button, and a shorter drawer.
    party.find = nil
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = party } })
    test.assertFalse(button.findButton.shown)
    test.assertTrue(drawer.height < withFind)
end)

test.test("lfg button: the party drawer sits its buttons under the text it measures, Ask in guild labeled", function()
    local button = newButton()
    button.options.onAskInGuild = function() end
    button:OpenDrawer()
    local drawer = button.drawer
    -- The game measures the drawer's top at 500 and the details' bottom
    -- at 440 (no note).
    rawset(drawer, "GetTop", function() return 500 end)
    rawset(drawer.partyDetails, "GetBottom", function() return 440 end)
    rawset(drawer.note, "GetText", function() return "" end)
    button.askGuildButton.label:SetText("")
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = { kind = "questing",
        label = "Questing in Alterac Mountains", size = 2, maxSize = 5, own = true, find = {},
        guildLine = "LF3M questing in Alterac Mountains" } } })

    test.assertTrue(button.askGuildButton.shown)
    test.assertEqual("Ask in guild", button.askGuildButton.label.text)
    -- 60 of text, 12 under it, then 3 buttons (26 each, 4 between), 8, the
    -- tiles (22) and 12.
    test.assertEqual(60 + 12 + 3 * 26 + 2 * 4 + 8 + 22 + 12, drawer.height)
end)

-- The composed add-on ----------------------------------------------------------------

local function guild()
    return {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box", class = "WARRIOR", level = 60, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge" },
            { name = "Hammer Smith", class = "PALADIN", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
        },
    }
end

local function login(channel, playerName)
    local world = fixtures.newEnvironment("Forever", { guild = guild(), playerName = playerName })
    world.playerLevel = 60
    world.grouped = false
    world.environment.IsInGroup = function() return world.grouped end
    fixtures.joinChannel(channel, world)
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    -- Only what follows counts (not the login's roster scan line).
    local index
    for index = #world.messages, 1, -1 do
        table.remove(world.messages, index)
    end
    -- Frames that draw, after login so the event frames keep working.
    fakeFrames.install(world.environment)
    addon.lfgButton:Refresh()
    return world, addon
end

-- Tool lists a Stratholme run from the board.
local function toolLists(tool)
    local addon = tool.addon
    test.assertTrue(addon.agfWindow:Open("lfg"))
    local page = addon.lfgPage
    page:StartEditing()
    page.draft.dungeon = addon.DungeonCatalog.For("forever", nil):Get("strat")
    test.assertTrue(page:Save())
end

test.test("Forever a guildmate's group lights the button: count, gold glow, and the drawer shows it", function()
    local channel = fixtures.newChannel()
    local tool = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    fixtures.deliver(channel)

    toolLists(tool)
    fixtures.deliver(channel)

    local button = addon.lfgButton
    test.assertEqual(1, button.count.count)
    test.assertEqual("gold", button.glow.color)
    button.button.scripts.OnClick(button.button, "LeftButton")
    test.assertEqual("Stratholme", button.drawer.purpose.text)
    -- Opening the drawer clears the glow, not the count.
    test.assertEqual(nil, button.glow.color)
    test.assertEqual(1, button.count.count)
    -- No chat line unless asked for.
    test.assertEqual(nil, hammer.messages[1])
end)

test.test("Forever the chat line for new groups is off by default and can be turned on in the LFG popup", function()
    local channel = fixtures.newChannel()
    local tool = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    test.assertFalse(addon.settings:Get("lfgChatLine"))
    addon.agfWindow:Open("lfg")
    addon.agfWindow:ToggleSettingsPopup()
    local switch = addon.agfWindow:Switches("lfgChatLine")[1]
    switch.scripts.OnClick(switch)
    test.assertTrue(addon.settings:Get("lfgChatLine"))

    toolLists(tool)
    fixtures.deliver(channel)

    test.assertContains(hammer.messages[#hammer.messages], "New group for you on the Guild LFG Board: Stratholme")
end)

test.test("lfg auto-list setting: off by default, saved, and unusable saved data reads as off", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertFalse(store:LfgAutoList())
    test.assertTrue(store:SetLfgAutoList(true))
    test.assertTrue(addon.FellowshipStore.Create(database):LfgAutoList())
    test.assertTrue(store:SetLfgAutoList(false))
    test.assertFalse(store:LfgAutoList())
    test.assertFalse(store:SetLfgAutoList("yes"))

    database.lfgAutoList = "corrupt"
    test.assertFalse(store:LfgAutoList())
    test.assertFalse(store:SetLfgAutoList(true))
    test.assertEqual("corrupt", database.lfgAutoList)
end)

test.test("Forever Auto-list my parties is off by default, in the LFG popup and the AddOns options", function()
    local channel = fixtures.newChannel()
    local hammer, addon = login(channel, "Hammer Smith")
    test.assertFalse(addon.settings:Get("lfgAutoList"))
    test.assertTrue(addon.settings:InHost("lfgAutoList", "options"))
    addon.agfWindow:Open("lfg")
    addon.agfWindow:ToggleSettingsPopup()
    local switch = addon.agfWindow:Switches("lfgAutoList")[1]
    test.assertFalse(switch:IsOn())
    test.assertTrue(addon.agfWindow.infoIcons.lfgAutoList ~= nil)
    switch.scripts.OnClick(switch)
    test.assertTrue(addon.settings:Get("lfgAutoList"))
end)

test.test("Forever no glow in a party or in Do Not Disturb, and the drawer shows the party", function()
    local channel = fixtures.newChannel()
    local tool = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    addon.settings:Set("dnd", true)
    toolLists(tool)
    fixtures.deliver(channel)
    test.assertEqual(1, addon.lfgButton.count.count)
    test.assertEqual(nil, addon.lfgButton.glow.color)

    addon.settings:Set("dnd", false)
    hammer.grouped = true
    fixtures.fire(hammer, "GROUP_ROSTER_UPDATE")
    addon.lfgButton:OpenDrawer()
    test.assertEqual("YOUR PARTY", addon.lfgButton.drawer.heading.text)
    test.assertEqual("Playing", addon.lfgButton.drawer.party.text)
    test.assertEqual(nil, addon.lfgButton.glow.color)
end)

test.test("Forever after Start a group with no party, the drawer shows my listing; Stop looking ends it", function()
    local channel = fixtures.newChannel()
    local tool = login(channel, "Tool Box")
    local hammer, addon = login(channel, "Hammer Smith")
    local button = tool.addon.lfgButton

    toolLists(tool)
    button:OpenDrawer()
    test.assertEqual("OPEN TO THE GUILD", button.drawer.heading.text)
    test.assertEqual("Stratholme", button.drawer.party.text)
    test.assertContains(button.drawer.partyDetails.text, "1/5")
    test.assertTrue(button.editListingButton.shown)

    -- Find guildmates opens the board on its panel.
    tool.addon.agfWindow:Close()
    test.assertTrue(button.findButton.shown)
    test.assertTrue(button.findButton.active)
    button.findButton.scripts.OnClick(button.findButton)
    test.assertTrue(tool.addon.agfWindow:IsOpen())
    test.assertTrue(tool.addon.lfgPage.fill.shown)
    test.assertContains(tool.addon.lfgPage.fill.rows[1].name.text, "Hammer")
    tool.addon.lfgPage:CloseFill()
    button:OpenDrawer()

    -- Edit opens the board's editor on it.
    tool.addon.agfWindow:Close()
    button.editListingButton.scripts.OnClick(button.editListingButton)
    test.assertTrue(tool.addon.agfWindow:IsOpen())
    test.assertEqual("edit", tool.addon.lfgPage:Mode())
    tool.addon.lfgPage:Save()

    -- Stop looking takes it off the board.
    fixtures.deliver(channel)
    test.assertEqual(1, addon.lfgButton.count.count)
    button:OpenDrawer()
    button.endListingButton.scripts.OnClick(button.endListingButton)
    test.assertFalse(tool.addon.lfgListing:IsActive())
    fixtures.deliver(channel)
    test.assertEqual(0, addon.lfgButton.count.count)
    button:OpenDrawer()
    test.assertEqual("NEW FOR YOU", button.drawer.heading.text)
end)

test.test("Forever the drawer's Start a group opens the board's editor", function()
    local channel = fixtures.newChannel()
    local hammer, addon = login(channel, "Hammer Smith")
    addon.lfgButton:OpenDrawer()

    addon.lfgButton.startButton.scripts.OnClick(addon.lfgButton.startButton)

    test.assertFalse(addon.lfgButton:DrawerOpen())
    test.assertTrue(addon.agfWindow:IsOpen())
    test.assertEqual("edit", addon.lfgPage:Mode())
    test.assertEqual(nil, hammer.messages[1])
end)
