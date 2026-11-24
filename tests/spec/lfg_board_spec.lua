local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local function load()
    return test.newAddon("Core/DungeonCatalog.lua", "Core/LfgProtocol.lua", "Core/LfgListing.lua",
        "Core/LfgBoard.lua")
end

local STRAT = { id = "strat", name = "Stratholme", minLevel = 58, maxLevel = 60 }

-- A valid listing message for a solo player, with `changes` applied.
local function listingMessage(addon, changes)
    local message = addon.LfgProtocol.Listing({
        k = "dungeon", p = "Stratholme", lo = 58, hi = 60, r = { "tank", "healer", "dps" },
        s = 1, x = 5, no = "Live side", mb = { { n = "Tool", c = "WARRIOR", l = 60, r = "dps" } }, aj = true,
    })
    local name, value
    for name, value in pairs(changes or {}) do
        if value == "nil" then
            message[name] = nil
        else
            message[name] = value
        end
    end
    return message
end

-- LfgProtocol -------------------------------------------------------------------

test.test("lfg protocol: a listing and its end are understood", function()
    local addon = load()
    local protocol = addon.LfgProtocol

    test.assertTrue(protocol.IsValid(listingMessage(addon)))
    test.assertTrue(protocol.IsValid(protocol.End()))
    test.assertEqual("lfg-listing", listingMessage(addon).t)
    test.assertTrue(protocol.TYPES["lfg-listing"])
    test.assertTrue(protocol.TYPES["lfg-end"])
    -- Questing, a raid and a free-text purpose carry no roles; a raid
    -- needn't name itself.
    test.assertTrue(protocol.IsValid(listingMessage(addon, { k = "questing", p = "Duskwood", lo = "nil", hi = "nil",
        r = "nil" })))
    test.assertTrue(protocol.IsValid(listingMessage(addon, { k = "raid", p = "nil", lo = "nil", hi = "nil", r = "nil",
        x = 40 })))
    test.assertTrue(protocol.IsValid(listingMessage(addon, { k = "other", p = "Gold run", r = "nil", no = "nil" })))
    -- A full dungeon party has no open roles.
    test.assertTrue(protocol.IsValid(listingMessage(addon, { r = {} })))
end)

test.test("lfg protocol: unknown versions and types, and malformed fields, are ignored", function()
    local addon = load()
    local protocol = addon.LfgProtocol

    test.assertFalse(protocol.IsValid(listingMessage(addon, { v = 2 })))
    test.assertFalse(protocol.IsValid({ v = 1, t = "lfg-something-new" }))
    test.assertFalse(protocol.IsValid("lfg-listing"))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { k = "pvp" })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { p = "nil" })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { lo = 61 })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { hi = "nil" })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { r = "nil" })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { r = { "dps", "dps" } })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { r = { "bard" } })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { k = "questing", p = "Duskwood" })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { s = 6 })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { s = 0, mb = {} })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { x = 41 })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { s = 2 })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { mb = { { c = "WARRIOR" } } })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { mb = { { n = "Tool", r = "bard" } } })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { no = string.rep("a", 61) })))
    test.assertFalse(protocol.IsValid(listingMessage(addon, { aj = "nil" })))
    -- 60 two-byte characters fit.
    test.assertTrue(protocol.IsValid(listingMessage(addon, { no = string.rep("\195\169", 60) })))
end)

test.test("lfg protocol: the old Group Finder's gf- messages are ignored", function()
    local addon = test.newAddon("Core/GroupFinderProtocol.lua", "Core/LfgProtocol.lua")
    local old = addon.GroupFinderProtocol.Group({ name = "Stratholme", minLevel = 58, maxLevel = 60 }, {
        { r = "tank" }, { r = "healer" }, { r = "dps" }, { r = "dps" }, { r = "dps" },
    })
    old.v = addon.LfgProtocol.VERSION

    test.assertFalse(addon.LfgProtocol.IsValid(old))
    test.assertFalse(addon.LfgProtocol.IsValid(addon.GroupFinderProtocol.GroupEnd()))
    local type_
    for type_ in pairs(addon.LfgProtocol.TYPES) do
        test.assertEqual("lfg-", string.sub(type_, 1, 4))
    end
end)

-- LfgListing ----------------------------------------------------------------------

local ME = { { name = "Tool", classToken = "WARRIOR", level = 60, role = "tank" } }

test.test("lfg listing: Start a group lists the player as a group of one", function()
    local addon = load()
    local listing = addon.LfgListing.Create()
    test.assertEqual(nil, listing:Announcement(ME))

    test.assertTrue(listing:Start({ kind = "dungeon", dungeon = STRAT }, "Live side", 100))

    local fields = listing:Announcement(ME)
    test.assertTrue(listing:IsActive())
    test.assertEqual("dungeon", fields.k)
    test.assertEqual("Stratholme", fields.p)
    test.assertEqual(58, fields.lo)
    test.assertEqual(60, fields.hi)
    -- The tank slot is the player's; the healer and DPS are open.
    test.assertEqual("healer,dps", table.concat(fields.r, ","))
    test.assertEqual(1, fields.s)
    test.assertEqual(5, fields.x)
    test.assertEqual("Live side", fields.no)
    test.assertEqual("Tool", fields.mb[1].n)
    test.assertEqual("tank", fields.mb[1].r)
    test.assertTrue(fields.aj)
    test.assertTrue(addon.LfgProtocol.IsValid(addon.LfgProtocol.Listing(fields)))
end)

test.test("lfg listing: questing is in the current zone, a raid counts players, other is free text", function()
    local addon = load()
    local listing = addon.LfgListing.Create()

    test.assertTrue(listing:Start({ kind = "questing", zone = "Duskwood" }, nil, 0))
    local fields = listing:Announcement(ME)
    test.assertEqual("Duskwood", fields.p)
    test.assertEqual(nil, fields.r)
    test.assertEqual(5, fields.x)
    test.assertEqual("Questing in Duskwood", addon.LfgListing.Label(fields.k, fields.p))

    test.assertTrue(listing:Update({ kind = "raid" }, nil))
    fields = listing:Announcement(ME)
    test.assertEqual(40, fields.x)
    test.assertEqual(nil, fields.p)
    test.assertEqual("Raid", addon.LfgListing.Label(fields.k, fields.p))

    test.assertTrue(listing:Update({ kind = "other", text = "  Gold run  " }, nil))
    fields = listing:Announcement(ME)
    test.assertEqual("Gold run", fields.p)
    test.assertTrue(addon.LfgProtocol.IsValid(addon.LfgProtocol.Listing(fields)))
end)

test.test("lfg listing: a purpose has to say what it's for", function()
    local addon = load()
    local listing = addon.LfgListing.Create()

    local started, reason = listing:Start({ kind = "dungeon" }, nil, 0)
    test.assertFalse(started)
    test.assertEqual("choose a dungeon", reason)
    started, reason = listing:Start({ kind = "questing" }, nil, 0)
    test.assertEqual("your zone isn't known yet", reason)
    started, reason = listing:Start({ kind = "other", text = "   " }, nil, 0)
    test.assertEqual("say what it's for", reason)
    test.assertFalse(listing:IsActive())
    local updated = listing:Update({ kind = "raid" }, nil)
    test.assertFalse(updated)
end)

test.test("lfg listing: the note holds 60 characters, trimmed, and an empty one is none", function()
    local addon = load()
    local listing = addon.LfgListing.Create()

    listing:Start({ kind = "raid" }, string.rep("a", 70), 0)
    test.assertEqual(string.rep("a", 60), listing:Note())
    -- Characters, not bytes: 60 accented letters fit whole.
    listing:Update({ kind = "raid" }, string.rep("\195\169", 65))
    test.assertEqual(string.rep("\195\169", 60), listing:Note())
    listing:Update({ kind = "raid" }, "  3 bosses down  ")
    test.assertEqual("3 bosses down", listing:Note())
    listing:Update({ kind = "raid" }, "   ")
    test.assertEqual(nil, listing:Note())
end)

test.test("lfg listing: a group of one runs out after 30 minutes with nobody joining", function()
    local addon = load()
    local listing = addon.LfgListing.Create()
    listing:Start({ kind = "raid" }, nil, 1000)

    test.assertFalse(listing:Expired(1000 + 30 * 60 - 1, 1))
    test.assertTrue(listing:Expired(1000 + 30 * 60, 1))

    -- Once someone joins, it never runs out this way.
    listing:Start({ kind = "raid" }, nil, 1000)
    test.assertFalse(listing:Expired(1100, 2))
    test.assertFalse(listing:Expired(1000 + 60 * 60, 1))

    listing:End()
    test.assertFalse(listing:IsActive())
    test.assertFalse(listing:Expired(1000 + 60 * 60, 1))
end)

-- LfgBoard ----------------------------------------------------------------------

test.test("lfg board: keeps each guildmate's listing, newest first", function()
    local addon = load()
    local board = addon.LfgBoard.Create()

    board:OnListing(listingMessage(addon), "tool-camelot", "Tool-Camelot", 100)
    board:OnListing(listingMessage(addon, { k = "other", p = "Gold run", r = "nil", lo = "nil", hi = "nil" }),
        "zap-camelot", "Zap-Camelot", 200)

    local listings = board:Listings(200)
    test.assertEqual(2, #listings)
    test.assertEqual("Zap", listings[1].leader)
    test.assertEqual("Gold run", listings[1].purpose)
    test.assertEqual(nil, listings[1].openRoles)
    test.assertEqual("Tool", listings[2].leader)
    test.assertEqual("Stratholme", listings[2].purpose)
    test.assertEqual("tank,healer,dps", table.concat(listings[2].openRoles, ","))
    test.assertEqual("Live side", listings[2].note)
    test.assertEqual("dps", listings[2].members[1].role)

    -- Heard again, it keeps its place.
    board:OnListing(listingMessage(addon, { no = "Undead side" }), "tool-camelot", "Tool-Camelot", 250)
    listings = board:Listings(250)
    test.assertEqual("Zap", listings[1].leader)
    test.assertEqual("Undead side", listings[2].note)
end)

test.test("lfg board: an end message drops the listing", function()
    local addon = load()
    local board = addon.LfgBoard.Create()
    board:OnListing(listingMessage(addon), "tool-camelot", "Tool-Camelot", 100)

    board:OnEnd("tool-camelot")

    test.assertEqual(0, #board:Listings(100))
    test.assertEqual(nil, board:Get("tool-camelot", 100))
end)

test.test("lfg board: a listing not heard from for 5 minutes is dropped", function()
    local addon = load()
    local board = addon.LfgBoard.Create()
    board:OnListing(listingMessage(addon), "tool-camelot", "Tool-Camelot", 100)

    test.assertEqual(1, #board:Listings(100 + 5 * 60 - 1))
    test.assertEqual(0, #board:Listings(100 + 5 * 60))
    -- Gone for good: hearing nothing more, it doesn't come back.
    test.assertEqual(0, #board:Listings(100))

    -- Heard again in time, it stays.
    board:OnListing(listingMessage(addon), "tool-camelot", "Tool-Camelot", 1000)
    board:OnListing(listingMessage(addon), "tool-camelot", "Tool-Camelot", 1200)
    test.assertEqual(1, #board:Listings(1000 + 5 * 60))
end)

-- DungeonCatalog search ------------------------------------------------------------

local SAMPLE = {
    { id = "sfk", name = "Shadowfang Keep", minLevel = 22, maxLevel = 30 },
    { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 },
    { id = "wc", name = "Wailing Caverns", minLevel = 17, maxLevel = 24 },
    { id = "strat", name = "Stratholme", minLevel = 58, maxLevel = 60 },
    { id = "scholo", name = "Scholomance", minLevel = 58, maxLevel = 60 },
}

local function names(list)
    local result = {}
    local index
    for index = 1, #list do
        result[index] = list[index].name
    end
    return table.concat(result, ", ")
end

test.test("dungeon catalog search: with nothing typed, the dungeons that fit your level", function()
    local catalog = load().DungeonCatalog.Create(SAMPLE)

    local fitting, others = catalog:Search("", 23)

    test.assertEqual("Wailing Caverns, The Deadmines, Shadowfang Keep", names(fitting))
    test.assertEqual(0, #others)
end)

test.test("dungeon catalog search: typing searches every dungeon, those that fit first", function()
    local catalog = load().DungeonCatalog.Create(SAMPLE)

    local fitting, others = catalog:Search("S", 23)
    test.assertEqual("Wailing Caverns, The Deadmines, Shadowfang Keep", names(fitting))
    test.assertEqual("Scholomance, Stratholme", names(others))

    fitting, others = catalog:Search(" strat ", 23)
    test.assertEqual(0, #fitting)
    test.assertEqual("Stratholme", names(others))

    fitting, others = catalog:Search("nowhere", 23)
    test.assertEqual(0, #fitting + #others)
end)

-- The composed add-on --------------------------------------------------------------

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

local function login(profile, channel, playerName)
    local world = fixtures.newEnvironment(profile, { guild = guild(), playerName = playerName })
    world.playerLevel = 60
    fixtures.joinChannel(channel, world)
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    return world, addon
end

-- Opens the Guild LFG Board on frames that draw (installed after login, so
-- the fixtures' event frames keep working). Returns the page.
local function openBoard(world)
    if world.addon.lfgPage == nil then
        fakeFrames.install(world.environment)
    end
    test.assertTrue(world.addon.agfWindow:Open("lfg"))
    return world.addon.lfgPage
end

local function click(button)
    button.scripts.OnClick(button, "LeftButton")
end

local function type_(field, text)
    field.box:SetText(text)
    field.box.scripts.OnTextChanged(field.box, true)
end

-- The page's dungeon row for `name`, or nil.
local function dungeonRow(page, name)
    local index
    for index = 1, #page.dungeonRows do
        local row = page.dungeonRows[index]
        if row.shown and type(row.dungeon) == "table" and row.dungeon.name == name then
            return row
        end
    end
    return nil
end

-- Lists `world`'s player for its client's DUNGEON with `note` from the board.
local DUNGEON = {
    Forever = { search = "strat", name = "Stratholme" },
    Retail = { search = "windrunner", name = "Windrunner Spire" },
}
local function startDungeon(world, note)
    local page = openBoard(world)
    click(page.startButton)
    type_(page.search, DUNGEON[world.profile].search)
    click(dungeonRow(page, DUNGEON[world.profile].name))
    type_(page.note, note or "")
    click(page.saveButton)
    return page
end

-- How many Guild LFG Board messages wait on `channel`.
local function lfgQueued(channel)
    local count = 0
    local index
    for index = 1, #channel.queue do
        local queued = channel.queue[index]
        local serializer = queued.from.environment.LibStub.libs["AceSerializer-3.0"]
        local ok, message = serializer:Deserialize(queued.text)
        if ok and type(message) == "table" and string.sub(tostring(message.t), 1, 4) == "lfg-" then
            count = count + 1
        end
    end
    return count
end

local function registerProfileTests(profile)
    test.test(profile .. " Start a group lists you as a small card on guildmates' Other Parties", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, "Tool Box")
        local hammer = login(profile, channel, "Hammer Smith")
        fixtures.deliver(channel)

        local page = startDungeon(tool, "Live side")
        test.assertEqual("view", page:Mode())
        test.assertEqual(DUNGEON[profile].name, page.view.purpose.text)
        test.assertEqual("Live side", page.view.note.text)
        fixtures.deliver(channel)

        local board = openBoard(hammer)
        test.assertEqual("Relevant Parties \194\183 0", board.tabs.tabs[1].label.text)
        test.assertEqual("Other Parties \194\183 1", board.tabs.tabs[2].label.text)
        test.assertEqual("No relevant groups for you right now.", board.emptyText.text)
        click(board.tabs.tabs[2])
        test.assertFalse(board.emptyText.shown)
        local card = board.smallCards[1]
        test.assertTrue(card.shown)
        test.assertEqual(DUNGEON[profile].name, card.purpose.text)
        test.assertContains(card.details.text, "Tool Box")
        test.assertContains(card.details.text, "1/5")
        -- Tool's own board doesn't list Tool.
        test.assertEqual(0, #tool.addon.lfgBoard:Listings(tool.time))
    end)

    test.test(profile .. " Not looking takes the listing off guildmates' boards", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, "Tool Box")
        local hammer = login(profile, channel, "Hammer Smith")
        local page = startDungeon(tool)
        fixtures.deliver(channel)
        test.assertEqual(1, #hammer.addon.lfgBoard:Listings(hammer.time))

        click(page.notLookingButton)
        fixtures.deliver(channel)

        test.assertEqual("solo", page:Mode())
        test.assertFalse(tool.addon.lfgListing:IsActive())
        test.assertEqual(0, #hammer.addon.lfgBoard:Listings(hammer.time))
    end)

    test.test(profile .. " a listing is re-sent every minute and runs out after 30 minutes alone", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, "Tool Box")
        local hammer = login(profile, channel, "Hammer Smith")
        startDungeon(tool)
        fixtures.deliver(channel)

        fixtures.runTimers(tool, 60)
        test.assertEqual(1, lfgQueued(channel))
        fixtures.deliver(channel)
        -- Heard every minute, it never goes stale on Hammer's board.
        local minute
        for minute = 2, 29 do
            fixtures.runTimers(tool, 60)
            fixtures.runTimers(hammer, 60)
            fixtures.deliver(channel)
        end
        test.assertEqual(1, #hammer.addon.lfgBoard:Listings(hammer.time))

        fixtures.runTimers(tool, 60)
        fixtures.deliver(channel)

        test.assertFalse(tool.addon.lfgListing:IsActive())
        test.assertContains(tool.messages[#tool.messages], "nobody joined in 30 minutes")
        test.assertEqual(0, #hammer.addon.lfgBoard:Listings(hammer.time))
        -- Nothing more is sent.
        fixtures.runTimers(tool, 600)
        test.assertEqual(0, lfgQueued(channel))
    end)

    test.test(profile .. " nothing is sent in combat; the listing goes out after", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, "Tool Box")
        local hammer = login(profile, channel, "Hammer Smith")
        fixtures.deliver(channel)
        tool.inCombat = true

        startDungeon(tool)
        test.assertEqual(0, lfgQueued(channel))
        fixtures.runTimers(tool, 10)
        test.assertEqual(0, lfgQueued(channel))

        tool.inCombat = false
        fixtures.runTimers(tool, 2)
        test.assertEqual(1, lfgQueued(channel))
        fixtures.deliver(channel)
        test.assertEqual(1, #hammer.addon.lfgBoard:Listings(hammer.time))
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

-- The page ------------------------------------------------------------------------

test.test("lfg page: the editor shows each kind's fields, and Cancel goes back", function()
    local channel = fixtures.newChannel()
    local tool = login("Forever", channel, "Tool Box")
    local page = openBoard(tool)
    test.assertEqual("solo", page:Mode())
    test.assertTrue(page.solo.shown)
    test.assertEqual("No relevant groups for you right now.", page.emptyText.text)
    click(page.tabs.tabs[3])
    test.assertEqual("No parties in your history yet.", page.emptyText.text)

    click(page.startButton)
    test.assertEqual("edit", page:Mode())
    test.assertTrue(page.editor.shown)
    test.assertEqual("dungeon", page.kindSelector:Selected())
    test.assertTrue(page.search.shown)
    test.assertEqual("0/60", page.note.counter.text)
    type_(page.note, "Bring water")
    test.assertEqual("11/60", page.note.counter.text)

    click(page.kindSelector.buttons[2])
    test.assertFalse(page.search.shown)
    test.assertTrue(page.editor.questing.shown)
    click(page.kindSelector.buttons[3])
    test.assertTrue(page.editor.raid.shown)
    click(page.kindSelector.buttons[4])
    test.assertTrue(page.otherText.shown)

    click(page.cancelButton)
    test.assertEqual("solo", page:Mode())
    test.assertFalse(tool.addon.lfgListing:IsActive())
end)

test.test("lfg page: your level's dungeons first, typing finds the rest under Other levels", function()
    local channel = fixtures.newChannel()
    local tool = login("Forever", channel, "Tool Box")
    tool.playerLevel = 23
    local page = openBoard(tool)
    click(page.startButton)

    test.assertTrue(dungeonRow(page, "Shadowfang Keep") ~= nil)
    test.assertEqual(nil, dungeonRow(page, "Stratholme"))

    type_(page.search, "s")
    test.assertTrue(dungeonRow(page, "Shadowfang Keep") ~= nil)
    local header
    for index = 1, #page.dungeonRows do
        if page.dungeonRows[index].shown and type(page.dungeonRows[index].dungeon) ~= "table" then
            header = page.dungeonRows[index].label.text
        end
    end
    test.assertEqual("OTHER LEVELS", header)
    type_(page.search, "strat")
    test.assertTrue(dungeonRow(page, "Stratholme") ~= nil)
end)

test.test("lfg page: Save without a dungeon says why, and Edit changes the listing", function()
    local channel = fixtures.newChannel()
    local tool = login("Forever", channel, "Tool Box")
    local page = openBoard(tool)
    click(page.startButton)

    click(page.saveButton)
    test.assertEqual("edit", page:Mode())
    test.assertEqual("Can't save: choose a dungeon.", page.errorText.text)
    test.assertEqual(0, lfgQueued(channel))

    click(page.kindSelector.buttons[4])
    type_(page.otherText, "Gold run")
    click(page.saveButton)
    test.assertEqual("view", page:Mode())
    test.assertEqual("Gold run", page.view.purpose.text)
    test.assertEqual(1, lfgQueued(channel))

    click(page.editButton)
    test.assertEqual("other", page.kindSelector:Selected())
    click(page.kindSelector.buttons[3])
    click(page.saveButton)
    test.assertEqual("Raid", page.view.purpose.text)
    test.assertEqual(2, lfgQueued(channel))
end)

test.test("lfg page: Other Parties shows 8 cards (4 while editing) and counts the rest", function()
    local channel = fixtures.newChannel()
    local tool = login("Forever", channel, "Tool Box")
    local addon = tool.addon
    local index
    for index = 1, 10 do
        addon.lfgBoard:OnListing(listingMessage(addon, { k = "other", p = "Run " .. index, r = "nil", lo = "nil",
            hi = "nil" }), "leader" .. index, "Leader" .. index, tool.time)
    end
    local page = openBoard(tool)
    click(page.tabs.tabs[2])

    test.assertEqual("Other Parties \194\183 10", page.tabs.tabs[2].label.text)
    test.assertTrue(page.smallCards[8].shown)
    test.assertEqual(nil, rawget(page.smallCards, 9))
    test.assertEqual("and 2 more", page.moreText.text)

    click(page.startButton)
    test.assertTrue(page.smallCards[4].shown)
    test.assertFalse(page.smallCards[5].shown)
    test.assertEqual("and 6 more", page.moreText.text)
end)
