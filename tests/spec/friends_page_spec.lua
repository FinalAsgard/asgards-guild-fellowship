local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

local contains = fakeFrames.contains

-- The Friends page on fake frames, over a list of pinned players held here.
-- Each player is { playerId, key, name }; `pinned` lists those pinned.
local function setup(pinnedNames)
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/GroupFriends.lua", "Core/PlayerDetailViewModel.lua",
        "Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/PlayerCards.lua", "Adapters/PlayerDetailPanel.lua",
        "Adapters/FriendsPage.lua")
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local content = environment.CreateFrame("Frame")
    local world = { addon = addon, content = content, calls = {}, players = {}, pinned = {} }
    local _, name
    for _, name in ipairs({ "Anvil", "Bolt", "Cog" }) do
        world.players[name] = { playerId = string.byte(name), key = string.lower(name), name = name,
            mainName = name, level = 60, className = "Warrior", online = name == "Bolt", left = false, status = "" }
    end
    for _, name in ipairs(pinnedNames or {}) do
        table.insert(world.pinned, world.players[name])
    end
    local function find(playerId)
        local index
        for index = 1, #world.pinned do
            if world.pinned[index].playerId == playerId then
                return index
            end
        end
        return nil
    end
    world.page = addon.FriendsPage.Create(content, ui, {
        model = function(selected)
            local view = { friends = {}, empty = 5 - #world.pinned, full = #world.pinned >= 5, mostGrouped = {} }
            local _, entry
            for _, entry in ipairs(world.most or {}) do
                if find(entry.playerId) == nil then
                    local card = {}
                    local field, value
                    for field, value in pairs(entry) do
                        card[field] = value
                    end
                    card.countText = "7×"
                    table.insert(view.mostGrouped, card)
                    if entry.playerId == selected then
                        view.selected = selected
                    end
                end
            end
            local index
            for index = 1, #world.pinned do
                view.friends[index] = world.pinned[index]
                if world.pinned[index].playerId == selected then
                    view.selected = selected
                end
            end
            view.default = view.friends[1] and view.friends[1].playerId or nil
            return view
        end,
        picker = function(query)
            local rows = {}
            local _, player
            for _, player in ipairs({ world.players.Anvil, world.players.Bolt, world.players.Cog }) do
                if find(player.playerId) == nil and string.find(string.lower(player.name), string.lower(query), 1, true)
                then
                    local row = {}
                    local field, value
                    for field, value in pairs(player) do
                        row[field] = value
                    end
                    row.alts, row.grouped = 0, "Never grouped"
                    table.insert(rows, row)
                end
            end
            return rows
        end,
        onAdd = function(key)
            table.insert(world.calls, "add " .. key)
            local _, player
            for _, player in pairs(world.players) do
                if player.key == key then
                    table.insert(world.pinned, player)
                end
            end
            return true
        end,
        onRemove = function(playerId)
            table.insert(world.calls, "remove " .. playerId)
            table.remove(world.pinned, find(playerId))
        end,
        -- The detail view, as PlayerDetailViewModel builds it.
        detail = function(playerId)
            local _, player
            for _, player in pairs(world.players) do
                if player.playerId == playerId and not world.gone then
                    local isFriend = find(playerId) ~= nil
                    local full = #world.pinned >= 5
                    return {
                        playerId = playerId,
                        header = {
                            name = player.name,
                            mainName = player.name,
                            facts = "Level 60 Warrior",
                            status = player.online and "Online, Ironforge" or "Last online 2 days ago",
                            target = player.online and (player.name .. "-Area52") or nil,
                            key = player.key,
                            badge = isFriend and { kind = "friend" } or nil,
                            isFriend = isFriend,
                            full = full,
                            canToggle = isFriend or not full,
                        },
                        tiles = {
                            { label = "Discord", value = "Not set", notSet = true },
                            { label = "Grouped", value = "3 times", notSet = false },
                            { label = "Last grouped", value = "2026-11-01", notSet = false },
                            { label = "Joined guild", value = "Not set", notSet = true },
                        },
                    }
                end
            end
            return nil
        end,
        onWhisper = function(target)
            table.insert(world.calls, "whisper " .. target)
        end,
        onInvite = function(target)
            table.insert(world.calls, "invite " .. target)
        end,
        onReplace = function(playerId, key)
            table.insert(world.calls, "replace " .. playerId .. " " .. key)
            local _, player
            for _, player in pairs(world.players) do
                if player.key == key then
                    world.pinned[find(playerId)] = player
                end
            end
            return true
        end,
    })
    world.page:Refresh()
    return world
end

local function click(button, which)
    button.scripts.OnClick(button, which)
end

-- The picker row showing `name`, or nil.
local function pickerRow(world, name)
    local index
    for index = 1, #world.page.picker.rows do
        local row = world.page.picker.rows[index]
        if row.shown and row.entry and row.entry.name == name then
            return row
        end
    end
    return nil
end

test.test("friends page: Friends show as cards, then + Add a friend for each open slot", function()
    local world = setup({ "Anvil", "Bolt" })
    local cards = world.page.cards

    test.assertEqual("Anvil", cards[1].name.text)
    test.assertEqual("Bolt", cards[2].name.text)
    test.assertTrue(cards[1].star.shown)
    test.assertTrue(cards[3].empty)
    test.assertEqual("+ Add a friend", cards[3].emptyText.text)
    test.assertTrue(cards[5].shown)
    -- The first Friend is selected, and the right side shows them.
    test.assertEqual(world.players.Anvil.playerId, world.page:Selected())
    test.assertTrue(cards[1].selected)
    test.assertEqual("Anvil", world.page.detail.name.text)
    test.assertFalse(world.page:PickerOpen())
end)

test.test("friends page: with no Friends, the right side says how to add them", function()
    local world = setup({})

    test.assertEqual(nil, world.page:Selected())
    test.assertEqual(world.addon.FriendsPage.EMPTY, world.page.detail.hint.text)
    test.assertTrue(world.page.cards[1].empty)
end)

test.test("friends page: + Add a friend opens Choose a friend, and picking fills the slot", function()
    local world = setup({ "Anvil" })
    click(world.page.cards[2])

    test.assertTrue(world.page:PickerOpen())
    test.assertTrue(world.page.picker.shown)
    test.assertFalse(world.page.detail.shown)
    test.assertEqual(nil, pickerRow(world, "Anvil"))
    test.assertTrue(pickerRow(world, "Cog") ~= nil)

    -- Typing narrows the list.
    world.page.picker.search.box:SetText("bo")
    world.page.picker.search.box.scripts.OnTextChanged(world.page.picker.search.box, true)
    test.assertEqual(nil, pickerRow(world, "Cog"))

    click(pickerRow(world, "Bolt"))
    test.assertEqual("add bolt", world.calls[1])
    test.assertFalse(world.page:PickerOpen())
    test.assertEqual("Bolt", world.page.cards[2].name.text)
    test.assertEqual(world.players.Bolt.playerId, world.page:Selected())
end)

test.test("friends page: Cancel backs out of Choose a friend without changing anything", function()
    local world = setup({ "Anvil" })
    click(world.page.cards[2])
    click(world.page.picker.cancel)

    test.assertFalse(world.page:PickerOpen())
    test.assertTrue(world.page.detail.shown)
    test.assertEqual(0, #world.calls)
end)

test.test("friends page: hovering a Friend shows the X, which removes them", function()
    local world = setup({ "Anvil", "Bolt" })
    local card = world.page.cards[1]
    test.assertFalse(card.remove.shown)

    card.scripts.OnEnter(card)
    test.assertTrue(card.remove.shown)
    card.scripts.OnLeave(card)
    test.assertFalse(card.remove.shown)
    -- Empty slots have no X.
    world.page.cards[3].scripts.OnEnter(world.page.cards[3])
    test.assertFalse(world.page.cards[3].remove.shown)

    click(card.remove)
    test.assertEqual("remove " .. world.players.Anvil.playerId, world.calls[1])
    test.assertEqual("Bolt", world.page.cards[1].name.text)
    test.assertTrue(world.page.cards[2].empty)
end)

test.test("friends page: right-clicking a Friend offers Replace... and Remove friend", function()
    local world = setup({ "Anvil", "Bolt" })
    click(world.page.cards[1], "RightButton")

    local menu = world.page.menu
    test.assertTrue(menu:IsOpen())
    test.assertEqual("Replace…", menu.rows[1].label.text)
    test.assertEqual("Remove friend", menu.rows[2].label.text)
    test.assertTrue(contains(world.content.texts, "Anvil"))

    click(menu.rows[1])
    test.assertTrue(world.page:PickerOpen())
    click(pickerRow(world, "Cog"))
    test.assertEqual("replace " .. world.players.Anvil.playerId .. " cog", world.calls[1])
    test.assertEqual("Cog", world.page.cards[1].name.text)

    click(world.page.cards[2], "RightButton")
    click(menu.rows[2])
    test.assertEqual("remove " .. world.players.Bolt.playerId, world.calls[2])
    -- An empty slot has no menu.
    click(world.page.cards[3], "RightButton")
    test.assertFalse(menu:IsOpen())
end)

test.test("friends page: a Friend who left the guild is greyed out, with no star", function()
    local world = setup({ "Anvil" })
    world.players.Anvil.left = true
    world.players.Anvil.status = "Left the guild"
    world.page:Refresh()

    local card = world.page.cards[1]
    test.assertEqual("Left the guild", card.sub.text)
    test.assertFalse(card.star.shown)
end)

test.test("friends page: Most grouped shows its cards with counts, or a hint with no history", function()
    local world = setup({ "Anvil" })
    test.assertTrue(world.page.noHistory.shown)
    test.assertFalse(world.page.mostCards[1].shown)

    world.most = { world.players.Cog }
    world.page:Refresh()
    local card = world.page.mostCards[1]
    test.assertFalse(world.page.noHistory.shown)
    test.assertEqual("Cog", card.name.text)
    test.assertEqual("7×", card.count.text)
    test.assertTrue(card.star.shown)
    test.assertEqual(nil, rawget(card, "remove"))

    click(card)
    test.assertEqual(world.players.Cog.playerId, world.page:Selected())
    test.assertEqual("Cog", world.page.detail.name.text)
end)

test.test("friends page: right-clicking a Most grouped card offers Add as friend, greyed out when the slots are full", function()
    local world = setup({ "Anvil" })
    world.most = { world.players.Cog }
    world.page:Refresh()
    local menu = world.page.menu

    click(world.page.mostCards[1], "RightButton")
    test.assertEqual("Add as friend", menu.rows[1].label.text)
    test.assertFalse(menu.rows[1].disabled)
    click(menu.rows[1])
    test.assertEqual("add cog", world.calls[1])
    test.assertEqual(world.players.Cog.playerId, world.page:Selected())
    -- Cog is a Friend now, so Most grouped is empty again.
    test.assertTrue(world.page.noHistory.shown)

    -- With every slot taken, the entry is greyed out and does nothing.
    local full = setup({ "Anvil", "Bolt" })
    local _, name
    for _, name in ipairs({ "X1", "X2", "X3" }) do
        table.insert(full.pinned, { playerId = name, key = name, name = name, mainName = name, left = false,
            status = "", online = false })
    end
    full.most = { full.players.Cog }
    full.page:Refresh()
    click(full.page.mostCards[1], "RightButton")
    test.assertTrue(full.page.menu.rows[1].disabled)
    click(full.page.menu.rows[1])
    test.assertEqual(0, #full.calls)
    test.assertTrue(full.page.menu:IsOpen())
end)

test.test("friends page: the detail panel shows the header, badge and tiles; Whisper and Invite reach the online character", function()
    local world = setup({ "Anvil", "Bolt" })
    local detail = world.page.detail

    test.assertEqual("Anvil", detail.name.text)
    test.assertEqual("Friend", detail.badge.text)
    test.assertTrue(detail.badge.shown)
    test.assertTrue(string.find(detail.sub.text, "Last online 2 days ago", 1, true) ~= nil)
    test.assertFalse(detail.whisper.active)
    test.assertFalse(detail.invite.active)
    click(detail.whisper)
    test.assertEqual(0, #world.calls)
    test.assertEqual("DISCORD", detail.tiles[1].label.text)
    test.assertEqual("Not set", detail.tiles[1].value.text)
    test.assertTrue(detail.tiles[1].notSet)
    test.assertEqual("3 times", detail.tiles[2].value.text)
    test.assertFalse(detail.tiles[2].notSet)

    click(world.page.cards[2])
    test.assertEqual("Bolt", detail.name.text)
    test.assertTrue(world.page.cards[2].selected)
    test.assertFalse(world.page.cards[1].selected)
    test.assertTrue(detail.whisper.active)
    click(detail.whisper)
    click(detail.invite)
    test.assertEqual("whisper Bolt-Area52", world.calls[1])
    test.assertEqual("invite Bolt-Area52", world.calls[2])
end)

test.test("friends page: the star button removes a Friend, or adds a Most grouped player, who stays selected", function()
    local world = setup({ "Anvil" })
    world.most = { world.players.Cog }
    world.page:Refresh()

    click(world.page.mostCards[1])
    test.assertFalse(world.page.detail.badge.shown)
    click(world.page.detail.star)
    test.assertEqual("add cog", world.calls[1])
    test.assertEqual(world.players.Cog.playerId, world.page:Selected())
    test.assertEqual("Friend", world.page.detail.badge.text)

    click(world.page.detail.star)
    test.assertEqual("remove " .. world.players.Cog.playerId, world.calls[2])
    -- Cog is back in Most grouped, still selected.
    test.assertEqual(world.players.Cog.playerId, world.page:Selected())
    test.assertEqual("Cog", world.page.mostCards[1].name.text)
end)

test.test("friends page: the star button does nothing when every slot is taken and the player isn't a Friend", function()
    local world = setup({ "Anvil", "Bolt" })
    local _, name
    for _, name in ipairs({ "X1", "X2", "X3" }) do
        table.insert(world.pinned, { playerId = name, key = name, name = name, mainName = name, left = false,
            status = "", online = false })
    end
    world.most = { world.players.Cog }
    world.page:Refresh()

    click(world.page.mostCards[1])
    test.assertEqual("Cog", world.page.detail.name.text)
    click(world.page.detail.star)
    test.assertEqual(0, #world.calls)
end)

test.test("friends page: a Friend whose player is gone still shows their name, with the star to remove them", function()
    local world = setup({ "Anvil" })
    world.gone = true
    world.players.Anvil.left = true
    world.players.Anvil.status = "Left the guild"
    world.page:Refresh()

    test.assertEqual("Anvil", world.page.detail.name.text)
    test.assertTrue(string.find(world.page.detail.sub.text, "Left the guild", 1, true) ~= nil)
    test.assertFalse(world.page.detail.tiles[1].shown)
    click(world.page.detail.star)
    test.assertEqual("remove " .. world.players.Anvil.playerId, world.calls[1])
end)
