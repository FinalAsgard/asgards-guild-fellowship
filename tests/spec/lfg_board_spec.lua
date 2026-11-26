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
    local addon = test.newAddon("Core/LfgProtocol.lua")
    -- As older versions still send them.
    local old = { v = addon.LfgProtocol.VERSION, t = "gf-group", dn = "Stratholme", lo = 58, hi = 60,
        s = { { r = "tank" }, { r = "healer" }, { r = "dps" }, { r = "dps" }, { r = "dps" } } }

    test.assertFalse(addon.LfgProtocol.IsValid(old))
    test.assertFalse(addon.LfgProtocol.IsValid({ v = addon.LfgProtocol.VERSION, t = "gf-group-end" }))
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

-- Clicks the name `line` on `page`, then the name menu's Whisper.
local function whisperName(page, line)
    click(line)
    test.assertTrue(page.namesMenu:IsOpen())
    test.assertEqual(line.title, page.namesMenu.titleText)
    test.assertEqual("Whisper", page.namesMenu.rows[1].label.text)
    click(page.namesMenu.rows[1])
    test.assertFalse(page.namesMenu:IsOpen())
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
        test.assertEqual("Other Parties \194\183 0", board.tabs.tabs[3].label.text)
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
        -- The leader's name opens the name menu, whose Whisper whispers
        -- them.
        click(card.members[1])
        test.assertEqual(nil, whispered)
        click(card.members[1])
        whisperName(board, card.members[1])
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
        test.assertEqual("Other Parties \194\183 1", board.tabs.tabs[3].label.text)
        test.assertEqual("No relevant groups for you right now.", board.emptyText.text)
        click(board.tabs.tabs[3])
        test.assertFalse(board.emptyText.shown)
        local card = board.smallCards[1]
        test.assertTrue(card.shown)
        test.assertTrue(card.greyed)
        test.assertEqual(DUNGEON[profile].name, card.purpose.text)
        test.assertContains(card.leader.name.text, "Tool Box")
        test.assertTrue(card.roleTiles[1].shown)
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
    click(page.tabs.tabs[4])
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

test.test("zone levels: the game's range when it has one, else the party's levels 5 either way", function()
    local ZoneLevels = load().ZoneLevels

    local game = ZoneLevels.For({ minLevel = 20, maxLevel = 30 }, { 50 })
    test.assertEqual(20, game.minLevel)
    test.assertEqual(30, game.maxLevel)
    test.assertEqual(ZoneLevels.GAME, game.source)

    local fallback = ZoneLevels.For(nil, { 24, 27, 22 })
    test.assertEqual(17, fallback.minLevel)
    test.assertEqual(32, fallback.maxLevel)
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
        "Core/GroupFriends.lua", "Core/LfgHistoryView.lua")
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

test.test("lfg page: a large card marks the leader, top friends, members' roles and the game's icon", function()
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
    -- Top 5 get a star; Grouped doesn't.
    test.assertTrue(card.members[2].topFriend)
    test.assertTrue(card.members[2].star.shown)
    test.assertFalse(card.members[3].topFriend)
    test.assertFalse(card.members[3].star.shown)
    test.assertFalse(card.members[4].shown)
    test.assertEqual("3 bosses down", card.note.text)
    -- Each member's role icon is beside their name, and the role tiles on
    -- the right, with their icons, show what's open: tank taken, healer
    -- open, two of three DPS taken.
    test.assertEqual("tank", card.members[1].role)
    test.assertTrue(card.members[1].roleIcon.shown)
    test.assertEqual("dps", card.members[2].role)
    local filled = {}
    local index
    for index = 1, 5 do
        test.assertTrue(card.roleTiles[index].icon.shown)
        filled[index] = card.roleTiles[index].filled and "x" or "o"
    end
    test.assertEqual("xoxxo", table.concat(filled))
    -- Every name opens the name menu; its Whisper whispers that member,
    -- the leader by the name they listed from.
    whisperName(page, card.members[2])
    whisperName(page, card.members[1])
    click(card.whisper)
    test.assertEqual("Hammer,Tool-Camelot,Tool-Camelot", table.concat(whispered, ","))
end)

test.test("lfg page: questing uses person tiles and no role icons, a raid one tile and its count", function()
    local questing = listingOf("questing", { purpose = "Duskwood", size = 2, minLevel = 18, maxLevel = 30,
        members = { { name = "Tool", classToken = "WARRIOR" }, { name = "Zap", classToken = "MAGE" } } })
    local raid = listingOf("raid", { size = 12 })
    local page = pageWith({ relevant = { questing, raid }, alts = {}, other = {} })

    local quest = page.largeCards[1]
    test.assertEqual("Questing in Duskwood", quest.purpose.text)
    test.assertContains(quest.details.text, "18\226\128\14730")
    test.assertContains(quest.details.text, "2/5")
    test.assertFalse(quest.members[1].roleIcon.shown)
    test.assertFalse(quest.members[2].roleIcon.shown)
    test.assertTrue(quest.anyTiles[2].filled)
    test.assertFalse(quest.anyTiles[3].filled)
    test.assertFalse(quest.roleTiles[1].shown)
    -- No dungeon, no icon.
    test.assertFalse(quest.iconTexture)

    local big = page.largeCards[2]
    test.assertEqual("Raid", big.purpose.text)
    test.assertContains(big.details.text, "12 players")
    test.assertTrue(big.raidTile.shown)
    test.assertEqual("12 players", big.count.text)
end)

test.test("lfg page: alts' groups as small cards, the leader's name a menu in class color", function()
    local listing = listingOf("dungeon", { purpose = "Wailing Caverns", minLevel = 17, maxLevel = 24,
        members = { { name = "Tool", classToken = "WARRIOR", role = "tank" } } })
    local page, whispered = pageWith({ relevant = {},
        alts = { { listing = listing, alt = { name = "Bolt", level = 20 } } }, other = {} })

    test.assertFalse(page.emptyText.shown)
    test.assertTrue(page.altsLabel.shown)
    local card = page.smallCards[1]
    test.assertFalse(card.greyed)
    test.assertEqual("Wailing Caverns", card.purpose.text)
    -- The second line: type and levels, then the leader, and nothing
    -- after (the role tiles share the row).
    test.assertEqual("Dungeon \194\183 17\226\128\14724 \194\183 ", card.details.text)
    test.assertEqual("|cffc79c6eTool|r", card.leader.name.text)
    whisperName(page, card.leader)
    test.assertEqual("Tool-Camelot", whispered[1])
    test.assertFalse(page.nearbyCard.shown)
end)

local NEARBY = {
    nearby = function()
        return { zone = "Ironforge", people = {
            { name = "Hammer", whisper = "Hammer-Camelot", level = 24, classToken = "WARRIOR" },
            { name = "Zap", whisper = "Zap-Camelot", level = 60, classToken = "MAGE" },
            { name = "Bolt", whisper = "Bolt-Camelot" },
        } }
    end,
}

test.test("lfg page: the Nearby tab lists guildmates with their levels in a column, each name a menu", function()
    local page, whispered = pageWith({ relevant = {}, alts = {}, other = {} }, NEARBY)

    -- Its own tab, between Relevant Parties and Other Parties, counted.
    test.assertEqual("nearby", page.tabs.tabs[2].id)
    test.assertEqual("Nearby \194\183 3", page.tabs.tabs[2].label.text)
    test.assertEqual("other", page.tabs.tabs[3].id)
    test.assertFalse(page.nearbyCard.shown)
    click(page.tabs.tabs[2])
    local nearby = page.nearbyCard
    test.assertTrue(nearby.shown)
    -- Wider now it has the tab to itself.
    test.assertEqual(320, nearby.width)
    test.assertEqual("NEARBY IN IRONFORGE", nearby.title.text)
    -- One per line, the level left of the name, the name in class color.
    test.assertEqual("24", nearby.rows[1].level.text)
    test.assertTrue(nearby.rows[1].level.shown)
    test.assertEqual("|cffc79c6eHammer|r", nearby.rows[1].name.text)
    test.assertEqual("60", nearby.rows[2].level.text)
    test.assertEqual("Zap", nearby.rows[2].name.text)
    -- An unknown level leaves the column empty, the name still in line.
    test.assertEqual("", nearby.rows[3].level.text)
    whisperName(page, nearby.rows[2])
    test.assertEqual("Zap-Camelot", whispered[1])

    -- Nobody nearby: one line.
    local empty = pageWith({ relevant = {}, alts = {}, other = {} })
    empty:ShowTab("nearby")
    test.assertEqual("Nearby \194\183 0", empty.tabs.tabs[2].label.text)
    test.assertTrue(empty.emptyText.shown)
    test.assertEqual("No guildmates nearby right now.", empty.emptyText.text)
end)


test.test("lfg page: Roles in your party shows each role's icon by the name, read-only", function()
    local page = pageWith({ relevant = {}, alts = {}, other = {} }, {
        partyRoles = function()
            return {
                { key = "tool", name = "Tool", classToken = "WARRIOR", role = "tank" },
                { key = "zap", name = "Zap", classToken = "MAGE", role = "dps" },
            }
        end,
    })
    page:StartEditing()
    local tool, zap = page.roleRows[1], page.roleRows[2]
    test.assertEqual("|cffc79c6eTool|r", tool.name.text)
    test.assertEqual("tank", tool.role)
    test.assertTrue(tool.roleIcon.shown)
    test.assertEqual("dps", zap.role)
    test.assertFalse(page.roleRows[3].shown)
    -- Roles are set in the game's party menu: the names open nothing.
    click(tool)
    test.assertTrue(page.namesMenu == nil or not page.namesMenu:IsOpen())
end)

test.test("lfg page: the name menu closes on a second click, a click outside it, and when its name goes", function()
    local page = pageWith({ relevant = {}, alts = {}, other = {} }, NEARBY)
    page:ShowTab("nearby")
    local row = page.nearbyCard.rows[1]
    click(row)
    test.assertTrue(page.namesMenu:IsOpen())
    test.assertTrue(page.namesMenu.catcher.shown)
    click(row)
    test.assertFalse(page.namesMenu:IsOpen())
    -- A click anywhere outside it.
    click(row)
    click(page.namesMenu.catcher)
    test.assertFalse(page.namesMenu:IsOpen())
    test.assertFalse(page.namesMenu.catcher.shown)
    click(row)
    page:ShowTab("history")
    test.assertFalse(page.namesMenu:IsOpen())
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
    test.assertContains(board.smallCards[1].leader.name.text, "Tool")
    board:ShowTab("nearby")
    test.assertTrue(board.nearbyCard.shown)
    test.assertEqual("NEARBY IN IRONFORGE", board.nearbyCard.title.text)
    local names = {}
    local index
    for index = 1, #board.nearbyCard.rows do
        if board.nearbyCard.rows[index].shown then
            table.insert(names, board.nearbyCard.rows[index].name.text)
        end
    end
    local listed = table.concat(names, ",")
    test.assertContains(listed, "Zap")
    test.assertContains(listed, "Tool")
    -- Each name whispers that character, by the name the guild has saved.
    local whispered
    hammer.environment.ChatFrame_SendTell = function(name)
        whispered = name
    end
    whisperName(board, board.nearbyCard.rows[1])
    test.assertContains(board.nearbyCard.rows[1].name.text, string.match(whispered, "^[^%-]+"))

    -- The LFG button's Show Nearby is handed the same guildmates.
    local nearby = hammer.addon.lfgButton.options.nearby()
    test.assertEqual("Ironforge", nearby.zone)
    test.assertContains(board.nearbyCard.rows[1].name.text, nearby.people[1].name)
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

    -- No zone levels from this client: Tool's level, 5 either way.
    local listing = zap.addon.lfgBoard:Listings(zap.time)[1]
    test.assertEqual("Ironforge", listing.purpose)
    test.assertEqual(55, listing.minLevel)
    test.assertEqual(65, listing.maxLevel)
    fixtures.slash(tool, "probe lfg")
    local printed = table.concat(tool.messages, "\n")
    test.assertContains(printed, "Zone levels in Ironforge: 55-65, the fallback")
    test.assertContains(printed, "Your listing: Questing in Ironforge.")

    fixtures.slash(zap, "probe lfg")
    printed = table.concat(zap.messages, "\n")
    test.assertContains(printed, "On the board: 0 relevant, 0 for your alts, 1 other.")
    test.assertContains(printed, "Other, Questing in Ironforge, by Tool Box, 1/5, levels 55-65")

    -- Where the game knows the zone's levels, they're used.
    tool.environment.C_Map.GetMapLevels = function()
        return 25, 35
    end
    fixtures.slash(tool, "probe lfg")
    test.assertContains(tool.messages[#tool.messages - 2], "Zone levels in Ironforge: 25-35, from the game.")
end)

-- Greetings ---------------------------------------------------------------------

test.test("greetings: the module sits after LFG, with the Greet prompts switch and the category list", function()
    local profile = fixtures.PROFILES[1]
    local world, addon = login(profile, fixtures.newChannel(), "Tool Box")
    fakeFrames.install(world.environment)
    local window = addon.agfWindow

    test.assertTrue(window:Open("greetings"))
    local order = {}
    local index
    for index = 1, #window.moduleButtons do
        order[index] = window.moduleButtons[index].id
    end
    test.assertEqual("friends,lfg,greetings,settings", table.concat(order, ","))
    test.assertEqual("Greetings", window.pages.greetings.title.text)
    test.assertTrue(window.gear.shown)

    -- The header switch is Show greet prompts.
    local header = window:HeaderSwitch("greetings")
    test.assertTrue(header.frame.shown)
    test.assertEqual("Greet prompts on", header.label.text)
    local page = addon.greetingsPage
    test.assertEqual("greetings", page:Tab())
    test.assertFalse(page.dimmed)
    click(header.switch)
    test.assertFalse(addon.settings:Get("guildGreet"))
    test.assertEqual("Greet prompts off", header.label.text)
    -- Off: the Greetings tab is dimmed, and still there on Settings.
    test.assertTrue(page.dimmed)
    click(page.tabs.tabs[2])
    test.assertEqual("settings", page:Tab())
    test.assertFalse(page.greetingsTab.shown)
    test.assertTrue(header.frame.shown)
    click(page.tabs.tabs[1])
    addon.settings:Set("guildGreet", true)
    test.assertFalse(page.dimmed)

    -- Join first, with the starters; Login's switch is the AddOns option.
    test.assertEqual("join", page.categories:Selected())
    test.assertEqual("Welcome to the guild, {name}!", page.rows[1].text.text)
    click(page.categories.buttons[2])
    test.assertEqual("Someone's first login you see this session.", page.description.text)
    test.assertEqual("Prompt me", page.switchLabel.text)
    test.assertTrue(page.switch:IsOn())
    click(page.switch)
    test.assertFalse(addon.settings:Get("greetCategory:login"))
    test.assertTrue(page.offNote.shown)
    test.assertEqual(addon.GreetingsEditor.OFF_NOTE, page.offNote.text)
    test.assertTrue(page.categories.buttons[2].dotShown)
    addon.settings:Set("greetCategory:login", true)
    test.assertFalse(page.categories.buttons[2].dotShown)
    test.assertFalse(page.offNote.shown)

    -- Welcome back's line has the minutes, and follows them.
    click(page.categories.buttons[3])
    test.assertContains(page.description.text, "more than " .. addon.settings:Get("welcomeBackMinutes") .. " minutes")
    addon.settings:Set("welcomeBackMinutes", 20)
    test.assertEqual("Someone you saw log off comes back after more than 20 minutes away.", page.description.text)

    -- A row shows Edit and 🗑 and its full text while hovered.
    local row = page.rows[1]
    test.assertFalse(row.edit.shown)
    row.scripts.OnEnter(row)
    test.assertTrue(row.edit.shown)
    -- Edit is a word, not an icon, and lights up on mouseover.
    test.assertEqual("Edit", row.edit.label.text)
    row.edit.scripts.OnEnter(row.edit)
    test.assertTrue(row.edit.hovered)
    row.edit.scripts.OnLeave(row.edit)
    test.assertFalse(row.edit.hovered)
    test.assertTrue(row.delete.shown)
    row.scripts.OnLeave(row)
    test.assertFalse(row.delete.shown)

    -- Saved greetings changed while it was away show when it's shown again.
    local greetings = addon.guildGreet:Library():Greetings("welcomeBack")
    addon.guildGreet:Library():Add("welcomeBack", "Back again, {name}?")
    window:ShowPage("lfg")
    window:ShowPage("greetings")
    test.assertEqual("Back again, {name}?", page.rows[#greetings + 1].text.text)
    test.assertTrue(page.rows[#greetings + 1].shown)
end)

test.test("greetings: ✎ edits a greeting in place, + Add a greeting adds one at the bottom", function()
    local profile = fixtures.PROFILES[1]
    local world, addon = login(profile, fixtures.newChannel(), "Tool Box")
    fakeFrames.install(world.environment)
    local window = addon.agfWindow
    test.assertTrue(window:Open("greetings"))
    local page = addon.greetingsPage
    local library = addon.guildGreet:Library()
    local box = page.edit.input.box
    local function typeText(text)
        box:SetText(text)
        box.scripts.OnTextChanged(box, true)
    end

    -- ✎ on the second Join greeting: the box takes its row's place.
    local row = page.rows[2]
    click(row.edit)
    test.assertTrue(page.edit.shown)
    test.assertFalse(row.shown)
    test.assertEqual("Welcome aboard, {name}! Glad to have you.", box:GetText())
    test.assertEqual("Save", page.edit.save.label.text)
    test.assertFalse(page.edit.save.active)
    typeText("Welcome aboard, {name}!")
    test.assertTrue(page.edit.save.active)
    -- Enter saves.
    box.scripts.OnEnterPressed(box)
    test.assertEqual("Welcome aboard, {name}!", library:Greetings("join")[2])
    test.assertFalse(page.edit.shown)
    test.assertEqual("Welcome aboard, {name}!", page.rows[2].text.text)

    -- + Add a greeting: an empty box at the bottom, Add.
    click(page.add)
    test.assertFalse(page.add.shown)
    test.assertEqual("", box:GetText())
    test.assertEqual("Add", page.edit.save.label.text)
    typeText("Hi {name}, make yourself at home!")
    click(page.edit.save)
    local join = library:Greetings("join")
    test.assertEqual("Hi {name}, make yourself at home!", join[#join])
    test.assertTrue(page.add.shown)

    -- Escape cancels: nothing saved.
    click(page.rows[1].edit)
    typeText("Not this")
    box.scripts.OnEscapePressed(box)
    test.assertFalse(page.edit.shown)
    test.assertEqual("Welcome to the guild, {name}!", library:Greetings("join")[1])

    -- A refused save shows why under the box, for a few seconds.
    click(page.add)
    typeText("Hello {name}")
    local saved = library.state.greetings.join
    library.state.greetings.join = "unreadable"
    click(page.edit.save)
    library.state.greetings.join = saved
    test.assertEqual("Can't save: the saved greetings are unreadable.", page.edit.error.text)
    fixtures.runTimers(world, 1)
    test.assertTrue(page.edit.error.text ~= "")
    fixtures.runTimers(world, 5)
    test.assertEqual("", page.edit.error.text)
    test.assertTrue(page.edit.shown)

    -- A draft is dropped on another tab, another category, or the window closing.
    click(page.tabs.tabs[2])
    click(page.tabs.tabs[1])
    test.assertFalse(page.edit.shown)
    click(page.rows[1].edit)
    click(page.categories.buttons[2])
    test.assertFalse(page.edit.shown)
    click(page.rows[1].edit)
    test.assertTrue(page.edit.shown)
    page.content.scripts.OnHide(page.content)
    test.assertFalse(page.edit.shown)
    test.assertEqual("Hey {name}!", library:Greetings("login")[1])
end)

test.test("greetings: Insert chips and More put placeholders in, and the preview uses the user's names", function()
    local profile = fixtures.PROFILES[1]
    local world, addon = login(profile, fixtures.newChannel(), "Tool Box")
    fakeFrames.install(world.environment)
    local tooltip = { lines = {} }
    function tooltip.SetOwner() end
    function tooltip.SetText(_, text)
        tooltip.lines = { text }
    end
    function tooltip.AddLine(_, text)
        table.insert(tooltip.lines, text)
    end
    function tooltip.Show()
        tooltip.shown = true
    end
    function tooltip.Hide()
        tooltip.shown = false
    end
    world.environment.GameTooltip = tooltip
    test.assertTrue(addon.agfWindow:Open("greetings"))
    local page = addon.greetingsPage
    local edit = page.edit

    -- The chips are part of the edit box, hidden until it's open.
    test.assertFalse(edit.shown)
    click(page.add)
    test.assertTrue(edit.shown)
    test.assertEqual("{name}", edit.chips[1].label.text)
    test.assertEqual("{character}", edit.chips[3].label.text)
    edit.chips[2].hooks.OnEnter(edit.chips[2])
    test.assertEqual("{main}", tooltip.lines[1])
    test.assertEqual("their main's name, even when they have an alias", tooltip.lines[2])
    edit.chips[2].hooks.OnLeave(edit.chips[2])
    test.assertFalse(tooltip.shown)

    -- A chip goes in at the cursor.
    local box = edit.input.box
    box:SetText("Hi !")
    box.scripts.OnTextChanged(box, true)
    rawset(box, "GetCursorPosition", function()
        return 3
    end)
    click(edit.chips[1])
    test.assertEqual("Hi {name}!", box:GetText())
    test.assertEqual(9, rawget(box, "cursor"))
    -- The preview fills it in with the user's own name.
    local _, _, normalizer = addon.rosterController:QuietContext()
    local names = addon.guildGreet:Names(normalizer:Key(addon.client:GetPlayerFullName()),
        addon.client:GetPlayerFullName())
    test.assertEqual("Preview: Hi " .. names.name .. "!", edit.preview.text)

    -- More offers the rare four and the note.
    click(edit.more)
    local menu = edit.moreMenu
    test.assertTrue(menu.open)
    test.assertContains(menu.rows[1].label.text, "{mainFirst}")
    test.assertContains(menu.rows[4].label.text, "{characterLast}")
    test.assertContains(menu.rows[5].label.text, "WoW Forever's two-part names")
    rawset(box, "GetCursorPosition", function()
        return 0
    end)
    click(menu.rows[3])
    test.assertEqual("{characterFirst}Hi {name}!", box:GetText())
    test.assertEqual("Preview: " .. names.characterfirst .. "Hi " .. names.name .. "!", edit.preview.text)
end)

-- Friends -----------------------------------------------------------------------

test.test("friends: the window opens on Friends, the page is built on show, and a pinned Friend is starred", function()
    local profile = fixtures.PROFILES[1]
    local world, addon = login(profile, fixtures.newChannel(), "Tool Box")
    fakeFrames.install(world.environment)

    test.assertTrue(addon.agfWindow:Open())
    test.assertEqual("friends", addon.agfWindow:Page())
    local page = addon.friendsPage
    test.assertTrue(page ~= nil)
    test.assertTrue(page.cards[1].empty)

    -- Pinning Hammer Smith through the picker: the user isn't offered.
    click(page.cards[1])
    test.assertTrue(page:PickerOpen())
    local hammer, tool
    local index
    for index = 1, #page.picker.rows do
        local row = page.picker.rows[index]
        if row.shown and row.entry.name == "Hammer Smith" then
            hammer = row
        elseif row.shown and row.entry.name == "Tool Box" then
            tool = row
        end
    end
    test.assertEqual(nil, tool)
    click(hammer)
    test.assertEqual("Hammer Smith", page.cards[1].name.text)
    -- The detail panel shows Hammer from saved data and the roster.
    test.assertEqual("Hammer Smith", page.detail.name.text)
    test.assertEqual("Friend", page.detail.badge.text)
    test.assertTrue(page.detail.tiles[1].shown)
    test.assertEqual("Discord", page.detail.view.tiles[1].label)
    -- Its tabs: Hammer and the alt Bolt, and the Log from the old panel.
    test.assertEqual("Characters · 2", page.detail.tabs.tabs[1].label.text)
    local cardName = string.gsub(string.gsub(page.detail.characterCards[1].name.text, "|c%x%x%x%x%x%x%x%x", ""), "|r", "")
    test.assertEqual("Hammer Smith", cardName)
    test.assertTrue(page.detail.view.logRows[1] ~= nil)

    -- Hammer's alt Bolt shares the Friend tier, with Guild Greet's perks.
    local _, partition, normalizer = addon.rosterController:QuietContext()
    test.assertEqual(1, #partition:GetFriends())
    test.assertTrue(addon.guildGreet:HasPerks(normalizer:Key("Bolt Smith")))
    test.assertFalse(addon.guildGreet:HasPerks(normalizer:Key("Zap Arcane")))

    -- Shown again, the page is built again.
    addon.agfWindow:ShowPage("lfg")
    addon.agfWindow:ShowPage("friends")
    test.assertEqual("Hammer Smith", page.cards[1].name.text)
end)

test.test("friends: Open in Guild Fellowship on a guildmate's menu opens the window on their player", function()
    local profile = fixtures.PROFILES[1]
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = "Tool Box" })
    world.playerLevel = TOP_LEVEL[profile]
    local callbacks = {}
    world.environment.Menu = {
        ModifyMenu = function(tag, callback)
            callbacks[tag] = callback
        end,
    }
    fixtures.joinChannel(fixtures.newChannel(), world)
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    fakeFrames.install(world.environment)
    test.assertTrue(callbacks.MENU_UNIT_FRIEND ~= nil)

    local root = { buttons = {} }
    function root:CreateButton(text, onClick)
        table.insert(self.buttons, { text = text, onClick = onClick })
    end
    -- Bolt Smith is Hammer Smith's alt; someone outside the guild gets nothing.
    callbacks.MENU_UNIT_FRIEND(nil, root, { name = "Bolt Smith" })
    callbacks.MENU_UNIT_FRIEND(nil, root, { name = "Nobody Here" })
    test.assertEqual(1, #root.buttons)
    root.buttons[1].onClick()

    test.assertTrue(addon.agfWindow:IsOpen())
    test.assertEqual("friends", addon.agfWindow:Page())
    local page = addon.friendsPage
    local _, partition, normalizer = addon.rosterController:QuietContext()
    test.assertEqual(partition:GetCharacter(normalizer:Key("Bolt Smith")).player, page:Selected())
    test.assertEqual("Hammer Smith", page.detail.name.text)
    test.assertTrue(page.cards[1].empty)
    test.assertTrue(page.detail.view.header.canToggle)
    test.assertFalse(page.detail.view.header.isFriend)
end)

test.test("greetings: 🗑 asks Delete? first, and an empty category says it won't prompt", function()
    local profile = fixtures.PROFILES[1]
    local world, addon = login(profile, fixtures.newChannel(), "Tool Box")
    fakeFrames.install(world.environment)
    test.assertTrue(addon.agfWindow:Open("greetings"))
    local page = addon.greetingsPage
    local library = addon.guildGreet:Library()
    click(page.categories.buttons[2])
    local count = #library:Greetings("login")

    -- The first click turns 🗑 into a red Delete?; nothing is deleted.
    local row = page.rows[1]
    row.scripts.OnEnter(row)
    click(row.delete)
    test.assertTrue(row.confirm.shown)
    test.assertFalse(row.delete.shown)
    test.assertEqual("Delete?", row.confirm.label.text)
    test.assertEqual(count, #library:Greetings("login"))
    -- Left alone, it goes back to 🗑 after 5 seconds.
    fixtures.runTimers(world, 6)
    test.assertFalse(row.confirm.shown)
    test.assertEqual(count, #library:Greetings("login"))

    -- A second click deletes.
    click(row.delete)
    click(row.confirm)
    test.assertEqual(count - 1, #library:Greetings("login"))
    test.assertFalse(row.confirm.shown)

    -- Down to the last one, then none.
    while #library:Greetings("login") > 1 do
        library:Remove("login", 1)
    end
    page:Refresh()
    click(page.rows[1].delete)
    test.assertEqual("Delete? (last one)", page.rows[1].confirm.label.text)
    click(page.rows[1].confirm)
    test.assertEqual(0, #library:Greetings("login"))
    test.assertTrue(page.empty.shown)
    test.assertEqual("No Login greetings yet. You won't get login prompts until you add one.", page.empty.text)
    test.assertTrue(page.add.shown)
    test.assertFalse(page.rows[1].shown)
    test.assertTrue(page.categories.buttons[2].dotShown)

    -- Join still has greetings: no empty text there.
    click(page.categories.buttons[1])
    test.assertFalse(page.empty.shown)
end)

test.test("greetings: loading deletes saved Long absence greetings and its switch, and the page shows Friends", function()
    local profile = fixtures.PROFILES[1]
    local database = {
        schemaVersion = 4,
        guilds = {},
        greet = {
            greetings = { login = { "Hi {name}" }, longAbsence = { "Ages, {name}!" } },
            lastUsed = { longAbsence = "Ages, {name}!" },
            categories = { longAbsence = false },
        },
    }
    local world = fixtures.newEnvironment(profile, { guild = guild(profile), playerName = "Tool Box",
        database = database })
    world.playerLevel = TOP_LEVEL[profile]
    fixtures.joinChannel(fixtures.newChannel(), world)
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)

    local greet = world.database.greet
    test.assertEqual(nil, greet.greetings.longAbsence)
    test.assertEqual(nil, greet.lastUsed.longAbsence)
    test.assertEqual(nil, greet.categories.longAbsence)
    test.assertEqual("Hi {name}", greet.greetings.login[1])

    fakeFrames.install(world.environment)
    test.assertTrue(addon.agfWindow:Open("greetings"))
    local page = addon.greetingsPage
    click(page.categories.buttons[4])
    test.assertEqual("Use for friends", page.switchLabel.text)
    test.assertEqual("There you are, {name}!", page.rows[1].text.text)
end)
