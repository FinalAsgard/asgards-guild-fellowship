local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local function load()
    return test.newAddon("Core/DungeonCatalog.lua", "Core/LfgProtocol.lua", "Core/LfgListing.lua",
        "Core/ZoneLevels.lua", "Core/LfgRelevance.lua", "Core/LfgBoard.lua")
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

-- Each client's top level here: its test dungeon fits it.
local TOP_LEVEL = { Forever = 60, Retail = 85 }

-- Bolt Smith is Hammer's alt (Forever's notes link it); Zap is in Ironforge
-- like everyone.
local function guild(profile)
    local top = TOP_LEVEL[profile]
    return {
        name = "Knights of Camelot",
        realm = "Camelot",
        members = {
            { name = "Tool Box", class = "WARRIOR", level = top, rank = 1, rankName = "Officer",
                online = true, zone = "Ironforge" },
            { name = "Hammer Smith", class = "PALADIN", level = top, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
            { name = "Bolt Smith", class = "PRIEST", level = top - 1, rank = 3, rankName = "Member",
                online = false, lastOnline = { 0, 0, 1, 0 }, note = ">Hammer Smith" },
            { name = "Zap Arcane", class = "MAGE", level = 30, rank = 3, rankName = "Member",
                online = true, zone = "Ironforge" },
        },
    }
end

local function login(profile, channel, playerName, level)
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = playerName })
    world.playerLevel = level or TOP_LEVEL[profile]
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
    test.test(profile .. " Start a group shows you large on Relevant Parties for guildmates who fit", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, "Tool Box")
        local hammer = login(profile, channel, "Hammer Smith")
        fixtures.deliver(channel)

        local page = startDungeon(tool, "Live side")
        test.assertEqual("view", page:Mode())
        test.assertEqual(DUNGEON[profile].name, page.view.purpose.text)
        test.assertEqual("Live side", page.view.note.text)
        fixtures.deliver(channel)

        -- Hammer, a paladin at the dungeon's level, can heal: relevant.
        local board = openBoard(hammer)
        test.assertEqual("Relevant Parties \194\183 1", board.tabs.tabs[1].label.text)
        test.assertEqual("Other Parties \194\183 0", board.tabs.tabs[2].label.text)
        local card = board.largeCards[1]
        test.assertTrue(card.shown)
        test.assertEqual(DUNGEON[profile].name, card.purpose.text)
        test.assertContains(card.details.text, "1/5")
        test.assertContains(card.members[1].name.text, "Tool")
        test.assertTrue(card.members[1].crown.shown)
        test.assertEqual("Live side", card.note.text)
        test.assertEqual("Whisper Tool Box", card.whisper.label.text)
        -- No game icon for it here: the generic dungeon icon.
        test.assertEqual(hammer.addon.Theme.TEXTURES.dungeon, card.iconTexture)
        local whispered
        hammer.environment.ChatFrame_SendTell = function(name)
            whispered = name
        end
        click(card.whisper)
        test.assertContains(whispered, "Tool")
        whispered = nil
        click(card.members[1])
        test.assertContains(whispered, "Tool")
        -- Tool's own board doesn't list Tool.
        test.assertEqual(0, #tool.addon.lfgBoard:Listings(tool.time))
    end)

    test.test(profile .. " a listing nothing of yours fits is greyed out on Other Parties", function()
        local channel = fixtures.newChannel()
        local tool = login(profile, channel, "Tool Box")
        local zap = login(profile, channel, "Zap Arcane", 30)
        startDungeon(tool)
        fixtures.deliver(channel)

        local board = openBoard(zap)
        test.assertEqual("Relevant Parties \194\183 0", board.tabs.tabs[1].label.text)
        test.assertEqual("Other Parties \194\183 1", board.tabs.tabs[2].label.text)
        test.assertEqual("No relevant groups for you right now.", board.emptyText.text)
        click(board.tabs.tabs[2])
        test.assertFalse(board.emptyText.shown)
        local card = board.smallCards[1]
        test.assertTrue(card.shown)
        test.assertTrue(card.greyed)
        test.assertEqual(DUNGEON[profile].name, card.purpose.text)
        test.assertContains(card.details.text, "Tool Box")
        test.assertContains(card.details.text, "1/5")
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

-- LfgRelevance ---------------------------------------------------------------------

-- A board listing of `kind` with `fields` over the defaults.
local function boardListing(kind, fields)
    local listing = { kind = kind, size = 1, maxSize = kind == "raid" and 40 or 5, members = {} }
    if kind == "dungeon" then
        listing.minLevel, listing.maxLevel, listing.openRoles = 58, 60, { "healer", "dps" }
    end
    local name, value
    for name, value in pairs(fields or {}) do
        listing[name] = value
    end
    return listing
end

test.test("lfg relevance: a dungeon fits your level and a role you're willing to play that's open", function()
    local relevance = load().LfgRelevance
    local listing = boardListing("dungeon")

    test.assertTrue(relevance.Fits(listing, { level = 59, roles = { "healer" } }))
    test.assertTrue(relevance.Fits(listing, { level = 60, roles = { "tank", "dps" } }))
    -- Only tank, which is taken.
    test.assertFalse(relevance.Fits(listing, { level = 59, roles = { "tank" } }))
    test.assertFalse(relevance.Fits(listing, { level = 57, roles = { "healer" } }))
    test.assertFalse(relevance.Fits(listing, { level = 61, roles = { "healer" } }))
    -- Full: no room.
    test.assertFalse(relevance.Fits(boardListing("dungeon", { size = 5, openRoles = {} }),
        { level = 59, roles = { "dps" } }))
end)

test.test("lfg relevance: questing fits the zone's levels with room, any role", function()
    local relevance = load().LfgRelevance
    local listing = boardListing("questing", { minLevel = 20, maxLevel = 30 })

    test.assertTrue(relevance.Fits(listing, { level = 25, roles = {} }))
    test.assertFalse(relevance.Fits(listing, { level = 31, roles = { "dps" } }))
    test.assertFalse(relevance.Fits(boardListing("questing", { minLevel = 20, maxLevel = 30, size = 5 }),
        { level = 25, roles = { "dps" } }))
end)

test.test("lfg relevance: a raid fits with no range, else when the range fits; other text only with a range", function()
    local relevance = load().LfgRelevance
    local me = { level = 12, roles = { "dps" } }

    test.assertTrue(relevance.Fits(boardListing("raid"), me))
    test.assertFalse(relevance.Fits(boardListing("raid", { minLevel = 50, maxLevel = 60 }), me))
    test.assertTrue(relevance.Fits(boardListing("raid", { minLevel = 10, maxLevel = 20 }), me))
    test.assertFalse(relevance.Fits(boardListing("raid", { size = 40 }), me))
    -- Free text with no range never counts: it goes to Other Parties.
    test.assertFalse(relevance.Fits(boardListing("other"), me))
    test.assertTrue(relevance.Fits(boardListing("other", { minLevel = 10, maxLevel = 20 }), me))
end)

test.test("lfg board: sorts listings into relevant, alts and other, and counts the relevant", function()
    local addon = load()
    local board = addon.LfgBoard.Create()
    board:OnListing(listingMessage(addon), "strat", "Tool-Camelot", 100)
    board:OnListing(listingMessage(addon, { k = "questing", p = "Duskwood", lo = 18, hi = 30, r = "nil" }),
        "dusk", "Zap-Camelot", 200)
    board:OnListing(listingMessage(addon, { k = "other", p = "Gold run", r = "nil", lo = "nil", hi = "nil" }),
        "gold", "Hammer-Camelot", 300)
    local current = { level = 59, roles = { "healer" } }
    local alts = { { name = "Low", level = 12, roles = { "dps" } }, { name = "Mid", level = 25, roles = { "dps" } } }

    local groups = board:Groups(300, current, alts)

    test.assertEqual(1, #groups.relevant)
    test.assertEqual("Stratholme", groups.relevant[1].purpose)
    test.assertEqual(1, #groups.alts)
    test.assertEqual("Duskwood", groups.alts[1].listing.purpose)
    test.assertEqual("Mid", groups.alts[1].alt.name)
    test.assertEqual(1, #groups.other)
    test.assertEqual("Gold run", groups.other[1].purpose)
    test.assertEqual(1, board:RelevantCount(300, current))
    test.assertEqual(0, board:RelevantCount(300, { level = 10, roles = { "dps" } }))
end)

-- ZoneLevels ----------------------------------------------------------------------

test.test("zone levels: the game's range when it has one, else the party's levels 3 either way", function()
    local ZoneLevels = load().ZoneLevels

    local game = ZoneLevels.For({ minLevel = 20, maxLevel = 30 }, { 50 })
    test.assertEqual(20, game.minLevel)
    test.assertEqual(30, game.maxLevel)
    test.assertEqual(ZoneLevels.GAME, game.source)

    local fallback = ZoneLevels.For(nil, { 24, 27, 22 })
    test.assertEqual(19, fallback.minLevel)
    test.assertEqual(30, fallback.maxLevel)
    test.assertEqual(ZoneLevels.FALLBACK, fallback.source)
    -- An unusable game range falls back too; levels never go under 1.
    local low = ZoneLevels.For({ minLevel = 0, maxLevel = 0 }, { 2 })
    test.assertEqual(1, low.minLevel)
    test.assertEqual(ZoneLevels.FALLBACK, low.source)
    test.assertEqual(nil, ZoneLevels.For(nil, {}))
end)

test.test("lfg listing: questing carries the zone's levels", function()
    local addon = load()
    local listing = addon.LfgListing.Create()
    listing:Start({ kind = "questing", zone = "Duskwood", minLevel = 18, maxLevel = 30 }, nil, 0)

    local fields = listing:Announcement(ME)
    test.assertEqual(18, fields.lo)
    test.assertEqual(30, fields.hi)
    test.assertTrue(addon.LfgProtocol.IsValid(addon.LfgProtocol.Listing(fields)))
end)

-- The page's cards --------------------------------------------------------------------

-- A page over fake frames showing `groups`, with `overrides` on its options.
local function pageWith(groups, overrides)
    local addon = test.newAddon("Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/LfgBoardPage.lua",
        "Core/DungeonCatalog.lua", "Core/LfgProtocol.lua", "Core/LfgListing.lua", "Core/LfgRelevance.lua",
        "Core/GroupFriends.lua")
    local environment = fakeFrames.install({})
    local whispered = {}
    local options = {
        listing = addon.LfgListing.Create(),
        members = function() return ME end,
        level = function() return 60 end,
        zone = function() return "Ironforge" end,
        catalog = function() return addon.DungeonCatalog.Create({}) end,
        groups = function() return groups end,
        nearby = function() return nil end,
        classColor = function(classToken) return classToken == "WARRIOR" and "ffc79c6e" or nil end,
        friendTier = function(name)
            return name == "Hammer" and addon.GroupFriends.TOP or (name == "Zap" and addon.GroupFriends.GROUPED or nil)
        end,
        dungeonIcon = function(name)
            return name == "Stratholme" and "Interface\\LFGFrame\\LFGIcon-Stratholme" or nil
        end,
        onWhisper = function(name) table.insert(whispered, name) end,
        onSave = function() return true end,
        onNotLooking = function() end,
    }
    local name, value
    for name, value in pairs(overrides or {}) do
        options[name] = value
    end
    local content = environment.CreateFrame("Frame")
    return addon.LfgBoardPage.Create(content, addon.Widgets.Create(environment), options), whispered
end

local function listingOf(kind, fields)
    local listing = boardListing(kind, fields)
    listing.leader = listing.leader or "Tool"
    listing.sender = listing.sender or "Tool-Camelot"
    return listing
end

test.test("lfg page: a large card marks the leader, group friends, filled roles and the game's icon", function()
    local listing = listingOf("dungeon", {
        purpose = "Stratholme", size = 3, note = "3 bosses down",
        members = {
            { name = "Tool", classToken = "WARRIOR", role = "tank" },
            { name = "Hammer", classToken = "PALADIN", role = "dps" },
            { name = "Zap", classToken = "MAGE", role = "dps" },
        },
    })
    local page, whispered = pageWith({ relevant = { listing }, alts = {}, other = {} })
    local card = page.largeCards[1]

    test.assertEqual("Interface\\LFGFrame\\LFGIcon-Stratholme", card.iconTexture)
    test.assertEqual("|cffc79c6eTool|r", card.members[1].name.text)
    test.assertTrue(card.members[1].crown.shown)
    test.assertFalse(card.members[2].crown.shown)
    -- Top 5 and Frequent get a heart; Grouped doesn't.
    test.assertTrue(card.members[2].friend)
    test.assertFalse(card.members[3].friend)
    test.assertFalse(card.members[4].shown)
    test.assertEqual("3 bosses down", card.note.text)
    -- Tank taken, healer open, two of three DPS taken.
    local filled = {}
    local index
    for index = 1, 5 do
        filled[index] = card.roleTiles[index].filled and "x" or "o"
    end
    test.assertEqual("xoxxo", table.concat(filled))
    -- Only the leader's name whispers.
    click(card.members[2])
    click(card.members[1])
    click(card.whisper)
    test.assertEqual("Tool-Camelot,Tool-Camelot", table.concat(whispered, ","))
end)

test.test("lfg page: questing uses person tiles, a raid one tile and its player count", function()
    local questing = listingOf("questing", { purpose = "Duskwood", size = 2, minLevel = 18, maxLevel = 30 })
    local raid = listingOf("raid", { size = 12 })
    local page = pageWith({ relevant = { questing, raid }, alts = {}, other = {} })

    local quest = page.largeCards[1]
    test.assertEqual("Questing in Duskwood", quest.purpose.text)
    test.assertContains(quest.details.text, "18\226\128\14730")
    test.assertTrue(quest.anyTiles[1].filled)
    test.assertTrue(quest.anyTiles[2].filled)
    test.assertFalse(quest.anyTiles[3].filled)
    test.assertFalse(quest.roleTiles[1].shown)
    -- No dungeon, no icon.
    test.assertFalse(quest.iconTexture)

    local big = page.largeCards[2]
    test.assertEqual("Raid", big.purpose.text)
    test.assertTrue(big.raidTile.shown)
    test.assertFalse(big.anyTiles[1].shown)
    test.assertEqual("12 players", big.count.text)
end)

test.test("lfg page: alts' groups as small cards naming the alt, then Nearby", function()
    local listing = listingOf("dungeon", { purpose = "Wailing Caverns", minLevel = 17, maxLevel = 24 })
    local page = pageWith({ relevant = {}, alts = { { listing = listing, alt = { name = "Bolt", level = 20 } } },
        other = {} }, {
        nearby = function() return { zone = "Ironforge", names = { "Hammer", "Zap" } } end,
    })

    test.assertFalse(page.emptyText.shown)
    test.assertTrue(page.altsLabel.shown)
    local card = page.smallCards[1]
    test.assertFalse(card.greyed)
    test.assertEqual("Wailing Caverns", card.purpose.text)
    test.assertContains(card.details.text, "Tool")
    test.assertContains(card.details.text, "Bolt (20)")
    test.assertEqual("Nearby in Ironforge: Hammer, Zap", page.nearbyText.text)
    test.assertTrue(page.nearbyText.shown)
end)

-- The composed add-on: alts, Nearby, questing levels and the probe ------------------

test.test("Forever a group only your alt fits shows under Your alts could join, with Nearby", function()
    local channel = fixtures.newChannel()
    local tool = login("Forever", channel, "Tool Box")
    local hammer = login("Forever", channel, "Hammer Smith", 30)
    startDungeon(tool)
    fixtures.deliver(channel)

    local board = openBoard(hammer)
    test.assertEqual("Relevant Parties \194\183 0", board.tabs.tabs[1].label.text)
    test.assertTrue(board.altsLabel.shown)
    test.assertContains(board.smallCards[1].details.text, "Bolt Smith (59)")
    test.assertContains(board.nearbyText.text, "Nearby in Ironforge:")
    test.assertContains(board.nearbyText.text, "Zap Arcane")
    test.assertContains(board.nearbyText.text, "Tool Box")
end)

test.test("Forever questing is listed in the zone's levels, and the probe says where they came from", function()
    local channel = fixtures.newChannel()
    local tool = login("Forever", channel, "Tool Box")
    local zap = login("Forever", channel, "Zap Arcane", 30)
    local page = openBoard(tool)
    click(page.startButton)
    click(page.kindSelector.buttons[2])
    click(page.saveButton)
    fixtures.deliver(channel)

    -- No zone levels from this client: Tool's level, 3 either way.
    local listing = zap.addon.lfgBoard:Listings(zap.time)[1]
    test.assertEqual("Ironforge", listing.purpose)
    test.assertEqual(57, listing.minLevel)
    test.assertEqual(63, listing.maxLevel)
    fixtures.slash(tool, "probe lfg")
    local printed = table.concat(tool.messages, "\n")
    test.assertContains(printed, "Zone levels in Ironforge: 57-63, the fallback")
    test.assertContains(printed, "Your listing: Questing in Ironforge.")

    fixtures.slash(zap, "probe lfg")
    printed = table.concat(zap.messages, "\n")
    test.assertContains(printed, "On the board: 0 relevant, 0 for your alts, 1 other.")
    test.assertContains(printed, "Other, Questing in Ironforge, by Tool Box, 1/5, levels 57-63")

    -- Where the game knows the zone's levels, they're used.
    tool.environment.C_Map.GetMapLevels = function()
        return 25, 35
    end
    fixtures.slash(tool, "probe lfg")
    test.assertContains(tool.messages[#tool.messages - 2], "Zone levels in Ironforge: 25-35, from the game.")
end)
