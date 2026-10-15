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

-- Guildmates heard in Elwynn Forest (1429) at times 1..n, and one elsewhere.
local function guildmates(count)
    local found = { { key = "far-area52", name = "Far-Area52", mapId = 1453, heard = 999 } }
    local index
    for index = 1, count do
        table.insert(found, { key = "g" .. index .. "-area52", name = "G" .. index .. "-Area52", mapId = 1429,
            heard = index })
    end
    return found
end

test.test("same-zone guildmates get a whispered update every 10 seconds", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()
    local state = { now = 1000, character = "toolbox-area52", spot = SPOT, guildmates = guildmates(2) }

    local message, targets = scheduler:Near(state)
    test.assertEqual("gm-near", message.t)
    test.assertEqual("toolbox-area52", message.c)
    test.assertEqual(1429, message.m)
    -- Only those in the same zone, most recently heard first.
    test.assertEqual(2, #targets)
    test.assertEqual("G2-Area52", targets[1])
    test.assertEqual("G1-Area52", targets[2])

    state.now = 1009
    test.assertEqual(nil, scheduler:Near(state))
    state.now = 1010
    test.assertEqual(2, #select(2, scheduler:Near(state)))
    -- Nobody nearby, nothing to whisper.
    state.now = 1020
    state.guildmates = { guildmates(0)[1] }
    test.assertEqual(nil, scheduler:Near(state))
end)

test.test("whispers go to at most the 10 most recently heard guildmates", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()

    local _, targets = scheduler:Near({ now = 1000, character = "toolbox-area52", spot = SPOT,
        guildmates = guildmates(12) })

    test.assertEqual(10, #targets)
    test.assertEqual("G12-Area52", targets[1])
    test.assertEqual("G3-Area52", targets[10])
end)

test.test("after a whisper fails, only the guild broadcast goes on", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()
    local state = { now = 1000, character = "toolbox-area52", spot = SPOT, guildmates = guildmates(1) }
    scheduler:Near(state)

    scheduler:WhisperFailed()

    state.now = 2000
    test.assertEqual(nil, scheduler:Near(state))
    test.assertEqual("gm-loc", scheduler:Tick(state).t)
end)

test.test("with sharing off, one gm-hide goes out and then nothing until it's back on", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()
    local state = { now = 1000, character = "toolbox-area52", spot = SPOT, guildmates = guildmates(1) }
    test.assertEqual("gm-loc", scheduler:Tick(state).t)

    state.now = 1001
    state.sharing = false
    local hide = scheduler:Tick(state)
    test.assertEqual("gm-hide", hide.t)
    test.assertEqual("toolbox-area52", hide.c)
    -- Sent even where the client can't place the player.
    state.spot = nil
    state.now = 2000
    test.assertEqual(nil, scheduler:Tick(state))
    state.spot = SPOT
    test.assertEqual(nil, scheduler:Tick(state))
    test.assertEqual(nil, scheduler:Near(state))

    -- Back on, the location goes out at once.
    state.sharing = true
    state.now = 2001
    test.assertEqual("gm-loc", scheduler:Tick(state).t)
end)

test.test("inside an instance, one gm-hide goes out and the location resumes on leaving", function()
    local addon = load()
    local scheduler = addon.LocationScheduler.Create()
    local state = { now = 1000, character = "toolbox-area52", spot = SPOT, guildmates = guildmates(1) }
    test.assertEqual("gm-loc", scheduler:Tick(state).t)

    state.now = 1001
    state.inInstance = true
    test.assertEqual("gm-hide", scheduler:Tick(state).t)
    state.now = 2000
    test.assertEqual(nil, scheduler:Tick(state))
    test.assertEqual(nil, scheduler:Near(state))

    state.inInstance = false
    state.now = 2001
    test.assertEqual("gm-loc", scheduler:Tick(state).t)
end)

test.test("board entries expire 5 minutes after their last update", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create()
    board:OnLocation(protocol.Location("hammer-area52", SPOT), "hammer-area52", 1000)
    board:OnLocation(protocol.Location("wrench-area52", SPOT), "wrench-area52", 1100)

    test.assertFalse(board:Expire(1299))
    test.assertTrue(board:Expire(1300))
    local all = board:All()
    test.assertEqual(1, #all)
    test.assertEqual("wrench-area52", all[1].key)
    test.assertFalse(board:Expire(nil))
end)

test.test("the board keeps only the guildmates the caller keeps", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create()
    board:OnLocation(protocol.Location("hammer-area52", SPOT), "hammer-area52", 1000)
    board:OnLocation(protocol.Location("wrench-area52", SPOT), "wrench-area52", 1000)

    test.assertTrue(board:Keep(function(key)
        return key == "wrench-area52"
    end))
    test.assertFalse(board:Keep(function()
        return true
    end))
    test.assertEqual(1, #board:All())
end)

test.test("a gm-hide takes that guildmate off the board", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create()
    board:OnLocation(protocol.Location("hammer-area52", SPOT), "hammer-area52", 1000)
    board:OnLocation(protocol.Location("wrench-area52", SPOT), "wrench-area52", 1000)

    -- Only about the sender itself.
    test.assertFalse(board:OnHide(protocol.Hide("hammer-area52"), "wrench-area52"))
    test.assertTrue(board:OnHide(protocol.Hide("hammer-area52"), "hammer-area52"))
    test.assertFalse(board:OnHide(protocol.Hide("hammer-area52"), "hammer-area52"))

    local all = board:All()
    test.assertEqual(1, #all)
    test.assertEqual("wrench-area52", all[1].key)
end)

test.test("the board keeps each guildmate's latest position and never the player's own characters", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create({
        isOwn = function(key)
            return key == "toolbox-area52" or key == "wrench-area52"
        end,
    })

    test.assertTrue(board:OnLocation(protocol.Location("hammer-area52", SPOT), "hammer-area52", 1000))
    test.assertTrue(board:OnLocation(protocol.Near("hammer-area52", { mapId = 1429, x = 0.5, y = 0.25,
        class = "MAGE", level = 43 }), "hammer-area52", 1010, "Hammer-Area52"))
    test.assertFalse(board:OnLocation(protocol.Location("toolbox-area52", SPOT), "toolbox-area52", 1010))
    test.assertFalse(board:OnLocation(protocol.Location("wrench-area52", SPOT), "wrench-area52", 1010))
    -- A message about someone else than its sender.
    test.assertFalse(board:OnLocation(protocol.Location("visitor-area52", SPOT), "hammer-area52", 1010))

    local all = board:All()
    test.assertEqual(1, #all)
    test.assertEqual("hammer-area52", all[1].key)
    test.assertEqual("Hammer-Area52", all[1].name)
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

test.test("online roster members without a position count on the world map, marked as from the roster", function()
    local addon = load()
    local protocol = addon.LocationProtocol
    local board = addon.LocationBoard.Create({
        isOwn = function(key)
            return key == "toolbox-area52"
        end,
    })
    board:OnLocation(protocol.Location("hammer-area52", { mapId = ZONES.elwynn, x = 0.5, y = 0.5, class = "PALADIN",
        level = 70 }), "hammer-area52", 1000)
    local roster = {
        -- A position from the add-on wins over the roster's zone.
        { key = "hammer-area52", mapId = ZONES.westfall, class = "PALADIN", level = 70 },
        { key = "wrench-area52", mapId = ZONES.elwynn, class = "ROGUE", level = 12 },
        { key = "visitor-area52", mapId = ZONES.durotar, class = "MAGE", level = 80 },
        -- Never the player's own characters.
        { key = "toolbox-area52", mapId = ZONES.durotar, class = "WARRIOR", level = 80 },
    }

    local zones = board:Markers(function(mapId)
        return mapId
    end, roster)

    test.assertEqual(2, #zones)
    test.assertEqual(ZONES.durotar, zones[1].area)
    test.assertEqual(1, #zones[1].people)
    test.assertEqual("visitor-area52", zones[1].people[1].key)
    test.assertTrue(zones[1].people[1].fromRoster)
    test.assertEqual(nil, zones[1].people[1].x)
    test.assertEqual(ZONES.elwynn, zones[2].area)
    test.assertEqual(2, #zones[2].people)
    test.assertEqual("hammer-area52", zones[2].people[1].key)
    test.assertEqual(nil, zones[2].people[1].fromRoster)
    test.assertEqual("wrench-area52", zones[2].people[2].key)
    test.assertTrue(zones[2].people[2].fromRoster)
    test.assertEqual("MAGE", board:Markers(function(mapId)
        return CONTINENTS[mapId]
    end, roster)[1].people[1].class)
    -- They never become dots.
    test.assertEqual(1, #board:All())
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

-- The zone maps under the cosmic map, as GetMapChildrenInfo lists them:
-- an instance and a continent among them, and a name two zones share.
local function zoneChildren(root, mapType, all)
    test.assertEqual(946, root)
    test.assertEqual(3, mapType)
    test.assertTrue(all)
    return {
        { mapID = 1429, name = "Elwynn Forest", mapType = 3 },
        { mapID = 1455, name = "Ironforge", mapType = 3 },
        { mapID = 1415, name = "Eastern Kingdoms", mapType = 2 },
        { mapID = 1581, name = "The Deadmines", mapType = 4 },
        { mapID = 2000, name = "Dalaran", mapType = 3 },
        { mapID = 1500, name = "Dalaran", mapType = 3 },
    }
end

test.test("the adapter names the zones in the client's map tree", function()
    local maps = treeMaps()
    maps.GetBestMapForUnit = function()
        return 1429
    end
    maps.GetMapChildrenInfo = zoneChildren
    local zones = newClient({ C_Map = maps }):GetZoneMapIds()

    test.assertEqual(1429, zones["Elwynn Forest"])
    test.assertEqual(1455, zones["Ironforge"])
    test.assertEqual(1500, zones["Dalaran"])
    -- Instances and continents never match a roster zone.
    test.assertEqual(nil, zones["The Deadmines"])
    test.assertEqual(nil, zones["Eastern Kingdoms"])

    -- Not yet placed on a map, it starts from the fallback world map.
    maps.GetBestMapForUnit = function()
        return nil
    end
    maps.GetFallbackWorldMapID = function()
        return 947
    end
    test.assertEqual(1429, newClient({ C_Map = maps }):GetZoneMapIds()["Elwynn Forest"])

    test.assertEqual(nil, next(newClient({}):GetZoneMapIds()))
    maps.GetMapChildrenInfo = function()
        error("no maps")
    end
    test.assertEqual(nil, next(newClient({ C_Map = maps }):GetZoneMapIds()))
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
    function widget:SetAlpha(alpha) self.alpha = alpha end
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

-- A stand-in for HereBeDragons-Pins-2.0: the icons on the world map and on
-- the minimap, by owner.
local function fakePins()
    local pins = { icons = {}, minimap = {} }
    function pins:AddMinimapIconMap(ref, icon, mapId, x, y, showInParent, floatOnEdge)
        table.insert(self.minimap, { ref = ref, icon = icon, mapId = mapId, x = x, y = y,
            showInParent = showInParent, floatOnEdge = floatOnEdge })
    end
    function pins:RemoveAllMinimapIcons(ref)
        local kept = {}
        local index
        for index = 1, #self.minimap do
            if self.minimap[index].ref ~= ref then
                table.insert(kept, self.minimap[index])
            end
        end
        self.minimap = kept
    end
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

-- MapPins.DIM_ALPHA, the opacity of guildmates outside the player's party.
local DIM_ALPHA = 0.35

local DOTS = {
    { key = "hammer-area52", mapId = 1429, x = 0.4, y = 0.6, class = "MAGE", name = "Hammer", level = 42,
        label = "TheTool" },
    { key = "wrench-area52", mapId = 1453, x = 0.1, y = 0.2, class = "WARRIOR", name = "Wrench", level = 70 },
}

local function buildPins(world, dots, markers, zone, shown)
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
        zone = function()
            return zone and zone.mapId
        end,
        shown = function()
            return shown == nil or shown.value
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

    lines = addon.MapPins.MarkerLines({ people = { { key = "anvil-area52", name = "Anvil", level = 12,
        label = "Smithy", fromRoster = true } } })
    test.assertEqual("Anvil, level 12 (Smithy), from the roster", lines[1])
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

    test.test(profile .. ": guildmates in the player's zone are class-colored dots on the minimap", function()
        local world = fixtures.newEnvironment(profile)
        local pins = installMap(world.environment)
        local dots = { DOTS[1], DOTS[2] }
        local zone = { mapId = 1429 }
        local mapPins = buildPins(world, dots, nil, zone)
        mapPins:Start()
        mapPins:Refresh()

        -- Only Hammer is in the player's zone.
        test.assertEqual(1, #pins.minimap)
        local pin = pins.minimap[1]
        test.assertEqual(1429, pin.mapId)
        test.assertEqual(0.4, pin.x)
        test.assertEqual(0.6, pin.y)
        test.assertFalse(pin.showInParent)
        test.assertFalse(pin.floatOnEdge)
        test.assertEqual(0x3f / 255, pin.icon.texture.color[1])
        -- Its own frame: one frame can't sit on both maps.
        test.assertTrue(pin.icon ~= pins.icons[1].icon)

        pin.icon.scripts.OnEnter(pin.icon)
        local tooltip = world.environment.GameTooltip
        test.assertEqual("Hammer", tooltip.lines[1])
        test.assertEqual("Level 42", tooltip.lines[2])
        test.assertEqual("TheTool", tooltip.lines[3])

        -- Moving, then leaving the board.
        dots[1] = { key = "hammer-area52", mapId = 1429, x = 0.7, y = 0.6, class = "MAGE", name = "Hammer", level = 42 }
        mapPins:Refresh()
        test.assertEqual(1, #pins.minimap)
        test.assertEqual(0.7, pins.minimap[1].x)
        test.assertEqual(pin.icon, pins.minimap[1].icon)
        table.remove(dots, 1)
        mapPins:Refresh()
        test.assertEqual(0, #pins.minimap)

        -- In another zone, the player sees that zone's guildmates.
        zone.mapId = 1453
        mapPins:Refresh()
        test.assertEqual(1, #pins.minimap)
        -- And none where the client can't place the player.
        zone.mapId = nil
        mapPins:Refresh()
        test.assertEqual(0, #pins.minimap)
    end)

    test.test(profile .. ": with showing turned off, no guildmates are drawn on any map", function()
        local world = fixtures.newEnvironment(profile)
        local pins = installMap(world.environment)
        installCoordinates(world.environment)
        local shown = { value = true }
        local markers = { { area = 1429, mapId = 1415, display = "dots", people = { DOTS[1] } } }
        local mapPins = buildPins(world, { DOTS[1], DOTS[2] }, markers, { mapId = 1429 }, shown)
        mapPins:Start()
        mapPins:Refresh()
        test.assertEqual(3, #pins.icons)
        test.assertEqual(1, #pins.minimap)

        shown.value = false
        mapPins:Refresh()
        test.assertEqual(0, #pins.icons)
        test.assertEqual(0, #pins.minimap)

        shown.value = true
        mapPins:Refresh()
        test.assertEqual(3, #pins.icons)
        test.assertEqual(1, #pins.minimap)
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

    test.test(profile .. ": guildmates outside the player's party are dimmed on every map", function()
        local world = fixtures.newEnvironment(profile)
        local pins = installMap(world.environment)
        installCoordinates(world.environment)
        local hammer = fixtures.snapshot(DOTS[1])
        local wrench = fixtures.snapshot(DOTS[2])
        wrench.mapId = 1429
        wrench.dimmed = true
        local outside = fixtures.snapshot(DOTS[2])
        outside.dimmed = true
        local markers = {
            { area = 1429, mapId = 1415, display = "dots", people = { hammer, wrench } },
            { area = 1415, mapId = 947, display = "count", people = { outside, outside, outside, outside } },
        }
        local mapPins = buildPins(world, { hammer, wrench }, markers, { mapId = 1429 })
        mapPins:Start()
        mapPins:Refresh()

        local zoneDots = iconsOn(pins, 1429)
        test.assertEqual(1, zoneDots[1].icon.alpha)
        test.assertEqual(DIM_ALPHA, zoneDots[2].icon.alpha)
        test.assertEqual(1, pins.minimap[1].icon.alpha)
        test.assertEqual(DIM_ALPHA, pins.minimap[2].icon.alpha)
        local zone = iconsOn(pins, 1415)[1].icon
        test.assertEqual(1, zone.dots[1].alpha)
        test.assertEqual(DIM_ALPHA, zone.dots[2].alpha)
        test.assertEqual(1, zone.badge.alpha)
        -- Nobody from the party: the whole count is dimmed.
        local continent = iconsOn(pins, 947)[1].icon
        test.assertEqual(DIM_ALPHA, continent.badge.alpha)
        test.assertEqual(DIM_ALPHA, continent.count.alpha)
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
    world.addon = fixtures.loadAddon(world)
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

    test.test(profile .. ": in the whole add-on, online guildmates count on the world map from the roster's zone", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        -- The officer is online in the fixture zone (Ironforge or Dornogal),
        -- which sits on the Eastern Kingdoms here.
        local zoneId = profile == "Retail" and 2339 or 1455
        -- The viewer stands in that zone too.
        local function prepare(environment)
            installCoordinates(environment)
            local maps = treeMaps()
            environment.C_Map.GetMapInfo = function(mapId)
                if mapId == zoneId then
                    return { mapID = mapId, name = guild.members[1].zone, mapType = 3, parentMapID = 1415 }
                end
                return maps.GetMapInfo(mapId)
            end
            environment.C_Map.GetMapChildrenInfo = function()
                return { { mapID = zoneId, name = guild.members[1].zone, mapType = 3 } }
            end
        end
        local viewer = login(profile, channel, guild.members[3].name, { mapID = zoneId, x = 0.5, y = 0.5 }, "MAGE",
            nil, prepare)

        local pins = viewer.pins
        -- Never a dot on the zone map or minimap, even in the same zone.
        test.assertEqual(0, #iconsOn(pins, zoneId))
        test.assertEqual(0, #pins.minimap)
        local zone = iconsOn(pins, 1415)[1]
        test.assertEqual(zoneId / 10000, zone.x)
        local people = zone.icon.marker.people
        test.assertEqual(1, #people)
        test.assertTrue(people[1].fromRoster)
        test.assertEqual("WARRIOR", people[1].class)
        test.assertEqual(guild.members[1].level, people[1].level)
        test.assertEqual(1, #iconsOn(pins, 947))

        -- Once the officer shares a position, that replaces the roster's.
        local officer = login(profile, channel, guild.members[1].name, { mapID = 1429, x = 0.25, y = 0.5 }, "WARRIOR")
        test.assertEqual(1, locationMessages(officer))
        fixtures.deliver(channel)
        test.assertEqual(1, #iconsOn(pins, 1429))
        people = iconsOn(pins, 1415)[1].icon.marker.people
        test.assertEqual(1, #people)
        test.assertEqual(nil, people[1].fromRoster)
    end)

    -- Whispers the sharer sent.
    local function whispers(world)
        local found = {}
        local index
        for index = 1, #world.sentMessages do
            if world.sentMessages[index].distribution == "WHISPER" then
                table.insert(found, world.sentMessages[index])
            end
        end
        return found
    end

    test.test(profile .. ": in the whole add-on, a guildmate in the same zone hears updates every 10 seconds", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        local spot = { mapID = 1429, x = 0.25, y = 0.5 }
        local sharer = login(profile, channel, guild.members[3].name, spot, "MAGE")
        fixtures.deliver(channel)
        test.assertEqual(0, #whispers(sharer))

        spot.x = 0.75
        fixtures.runTimers(sharer, 5)
        local sent = whispers(sharer)
        test.assertEqual(1, #sent)
        test.assertEqual(guild.members[1].name, sent[1].recipient)
        test.assertEqual("BULK", sent[1].priority)
        -- Not yet time for the guild broadcast.
        test.assertEqual(1, locationMessages(sharer))
        fixtures.deliver(channel)
        test.assertEqual(0.75, viewer.pins.icons[1].x)
        -- In the same zone, so on the minimap too.
        test.assertEqual(1, #viewer.pins.minimap)
        test.assertEqual(0.75, viewer.pins.minimap[1].x)

        fixtures.runTimers(sharer, 5)
        test.assertEqual(1, #whispers(sharer))
        fixtures.runTimers(sharer, 5)
        test.assertEqual(2, #whispers(sharer))
    end)

    -- The location messages of type `kind` the world sent.
    local function sentOfType(world, kind)
        local count = 0
        local index
        for index = 1, #world.sentMessages do
            local ok, message = world.environment.LibStub.libs["AceSerializer-3.0"]
                :Deserialize(world.sentMessages[index].text)
            if ok and type(message) == "table" and message.t == kind then
                count = count + 1
            end
        end
        return count
    end

    test.test(profile .. ": in the whole add-on, turning sharing off hides the player's dot for everyone", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        local sharer = login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)
        test.assertEqual(1, #viewer.pins.icons)

        test.assertTrue(sharer.addon.settings:Set("shareLocation", false))
        test.assertEqual(1, sentOfType(sharer, "gm-hide"))
        fixtures.deliver(channel)
        test.assertEqual(0, #viewer.pins.icons)
        test.assertEqual(0, #viewer.pins.minimap)

        -- Nothing more while it's off: no broadcasts, no whispers.
        fixtures.runTimers(sharer, 300)
        test.assertEqual(1, sentOfType(sharer, "gm-hide"))
        test.assertEqual(1, sentOfType(sharer, "gm-loc"))
        test.assertEqual(0, sentOfType(sharer, "gm-near"))

        test.assertTrue(sharer.addon.settings:Set("shareLocation", true))
        fixtures.runTimers(sharer, 5)
        test.assertEqual(2, sentOfType(sharer, "gm-loc"))
        fixtures.deliver(channel)
        test.assertEqual(1, #viewer.pins.icons)
    end)

    test.test(profile .. ": in the whole add-on, entering an instance hides the player until they leave", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        local sharer = login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)
        test.assertEqual(1, #viewer.pins.icons)

        sharer.inInstance = "party"
        fixtures.runTimers(sharer, 5)
        test.assertEqual(1, sentOfType(sharer, "gm-hide"))
        fixtures.deliver(channel)
        test.assertEqual(0, #viewer.pins.icons)

        fixtures.runTimers(sharer, 300)
        test.assertEqual(1, sentOfType(sharer, "gm-hide"))
        test.assertEqual(1, sentOfType(sharer, "gm-loc"))
        test.assertEqual(0, sentOfType(sharer, "gm-near"))

        sharer.inInstance = nil
        fixtures.runTimers(sharer, 5)
        test.assertEqual(2, sentOfType(sharer, "gm-loc"))
        fixtures.deliver(channel)
        test.assertEqual(1, #viewer.pins.icons)
    end)

    test.test(profile .. ": in the whole add-on, nothing is sent while the player is busy", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        local sharer = login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)

        local inCombat = true
        sharer.environment.InCombatLockdown = function()
            return inCombat
        end
        fixtures.runTimers(sharer, 300)
        test.assertEqual(1, sentOfType(sharer, "gm-loc"))
        test.assertEqual(0, sentOfType(sharer, "gm-near"))
        -- Turning sharing off waits too.
        test.assertTrue(sharer.addon.settings:Set("shareLocation", false))
        test.assertEqual(0, sentOfType(sharer, "gm-hide"))

        inCombat = false
        fixtures.runTimers(sharer, 5)
        test.assertEqual(1, sentOfType(sharer, "gm-hide"))
    end)

    test.test(profile .. ": in the whole add-on, a guildmate's dot clears after 5 minutes without an update", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)
        test.assertEqual(1, #viewer.pins.icons)

        -- The sharer's updates stop arriving.
        fixtures.runTimers(viewer, 295)
        test.assertEqual(1, #viewer.pins.icons)
        fixtures.runTimers(viewer, 5)
        test.assertEqual(0, #viewer.pins.icons)
        test.assertEqual(0, #viewer.pins.minimap)
    end)

    test.test(profile .. ": in the whole add-on, a guildmate the roster shows offline or gone leaves the map", function()
        local guild = fixtures.GUILDS[profile]
        local kinds = { "offline", "gone" }
        local index
        for index = 1, #kinds do
            local channel = fixtures.newChannel()
            local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
            local sharer = login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 },
                "MAGE")
            fixtures.deliver(channel)
            test.assertEqual(1, #viewer.pins.icons, kinds[index])

            if kinds[index] == "offline" then
                viewer.guild.members[3].online = false
            else
                table.remove(viewer.guild.members, 3)
            end
            fixtures.fire(viewer, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(viewer)
            test.assertEqual(0, #viewer.pins.icons, kinds[index])

            -- And it gets no more whispers from the viewer.
            fixtures.runTimers(viewer, 10)
            local whispered = 0
            local sent
            for _, sent in ipairs(viewer.sentMessages) do
                if sent.distribution == "WHISPER" and sent.recipient == sharer.playerName then
                    whispered = whispered + 1
                end
            end
            test.assertEqual(0, whispered, kinds[index])
        end
    end)

    test.test(profile .. ": in the whole add-on, guildmates outside the player's party are dimmed", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)
        test.assertEqual(1, viewer.pins.icons[1].icon.alpha)

        -- In a party without the sharer.
        local environment = viewer.environment
        local units = { player = guild.members[1].name, party1 = "Stranger" }
        environment.IsInGroup = function() return true end
        environment.UnitExists = function(unit) return units[unit] ~= nil end
        environment.UnitName = function(unit) return units[unit] end
        fixtures.fire(viewer, "GROUP_ROSTER_UPDATE")
        test.assertEqual(DIM_ALPHA, viewer.pins.icons[1].icon.alpha)
        test.assertEqual(DIM_ALPHA, viewer.pins.minimap[1].icon.alpha)

        -- The sharer joins the party.
        units.party1 = guild.members[3].name
        fixtures.fire(viewer, "GROUP_ROSTER_UPDATE")
        test.assertEqual(1, viewer.pins.icons[1].icon.alpha)

        -- Out of the party, nobody is dimmed.
        environment.IsInGroup = function() return false end
        units.party1 = nil
        fixtures.fire(viewer, "GROUP_ROSTER_UPDATE")
        test.assertEqual(1, viewer.pins.icons[1].icon.alpha)
    end)

    test.test(profile .. ": in the whole add-on, turning showing off clears every guildmate pin", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        local viewer = login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)
        test.assertEqual(1, #viewer.pins.minimap)

        test.assertTrue(viewer.addon.settings:Set("showGuildMap", false))
        test.assertEqual(0, #viewer.pins.icons)
        test.assertEqual(0, #viewer.pins.minimap)
        test.assertFalse(viewer.database.guildMap.show)

        test.assertTrue(viewer.addon.settings:Set("showGuildMap", true))
        test.assertEqual(1, #viewer.pins.icons)
    end)

    test.test(profile .. ": in the whole add-on, when whispers fail the guild broadcast goes on", function()
        local channel = fixtures.newChannel()
        local guild = fixtures.GUILDS[profile]
        login(profile, channel, nil, { mapID = 1429, x = 0.5, y = 0.5 }, "WARRIOR")
        local sharer = login(profile, channel, guild.members[3].name, { mapID = 1429, x = 0.25, y = 0.5 }, "MAGE")
        fixtures.deliver(channel)
        sharer.whisperFails = true

        fixtures.runTimers(sharer, 5)
        sharer.whisperFails = false
        fixtures.runTimers(sharer, 30)
        test.assertEqual(0, #whispers(sharer))
        fixtures.runTimers(sharer, 90)
        test.assertEqual(2, locationMessages(sharer))
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
