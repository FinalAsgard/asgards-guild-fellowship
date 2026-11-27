local test = require("tests.test_helper")

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- A guild partition with these players, by main: Toolbox (alias "TheTool",
-- with alts Hammer and Nail), Anvil, Bolt and Cog. `online` names the
-- characters online, by name, with their zone; `noAlias` leaves Toolbox
-- without the alias.
local function setup(online, noAlias)
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/RosterViewModel.lua",
        "Core/RosterListModel.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local members = {}
    local world = { addon = addon, partition = partition, normalizer = normalizer, members = members, keys = {} }
    local _, entry
    for _, entry in ipairs({
        { "Toolbox", "WARRIOR", 3 }, { "Hammer", "PALADIN", 1 }, { "Nail", "MAGE", 5 }, { "Anvil", "MAGE", 2 },
        { "Bolt", "ROGUE", 9 }, { "Cog", "PRIEST", 4 },
    }) do
        local name = entry[1]
        local key = normalizer:Key(name .. "-Area52")
        partition:RecordCharacter(key, { name = name .. "-Area52", classToken = entry[2], level = 60 })
        local zone = online ~= nil and online[name] or nil
        members[key] = { name = name .. "-Area52", classToken = entry[2], level = 60, online = zone ~= nil,
            zone = zone, lastOnline = zone == nil and { days = entry[3] } or nil }
        world.keys[name] = key
    end
    partition:JoinPlayerOf(world.keys.Hammer, world.keys.Toolbox, "manual")
    partition:JoinPlayerOf(world.keys.Nail, world.keys.Toolbox, "manual")
    if not noAlias then
        partition:SetAlias(partition:GetCharacter(world.keys.Toolbox).player, "TheTool", "manual")
    end
    function world.playerOf(name)
        return partition:GetCharacter(world.keys[name]).player
    end
    function world.build(extra)
        local fields = {
            partition = partition,
            members = members,
            normalizer = normalizer,
            friendKeys = partition:GetFriends(),
            classColor = function(classToken)
                return "ff" .. string.lower(string.sub(classToken, 1, 6))
            end,
            className = function(classToken)
                return string.upper(string.sub(classToken, 1, 1)) .. string.lower(string.sub(classToken, 2))
            end,
            now = 1000,
        }
        local name, value
        for name, value in pairs(extra or {}) do
            fields[name] = value
        end
        return addon.RosterListModel.Build(fields)
    end
    return world
end

-- The rows as text: sections as "[Online 2]", cards by name.
local function outline(view)
    local parts = {}
    local index
    for index = 1, #view.rows do
        local row = view.rows[index]
        if row.kind == "section" then
            table.insert(parts, "[" .. row.text .. " " .. row.count .. "]")
        else
            table.insert(parts, row.name)
        end
    end
    return table.concat(parts, ", ")
end

local function cardOf(view, name)
    local index
    for index = 1, #view.cards do
        if view.cards[index].name == name then
            return view.cards[index]
        end
    end
    return nil
end

test.test("roster list model: one card per player, alts folded into their player", function()
    local world = setup()
    local view = world.build()

    test.assertEqual("[Offline 4], Anvil, Bolt, Cog, TheTool", outline(view))
    test.assertEqual(4, view.players)
    test.assertEqual(3, cardOf(view, "TheTool").characters)
    test.assertEqual(1, cardOf(view, "Anvil").characters)
end)

test.test("roster list model: online players come first, each section with its count", function()
    local world = setup({ Cog = "Ironforge", Hammer = "Stormwind" })
    local view = world.build()

    test.assertEqual("[Online 2], Cog, TheTool, [Offline 2], Anvil, Bolt", outline(view))
    test.assertEqual(2, view.online)
    test.assertEqual("4 players · 2 online", view.header)
    test.assertTrue(cardOf(view, "Cog").online)
    test.assertFalse(cardOf(view, "Anvil").online)
end)

test.test("roster list model: an empty section is left out", function()
    local world = setup({ Toolbox = "Orgrimmar", Anvil = "Orgrimmar", Bolt = "Orgrimmar", Cog = "Orgrimmar" })
    local view = world.build()

    test.assertEqual("[Online 4], Anvil, Bolt, Cog, TheTool", outline(view))
    test.assertEqual("4 players · 4 online", view.header)
end)

test.test("roster list model: the sub line names the online character, the count and the zone", function()
    local world = setup({ Hammer = "Stormwind" })
    local card = cardOf(world.build(), "TheTool")

    test.assertEqual("|cffpaladiHammer|r · 3 characters · Stormwind", card.sub)
    -- The initial is in the main's class color.
    test.assertEqual("ffwarrio", card.color)
    test.assertEqual("Toolbox", card.mainName)
end)

test.test("roster list model: offline, the sub line names the main and the latest login", function()
    local world = setup()
    local view = world.build()

    -- Hammer was on a day ago, the most recent of the three.
    test.assertEqual("|cffwarrioToolbox|r · 3 characters · 1 day ago", cardOf(view, "TheTool").sub)
    -- A lone character's name is its big name, so the sub line skips it.
    test.assertEqual("2 days ago", cardOf(view, "Anvil").sub)
end)

test.test("roster list model: a lone character online shows only where they are", function()
    local world = setup({ Bolt = "Darnassus" })

    test.assertEqual("Darnassus", cardOf(world.build(), "Bolt").sub)
end)

test.test("roster list model: Friends' cards carry the star", function()
    local world = setup()
    world.partition:AddFriend(world.keys.Hammer)
    local view = world.build()

    test.assertTrue(cardOf(view, "TheTool").star)
    test.assertFalse(cardOf(view, "Anvil").star)
end)

test.test("roster list model: departed characters don't count, and a player with none left has no card", function()
    local world = setup()
    world.partition:MarkDeparted(world.keys.Nail, 900)
    world.partition:MarkDeparted(world.keys.Bolt, 900)
    local view = world.build()

    test.assertEqual("[Offline 3], Anvil, Cog, TheTool", outline(view))
    test.assertEqual(2, cardOf(view, "TheTool").characters)
    test.assertEqual("3 players · 0 online", view.header)
end)

test.test("roster list model: a player whose main left is led by a character still in the guild", function()
    local world = setup()
    world.partition:MarkDeparted(world.keys.Toolbox, 900)
    local card = cardOf(world.build(), "TheTool")

    test.assertEqual("Hammer", card.mainName)
    test.assertEqual(world.keys.Hammer, card.key)
end)

test.test("roster list model: without an alias the big name is the main's", function()
    local world = setup(nil, true)
    local view = world.build()

    test.assertEqual("3 characters · 1 day ago", cardOf(view, "Toolbox").sub)
end)

test.test("roster list model: the selection is kept while it has a card, with its row", function()
    local world = setup({ Cog = "Ironforge" })
    local view = world.build({ selected = world.playerOf("Bolt") })

    test.assertEqual(world.playerOf("Bolt"), view.selected)
    test.assertEqual("Bolt", view.rows[view.selectedIndex].name)
    test.assertEqual(world.playerOf("Cog"), view.default)

    world.partition:MarkDeparted(world.keys.Bolt, 900)
    view = world.build({ selected = world.playerOf("Bolt") })
    test.assertEqual(nil, view.selected)
    test.assertEqual(nil, view.selectedIndex)
end)

test.test("roster list model: the sync text says when the guild last synced", function()
    local world = setup()

    test.assertEqual("Not synced yet", world.build().sync)
    test.assertEqual("Synced 5 minutes ago", world.build({ lastSync = 700 }).sync)
end)

test.test("roster list model: an empty guild has no rows and no default", function()
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/RosterViewModel.lua",
        "Core/RosterListModel.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local view = addon.RosterListModel.Build({ partition = partition, members = {} })

    test.assertEqual(0, #view.rows)
    test.assertEqual(nil, view.default)
    test.assertEqual("0 players · 0 online", view.header)
end)
