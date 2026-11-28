local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- The Roster page on fake frames, over `count` players held here (default
-- 3): "Player001" and on, the first `online` of them online. Friends are
-- the player ids in `world.friends`. The model keeps the filters it was
-- last given in `world.filters`, and honors the search (on names) and
-- Online only.
local function setup(count, online)
    local addon = test.newAddon("Core/FellowshipStore.lua", "Core/ListWindow.lua", "Core/RosterViewModel.lua", "Core/RosterListModel.lua",
        "Core/LfgHistoryView.lua", "Core/PlayerDetailViewModel.lua", "Core/RankUpViewModel.lua",
        "Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/PlayerCards.lua", "Adapters/PlayerDetailPanel.lua",
        "Adapters/RosterPage.lua")
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local content = environment.CreateFrame("Frame")
    local world = { addon = addon, environment = environment, calls = {}, friends = {}, players = {} }
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
            -- `world.flat` lists everyone in one section, as the model does.
            local sections = world.flat and { { text = "Players" } }
                or { { text = "Online", on = true }, { text = "Offline", on = false } }
            for _, section in ipairs(sections) do
                local cards = {}
                local _, player
                for _, player in ipairs(world.players) do
                    if (section.on == nil or player.online == section.on)
                        and string.find(string.lower(player.name), string.lower(filters.search or ""), 1, true)
                        and (player.online or not filters.onlineOnly)
                    then
                        table.insert(cards, { kind = "player", playerId = player.playerId, name = player.name,
                            sub = "2 characters", online = player.online, star = world.friends[player.playerId],
                            tag = world.tag })
                    end
                end
                -- `world.reverse` sorts each section the other way.
                if world.reverse then
                    local reversed = {}
                    local position
                    for position = #cards, 1, -1 do
                        table.insert(reversed, cards[position])
                    end
                    cards = reversed
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
                -- `world.checklist(playerId)` is the Rank tab's, when set.
                rank = world.checklist and world.checklist(playerId) or nil,
            }
        end,
        onRankTick = function(key, item, ticked, note)
            table.insert(world.calls, "tick " .. key .. " " .. item .. " " .. tostring(ticked)
                .. (note and (" " .. note) or ""))
            if world.refuse ~= nil then
                return false, world.refuse
            end
            return true
        end,
        onSnooze = function(key)
            table.insert(world.calls, "snooze " .. key)
            return true
        end,
        onError = function(text)
            world.error = text
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
        -- `world.officer` gets the tabs; `world.gone` are the departed rows.
        isOfficer = function()
            return world.officer == true
        end,
        departed = function()
            return world.gone or {}
        end,
        onPurge = function(key)
            table.insert(world.calls, "purge " .. key)
            local index
            for index = #(world.gone or {}), 1, -1 do
                if world.gone[index].key == key then
                    table.remove(world.gone, index)
                end
            end
        end,
        onPurgeAll = function()
            table.insert(world.calls, "purge all")
            world.gone = {}
        end,
        -- `world.waiting` are the Review rows; `world.reviews` the reviews by
        -- group.
        suggestions = function()
            return world.waiting or {}
        end,
        onApprove = function(character, kind)
            table.insert(world.calls, "approve " .. character .. " " .. kind)
            table.remove(world.waiting, 1)
        end,
        onDeny = function(character, kind)
            table.insert(world.calls, "deny " .. character .. " " .. kind)
            table.remove(world.waiting, 1)
        end,
        onApproveAll = function()
            table.insert(world.calls, "approve all")
            world.waiting = {}
        end,
        onDenyAll = function()
            table.insert(world.calls, "deny all")
            world.waiting = {}
        end,
        reviewOf = function(group)
            if world.waiting == nil or world.waiting[1] == nil then
                return nil
            end
            return (world.reviews or {})[group]
        end,
        countsTooltip = function()
            return { "Guild size", "3 players, all known", "5 of 9 characters online" }
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

test.test("roster page: players show as cards under their section labels", function()
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

test.test("roster page: the ⋯ menu's Whisper and Invite reach the online player", function()
    local world = setup(3, 1)
    -- No buttons for them on the panel itself.
    test.assertFalse(world.page.detail.whisper.shown)
    test.assertFalse(world.page.detail.invite.shown)
    click(world.page.detail.actions)
    click(world.page.menu.rows[1])

    test.assertEqual("whisper Player001", world.calls[1])
end)

test.test("roster page: Whisper and Invite are greyed out for an offline player", function()
    local world = setup(3, 1)
    world.page:Refresh(2)
    click(world.page.detail.actions)

    test.assertTrue(world.page.menu.rows[1].disabled)
    test.assertTrue(world.page.menu.rows[2].disabled)
    click(world.page.menu.rows[1])
    test.assertEqual(0, #world.calls)
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

test.test("roster page: the column starts with no search, by Name, any rank and everyone", function()
    local world = setup(3, 1)

    test.assertEqual("", world.filters.search)
    test.assertEqual("name", world.filters.sort)
    test.assertEqual(nil, world.filters.rank)
    test.assertFalse(world.filters.onlineOnly)
    test.assertEqual("Sort: Name", world.page.sortButton.label.text)
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
    test.assertEqual("Name", menu.rows[1].label.text)
    test.assertEqual("Grouped with", menu.rows[4].label.text)
    click(menu.rows[3])
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

test.test("roster page: the ⋯ menu offers Whisper, Invite, Set alias..., Set Discord... and Merge into player...", function()
    local world = setup(3, 1)
    local actions = world.page.detail.actions

    test.assertTrue(actions.shown)
    click(actions)
    test.assertEqual("Whisper, Invite, Set alias..., Set Discord..., Merge into player...", menuLabels(world))
    click(world.page.menu.rows[5])
    test.assertEqual("Merge into player", world.page.picker.title.text)
end)

test.test("roster page: on someone else's player, a member's ⋯ has only Whisper and Invite, and there's no Edit", function()
    local world = setup(3, 1)
    world.member = true
    world.page:Refresh(2)

    test.assertTrue(world.page.detail.actions.shown)
    click(world.page.detail.actions)
    test.assertEqual("Whisper, Invite", menuLabels(world))
    world.page.menu:Close()
    world.page.detail:ShowTab("bio")
    test.assertEqual(0, #world.page.detail.edits)

    world.page:Refresh(1)
    click(world.page.detail.actions)
    test.assertEqual("Whisper, Invite, Set alias..., Set Discord..., Merge into player...", menuLabels(world))
end)

test.test("roster page: a card shows its tag after the name", function()
    local world = setup(3, 1)
    world.tag = "Officer"
    world.page:Refresh()

    test.assertEqual("Officer", cardNamed(world, "Player002").tag.text)
    world.tag = nil
    world.page:Refresh()
    test.assertEqual("", cardNamed(world, "Player002").tag.text)
end)

test.test("roster page: a short list has no scroll bar", function()
    local world = setup(3, 1)

    test.assertFalse(world.page.list.bar.shown)
end)

test.test("roster page: a long list has a scroll bar that jumps through it", function()
    local world = setup(550, 40)
    local bar = world.page.list.bar

    test.assertTrue(bar.shown)
    bar.scripts.OnValueChanged(bar, 999999)
    local cards = shownCards(world)
    test.assertEqual("Player550", cards[#cards].name.text)
    bar.scripts.OnValueChanged(bar, 0)
    test.assertEqual(0, world.page.list:Offset())
    test.assertEqual("Player001", shownCards(world)[1].name.text)
end)

-- The shown cards' names in list order (by where each sits).
local function cardOrder(world)
    local cards = {}
    local _, frame
    for _, frame in ipairs(world.page.list:Shown()) do
        if rawget(frame, "entry") ~= nil and frame.shown then
            table.insert(cards, frame)
        end
    end
    local rows = world.page.list:Rows()
    local index = {}
    local position
    for position = 1, #rows do
        local row = rows[position]
        index[row] = position
    end
    table.sort(cards, function(a, b)
        return index[a.entry] < index[b.entry]
    end)
    local names = {}
    local _, card
    for _, card in ipairs(cards) do
        table.insert(names, card.name.text)
    end
    return table.concat(names, ", ")
end

test.test("roster page: a roster update shows what's new without sorting the list again", function()
    local world = setup(3, 3)
    world.flat = true
    world.page:Refresh()
    world.reverse = true
    world.players[2].online = false
    world.page:Update()

    -- Player002 went offline: their dot changes, but nobody moves.
    test.assertEqual("Player001, Player002, Player003", cardOrder(world))
    test.assertFalse(cardNamed(world, "Player002").entry.online)

    -- A sort (or filter, or search) change sorts it again.
    world.page:Refresh()
    test.assertEqual("Player003, Player002, Player001", cardOrder(world))
end)

test.test("roster page: a player new to the list goes after the rest on an update", function()
    local world = setup(3, 3)
    table.insert(world.players, 1, { playerId = 9, name = "Player000", online = true })
    world.players[9] = world.players[1]
    world.page:Update()

    test.assertEqual("Player001, Player002, Player003, Player000", cardOrder(world))
end)

test.test("roster page: a roster update leaves the list where it's scrolled to", function()
    local world = setup(550, 40)
    world.page:Refresh(1)
    world.page.list:ScrollTo(5000)
    local offset = world.page.list:Offset()
    world.page:Update()

    test.assertEqual(offset, world.page.list:Offset())
    test.assertEqual(1, world.page:Selected())
end)

test.test("roster page: under Online only, a player who logs off keeps their card until the list is sorted again", function()
    local world = setup(3, 3)
    world.flat = true
    click(world.page.onlineSwitch)
    world.players[2].online = false
    table.insert(world.players, { playerId = 4, name = "Player004", online = false })
    table.insert(world.players, { playerId = 5, name = "Player005", online = true })
    world.page:Update()

    -- Player002 stays where they were, now offline; only the new online
    -- player is added.
    test.assertEqual("Player001, Player002, Player003, Player005", cardOrder(world))
    test.assertFalse(cardNamed(world, "Player002").entry.online)

    world.page:Refresh()
    test.assertEqual("Player001, Player003, Player005", cardOrder(world))
end)

test.test("roster page: hovering the counts shows the guild's size, characters included", function()
    local world = setup(3, 1)
    local shown = {}
    world.environment.GameTooltip = {
        SetOwner = function() end,
        SetText = function(_, text)
            shown = { text }
        end,
        AddLine = function(_, text)
            table.insert(shown, text)
        end,
        Show = function(self)
            self.open = true
        end,
        Hide = function(self)
            self.open = false
        end,
    }
    local hover = world.page.countsHover
    hover.scripts.OnEnter(hover)

    test.assertTrue(world.environment.GameTooltip.open)
    test.assertEqual("Guild size | 3 players, all known | 5 of 9 characters online", table.concat(shown, " | "))
    hover.scripts.OnLeave(hover)
    test.assertFalse(world.environment.GameTooltip.open)
end)

-- Officers' tabs ---------------------------------------------------------------

-- Two departed characters: Oldalt, whose player still has Player001 in the
-- guild, and Gonzo, whose whole player left.
local function departedRows()
    return {
        { key = "oldalt", name = "Oldalt", level = 30, className = "Mage", color = "ff3fc7eb", player = "Player001",
            left = "Left 2 days ago", remaining = { "Player001" } },
        { key = "gonzo", name = "Gonzo", level = 60, className = "Rogue", player = "Gonzo",
            left = "Left 9 days ago", remaining = {} },
    }
end

-- The shown departed rows, top to bottom.
local function departedShown(world)
    local rows = {}
    local _, frame
    for _, frame in ipairs(world.page.departedList:Shown()) do
        if frame.shown then
            table.insert(rows, frame)
        end
    end
    table.sort(rows, function(a, b)
        return a.entry.key > b.entry.key
    end)
    return rows
end

test.test("roster page: a member gets the roster with no tabs", function()
    local world = setup(3, 1)

    test.assertFalse(world.page.tabs.shown)
    test.assertTrue(world.page.membersBody.shown)
    test.assertFalse(world.page.departedBody.shown)
    test.assertFalse(world.page.reviewBody.shown)
end)

test.test("roster page: an officer gets Members, Departed and Review tabs, on Members", function()
    local world = setup(3, 1)
    world.officer = true
    world.gone = departedRows()
    world.page:Refresh()
    local tabs = world.page.tabs

    test.assertTrue(tabs.shown)
    test.assertEqual("Members", tabs.tabs[1].label.text)
    test.assertEqual("Departed · 2", tabs.tabs[2].label.text)
    test.assertEqual("Review", tabs.tabs[3].label.text)
    test.assertEqual("members", tabs:Selected())
    test.assertTrue(world.page.membersBody.shown)

    click(tabs.tabs[3])
    test.assertTrue(world.page.reviewBody.shown)
    test.assertFalse(world.page.membersBody.shown)
end)

test.test("roster page: Departed lists each character with its player, when it left and who's still in", function()
    local world = setup(3, 1)
    world.officer = true
    world.gone = departedRows()
    world.page:Refresh()
    click(world.page.tabs.tabs[2])

    test.assertTrue(world.page.departedBody.shown)
    test.assertFalse(world.page.membersBody.shown)
    test.assertEqual("2 characters have left the guild.", world.page.departedSummary.text)
    local rows = departedShown(world)
    test.assertEqual(2, #rows)
    test.assertEqual("|cff3fc7ebOldalt|r  |cff9d9d9dLevel 30 Mage|r", rows[1].name.text)
    test.assertEqual("Player001 · Left 2 days ago · Still in the guild: Player001", rows[1].sub.text)
    test.assertEqual("Gonzo · Left 9 days ago · The whole player left", rows[2].sub.text)
end)

test.test("roster page: Purge purges one departed character and the count follows", function()
    local world = setup(3, 1)
    world.officer = true
    world.gone = departedRows()
    world.page:Refresh()
    click(world.page.tabs.tabs[2])
    click(departedShown(world)[2].purge)

    test.assertEqual("purge gonzo", world.calls[1])
    test.assertEqual(1, #departedShown(world))
    test.assertEqual("Departed · 1", world.page.tabs.tabs[2].label.text)
end)

test.test("roster page: Purge all departed asks first, and Cancel backs out", function()
    local world = setup(3, 1)
    world.officer = true
    world.gone = departedRows()
    world.page:Refresh()
    click(world.page.tabs.tabs[2])
    local purgeAll = world.page.purgeAll

    click(purgeAll)
    test.assertEqual(0, #world.calls)
    test.assertEqual("Purge all 2?", purgeAll.label.text)
    test.assertTrue(world.page.purgeCancel.shown)
    click(world.page.purgeCancel)
    test.assertEqual("Purge all departed", purgeAll.label.text)
    test.assertEqual(0, #world.calls)

    click(purgeAll)
    click(purgeAll)
    test.assertEqual("purge all", world.calls[1])
    test.assertEqual("Departed · 0", world.page.tabs.tabs[2].label.text)
    test.assertTrue(world.page.noDeparted.shown)
    test.assertFalse(purgeAll.active)
end)

test.test("roster page: an officer demoted to member loses the tabs", function()
    local world = setup(3, 1)
    world.officer = true
    world.page:Refresh()
    click(world.page.tabs.tabs[2])
    world.officer = false
    world.page:Refresh()

    test.assertFalse(world.page.tabs.shown)
    test.assertTrue(world.page.membersBody.shown)
    test.assertFalse(world.page.departedBody.shown)
end)

-- Review -----------------------------------------------------------------------

local function waitingRows()
    return {
        { character = "hammer", kind = "suggested main", group = "g1", player = "TheTool", name = "Hammer",
            suggests = "Alt of Nail", current = "Alt of Toolbox", suggestedBy = "Hammer (TheTool)", reviewable = true },
        { character = "bolt", kind = "suggested discord", group = "g2", player = "Bolt", name = "Bolt",
            suggests = "Discord \"bolt#1\"", current = "No Discord", suggestedBy = "Bolt", reviewable = false },
    }
end

local function reviewShown(world)
    local rows = {}
    local _, frame
    for _, frame in ipairs(world.page.reviewList:Shown()) do
        if frame.shown then
            table.insert(rows, frame)
        end
    end
    table.sort(rows, function(a, b)
        return a.entry.character > b.entry.character
    end)
    return rows
end

local function openReviewTab(world)
    world.officer = true
    world.waiting = waitingRows()
    world.page:Refresh()
    click(world.page.tabs.tabs[3])
end

test.test("roster page: Review lists each suggestion with the player, the change and who suggested it", function()
    local world = setup(3, 1)
    openReviewTab(world)

    test.assertEqual("Review · 2", world.page.tabs.tabs[3].label.text)
    test.assertEqual("2 suggestions are waiting.", world.page.reviewSummary.text)
    local rows = reviewShown(world)
    test.assertEqual("TheTool · Hammer", rows[1].name.text)
    test.assertEqual("Alt of Nail · now Alt of Toolbox · Suggested by Hammer (TheTool)", rows[1].sub.text)
    -- Only a change to a main or its alts offers Review.
    test.assertTrue(rows[1].review.shown)
    test.assertFalse(rows[2].review.shown)
end)

test.test("roster page: Approve and Deny decide one suggestion each", function()
    local world = setup(3, 1)
    openReviewTab(world)
    click(reviewShown(world)[1].approve)

    test.assertEqual("approve hammer suggested main", world.calls[1])
    test.assertEqual("Review · 1", world.page.tabs.tabs[3].label.text)
    click(reviewShown(world)[1].deny)
    test.assertEqual("deny bolt suggested discord", world.calls[2])
    test.assertEqual("Review", world.page.tabs.tabs[3].label.text)
    test.assertTrue(world.page.reviewEmpty.shown)
    test.assertFalse(world.page.approveAll.active)
end)

test.test("roster page: Approve all and Deny all decide the whole list", function()
    local world = setup(3, 1)
    openReviewTab(world)
    click(world.page.approveAll)

    test.assertEqual("approve all", world.calls[1])
    test.assertEqual(0, #reviewShown(world))

    world.waiting = waitingRows()
    world.page:Refresh()
    click(world.page.denyAll)
    test.assertEqual("deny all", world.calls[2])
end)

test.test("roster page: Review shows the player before and after, and Back returns to the list", function()
    local world = setup(3, 1)
    world.reviews = { g1 = { title = "TheTool", suggestedBy = "Suggested by Hammer (TheTool)", lines = {
        { before = "Main: Toolbox", after = "Main: Toolbox" },
        { before = "Alt: Hammer", after = "" },
    } } }
    openReviewTab(world)
    click(reviewShown(world)[1].review)
    local view = world.page.reviewView

    test.assertTrue(view.shown)
    test.assertEqual("Review: TheTool", view.title.text)
    test.assertEqual("Suggested by Hammer (TheTool)", view.suggestedBy.text)
    test.assertEqual("Alt: Hammer", view.lines[2].before.text)
    test.assertEqual("", view.lines[2].after.text)
    click(view.back)
    test.assertFalse(view.shown)
end)

test.test("roster page: a review closes once its suggestions are all decided", function()
    local world = setup(3, 1)
    world.reviews = { g1 = { title = "TheTool", lines = {} } }
    openReviewTab(world)
    click(reviewShown(world)[1].review)
    click(world.page.approveAll)

    test.assertFalse(world.page.reviewView.shown)
end)

-- The panel's Rank tab --------------------------------------------------------------

-- A Due checklist for the panel: an automated item met, one missing, an
-- officer check and one that needs a note.
local function dueChecklist(editable)
    return function(playerId)
        return {
            playerId = playerId,
            key = "key" .. playerId,
            status = "Due",
            statusText = "Due",
            rankText = "→ Member",
            promoteText = "",
            editable = editable,
            items = {
                { id = "days", label = "In the guild 7 days", state = "met", detail = "30 days (needs 7)" },
                { id = "level", label = "Level 70", state = "missing", detail = "level 66 of 70" },
                { id = "rules", label = "Read the rules", check = true, checked = true, state = "ticked",
                    detail = "by Toolbox" },
                { id = "interview", label = "Interview", check = true, needsNote = true, checked = false,
                    state = "unticked", detail = "" },
            },
        }
    end
end

local function rankTab(world)
    local detail = world.page.detail
    detail.tabs.tabs[5].scripts.OnClick(detail.tabs.tabs[5], "LeftButton")
    return detail
end

test.test("roster page: the panel's Rank tab shows only with a checklist", function()
    local world = setup()
    world.page:Refresh()
    test.assertFalse(world.page.detail.tabs.tabs[5].shown)

    world.checklist = dueChecklist(true)
    world.page:Refresh()
    test.assertTrue(world.page.detail.tabs.tabs[5].shown)
    test.assertEqual("Rank", world.page.detail.tabs.tabs[5].label.text)
end)

test.test("roster page: the Rank tab shows the status, the rank promoted to and each requirement in words", function()
    local world = setup()
    world.checklist = dueChecklist(true)
    world.page:Refresh()
    local detail = rankTab(world)

    test.assertEqual("rank", detail.tabs:Selected())
    test.assertEqual("Due · → Member", detail.lines[1].text)
    local rows = detail.rankRows
    test.assertEqual("In the guild 7 days", rows[1].label.text)
    test.assertEqual("30 days (needs 7)", rows[1].detail.text)
    test.assertEqual("green", rows[1].color)
    test.assertFalse(rows[1].box.shown)
    test.assertEqual("red", rows[2].color)
    test.assertTrue(rows[3].box.shown)
    test.assertTrue(rows[3].box:IsChecked())
    test.assertEqual("by Toolbox", rows[3].detail.text)
    test.assertTrue(detail.snooze.shown)
end)

test.test("roster page: an officer ticks, notes, overrides and snoozes from the Rank tab", function()
    local world = setup()
    world.checklist = dueChecklist(true)
    world.page:Refresh()
    local detail = rankTab(world)
    local rows = detail.rankRows

    rows[3].box.scripts.OnClick(rows[3].box, "LeftButton")
    test.assertEqual("tick key1 rules false", world.calls[#world.calls])

    -- A check that needs a note asks for it first.
    rows[4].box.scripts.OnClick(rows[4].box, "LeftButton")
    test.assertTrue(detail.prompt:IsOpen())
    detail.prompt.single:SetValue("Talked on Discord")
    detail.prompt.save.scripts.OnClick(detail.prompt.save, "LeftButton")
    test.assertEqual("tick key1 interview true Talked on Discord", world.calls[#world.calls])

    -- Right-click a failed automated one to override it.
    rows[2].scripts.OnClick(rows[2], "RightButton")
    test.assertEqual("Override as met...", detail.menu.rows[1].label.text)
    detail.menu.rows[1].scripts.OnClick(detail.menu.rows[1], "LeftButton")
    detail.prompt.single:SetValue("Levels on an alt")
    detail.prompt.save.scripts.OnClick(detail.prompt.save, "LeftButton")
    test.assertEqual("tick key1 level true Levels on an alt", world.calls[#world.calls])

    detail.snooze.scripts.OnClick(detail.snooze, "LeftButton")
    test.assertEqual("snooze key1", world.calls[#world.calls])
    -- Still on the Rank tab, shown again.
    test.assertEqual("rank", detail.tabs:Selected())
end)

test.test("roster page: a refused tick on the Rank tab says why", function()
    local world = setup()
    world.checklist = dueChecklist(true)
    world.page:Refresh()
    local rows = rankTab(world).rankRows
    world.refuse = "only officers can tick promotion requirements"
    rows[3].box.scripts.OnClick(rows[3].box, "LeftButton")

    test.assertEqual("Player001's checklist wasn't changed: only officers can tick promotion requirements.",
        world.error)
end)

test.test("roster page: a member's own Rank tab is read-only", function()
    local world = setup()
    world.checklist = dueChecklist(false)
    world.page:Refresh()
    local detail = rankTab(world)
    local rows = detail.rankRows
    local before = #world.calls

    test.assertEqual("Only officers can change this checklist.", detail.lines[2].text)
    test.assertFalse(detail.snooze.shown)
    rows[3].box.scripts.OnClick(rows[3].box, "LeftButton")
    rows[2].scripts.OnClick(rows[2], "RightButton")
    test.assertFalse(detail.menu:IsOpen())
    test.assertEqual(before, #world.calls)
    test.assertTrue(rows[3].box:IsChecked())
end)

test.test("roster page: ShowDetailTab opens the Rank tab, and a player without one stays on Characters", function()
    local world = setup()
    world.checklist = dueChecklist(true)
    world.page:Refresh()
    world.page:ShowDetailTab("rank")
    test.assertEqual("rank", world.page.detail.tabs:Selected())

    world.checklist = nil
    world.page:Refresh()
    test.assertEqual("characters", world.page.detail.tabs:Selected())
    world.page:ShowDetailTab("rank")
    test.assertEqual("characters", world.page.detail.tabs:Selected())
end)

test.test("roster page: ShowDetailTab from the Departed tab goes back to Members first", function()
    local world = setup()
    world.officer = true
    world.checklist = dueChecklist(true)
    world.page:Refresh()
    click(world.page.tabs.tabs[2])
    test.assertFalse(world.page.membersBody.shown)

    world.page:ShowDetailTab("rank")
    test.assertEqual("members", world.page.tabs:Selected())
    test.assertTrue(world.page.membersBody.shown)
    test.assertEqual("rank", world.page.detail.tabs:Selected())
end)

test.test("roster page: opening a player the search hides clears the search, so their card shows", function()
    local world = setup(3, 1)
    local box = world.page.search.box
    box:SetText("player002")
    box.scripts.OnTextChanged(box, true)

    world.page:Refresh(3)
    test.assertEqual("", world.filters.search)
    test.assertEqual("", world.page.search:GetValue())
    test.assertEqual(3, #shownCards(world))
    test.assertEqual(3, world.page:Selected())
end)

test.test("roster page: opening a player the search shows keeps the search", function()
    local world = setup(3, 1)
    local box = world.page.search.box
    box:SetText("player002")
    box.scripts.OnTextChanged(box, true)

    world.page:Refresh(2)
    test.assertEqual("player002", world.filters.search)
    test.assertEqual(1, #shownCards(world))
end)

test.test("roster page: an update keeps Departed's count current from the Members tab", function()
    local world = setup(3, 1)
    world.officer = true
    world.gone = departedRows()
    world.page:Refresh()
    test.assertEqual("Departed · 2", world.page.tabs.tabs[2].label.text)

    table.remove(world.gone, 1)
    world.page:Update()
    test.assertEqual("members", world.page.tabs:Selected())
    test.assertEqual("Departed · 1", world.page.tabs.tabs[2].label.text)
end)

test.test("roster page: an officer demoted during an update loses the tabs and Review", function()
    local world = setup(3, 1)
    world.officer = true
    world.page:Refresh()
    click(world.page.tabs.tabs[3])
    test.assertTrue(world.page.reviewBody.shown)

    world.officer = false
    world.page:Update()
    test.assertFalse(world.page.tabs.shown)
    test.assertFalse(world.page.reviewBody.shown)
    test.assertTrue(world.page.membersBody.shown)
end)
