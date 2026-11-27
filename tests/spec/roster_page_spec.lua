local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- The Roster page on fake frames, over `count` players held here (default
-- 3): "Player001" and on, the first `online` of them online. Friends are
-- the player ids in `world.friends`. The model keeps the filters it was
-- last given in `world.filters`, and honors the search (on names) and
-- Online only.
local function setup(count, online)
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/ListWindow.lua", "Core/RosterViewModel.lua", "Core/RosterListModel.lua",
        "Core/LfgHistoryView.lua", "Core/PlayerDetailViewModel.lua",
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
        model = function(selected, filters)
            world.filters = filters
            local view = { rows = {}, cards = {}, ranks = { { index = 0, name = "Guild Master" },
                { index = 2, name = "Member" } } }
            local _, section
            for _, section in ipairs({ { text = "Online", on = true }, { text = "Offline", on = false } }) do
                local cards = {}
                local _, player
                for _, player in ipairs(world.players) do
                    if player.online == section.on
                        and string.find(string.lower(player.name), string.lower(filters.search or ""), 1, true)
                        and (player.online or not filters.onlineOnly)
                    then
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
                characters = { { key = "key" .. playerId, name = player.name, isMain = true } },
                panel = { main = "key" .. playerId, canMerge = true },
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
        -- Officers' entries; `world.member` makes the user player 1's.
        menuFor = function(target)
            if target.kind == "player" then
                return { { text = "Set alias...", action = "alias", key = "key" .. target.id },
                    { text = "View player...", action = "view", key = "key" .. target.id } }
            end
            return { { text = "Link as alt of...", action = "setMain", key = target.key },
                { text = "Split off as own player", action = "detach", key = target.key } }
        end,
        canEdit = function(key)
            return not world.member or key == "key1"
        end,
        playerOf = function(key)
            return tonumber(string.match(key, "%d+"))
        end,
        aliasOf = function()
            return "Old"
        end,
        searchPlayers = function(key, query)
            table.insert(world.calls, "search " .. key .. " " .. query)
            return { { id = 2, label = "Player002", matched = "Alty" } }
        end,
        onSetAlias = function(key, text)
            table.insert(world.calls, "alias " .. key .. " " .. text)
        end,
        onSetMain = function(key, playerId)
            table.insert(world.calls, "link " .. key .. " " .. playerId)
        end,
        onDetach = function(key)
            table.insert(world.calls, "detach " .. key)
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

test.test("roster page: the column starts with no search, Online first, any rank and everyone", function()
    local world = setup(3, 1)

    test.assertEqual("", world.filters.search)
    test.assertEqual("online", world.filters.sort)
    test.assertEqual(nil, world.filters.rank)
    test.assertFalse(world.filters.onlineOnly)
    test.assertEqual("Sort: Online first", world.page.sortButton.label.text)
    test.assertEqual("Any rank", world.page.rankButton.label.text)
    test.assertFalse(world.page.onlineSwitch:IsOn())
end)

test.test("roster page: typing a search narrows the list", function()
    local world = setup(3, 1)
    local box = world.page.search.box
    box:SetText("player002")
    box.scripts.OnTextChanged(box, true)

    test.assertEqual("player002", world.filters.search)
    local cards = shownCards(world)
    test.assertEqual(1, #cards)
    test.assertEqual("Player002", cards[1].name.text)
end)

test.test("roster page: Sort opens its choices and picking one re-sorts", function()
    local world = setup(3, 1)
    click(world.page.sortButton)
    local menu = world.page.menu

    test.assertTrue(menu:IsOpen())
    test.assertEqual("Online first", menu.rows[1].label.text)
    test.assertEqual("Rank", menu.rows[4].label.text)
    click(menu.rows[4])
    test.assertEqual("rank", world.filters.sort)
    test.assertEqual("Sort: Rank", world.page.sortButton.label.text)
end)

test.test("roster page: Rank offers Any rank and each rank, and filters by the one picked", function()
    local world = setup(3, 1)
    click(world.page.rankButton)
    local menu = world.page.menu

    test.assertEqual("Any rank", menu.rows[1].label.text)
    test.assertEqual("Guild Master", menu.rows[2].label.text)
    test.assertEqual("Member", menu.rows[3].label.text)
    click(menu.rows[3])
    test.assertEqual(2, world.filters.rank)
    test.assertEqual("Rank: Member", world.page.rankButton.label.text)

    click(world.page.rankButton)
    click(menu.rows[1])
    test.assertEqual(nil, world.filters.rank)
    test.assertEqual("Any rank", world.page.rankButton.label.text)
end)

test.test("roster page: Online only hides offline players, and a hidden selection moves to the first shown", function()
    local world = setup(3, 1)
    click(cardNamed(world, "Player003"))
    click(world.page.onlineSwitch)

    test.assertTrue(world.filters.onlineOnly)
    test.assertTrue(world.page.onlineSwitch:IsOn())
    test.assertEqual(1, #shownCards(world))
    test.assertEqual(1, world.page:Selected())
    test.assertEqual("Player001", world.page.detail.name.text)
end)

test.test("roster page: the selection stays while its player is still shown", function()
    local world = setup(3, 1)
    click(cardNamed(world, "Player003"))
    local box = world.page.search.box
    box:SetText("3")
    box.scripts.OnTextChanged(box, true)

    test.assertEqual(3, world.page:Selected())
    test.assertTrue(cardNamed(world, "Player003").selected)
    -- Refreshed with the filters still on, it keeps them.
    world.page:Refresh()
    test.assertEqual("3", world.filters.search)
    test.assertEqual(3, world.page:Selected())
end)

-- The labels of the page's open context menu, in order.
local function menuLabels(world)
    local labels = {}
    local _, item
    for _, item in ipairs(world.page.menu.items or {}) do
        table.insert(labels, item.label)
    end
    return table.concat(labels, ", ")
end

test.test("roster page: right-clicking a card lists its actions, and View player... shows that player", function()
    local world = setup(3, 1)
    local card = cardNamed(world, "Player003")
    click(card, "RightButton")

    test.assertEqual("Set alias..., View player...", menuLabels(world))
    test.assertEqual("Player003", world.page.menu.titleText)
    click(world.page.menu.rows[2])
    test.assertEqual(3, world.page:Selected())
    test.assertEqual("Player003", world.page.detail.name.text)
end)

test.test("roster page: Set alias... asks for the alias, starting with the current one", function()
    local world = setup(3, 1)
    click(cardNamed(world, "Player002"), "RightButton")
    click(world.page.menu.rows[1])
    local prompt = world.page.prompt

    test.assertTrue(prompt:IsOpen())
    test.assertEqual("Old", prompt.single:GetValue())
    prompt.single:SetValue("Newname")
    click(prompt.save)
    test.assertFalse(prompt:IsOpen())
    test.assertEqual("alias key2 Newname", world.calls[1])
end)

test.test("roster page: Cancel closes the prompt without saving", function()
    local world = setup(3, 1)
    click(cardNamed(world, "Player002"), "RightButton")
    click(world.page.menu.rows[1])
    click(world.page.prompt.cancel)

    test.assertFalse(world.page.prompt:IsOpen())
    test.assertEqual(0, #world.calls)
end)

test.test("roster page: a character card's Link as alt of... picks the player from a search", function()
    local world = setup(3, 1)
    local card = world.page.detail.characterCards[1]
    click(card, "RightButton")

    test.assertEqual("Link as alt of..., Split off as own player", menuLabels(world))
    click(world.page.menu.rows[1])
    test.assertTrue(world.page:PickerOpen())
    test.assertFalse(world.page.detail.shown)
    test.assertEqual("Link Player001 as an alt of:", world.page.picker.prompt.text)
    test.assertEqual("search key1 ", world.calls[1])
    local row = world.page.picker.rows[1]
    test.assertEqual("Player002", row.name.text)
    test.assertEqual("matches Alty", row.sub.text)
    click(row)
    test.assertEqual("link key1 2", world.calls[2])
    test.assertFalse(world.page:PickerOpen())
    test.assertTrue(world.page.detail.shown)
end)

test.test("roster page: the picker stays over the panel when the roster changes", function()
    local world = setup(3, 1)
    click(world.page.detail.characterCards[1], "RightButton")
    click(world.page.menu.rows[1])
    world.page:Refresh()

    test.assertTrue(world.page:PickerOpen())
    test.assertFalse(world.page.detail.shown)
    click(world.page.picker.cancel)
    test.assertFalse(world.page:PickerOpen())
    test.assertTrue(world.page.detail.shown)
end)

test.test("roster page: the ⋯ menu offers Set alias..., Set Discord... and Merge into player...", function()
    local world = setup(3, 1)
    local actions = world.page.detail.actions

    test.assertTrue(actions.shown)
    click(actions)
    test.assertEqual("Set alias..., Set Discord..., Merge into player...", menuLabels(world))
    click(world.page.menu.rows[3])
    test.assertEqual("Merge into player", world.page.picker.title.text)
end)

test.test("roster page: someone else's player has no ⋯ and no Edit for a member", function()
    local world = setup(3, 1)
    world.member = true
    world.page:Refresh(2)

    test.assertFalse(world.page.detail.actions.shown)
    world.page.detail:ShowTab("bio")
    test.assertEqual(0, #world.page.detail.edits)

    world.page:Refresh(1)
    test.assertTrue(world.page.detail.actions.shown)
end)
