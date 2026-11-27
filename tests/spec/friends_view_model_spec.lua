local test = require("tests.test_helper")

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- A guild partition with these players, by main: Toolbox (alias "TheTool",
-- with alt Hammer), Anvil, Bolt, Cog, Dirk, Elm, and Zed (the user).
-- `online` names the characters online.
local function setup(online)
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua", "Core/FriendsViewModel.lua")
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local members = {}
    local function add(name, classToken, level)
        local key = normalizer:Key(name .. "-Area52")
        partition:RecordCharacter(key, { name = name .. "-Area52", classToken = classToken, level = level })
        members[key] = { name = name .. "-Area52", classToken = classToken, level = level,
            online = online ~= nil and online[name] == true }
        return key
    end
    local world = { addon = addon, partition = partition, normalizer = normalizer, members = members, keys = {} }
    local _, entry
    for _, entry in ipairs({
        { "Toolbox", "WARRIOR", 60 }, { "Hammer", "PALADIN", 40 }, { "Anvil", "MAGE", 52 }, { "Bolt", "ROGUE", 60 },
        { "Cog", "PRIEST", 60 }, { "Dirk", "DRUID", 30 }, { "Elm", "HUNTER", 60 }, { "Zed", "WARLOCK", 60 },
    }) do
        world.keys[entry[1]] = add(entry[1], entry[2], entry[3])
    end
    partition:JoinPlayerOf(world.keys.Hammer, world.keys.Toolbox, "manual")
    partition:SetAlias(partition:GetCharacter(world.keys.Toolbox).player, "TheTool", "manual")
    world.counts = {}
    function world.playerOf(name)
        return partition:GetCharacter(world.keys[name]).player
    end
    function world.inputs(extra)
        local fields = {
            partition = partition,
            friendKeys = partition:GetFriends(),
            members = members,
            normalizer = normalizer,
            classColor = function(classToken)
                return "ff" .. string.lower(string.sub(classToken, 1, 6))
            end,
            className = function(classToken)
                return string.upper(string.sub(classToken, 1, 1)) .. string.lower(string.sub(classToken, 2))
            end,
            selfKey = world.keys.Zed,
            statsOf = function(key)
                return world.counts[key] or 0
            end,
        }
        local name, value
        for name, value in pairs(extra or {}) do
            fields[name] = value
        end
        return fields
    end
    function world.build(extra)
        return addon.FriendsViewModel.Build(world.inputs(extra))
    end
    function world.picker(query)
        return addon.FriendsViewModel.Picker(world.inputs({ query = query }))
    end
    return world
end

local function names(cards)
    local list = {}
    local index
    for index = 1, #cards do
        list[index] = cards[index].name
    end
    return table.concat(list, ", ")
end

test.test("friends view model: no Friends is five empty slots and nothing selected", function()
    local world = setup()
    local view = world.build()

    test.assertEqual(0, #view.friends)
    test.assertEqual(5, view.empty)
    test.assertFalse(view.full)
    test.assertEqual(nil, view.default)
    test.assertEqual(nil, view.selected)
end)

test.test("friends view model: Friends are sorted online first, then by name, with empty slots after them", function()
    local world = setup({ Elm = true, Hammer = true })
    world.partition:AddFriend(world.keys.Cog)
    world.partition:AddFriend(world.keys.Elm)
    world.partition:AddFriend(world.keys.Anvil)
    world.partition:AddFriend(world.keys.Hammer)

    local view = world.build()

    test.assertEqual("Elm, TheTool, Anvil, Cog", names(view.friends))
    test.assertEqual(1, view.empty)
    test.assertEqual(world.playerOf("Elm"), view.default)
    test.assertTrue(view.friends[1].online)
    -- Toolbox's alt is online, so the player is.
    test.assertTrue(view.friends[2].online)
    test.assertFalse(view.friends[3].online)
end)

test.test("friends view model: a card shows the alias over the main's name, and the main's level and class", function()
    local world = setup()
    world.partition:AddFriend(world.keys.Hammer)
    world.partition:AddFriend(world.keys.Bolt)

    local view = world.build()
    local bolt, tool = view.friends[1], view.friends[2]

    test.assertEqual("TheTool", tool.name)
    test.assertEqual("Toolbox", tool.mainName)
    test.assertEqual(60, tool.level)
    test.assertEqual("Warrior", tool.className)
    test.assertEqual("ffwarrio", tool.color)
    -- No alias: the main's name is the large name.
    test.assertEqual("Bolt", bolt.name)
    test.assertEqual(nil, bolt.alias)
    test.assertEqual(world.playerOf("Bolt"), bolt.playerId)
end)

test.test("friends view model: two keys of one player show one card, and a merge follows along", function()
    local world = setup()
    world.partition:AddFriend(world.keys.Anvil)
    world.partition:AddFriend(world.keys.Dirk)
    world.partition:JoinPlayerOf(world.keys.Dirk, world.keys.Anvil, "manual")

    local view = world.build()

    test.assertEqual("Anvil", names(view.friends))
    test.assertEqual(4, view.empty)
end)

test.test("friends view model: a Friend who left the guild keeps the card, as Left the guild", function()
    local world = setup()
    world.partition:AddFriend(world.keys.Bolt)
    world.partition:MarkDeparted(world.keys.Bolt, 1790000000)

    local card = world.build().friends[1]

    test.assertTrue(card.left)
    test.assertFalse(card.online)
    test.assertEqual("Left the guild", card.status)

    -- Purged for good: the slot stays, under the key.
    world.partition:Purge(world.keys.Bolt, 1790000100)
    card = world.build().friends[1]
    test.assertTrue(card.left)
    test.assertEqual(world.keys.Bolt, card.playerId)
end)

test.test("friends view model: the selection stays only while that player has a card; a full set says so", function()
    local world = setup()
    local _, name
    for _, name in ipairs({ "Anvil", "Bolt", "Cog", "Dirk", "Elm" }) do
        world.partition:AddFriend(world.keys[name])
    end

    local view = world.build({ selected = world.playerOf("Cog") })
    test.assertTrue(view.full)
    test.assertEqual(0, view.empty)
    test.assertEqual(world.playerOf("Cog"), view.selected)
    test.assertEqual(nil, world.build({ selected = world.playerOf("Zed") }).selected)
end)

test.test("friends view model: the picker leaves out the user and Friends, sorted by times grouped, then name", function()
    local world = setup({ Bolt = true })
    world.partition:AddFriend(world.keys.Anvil)
    world.counts[world.keys.Cog] = 3
    world.counts[world.keys.Toolbox] = 12

    local rows = world.picker("")

    test.assertEqual("TheTool, Cog, Bolt, Dirk, Elm", names(rows))
    test.assertEqual("12× grouped", rows[1].grouped)
    test.assertEqual(1, rows[1].alts)
    test.assertEqual(world.keys.Toolbox, rows[1].key)
    test.assertEqual("Never grouped", rows[3].grouped)
    test.assertTrue(rows[3].online)
    test.assertEqual(0, rows[3].alts)
end)

test.test("friends view model: the picker searches the alias and every character name, ignoring case", function()
    local world = setup()
    world.partition:MarkDeparted(world.keys.Elm, 1790000000)

    test.assertEqual("TheTool", names(world.picker("thetool")))
    test.assertEqual("TheTool", names(world.picker("HAMM")))
    test.assertEqual("Bolt", names(world.picker("  bol ")))
    test.assertEqual("", names(world.picker("nobody")))
    -- Nobody left in the guild can be picked.
    test.assertEqual("", names(world.picker("elm")))
end)

test.test("friends view model: a search that finds only an alt names it; alias or main matches don't", function()
    local world = setup()

    local found = world.picker("hamm")
    test.assertEqual("Hammer", table.concat(found[1].matchedAlts, ","))
    -- By the alias or the main: no alt line.
    test.assertEqual(nil, world.picker("thetool")[1].matchedAlts)
    test.assertEqual(nil, world.picker("toolb")[1].matchedAlts)
    -- Matching the main and an alt both: the main is enough.
    world.partition:RecordCharacter(world.keys.Toolbox, { name = "Toolhammer-Area52", classToken = "WARRIOR" })
    test.assertEqual(nil, world.picker("hammer")[1].matchedAlts)
    -- With nothing typed, nothing to name.
    test.assertEqual(nil, world.picker("")[1].matchedAlts)
end)

test.test("friends view model: Most grouped cards come in the given order with counts; the first is the default", function()
    local world = setup()
    local view = world.build({ mostGrouped = {
        { player = world.playerOf("Cog"), count = 12 },
        { player = world.playerOf("Hammer"), count = 3 },
    } })

    test.assertEqual("Cog, TheTool", names(view.mostGrouped))
    test.assertEqual("12×", view.mostGrouped[1].countText)
    test.assertEqual(world.keys.Toolbox, view.mostGrouped[2].key)
    -- No Friends: the first Most grouped is selected.
    test.assertEqual(world.playerOf("Cog"), view.default)
    test.assertEqual(world.playerOf("Hammer"),
        world.build({ selected = world.playerOf("Hammer"), mostGrouped = { { player = world.playerOf("Hammer"),
            count = 3 } } }).selected)

    -- A Friend comes first.
    world.partition:AddFriend(world.keys.Elm)
    test.assertEqual(world.playerOf("Elm"), world.build({ mostGrouped = { { player = world.playerOf("Cog"),
        count = 12 } } }).default)
end)
