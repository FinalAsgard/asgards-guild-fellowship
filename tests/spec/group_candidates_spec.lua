local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

local GUILD = { name = "Knights of Camelot", realm = "Camelot" }
local NOW = 1790000000
local DEADMINES = { id = "dm", name = "The Deadmines", minLevel = 17, maxLevel = 26 }

local function load()
    return test.newAddon("Core/FellowshipStore.lua", "Core/RoleCatalog.lua", "Core/GroupCandidates.lua",
        "Core/DungeonCatalog.lua", "Core/GroupSession.lua", "Adapters/GroupFinderWindow.lua")
end

-- A guild:
--   Thunderer (alias): Bolt, a shaman (22, online in Ironforge), with
--     alts Hammer, a paladin (24, offline), and Oldbolt, a warrior (60)
--   Cleric, a priest (20, online), no add-on
--   Zap, a mage (22, online)
--   Busy, a warrior (25, online), replied unavailable
--   Sleepy, a druid (22, offline)
--   Me, a warrior (24, online): the organizer
--   Mate, a rogue (23, online): already in the party
local function newGuild()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 3, guilds = {} }):Partition(GUILD)
    local function add(key, class, level)
        partition:RecordCharacter(key, { name = key:gsub("^%l", string.upper), classToken = class, level = level })
    end
    add("bolt", "SHAMAN", 22)
    add("hammer", "PALADIN", 24)
    add("oldbolt", "WARRIOR", 60)
    partition:JoinPlayerOf("hammer", "bolt", "manual")
    partition:JoinPlayerOf("oldbolt", "bolt", "manual")
    partition:SetAlias(partition:GetCharacter("bolt").player, "Thunderer", "manual")
    add("cleric", "PRIEST", 20)
    add("zap", "MAGE", 22)
    add("busy", "WARRIOR", 25)
    add("sleepy", "DRUID", 22)
    add("me", "WARRIOR", 24)
    add("mate", "ROGUE", 23)
    local world = {
        addon = addon,
        partition = partition,
        members = {
            bolt = { online = true, zone = "Ironforge", level = 22, name = "Bolt" },
            hammer = { online = false, name = "Hammer" },
            oldbolt = { online = false, name = "Oldbolt" },
            cleric = { online = true, zone = "Stormwind", level = 20, name = "Cleric" },
            zap = { online = true, zone = "Westfall", level = 22, name = "Zap" },
            busy = { online = true, zone = "Duskwood", level = 25, name = "Busy" },
            sleepy = { online = false, name = "Sleepy" },
            me = { online = true, zone = "Westfall", level = 24, name = "Me" },
            mate = { online = true, zone = "Westfall", level = 23, name = "Mate" },
        },
        replies = {
            bolt = { key = "bolt", available = true },
            zap = { key = "zap", available = true },
            busy = { key = "busy", available = false },
        },
        excluded = { me = true, mate = true },
    }
    function world.candidates()
        return addon.GroupCandidates.Create({
            partition = partition,
            members = world.members,
            roles = addon.RoleCatalog.For("forever"),
            replies = world.replies,
            excluded = world.excluded,
        })
    end
    return world
end

local function labels(list)
    local result = {}
    local index
    for index = 1, #list do
        result[index] = list[index].label
    end
    return table.concat(result, ", ")
end

local function names(characters)
    local result = {}
    local index
    for index = 1, #characters do
        result[index] = characters[index].name .. " " .. characters[index].level
    end
    return table.concat(result, ", ")
end

test.test("group candidates: one entry per player, with alias, current character and zone", function()
    local world = newGuild()

    local healers = world.candidates():ForRole("healer", DEADMINES)

    test.assertEqual("Thunderer, Cleric", labels(healers))
    local thunderer = healers[1]
    test.assertEqual("bolt", thunderer.current.key)
    test.assertEqual("Bolt", thunderer.current.name)
    test.assertEqual("Ironforge", thunderer.current.zone)
    -- The offline alt is offered too: they can log over.
    test.assertEqual("Bolt 22, Hammer 24", names(thunderer.fitting))
end)

test.test("group candidates: only characters whose level fits the dungeon are offered", function()
    local world = newGuild()
    local candidates = world.candidates()

    -- Oldbolt (60) could tank, but not in the Deadmines; Hammer (24) can.
    local tanks = candidates:ForRole("tank", DEADMINES)
    test.assertEqual("Thunderer", labels(tanks))
    test.assertEqual("Hammer 24", names(tanks[1].fitting))

    local tanksForStrat = candidates:ForRole("tank", { minLevel = 58, maxLevel = 60 })
    test.assertEqual("Oldbolt 60", names(tanksForStrat[1].fitting))
    -- Nobody fits a dungeon far from everyone's level.
    test.assertEqual(0, #candidates:ForRole("dps", { minLevel = 40, maxLevel = 45 }))
end)

test.test("group candidates: add-on users' role preferences leave out roles they turned off", function()
    local world = newGuild()
    world.partition:SetRoles("hammer", { "dps" }, NOW, "hammer")

    local candidates = world.candidates()

    test.assertEqual("Bolt 22", names(candidates:ForRole("healer", DEADMINES)[1].fitting))
    test.assertEqual(0, #candidates:ForRole("tank", DEADMINES))
    local dps = candidates:ForRole("dps", DEADMINES)
    test.assertEqual("Thunderer, Zap, Cleric", labels(dps))
    test.assertEqual("Bolt 22, Hammer 24", names(dps[1].fitting))
end)

test.test("group candidates: guildmates without the add-on are labeled and suggested by class alone", function()
    local world = newGuild()
    -- Even a stored preference is ignored for someone whose add-on didn't
    -- reply: it may be stale.
    world.partition:SetRoles("cleric", { "dps" }, NOW, "cleric")

    local healers = world.candidates():ForRole("healer", DEADMINES)

    test.assertTrue(healers[1].addon)
    test.assertEqual("Cleric", healers[2].label)
    test.assertFalse(healers[2].addon)
    test.assertContains(world.addon.GroupCandidates.Describe(healers[2]), "(no add-on)")
end)

test.test("group candidates: only players online now, and never unavailable or excluded ones", function()
    local world = newGuild()
    local candidates = world.candidates()

    local everyone = {}
    local role
    for _, role in ipairs({ "tank", "healer", "dps" }) do
        local list = candidates:ForRole(role, DEADMINES)
        local index
        for index = 1, #list do
            everyone[list[index].label] = true
        end
    end
    -- Sleepy is offline; Busy replied unavailable; Me and Mate are the
    -- organizer and the party.
    test.assertEqual(nil, everyone.Sleepy)
    test.assertEqual(nil, everyone.Busy)
    test.assertEqual(nil, everyone.Me)
    test.assertEqual(nil, everyone.Mate)
    test.assertTrue(everyone.Thunderer)
    test.assertTrue(everyone.Zap)

    -- Busy comes back once available, Thunderer goes when they log off.
    world.replies.busy.available = true
    world.members.bolt.online = false
    local tanks = world.candidates():ForRole("tank", DEADMINES)
    test.assertEqual("Busy", labels(tanks))
end)

test.test("group candidates: filled roles get no suggestions", function()
    local world = newGuild()

    local lists = world.candidates():Suggestions(DEADMINES, { "dps", "healer", "dps" })

    test.assertEqual(2, #lists)
    test.assertEqual("healer", lists[1].role)
    test.assertEqual("dps", lists[2].role)
    test.assertEqual(0, #world.candidates():Suggestions(DEADMINES, {}))
end)

test.test("group candidates: describes an entry with its fitting characters", function()
    local world = newGuild()
    local healers = world.candidates():ForRole("healer", DEADMINES)

    test.assertEqual("Bolt 22, Hammer 24", world.addon.GroupCandidates.Describe(healers[1]))
    test.assertEqual("Cleric 20 (no add-on)", world.addon.GroupCandidates.Describe(healers[2]))
    -- Where they are now goes in the mouseover.
    test.assertEqual("On Bolt, Ironforge", world.addon.GroupCandidates.Location(healers[1]))
end)

test.test("group candidates: character names in their class colors", function()
    local world = newGuild()
    local healers = world.candidates():ForRole("healer", DEADMINES)
    local colors = { SHAMAN = "ff0070dd", PALADIN = "fff58cba" }
    local function colorOf(class)
        return colors[class]
    end

    test.assertEqual("|cff0070ddBolt|r 22, |cfff58cbaHammer|r 24", world.addon.GroupCandidates.Describe(healers[1], colorOf))
    test.assertEqual("On |cff0070ddBolt|r, Ironforge", world.addon.GroupCandidates.Location(healers[1], colorOf))
    -- A class with no color stays plain.
    test.assertEqual("Cleric 20 (no add-on)", world.addon.GroupCandidates.Describe(healers[2], colorOf))
    local nearby = world.candidates():Nearby("Ironforge", "me")
    test.assertEqual("Thunderer — |cff0070ddBolt|r 22", world.addon.GroupCandidates.DescribeNearby(nearby[1], colorOf))
end)

-- The window's lists ----------------------------------------------------------

local function newWindow(world)
    local addon = world.addon
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local roles = addon.RoleCatalog.For("forever")
    world.session = addon.GroupSession.Create(roles)
    world.window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES }) end,
        playerLevel = function() return 24 end,
        session = world.session,
        roles = roles,
        syncParty = function()
            if world.session:IsActive() then
                world.session:UpdateParty({
                    { key = "me", name = "Me", classToken = "WARRIOR", inGuild = true, isPlayer = true },
                }, false)
            end
        end,
        candidates = world.candidates,
    })
    world.window:Opened()
    return world.window
end

local function shownLines(window)
    local texts = {}
    local index
    for index = 1, #window.suggestionLines do
        if window.suggestionLines[index].shown then
            table.insert(texts, window.suggestionLines[index].text)
        end
    end
    return texts
end

test.test("group finder window: the picker shows each dungeon with its range and no role counts", function()
    local window = newWindow(newGuild())

    test.assertEqual("The Deadmines (17–26)", window.rows[1].label.text)
    -- Before a dungeon is picked, the column holds only Nearby.
    test.assertTrue(window.suggestions.shown)
    test.assertContains(window.suggestionLines[1].text, "Nearby")
end)

test.test("group finder window: each open role lists who could fill it, and filled roles none", function()
    local world = newGuild()
    local window = newWindow(world)

    window:Pick("dm")

    test.assertTrue(window.suggestions.shown)
    local lines = shownLines(window)
    -- The organizer, a warrior, took the tank slot: no tank list.
    test.assertEqual("|cffffd100Healer|r", lines[1])
    test.assertEqual("  Bolt 22, Hammer 24", lines[2])
    test.assertEqual("  Cleric 20 (no add-on)", lines[3])
    -- Hovering a guildmate's line shows where they are; headings have none.
    test.assertEqual("On Bolt, Ironforge", window.suggestionHovers[2].text)
    test.assertTrue(window.suggestionHovers[2].frame.shown)
    test.assertFalse(window.suggestionHovers[1].frame.shown)
    local tooltip = { shown = false }
    function tooltip:SetOwner(owner, anchor) self.anchor = anchor end
    function tooltip:ClearAllPoints() self.point = nil end
    function tooltip:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = { point = point, relativePoint = relativePoint, x = x, y = y }
    end
    function tooltip:SetText(text) self.text = text end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    window.environment.GameTooltip = tooltip
    -- The cursor at (400, 300) screen pixels, with the UI at scale 2.
    window.environment.GetCursorPosition = function() return 400, 300 end
    rawset(window.environment.UIParent, "GetEffectiveScale", function() return 2 end)
    window.suggestionHovers[2].frame.scripts.OnEnter(window.suggestionHovers[2].frame)
    test.assertEqual("On Bolt, Ironforge", tooltip.text)
    test.assertTrue(tooltip.shown)
    -- Just above the cursor and a little to its right.
    test.assertEqual("ANCHOR_NONE", tooltip.anchor)
    test.assertEqual("BOTTOMLEFT", tooltip.point.point)
    test.assertEqual(200 + 12, tooltip.point.x)
    test.assertEqual(150 + 12, tooltip.point.y)
    window.suggestionHovers[2].frame.scripts.OnLeave()
    test.assertFalse(tooltip.shown)
    test.assertEqual("|cffffd100DPS|r", lines[4])
    local index
    for index = 1, #lines do
        test.assertFalse(string.find(lines[index], "Tank", 1, true) ~= nil, lines[index])
    end
end)

test.test("group finder window: a role nobody online fits says so", function()
    local addon = load()
    local texts = addon.GroupFinderWindow.SuggestionTexts({ { role = "tank", players = {} } })

    test.assertEqual("|cffffd100Tank|r", texts[1])
    test.assertContains(texts[2], "No one online fits.")
    test.assertEqual("Every role is filled.", addon.GroupFinderWindow.SuggestionTexts({})[1])
end)

-- Nearby ------------------------------------------------------------------------

test.test("nearby: online guildmates in the zone, at any level and whatever their availability", function()
    local world = newGuild()
    -- Oldbolt (60) is online in Westfall too, beside Zap and Me and Mate.
    world.members.oldbolt = { online = true, zone = "Westfall", level = 60, name = "Oldbolt" }
    world.members.busy.zone = "Westfall"

    local nearby = world.candidates():Nearby("Westfall", "me")

    -- The organizer's own player is left out; Busy (unavailable) and Mate
    -- (in the party) are still nearby.
    test.assertEqual("Busy, Mate, Thunderer, Zap", labels(nearby))
    test.assertEqual("Oldbolt 60", names(nearby[3].characters))
    test.assertEqual("Thunderer — Oldbolt 60", world.addon.GroupCandidates.DescribeNearby(nearby[3]))
    test.assertEqual(0, #world.candidates():Nearby("Moonglade", "me"))
    test.assertEqual(0, #world.candidates():Nearby(nil, "me"))
end)

test.test("nearby: one entry per player, with each of their characters there", function()
    local world = newGuild()
    world.members.hammer = { online = true, zone = "Ironforge", level = 24, name = "Hammer" }

    local nearby = world.candidates():Nearby("Ironforge", "me")

    test.assertEqual("Thunderer", labels(nearby))
    test.assertEqual("Bolt 22, Hammer 24", names(nearby[1].characters))
end)

test.test("group finder window: Nearby shows before a dungeon is picked, and under the suggestions after", function()
    local world = newGuild()
    local addon = world.addon
    local environment = fakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local roles = addon.RoleCatalog.For("forever")
    local session = addon.GroupSession.Create(roles)
    local window = addon.GroupFinderWindow.Create({
        environment = environment,
        GetGlobal = function(_, name) return environment[name] end,
    }, fakeFrames.host(environment), {
        dungeons = function() return addon.DungeonCatalog.Create({ DEADMINES }) end,
        playerLevel = function() return 24 end,
        session = session,
        roles = roles,
        candidates = world.candidates,
        zone = function() return "Westfall" end,
        selfKey = function() return "me" end,
    })
    window:Opened()

    local lines = shownLines(window)
    test.assertEqual("|cffffd100Nearby in Westfall|r", lines[1])
    test.assertEqual("  Mate — Mate 23", lines[2])
    test.assertEqual("  Zap — Zap 22", lines[3])

    window:Pick("dm")
    lines = shownLines(window)
    test.assertEqual("|cffffd100Tank|r", lines[1])
    test.assertEqual("|cffffd100Nearby in Westfall|r", lines[#lines - 2])

    -- It updates on a refresh.
    world.members.zap.zone = "Duskwood"
    window:Refresh()
    lines = shownLines(window)
    test.assertEqual("  Mate — Mate 23", lines[#lines])
end)

test.test("group finder window: nobody nearby says so", function()
    local addon = load()
    local items = addon.GroupFinderWindow.NearbyItems({}, "Moonglade")

    test.assertEqual("|cffffd100Nearby in Moonglade|r", items[1].text)
    test.assertContains(items[2].text, "No guildmates nearby.")
end)
