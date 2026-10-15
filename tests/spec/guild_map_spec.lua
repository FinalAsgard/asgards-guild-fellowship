local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon("Core/LocationProtocol.lua", "Core/LocationScheduler.lua", "Core/LocationBoard.lua")
end

local SPOT = { mapId = 1429, x = 0.41234, y = 0.6, class = "MAGE", level = 42 }

-- LocationProtocol -----------------------------------------------------------

test.test("location messages carry the character, zone, rounded position, class and level", function()
    local protocol = load().LocationProtocol

    local message = protocol.Location("hammer-area52", SPOT)

    test.assertEqual("gm-loc", message.t)
    test.assertEqual(protocol.VERSION, message.v)
    test.assertEqual("hammer-area52", message.c)
    test.assertEqual(1429, message.m)
    test.assertEqual(0.412, message.x)
    test.assertEqual(0.6, message.y)
    test.assertEqual("MAGE", message.cl)
    test.assertEqual(42, message.l)
    test.assertTrue(protocol.IsValid(message))
    test.assertTrue(protocol.IsValid(protocol.Near("hammer-area52", SPOT)))
    test.assertTrue(protocol.IsValid(protocol.Hide("hammer-area52")))
    test.assertTrue(protocol.TYPES["gm-loc"] and protocol.TYPES["gm-near"] and protocol.TYPES["gm-hide"])
end)

test.test("malformed location messages and other versions are ignored", function()
    local protocol = load().LocationProtocol
    local function with(field, value)
        local message = protocol.Location("hammer-area52", SPOT)
        message[field] = value
        return message
    end

    test.assertFalse(protocol.IsValid(with("v", protocol.VERSION + 1)))
    test.assertFalse(protocol.IsValid(with("t", "gm-unknown")))
    test.assertFalse(protocol.IsValid(with("c", "")))
    test.assertFalse(protocol.IsValid(with("m", 1.5)))
    test.assertFalse(protocol.IsValid(with("m", "1429")))
    test.assertFalse(protocol.IsValid(with("x", 1.2)))
    test.assertFalse(protocol.IsValid(with("y", -0.1)))
    test.assertFalse(protocol.IsValid(with("cl", nil)))
    test.assertFalse(protocol.IsValid(with("l", 0)))
    test.assertFalse(protocol.IsValid({ v = protocol.VERSION, t = "gm-hide" }))
    test.assertFalse(protocol.IsValid("gm-loc"))
end)

-- LocationScheduler ----------------------------------------------------------

test.test("the location goes to the guild every 2 minutes", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()
    local function tick(now, spot)
        return scheduler:Tick({ now = now, character = "hammer-area52", spot = spot or SPOT })
    end

    test.assertEqual("gm-loc", tick(1000).t)
    test.assertEqual(nil, tick(1005))
    test.assertEqual(nil, tick(1119))
    test.assertEqual("gm-loc", tick(1120).t)
    -- Nowhere to place the player: nothing goes out.
    test.assertEqual(nil, scheduler:Tick({ now = 1300, character = "hammer-area52" }))
    test.assertEqual(nil, scheduler:Tick({ now = 1300, spot = SPOT }))
end)

test.test("a zone change goes out promptly, but at most once every 10 seconds", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()
    local elsewhere = { mapId = 1453, x = 0.5, y = 0.5, class = "MAGE", level = 42 }
    local function tick(now, spot)
        return scheduler:Tick({ now = now, character = "hammer-area52", spot = spot })
    end

    tick(1000, SPOT)
    -- Moving within the zone waits for the next broadcast.
    test.assertEqual(nil, tick(1030, { mapId = 1429, x = 0.1, y = 0.1, class = "MAGE", level = 42 }))
    test.assertEqual(1453, tick(1040, elsewhere).m)
    -- Straight back: held until 10 seconds have passed.
    test.assertEqual(nil, tick(1045, SPOT))
    test.assertEqual(1429, tick(1050, SPOT).m)
end)

-- LocationBoard --------------------------------------------------------------

test.test("the board keeps each guildmate's latest position and never the player's own characters", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create({
        isOwn = function(key)
            return key == "toolbox-area52" or key == "wrench-area52"
        end,
    })

    test.assertTrue(board:OnLocation(protocol.Location("hammer-area52", SPOT), "hammer-area52", 1000))
    test.assertTrue(board:OnLocation(protocol.Location("hammer-area52", { mapId = 1429, x = 0.5, y = 0.25,
        class = "MAGE", level = 43 }), "hammer-area52", 1010))
    test.assertFalse(board:OnLocation(protocol.Location("toolbox-area52", SPOT), "toolbox-area52", 1010))
    test.assertFalse(board:OnLocation(protocol.Location("wrench-area52", SPOT), "wrench-area52", 1010))
    -- A message about someone else than its sender.
    test.assertFalse(board:OnLocation(protocol.Location("visitor-area52", SPOT), "hammer-area52", 1010))

    local all = board:All()
    test.assertEqual(1, #all)
    test.assertEqual("hammer-area52", all[1].key)
    test.assertEqual(0.5, all[1].x)
    test.assertEqual(0.25, all[1].y)
    test.assertEqual(43, all[1].level)
    test.assertEqual("MAGE", all[1].class)
    test.assertEqual(1010, all[1].heard)
end)

-- Two Eastern Kingdoms zones and one Kalimdor zone.
local ZONES = { elwynn = 1429, westfall = 1436, durotar = 1411 }
local CONTINENTS = { [1429] = 1415, [1436] = 1415, [1411] = 1414 }

test.test("the board groups guildmates per zone: up to 3 as dots, 4 or more as a count", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create()
    local function at(key, mapId, now)
        board:OnLocation(protocol.Location(key, { mapId = mapId, x = 0.5, y = 0.5, class = "MAGE", level = 30 }),
            key, now or 1000)
    end
    at("a-area52", ZONES.elwynn)
    at("b-area52", ZONES.elwynn)
    at("c-area52", ZONES.elwynn)
    at("d-area52", ZONES.westfall)
    at("e-area52", ZONES.durotar)

    local zones = board:Markers(function(mapId)
        return mapId
    end)
    test.assertEqual(3, #zones)
    test.assertEqual(ZONES.durotar, zones[1].area)
    test.assertEqual(ZONES.elwynn, zones[2].area)
    test.assertEqual("dots", zones[2].display)
    test.assertEqual(3, #zones[2].people)
    test.assertEqual("a-area52", zones[2].people[1].key)

    at("f-area52", ZONES.elwynn)
    zones = board:Markers(function(mapId)
        return mapId
    end)
    test.assertEqual("count", zones[2].display)
    test.assertEqual(4, #zones[2].people)
end)

test.test("the board groups guildmates per continent for the world map", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create()
    local keys = { "a-area52", "b-area52", "c-area52", "d-area52", "e-area52" }
    local maps = { ZONES.elwynn, ZONES.elwynn, ZONES.westfall, ZONES.westfall, ZONES.durotar }
    local index
    for index = 1, #keys do
        board:OnLocation(protocol.Location(keys[index], { mapId = maps[index], x = 0.5, y = 0.5, class = "MAGE",
            level = 30 }), keys[index], 1000)
    end
    -- A zone whose continent isn't known is left out.
    board:OnLocation(protocol.Location("z-area52", { mapId = 9999, x = 0.5, y = 0.5, class = "MAGE", level = 30 }),
        "z-area52", 1000)

    local continents = board:Markers(function(mapId)
        return CONTINENTS[mapId]
    end)

    test.assertEqual(2, #continents)
    test.assertEqual(1414, continents[1].area)
    test.assertEqual("dots", continents[1].display)
    test.assertEqual(1415, continents[2].area)
    test.assertEqual("count", continents[2].display)
    test.assertEqual(4, #continents[2].people)
end)

-- WoW adapter ----------------------------------------------------------------

local function newClient(environment)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua")
    return addon.Compatibility.Create(environment)
end

local function mapsAt(x, y)
    return {
        GetBestMapForUnit = function()
            return 1429
        end,
        GetMapInfo = function(mapId)
            return { mapID = mapId, name = "Elwynn Forest", mapType = 3, parentMapID = 13 }
        end,
        GetPlayerMapPosition = function(mapId, unit)
            test.assertEqual(1429, mapId)
            test.assertEqual("player", unit)
            if x == nil then
                return nil
            end
            return { GetXY = function() return x, y end }
        end,
    }
end

test.test("the adapter reads the player's zone map, position and class", function()
    local client = newClient({
        C_Map = mapsAt(0.25, 0.75),
        UnitClass = function(unit)
            test.assertEqual("player", unit)
            return "Mage", "MAGE", 8
        end,
    })

    local position = client:GetPlayerPosition()
    test.assertEqual(1429, position.mapId)
    test.assertEqual(0.25, position.x)
    test.assertEqual(0.75, position.y)
    test.assertEqual("MAGE", client:GetPlayerClass())
end)

-- Elwynn Forest (zone) in the Eastern Kingdoms (continent) on Azeroth
-- (world), under the cosmic map.
local MAP_TREE = {
    [1429] = { mapType = 3, parentMapID = 1415 },
    [1415] = { mapType = 2, parentMapID = 947 },
    [947] = { mapType = 1, parentMapID = 946 },
    [946] = { mapType = 0, parentMapID = 0 },
}

local function treeMaps()
    return {
        GetMapInfo = function(mapId)
            local info = MAP_TREE[mapId]
            return info and { mapID = mapId, name = "Map " .. mapId, mapType = info.mapType,
                parentMapID = info.parentMapID }
        end,
    }
end

test.test("the adapter finds the continent and world map a zone sits in", function()
    local client = newClient({ C_Map = treeMaps() })

    local parents = client:GetMapParents(1429)
    test.assertEqual(1415, parents.continent)
    test.assertEqual(947, parents.world)
    test.assertEqual(947, client:GetMapParents(1415).world)
    test.assertEqual(nil, client:GetMapParents(1415).continent)
    test.assertEqual(nil, client:GetMapParents(12345).continent)
    test.assertEqual(nil, newClient({}):GetMapParents(1429).continent)
    test.assertEqual(nil, newClient({ C_Map = { GetMapInfo = function() error("no maps") end } })
        :GetMapParents(1429).world)
end)

test.test("without a position or class the adapter returns nil instead of raising", function()
    local function raises()
        error("client API failed")
    end
    test.assertEqual(nil, newClient({}):GetPlayerPosition())
    test.assertEqual(nil, newClient({}):GetPlayerClass())
    -- Inside an instance the client gives no position.
    test.assertEqual(nil, newClient({ C_Map = mapsAt(nil) }):GetPlayerPosition())
    test.assertEqual(nil, newClient({ C_Map = mapsAt(0, 0) }):GetPlayerPosition())
    local maps = mapsAt(0.5, 0.5)
    maps.GetPlayerMapPosition = raises
    test.assertEqual(nil, newClient({ C_Map = maps }):GetPlayerPosition())
    test.assertEqual(nil, newClient({ UnitClass = raises }):GetPlayerClass())
end)

-- MapPins --------------------------------------------------------------------

-- A widget that records what's done to it.
local function fakeWidget()
    local widget = { scripts = {} }
    function widget:SetSize(width, height) self.size = { width, height } end
    function widget:SetAllPoints(target) self.allPoints = target end
    function widget:SetTexture(texture) self.textureFile = texture end
    function widget:SetVertexColor(r, g, b) self.color = { r, g, b } end
    function widget:EnableMouse(enabled) self.mouse = enabled end
    function widget:SetScript(name, handler) self.scripts[name] = handler end
    function widget:SetPoint(...) self.point = { ... } end
    function widget:SetText(text) self.text = text end
    function widget:Show() self.shown = true end
    function widget:Hide() self.shown = false end
    function widget:CreateTexture()
        return fakeWidget()
    end
    function widget:CreateFontString()
        return fakeWidget()
    end
    return widget
end

-- A stand-in for HereBeDragons-Pins-2.0: the icons on the world map, by
-- owner.
local function fakePins()
    local pins = { icons = {} }
    function pins:AddWorldMapIconMap(ref, icon, mapId, x, y, showFlag)
        table.insert(self.icons, { ref = ref, icon = icon, mapId = mapId, x = x, y = y, showFlag = showFlag })
    end
    function pins:RemoveAllWorldMapIcons(ref)
        local kept = {}
        local index
        for index = 1, #self.icons do
            if self.icons[index].ref ~= ref then
                table.insert(kept, self.icons[index])
            end
        end
        self.icons = kept
    end
    return pins
end

-- A tooltip that records its lines.
local function fakeTooltip()
    local tooltip = { lines = {}, shown = false }
    function tooltip:SetOwner(owner) self.owner = owner; self.lines = {} end
    function tooltip:AddLine(text) table.insert(self.lines, text) end
    function tooltip:Show() self.shown = true end
    function tooltip:Hide() self.shown = false end
    return tooltip
end

-- Gives `environment` the pins library and frames that draw, keeping the
-- fixtures' event frames working. Returns the pins library.
local function installMap(environment)
    local pins = fakePins()
    if environment.LibStub ~= nil then
        environment.LibStub.libs["HereBeDragons-Pins-2.0"] = pins
    end
    environment.GameTooltip = fakeTooltip()
    environment.RAID_CLASS_COLORS = {
        MAGE = { colorStr = "ff3fc7eb" },
        WARRIOR = { colorStr = "ffc69b6d" },
    }
    local createFrame = environment.CreateFrame
    environment.CreateFrame = function(...)
        local frame = createFrame(...)
        local widget = fakeWidget()
        local name, method
        for name, method in pairs(widget) do
            if frame[name] == nil then
                frame[name] = method
            end
        end
        -- Event frames keep their OnEvent handler; other scripts are kept
        -- by name.
        local setScript = frame.SetScript
        frame.SetScript = function(self, scriptName, handler)
            self.scripts[scriptName] = handler
            return setScript(self, scriptName, handler)
        end
        return frame
    end
    return pins
end

local DOTS = {
    { key = "hammer-area52", mapId = 1429, x = 0.4, y = 0.6, class = "MAGE", name = "Hammer", level = 42,
        label = "TheTool" },
    { key = "wrench-area52", mapId = 1453, x = 0.1, y = 0.2, class = "WARRIOR", name = "Wrench", level = 70 },
}

local function buildPins(world, dots, markers)
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua", "Adapters/MapPins.lua",
        "Core/LocationBoard.lua")
    local client = addon.Compatibility.Create(world.environment)
    return addon.MapPins.Create({
        client = client,
        dots = function()
            return dots
        end,
        markers = function()
            return markers or {}
        end,
    }), addon
end

-- A stand-in for HereBeDragons-2.0: an area's center is its map id over
-- 10000 on any other map, so specs can tell where a marker went.
local function installCoordinates(environment)
    environment.LibStub.libs["HereBeDragons-2.0"] = {
        TranslateZoneCoordinates = function(_, x, y, area, mapId)
            test.assertEqual(0.5, x)
            test.assertEqual(0.5, y)
            if area == mapId then
                return nil
            end
            return area / 10000, mapId / 10000
        end,
    }
end

-- The icons drawn on map `mapId`.
local function iconsOn(pins, mapId)
    local found = {}
    local index
    for index = 1, #pins.icons do
        if pins.icons[index].mapId == mapId then
            table.insert(found, pins.icons[index])
        end
    end
    return found
end

test.test("a marker's tooltip lists everyone there with their level and alias or main", function()
    local addon = test.newAddon("Adapters/MapPins.lua")

    local lines = addon.MapPins.MarkerLines({ people = DOTS })
    test.assertEqual(2, #lines)
    test.assertEqual("Hammer, level 42 (TheTool)", lines[1])
    test.assertEqual("Wrench, level 70", lines[2])
end)

test.test("a dot's tooltip names the character, its level, and its alias or main", function()
    local addon = test.newAddon("Adapters/MapPins.lua")

    local lines = addon.MapPins.TooltipLines(DOTS[1])
    test.assertEqual("Hammer", lines[1])
    test.assertEqual("Level 42", lines[2])
    test.assertEqual("TheTool", lines[3])
    test.assertEqual(2, #addon.MapPins.TooltipLines(DOTS[2]))
end)

local function registerProfileTests(profile)
    test.test(profile .. ": guildmates are class-colored dots at their position on the zone map", function()
        local world = fixtures.newEnvironment(profile)
        local pins = installMap(world.environment)
        local dots = { DOTS[1], DOTS[2] }
        local mapPins = buildPins(world, dots)

        test.assertTrue(mapPins:Start())
        mapPins:Refresh()

        test.assertEqual(2, #pins.icons)
        local icon = pins.icons[1]
        test.assertEqual(1429, icon.mapId)
        test.assertEqual(0.4, icon.x)
        test.assertEqual(0.6, icon.y)
        test.assertEqual(0, icon.showFlag)
        test.assertEqual(0x3f / 255, icon.icon.texture.color[1])
        test.assertEqual(0xc7 / 255, icon.icon.texture.color[2])
        test.assertEqual(0xeb / 255, icon.icon.texture.color[3])

        icon.icon.scripts.OnEnter(icon.icon)
        local tooltip = world.environment.GameTooltip
        test.assertTrue(tooltip.shown)
        test.assertEqual("Hammer", tooltip.lines[1])
        test.assertEqual("Level 42", tooltip.lines[2])
        test.assertEqual("TheTool", tooltip.lines[3])
        icon.icon.scripts.OnLeave(icon.icon)
        test.assertFalse(tooltip.shown)

        -- Redrawn as the board changes, reusing its frames.
        table.remove(dots, 1)
        mapPins:Refresh()
        test.assertEqual(1, #pins.icons)
        test.assertEqual(icon.icon, pins.icons[1].icon)
        test.assertEqual(1453, pins.icons[1].mapId)
    end)

    test.test(profile .. ": world map markers sit at the area's center, dots side by side or a count", function()
        local world = fixtures.newEnvironment(profile)
        local pins = installMap(world.environment)
        installCoordinates(world.environment)
        local four = { DOTS[1], DOTS[2], DOTS[1], DOTS[2] }
        local markers = {
            { area = 1429, mapId = 1415, display = "dots", people = { DOTS[1], DOTS[2] } },
            { area = 1415, mapId = 947, display = "count", people = four },
        }
        local mapPins = buildPins(world, {}, markers)
        mapPins:Start()
        mapPins:Refresh()

        local zone = iconsOn(pins, 1415)[1]
        test.assertEqual(0.1429, zone.x)
        test.assertEqual(0.1415, zone.y)
        local frame = zone.icon
        test.assertTrue(frame.dots[1].shown)
        test.assertTrue(frame.dots[2].shown)
        test.assertFalse(frame.dots[3].shown)
        test.assertFalse(frame.badge.shown)
        -- Side by side, never on top of each other.
        test.assertTrue(frame.dots[1].point[4] < frame.dots[2].point[4])
        test.assertEqual(0x3f / 255, frame.dots[1].color[1])
        test.assertEqual(0xc6 / 255, frame.dots[2].color[1])

        local continent = iconsOn(pins, 947)[1]
        test.assertEqual(0.1415, continent.x)
        test.assertTrue(continent.icon.badge.shown)
        test.assertEqual("4", continent.icon.count.text)
        test.assertFalse(continent.icon.dots[1].shown)

        continent.icon.scripts.OnEnter(continent.icon)
        local tooltip = world.environment.GameTooltip
        test.assertEqual(4, #tooltip.lines)
        test.assertEqual("Hammer, level 42 (TheTool)", tooltip.lines[1])
    end)

    test.test(profile .. ": markers are redrawn when the world map changes maps", function()
        local world = fixtures.newEnvironment(profile)
        local pins = installMap(world.environment)
        installCoordinates(world.environment)
        local markers = {}
        world.environment.WorldMapFrame = { OnMapChanged = function() end }
        world.environment.hooksecurefunc = function(target, method, hook)
            local original = target[method]
            target[method] = function(...)
                original(...)
                hook(...)
            end
        end
        local mapPins = buildPins(world, {}, markers)
        mapPins:Start()
        mapPins:Refresh()
        test.assertEqual(0, #pins.icons)

        table.insert(markers, { area = 1429, mapId = 1415, display = "dots", people = { DOTS[1] } })
        world.environment.WorldMapFrame:OnMapChanged()

        test.assertEqual(1, #iconsOn(pins, 1415))
    end)

    test.test(profile .. ": without the pins library the map stays off without errors", function()
        local world = fixtures.newEnvironment(profile, { missingLibraries = { "HereBeDragons-Pins-2.0" } })
        local mapPins = buildPins(world, DOTS)

        test.assertFalse(mapPins:Start())
        mapPins:Refresh()
    end)
end

-- Whole add-on ---------------------------------------------------------------

-- Logs in a world on the shared channel as `playerName`, standing at `spot`
-- ({ mapID, x, y }) when given.
local function login(profile, channel, playerName, spot, class, guild, prepare)
    local world = fixtures.newEnvironment(profile, { playerName = playerName, guild = guild })
    local pins = installMap(world.environment)
    world.pins = pins
    if prepare ~= nil then
        prepare(world.environment)
    end
    if spot ~= nil then
        world.zone.mapID = spot.mapID
        world.environment.C_Map.GetPlayerMapPosition = function(mapId)
            if mapId ~= world.zone.mapID then
                return nil
            end
            return { GetXY = function() return spot.x, spot.y end }
        end
        world.environment.UnitClass = function()
            return "Class", class, 1
        end
    end
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

local function locationMessages(world)
    local count = 0
    local index
    for index = 1, #world.sentMessages do
        local sent = world.sentMessages[index]
        local ok, message = world.environment.LibStub.libs["AceSerializer-3.0"]:Deserialize(sent.text)
        if ok and type(message) == "table" and message.t == "gm-loc" then
            count = count + 1
        end
    end
    return count
end

local function registerWholeAddonTests(profile)
    test.test(profile .. ": in the whole add-on, a guildmate sharing their location appears on the zone map", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local sharerName = guild.members[3].name
        local viewer = login(profile, channel, nil)
        local sharer = login(profile, channel, sharerName, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")

        test.assertEqual(1, locationMessages(sharer))
        test.assertEqual("BULK", sharer.sentMessages[#sharer.sentMessages].priority)
        fixtures.deliver(channel)

        local icons = viewer.pins.icons
        test.assertEqual(1, #icons)
        test.assertEqual(1429, icons[1].mapId)
        test.assertEqual(0.25, icons[1].x)
        test.assertEqual(0.5, icons[1].y)
        -- The sharer never sees themselves.
        test.assertEqual(0, #sharer.pins.icons)

        -- Two minutes on, it goes out again.
        fixtures.runTimers(sharer, 60)
        test.assertEqual(1, locationMessages(sharer))
        fixtures.runTimers(sharer, 60)
        test.assertEqual(2, locationMessages(sharer))
    end)

    test.test(profile .. ": in the whole add-on, a guildmate's zone and continent get world map markers", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, nil, nil, nil, function(environment)
            installCoordinates(environment)
            environment.C_Map.GetMapInfo = treeMaps().GetMapInfo
        end)
        login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")

        fixtures.deliver(channel)

        local pins = viewer.pins
        test.assertEqual(1, #iconsOn(pins, 1429))
        local zone = iconsOn(pins, 1415)[1]
        test.assertEqual(0.1429, zone.x)
        test.assertEqual(1, #zone.icon.marker.people)
        test.assertEqual("MAGE", zone.icon.marker.people[1].class)
        local continent = iconsOn(pins, 947)[1]
        test.assertEqual(0.1415, continent.x)
    end)

    test.test(profile .. ": in the whole add-on, locations from outside the guild are ignored", function()
        local channel = fixtures.newChannel()
        local viewer = login(profile, channel, nil)
        -- In the stranger's own roster, but not in the viewer's.
        local stranger = profile == "Retail" and "Stranger-Area52" or "Strange Person"
        local theirGuild = fixtures.snapshot(fixtures.GUILDS[profile])
        table.insert(theirGuild.members, { name = stranger, class = "MAGE", level = 30, rank = 4,
            rankName = "Initiate", online = true, zone = "Elwynn Forest" })
        local outsider = login(profile, channel, stranger, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE", theirGuild)
        test.assertEqual(1, locationMessages(outsider))

        fixtures.deliver(channel)

        test.assertEqual(0, #viewer.pins.icons)
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
    registerWholeAddonTests(fixtures.PROFILES[index])
end
