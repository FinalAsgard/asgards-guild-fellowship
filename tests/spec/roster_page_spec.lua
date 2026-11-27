local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- The Roster page on fake frames, over `count` players held here (default
-- 3): "Player001" and on, the first `online` of them online. Friends are
-- the player ids in `world.friends`.
local function setup(count, online)
    local addon = test.newAddon("Core/ListWindow.lua", "Core/LfgHistoryView.lua", "Core/PlayerDetailViewModel.lua",
        "Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/PlayerCards.lua", "Adapters/PlayerDetailPanel.lua",
        "Adapters/RosterPage.lua")
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local content = environment.CreateFrame("Frame")
    local world = { addon = addon, calls = {}, friends = {}, players = {} }
    local index
    for index = 1, count or 3 do
        table.insert(world.players, { playerId = index, name = string.format("Player%03d", index),
            online = index <= (online or 1) })
    end
    world.page = addon.RosterPage.Create(content, ui, {
        model = function(selected)
            local view = { rows = {}, cards = {} }
            local _, section
            for _, section in ipairs({ { text = "Online", on = true }, { text = "Offline", on = false } }) do
                local cards = {}
                local _, player
                for _, player in ipairs(world.players) do
                    if player.online == section.on then
                        table.insert(cards, { kind = "player", playerId = player.playerId, name = player.name,
                            sub = "2 characters", online = player.online, star = world.friends[player.playerId] })
                    end
                end
                if cards[1] ~= nil then
                    table.insert(view.rows, { kind = "section", text = section.text, count = #cards })
                    local _, card
                    for _, card in ipairs(cards) do
                        table.insert(view.rows, card)
                        table.insert(view.cards, card)
                        if card.playerId == selected then
                            view.selected = selected
                        end
                    end
                end
            end
            view.default = view.cards[1] and view.cards[1].playerId or nil
            view.header = #world.players .. " players · " .. (online or 1) .. " online"
            view.sync = "Synced 5 minutes ago"
            return view
        end,
        detail = function(playerId)
            local player = world.players[playerId]
            if player == nil then
                return nil
            end
            local isFriend = world.friends[playerId] == true
            return {
                playerId = playerId,
                header = { name = player.name, mainName = player.name, key = "key" .. playerId,
                    target = player.online and player.name or nil, isFriend = isFriend, canToggle = true,
                    badge = isFriend and { kind = "friend" } or nil },
                characters = {},
                tiles = {},
            }
        end,
        onWhisper = function(target)
            table.insert(world.calls, "whisper " .. target)
        end,
        onToggleFriend = function(view)
            table.insert(world.calls, "toggle " .. view.playerId)
            world.friends[view.playerId] = not world.friends[view.playerId] or nil
            return true
        end,
        onRescan = function()
            table.insert(world.calls, "rescan")
        end,
    })
    world.page:Refresh()
    return world
end

-- The shown player cards, by name, top to bottom.
local function shownCards(world)
    local cards = {}
    local _, frame
    for _, frame in ipairs(world.page.list:Shown()) do
        if rawget(frame, "entry") ~= nil and frame.shown then
            table.insert(cards, frame)
        end
    end
    table.sort(cards, function(a, b)
        return a.entry.playerId < b.entry.playerId
    end)
    return cards
end

local function cardNamed(world, name)
    local _, card
    for _, card in ipairs(shownCards(world)) do
        if card.name.text == name then
            return card
        end
    end
    return nil
end

local function click(button, which)
    button.scripts.OnClick(button, which)
end

test.test("roster page: players show as cards under Online and Offline labels", function()
    local world = setup(3, 1)
    local cards = shownCards(world)

    test.assertEqual(3, #cards)
    test.assertEqual("Player001", cards[1].name.text)
    test.assertEqual("2 characters", cards[1].sub.text)
    local labels = {}
    local _, frame
    for _, frame in ipairs(world.page.list:Shown()) do
        if rawget(frame, "entry") == nil and frame.shown then
            table.insert(labels, frame.label.text)
        end
    end
    table.sort(labels)
    test.assertEqual("OFFLINE · 2, ONLINE · 1", table.concat(labels, ", "))
end)

test.test("roster page: the first player is selected and shown in the player panel", function()
    local world = setup(3, 1)

    test.assertEqual(1, world.page:Selected())
    test.assertTrue(cardNamed(world, "Player001").selected)
    test.assertEqual("Player001", world.page.detail.name.text)
end)

test.test("roster page: clicking a card selects it and shows that player", function()
    local world = setup(3, 1)
    click(cardNamed(world, "Player003"))

    test.assertEqual(3, world.page:Selected())
    test.assertTrue(cardNamed(world, "Player003").selected)
    test.assertFalse(cardNamed(world, "Player001").selected)
    test.assertEqual("Player003", world.page.detail.name.text)
end)

test.test("roster page: Whisper on the panel whispers the online player", function()
    local world = setup(3, 1)
    click(world.page.detail.whisper)

    test.assertEqual("whisper Player001", world.calls[1])
end)

test.test("roster page: the header shows the counts and the sync time, and Rescan rescans", function()
    local world = setup(3, 1)

    test.assertEqual("3 players · 1 online · Synced 5 minutes ago", world.page.counts.text)
    click(world.page.rescan)
    test.assertEqual("rescan", world.calls[1])
end)

test.test("roster page: the star pins the player as a Friend and their card gets the star", function()
    local world = setup(3, 1)
    click(cardNamed(world, "Player002"))
    click(world.page.detail.star)

    test.assertEqual("toggle 2", world.calls[1])
    test.assertEqual(2, world.page:Selected())
    test.assertTrue(cardNamed(world, "Player002").star.shown)
end)

test.test("roster page: 550 players build only the frames the viewport needs", function()
    local world = setup(550, 40)
    local list = world.page.list
    local bound = math.ceil(world.addon.RosterPage.VIEWPORT / world.addon.RosterPage.CARD_HEIGHT) + 1

    test.assertTrue(list:Built("player") <= bound, "built " .. list:Built("player") .. " cards")
    -- Scrolling all the way down refills the same frames.
    local notch
    for notch = 1, 1000 do
        list.scripts.OnMouseWheel(list, -1)
    end
    test.assertTrue(list:Built("player") <= bound, "built " .. list:Built("player") .. " cards")
    test.assertTrue(list:Built("section") <= 2)
    local cards = shownCards(world)
    test.assertEqual("Player550", cards[#cards].name.text)
    -- And back up.
    for notch = 1, 1000 do
        list.scripts.OnMouseWheel(list, 1)
    end
    test.assertEqual(0, list:Offset())
    test.assertEqual("Player001", shownCards(world)[1].name.text)
end)

test.test("roster page: showing a player keeps their card in view", function()
    local world = setup(550, 40)
    world.page:Refresh(300)

    test.assertEqual(300, world.page:Selected())
    test.assertTrue(world.page.list:Offset() > 0)
    test.assertTrue(cardNamed(world, "Player300").selected)
    test.assertEqual("Player300", world.page.detail.name.text)
end)

test.test("roster page: with nobody to show, the panel says so", function()
    local world = setup(0)

    test.assertEqual(nil, world.page:Selected())
    test.assertEqual(world.addon.RosterPage.EMPTY, world.page.detail.hint.text)
    test.assertEqual(0, #shownCards(world))
end)
