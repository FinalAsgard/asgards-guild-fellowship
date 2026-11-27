local test = require("tests.test_helper")

local RULES = { twoPartNames = false, homeRealm = "Area52" }
local RANKS = { [0] = "Guild Master", [1] = "Officer", [2] = "Member", [3] = "Initiate" }

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
    -- Name, class, days since last online, rank index.
    for _, entry in ipairs({
        { "Toolbox", "WARRIOR", 3, 2 }, { "Hammer", "PALADIN", 1, 1 }, { "Nail", "MAGE", 5, 3 },
        { "Anvil", "MAGE", 2, 2 }, { "Bolt", "ROGUE", 9, 2 }, { "Cog", "PRIEST", 4, 0 },
    }) do
        local name, rank = entry[1], entry[4]
        local key = normalizer:Key(name .. "-Area52")
        partition:RecordCharacter(key, { name = name .. "-Area52", classToken = entry[2], level = 60,
            rankIndex = entry[4] })
        local zone = online ~= nil and online[name] or nil
        members[key] = { name = name .. "-Area52", classToken = entry[2], level = 60, online = zone ~= nil,
            zone = zone, lastOnline = zone == nil and { days = entry[3] } or nil, rankIndex = entry[4],
            rankName = RANKS[rank] }
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

    test.assertEqual("[Players 4], Anvil, Bolt, Cog, TheTool", outline(view))
    test.assertEqual(4, view.players)
    test.assertEqual(3, cardOf(view, "TheTool").characters)
    test.assertEqual(1, cardOf(view, "Anvil").characters)
end)

test.test("roster list model: online and offline players share one list, by name", function()
    local world = setup({ Cog = "Ironforge", Hammer = "Stormwind" })
    local view = world.build()

    test.assertEqual("[Players 4], Anvil, Bolt, Cog, TheTool", outline(view))
    test.assertEqual(2, view.online)
    test.assertEqual("4 players · 2 online", view.header)
    test.assertTrue(cardOf(view, "Cog").online)
    test.assertFalse(cardOf(view, "Anvil").online)
end)

test.test("roster list model: sorted by Name, cards carry no tag", function()
    local world = setup({ Toolbox = "Orgrimmar", Anvil = "Orgrimmar", Bolt = "Orgrimmar", Cog = "Orgrimmar" })
    local view = world.build()

    test.assertEqual("[Players 4], Anvil, Bolt, Cog, TheTool", outline(view))
    test.assertEqual(nil, view.cards[1].tag)
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

    test.assertEqual("[Players 3], Anvil, Cog, TheTool", outline(view))
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
    test.assertEqual(world.playerOf("Anvil"), view.default)

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

-- Search, sort and filters ----------------------------------------------------

test.test("roster list model: search finds an alias, ignoring case, with the usual sub line", function()
    local world = setup()
    local view = world.build({ search = "  THETOOL " })

    test.assertEqual("[Players 1], TheTool", outline(view))
    test.assertEqual("|cffwarrioToolbox|r · 3 characters · 1 day ago", view.cards[1].sub)
    -- The header still counts the whole guild.
    test.assertEqual("4 players · 0 online", view.header)
end)

test.test("roster list model: search finds the main's name without naming it", function()
    local world = setup()
    local view = world.build({ search = "toolb" })

    test.assertEqual("TheTool", view.cards[1].name)
    test.assertEqual("|cffwarrioToolbox|r · 3 characters · 1 day ago", view.cards[1].sub)
end)

test.test("roster list model: search that finds only alts says which characters matched", function()
    local world = setup()
    local view = world.build({ search = "hamm" })

    test.assertEqual("[Players 1], TheTool", outline(view))
    test.assertEqual("matches Hammer", view.cards[1].sub)

    -- "a" is in Hammer and Nail, and in Anvil's own name.
    view = world.build({ search = "a" })
    test.assertEqual("matches Hammer and Nail", cardOf(view, "TheTool").sub)
    test.assertEqual("2 days ago", cardOf(view, "Anvil").sub)
end)

test.test("roster list model: search finds a player's Discord name", function()
    local world = setup()
    world.partition:SetProfileText(world.keys.Bolt, "discord", "BoltyMcBolt", 900, world.keys.Bolt)
    local view = world.build({ search = "mcbolt" })

    test.assertEqual("[Players 1], Bolt", outline(view))
    test.assertEqual("9 days ago", view.cards[1].sub)
end)

test.test("roster list model: search that finds nobody leaves no rows", function()
    local world = setup()
    local view = world.build({ search = "zzz" })

    test.assertEqual(0, #view.rows)
    test.assertEqual(nil, view.default)
end)

test.test("roster list model: the match text names two characters, then how many more", function()
    local world = setup()
    local MatchText = world.addon.RosterListModel.MatchText

    test.assertEqual("matches Vexadin", MatchText({ "Vexadin" }))
    test.assertEqual("matches Vexadin and Vexhunt", MatchText({ "Vexadin", "Vexhunt" }))
    test.assertEqual("matches Vexadin, Vexhunt and Vexmage", MatchText({ "Vexadin", "Vexhunt", "Vexmage" }))
    test.assertEqual("matches Vexadin, Vexhunt and 3 more",
        MatchText({ "Vexadin", "Vexhunt", "Vexmage", "Vexlock", "Vexdruid" }))
end)

test.test("roster list model: sorting by Name is one Players section, online or not", function()
    local world = setup({ Cog = "Ironforge" })
    local view = world.build({ sort = "name" })

    test.assertEqual("[Players 4], Anvil, Bolt, Cog, TheTool", outline(view))
end)

test.test("roster list model: sorting by Last online puts the most recent first", function()
    local world = setup({ Cog = "Ironforge" })
    local view = world.build({ sort = "lastOnline" })

    -- Cog is online; Hammer was on 1 day ago, Anvil 2, Bolt 9.
    test.assertEqual("[Players 4], Cog, TheTool, Anvil, Bolt", outline(view))
end)

test.test("roster list model: sorting by Rank uses each player's highest-ranked character, then the name", function()
    local world = setup()
    local view = world.build({ sort = "rank" })

    -- TheTool is an Officer through Hammer, though Toolbox is a Member;
    -- Anvil and Bolt are both Members.
    test.assertEqual("[Players 4], Cog, TheTool, Anvil, Bolt", outline(view))
    test.assertEqual("Officer", cardOf(view, "TheTool").rankName)
    test.assertEqual(1, cardOf(view, "TheTool").rankIndex)
end)

test.test("roster list model: an unknown sort is by Name", function()
    local world = setup({ Cog = "Ironforge" })
    local view = world.build({ sort = "bogus" })

    test.assertEqual("[Players 4], Anvil, Bolt, Cog, TheTool", outline(view))
    test.assertEqual(nil, view.cards[1].tag)
end)

test.test("roster list model: the Rank filter shows only players at that rank, by their highest character", function()
    local world = setup()
    local view = world.build({ rank = 2 })

    -- Toolbox is a Member, but TheTool's highest rank is Officer.
    test.assertEqual("[Players 2], Anvil, Bolt", outline(view))
    test.assertEqual("[Players 1], TheTool", outline(world.build({ rank = 1 })))
end)

test.test("roster list model: the Rank filter offers each rank a player holds, highest first", function()
    local world = setup()
    local ranks = world.build().ranks
    local names = {}
    local index
    for index = 1, #ranks do
        names[index] = ranks[index].index .. " " .. ranks[index].name
    end

    -- Nail is the only Initiate, and TheTool counts as an Officer.
    test.assertEqual("0 Guild Master, 1 Officer, 2 Member", table.concat(names, ", "))
end)

test.test("roster list model: Online only hides offline players", function()
    local world = setup({ Cog = "Ironforge", Nail = "Dalaran" })
    local view = world.build({ onlineOnly = true })

    test.assertEqual("[Players 2], Cog, TheTool", outline(view))
    test.assertEqual("4 players · 2 online", view.header)
end)

test.test("roster list model: filters combine", function()
    local world = setup({ Cog = "Ironforge", Bolt = "Gadgetzan" })
    local view = world.build({ onlineOnly = true, rank = 2, search = "o", sort = "name" })

    test.assertEqual("[Players 1], Bolt", outline(view))
end)

test.test("roster list model: the selection stays while its player is shown, and goes when filtered out", function()
    local world = setup({ Cog = "Ironforge" })
    local bolt = world.playerOf("Bolt")

    test.assertEqual(bolt, world.build({ selected = bolt, sort = "rank" }).selected)
    test.assertEqual(bolt, world.build({ selected = bolt, search = "bo" }).selected)
    local view = world.build({ selected = bolt, onlineOnly = true })
    test.assertEqual(nil, view.selected)
    test.assertEqual(world.playerOf("Cog"), view.default)
end)

test.test("roster list model: sorted by Last online, each card is tagged with when", function()
    local world = setup({ Cog = "Ironforge" })
    local view = world.build({ sort = "lastOnline" })

    test.assertEqual("Online", cardOf(view, "Cog").tag)
    test.assertEqual("1 day ago", cardOf(view, "TheTool").tag)
    test.assertEqual("9 days ago", cardOf(view, "Bolt").tag)
end)

test.test("roster list model: sorted by Rank, each card is tagged with the player's rank", function()
    local world = setup()
    local view = world.build({ sort = "rank" })

    test.assertEqual("Guild Master", cardOf(view, "Cog").tag)
    test.assertEqual("Officer", cardOf(view, "TheTool").tag)
    test.assertEqual("Member", cardOf(view, "Anvil").tag)
end)

test.test("roster list model: sorting by Grouped with puts the most parties first, tagged with the count", function()
    local world = setup()
    local counts = { [world.keys.Toolbox] = 12, [world.keys.Bolt] = 3, [world.keys.Anvil] = 3 }
    local view = world.build({ sort = "grouped", groupedOf = function(key)
        return counts[key] or 0
    end })

    test.assertEqual("[Players 4], TheTool, Anvil, Bolt, Cog", outline(view))
    test.assertEqual("12×", cardOf(view, "TheTool").tag)
    test.assertEqual("3×", cardOf(view, "Bolt").tag)
    -- Never grouped with: no tag.
    test.assertEqual(nil, cardOf(view, "Cog").tag)
end)

test.test("roster list model: the user's own player has no party count", function()
    local world = setup()
    local view = world.build({ sort = "grouped", selfKey = world.keys.Nail, groupedOf = function()
        return 40
    end })

    test.assertEqual(nil, cardOf(view, "TheTool").tag)
    test.assertEqual("40×", cardOf(view, "Anvil").tag)
    test.assertEqual("TheTool", view.cards[#view.cards].name)
end)

test.test("roster list model: Last online puts those online now before those on less than an hour ago", function()
    local world = setup({ Cog = "Ironforge", Bolt = "Gadgetzan" })
    world.members[world.keys.Anvil].lastOnline = { hours = 0 }
    world.members[world.keys.Hammer].lastOnline = { hours = 0 }
    local view = world.build({ sort = "lastOnline" })

    test.assertEqual("[Players 4], Bolt, Cog, Anvil, TheTool", outline(view))
    test.assertEqual("less than an hour ago", cardOf(view, "Anvil").tag)
end)

-- Departed --------------------------------------------------------------------

test.test("roster list model: Departed lists characters that left, newest first, with their player", function()
    local world = setup()
    world.partition:MarkDeparted(world.keys.Nail, 1000 - 3 * 86400)
    world.partition:MarkDeparted(world.keys.Bolt, 1000 - 86400)
    local rows = world.addon.RosterListModel.Departed({ partition = world.partition, normalizer = world.normalizer,
        now = 1000,
        classColor = function(classToken)
            return "ff" .. string.lower(string.sub(classToken, 1, 6))
        end,
        className = function(classToken)
            return string.upper(string.sub(classToken, 1, 1)) .. string.lower(string.sub(classToken, 2))
        end })

    test.assertEqual(2, #rows)
    test.assertEqual("Bolt", rows[1].name)
    test.assertEqual("Left 1 day ago", rows[1].left)
    test.assertEqual("Bolt", rows[1].player)
    -- Bolt was a player of one: the whole player left.
    test.assertEqual(0, #rows[1].remaining)

    test.assertEqual("Nail", rows[2].name)
    test.assertEqual("Left 3 days ago", rows[2].left)
    test.assertEqual("Mage", rows[2].className)
    test.assertEqual("ffmage", rows[2].color)
    test.assertEqual(60, rows[2].level)
    test.assertEqual("TheTool", rows[2].player)
    test.assertEqual("Toolbox, Hammer", table.concat(rows[2].remaining, ", "))
end)

test.test("roster list model: Departed is empty when nobody left", function()
    local world = setup()

    test.assertEqual(0, #world.addon.RosterListModel.Departed({ partition = world.partition, now = 1000 }))
end)

-- Review ------------------------------------------------------------------------

test.test("roster list model: Review has one row per member's suggestion, without note conflicts", function()
    local world = setup()
    local rows = world.addon.RosterListModel.Suggestions({
        { kind = "bundle", group = "player:7", name = "TheTool", suggestedBy = "Hammer (TheTool)", items = {
            { character = "hammer", kind = "suggested main", name = "Hammer", suggests = "Alt of Nail",
                current = "Alt of Toolbox" },
            { character = "toolbox", kind = "suggested discord", name = "Toolbox", suggests = "Discord \"tool#1\"",
                current = "No Discord" },
        } },
        { section = "notes", kind = "main", character = "bolt", name = "Bolt", suggests = "Alt of Cog" },
    })

    test.assertEqual(2, #rows)
    test.assertEqual("TheTool", rows[1].player)
    test.assertEqual("Hammer", rows[1].name)
    test.assertEqual("Alt of Nail", rows[1].suggests)
    test.assertEqual("Alt of Toolbox", rows[1].current)
    test.assertEqual("Hammer (TheTool)", rows[1].suggestedBy)
    test.assertEqual("player:7", rows[1].group)
    test.assertTrue(rows[1].reviewable)
    test.assertEqual("suggested discord", rows[2].kind)
    test.assertFalse(rows[2].reviewable)
end)
