local test = require("tests.test_helper")
local fakeFrames = require("tests.fake_frames")

-- LfgProtocol: Ask to join and its answer ---------------------------------------------

test.test("lfg protocol: Ask to join and its answers are understood; bad fields are ignored", function()
    local addon = test.newAddon("Core/LfgProtocol.lua")
    local protocol = addon.LfgProtocol
    test.assertTrue(protocol.IsValid(protocol.Ask("healer", 60, "PALADIN")))
    -- Raids and questing ask with no role.
    test.assertTrue(protocol.IsValid(protocol.Ask(nil, 24, nil)))
    test.assertFalse(protocol.IsValid(protocol.Ask("bard", 60, "PALADIN")))
    test.assertFalse(protocol.IsValid(protocol.Ask("healer", nil, "PALADIN")))
    test.assertFalse(protocol.IsValid(protocol.Ask("healer", 0, "PALADIN")))
    test.assertFalse(protocol.IsValid(protocol.Ask("healer", 60, 7)))

    local answer
    for answer in pairs({ invited = true, declined = true, expired = true, roleFilled = true }) do
        test.assertTrue(protocol.IsValid(protocol.Answer(answer)))
    end
    test.assertFalse(protocol.IsValid(protocol.Answer("maybe")))
    test.assertFalse(protocol.IsValid(protocol.Answer(nil)))
end)

-- LfgBoard: outgoing requests ------------------------------------------------------

local function newBoard()
    local addon = test.newAddon("Core/LfgProtocol.lua", "Core/LfgRelevance.lua", "Core/LfgBoard.lua")
    return addon.LfgBoard.Create(), addon.LfgBoard
end

test.test("lfg board: an Ask to join is pending until answered, then accepted or declined", function()
    local board, LfgBoard = newBoard()
    test.assertEqual(nil, board:Request("tool", 0))
    board:Ask("tool", "healer", 0)
    local request = board:Request("tool", 10)
    test.assertEqual(LfgBoard.PENDING, request.state)
    test.assertEqual("healer", request.role)

    test.assertTrue(board:OnAnswer("tool", "invited"))
    test.assertEqual(LfgBoard.ACCEPTED, board:Request("tool", 20).state)
    -- Only a pending request changes.
    test.assertFalse(board:OnAnswer("tool", "declined"))
    test.assertEqual(LfgBoard.ACCEPTED, board:Request("tool", 20).state)

    board:Ask("zap", nil, 0)
    test.assertTrue(board:OnAnswer("zap", "declined"))
    test.assertEqual(LfgBoard.DECLINED, board:Request("zap", 0).state)
    board:Ask("hammer", "dps", 0)
    board:OnAnswer("hammer", "roleFilled")
    test.assertEqual(LfgBoard.DECLINED, board:Request("hammer", 0).state)
    test.assertTrue(board:Request("hammer", 0).roleFilled)

    -- An answer from someone never asked changes nothing.
    test.assertFalse(board:OnAnswer("nobody", "invited"))
    test.assertFalse(board:OnAnswer("hammer", "bogus"))
end)

test.test("lfg board: an unanswered Ask to join expires, and can be asked again", function()
    local board, LfgBoard = newBoard()
    board:Ask("tool", nil, 100)
    test.assertEqual(LfgBoard.PENDING, board:Request("tool", 100 + LfgBoard.REQUEST_SECONDS - 1).state)
    test.assertEqual(LfgBoard.EXPIRED, board:Request("tool", 100 + LfgBoard.REQUEST_SECONDS).state)

    board:Ask("tool", nil, 500)
    board:OnAnswer("tool", "expired")
    test.assertEqual(LfgBoard.EXPIRED, board:Request("tool", 500).state)
end)

test.test("lfg board: the Ask to join button reads each request's state", function()
    local _, LfgBoard = newBoard()
    local function button(request)
        local label, active = LfgBoard.AskButton(request)
        return label .. "|" .. tostring(active)
    end
    test.assertEqual("Ask to join|true", button(nil))
    test.assertEqual("Asked \194\183 pending|false", button({ state = LfgBoard.PENDING }))
    test.assertEqual("Invited|false", button({ state = LfgBoard.ACCEPTED }))
    test.assertEqual("Declined|false", button({ state = LfgBoard.DECLINED }))
    test.assertEqual("Declined \194\183 role filled|false", button({ state = LfgBoard.DECLINED, roleFilled = true }))
    test.assertEqual("Expired \194\183 ask again|true", button({ state = LfgBoard.EXPIRED }))
end)

-- LfgRequests and the listing --------------------------------------------------------

test.test("lfg requests: requests stack in order; asking again replaces the last", function()
    local addon = test.newAddon("Core/LfgRequests.lua")
    local requests = addon.LfgRequests.Create()
    test.assertTrue(requests:Add({ key = "hammer", name = "Hammer", level = 24, role = "healer" }))
    test.assertTrue(requests:Add({ key = "zap", name = "Zap", level = 25 }))
    test.assertFalse(requests:Add({ key = "hammer", name = "Hammer", level = 24, role = "dps" }))
    local list = requests:List()
    test.assertEqual(2, #list)
    test.assertEqual("dps", list[1].role)
    test.assertEqual("zap", list[2].key)

    test.assertEqual("hammer", requests:Remove("hammer").key)
    test.assertEqual(nil, requests:Remove("hammer"))
    test.assertEqual(nil, requests:Get("hammer"))
    requests:Clear()
    test.assertEqual(0, #requests:List())
end)

test.test("lfg listing: Ask to join is accepted unless the button is hidden or the player is the contact", function()
    local addon = test.newAddon("Core/LfgProtocol.lua", "Core/LfgListing.lua")
    local listing = addon.LfgListing.Create()
    listing:Start({ kind = "raid" }, nil, 0)
    local solo = { { name = "Tool", isPlayer = true } }
    test.assertTrue(listing:Announcement(solo).aj)
    test.assertTrue(listing:Announcement(solo, true).aj)
    test.assertFalse(listing:Announcement(solo, false).aj)
    test.assertFalse(listing:Announcement({ { name = "Stranger", isPlayer = false },
        { name = "Tool", isPlayer = true } }, true).aj)
end)

-- The drawer: Ask to join, Whisper and the request toasts ----------------------------

local function newButton()
    local addon = test.newAddon("Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/LfgButton.lua",
        "Core/LfgProtocol.lua", "Core/LfgListing.lua", "Core/LfgRelevance.lua", "Core/LfgBoard.lua",
        "Core/LfgDrawerModel.lua")
    local environment = fakeFrames.install({})
    local state = { asked = {}, whispered = {}, invited = {}, declined = {}, roles = { "healer", "dps" } }
    local button = addon.LfgButton.Create({ environment = environment }, {
        frameName = "AgfTestLfgButton",
        shown = function() return true end,
        onOpenBoard = function() end,
        onHide = function() end,
        onDrawerOpened = function() end,
        onStartGroup = function() end,
        askRoles = function() return state.roles end,
        onAsk = function(listing, role) table.insert(state.asked, listing.id .. ":" .. tostring(role)) end,
        onWhisper = function(name) table.insert(state.whispered, name) end,
        onInvite = function(request) table.insert(state.invited, request.key) end,
        onDecline = function(request) table.insert(state.declined, request.key) end,
        classColor = function(token) return token == "PALADIN" and "fff58cba" or nil end,
        dungeonIcon = function() return nil end,
    })
    button:Refresh()
    return button, state, addon
end

local function click(button)
    button.scripts.OnClick(button, "LeftButton")
end

local DUNGEON = {
    id = "tool", kind = "dungeon", purpose = "Stratholme", leader = "Tool", sender = "Tool-Camelot", size = 1,
    maxSize = 5, openRoles = { "healer", "dps" }, acceptsAsk = true,
}

test.test("lfg button: Ask to join picks a role for a dungeon; Whisper when the leader takes no asks", function()
    local button, state = newButton()
    button:OpenDrawer()
    button:Update({ count = 1, fresh = {}, top = { kind = "newest", listing = DUNGEON } })
    test.assertEqual("Ask to join", button.askButton.label.text)

    -- Two roles the character could fill: a menu picks one.
    click(button.askButton)
    test.assertTrue(button.menu:IsOpen())
    test.assertEqual("Ask as Healer", button.menu.rows[1].label.text)
    test.assertEqual("Ask as DPS", button.menu.rows[2].label.text)
    click(button.menu.rows[1])
    test.assertEqual("tool:healer", state.asked[1])

    -- One: asked at once.
    state.roles = { "dps" }
    click(button.askButton)
    test.assertEqual("tool:dps", state.asked[2])

    -- A raid carries no role.
    local raid = { id = "zap", kind = "raid", purpose = nil, leader = "Zap", sender = "Zap", size = 9, maxSize = 40,
        acceptsAsk = true }
    button:Update({ count = 1, fresh = {}, top = { kind = "newest", listing = raid } })
    click(button.askButton)
    test.assertEqual("zap:nil", state.asked[3])

    -- Pending: the button says so and can't be clicked.
    button:Update({ count = 1, fresh = {}, top = { kind = "newest", listing = DUNGEON,
        request = { state = "pending" } } })
    test.assertEqual("Asked \194\183 pending", button.askButton.label.text)
    test.assertFalse(button.askButton.active)

    -- No asks taken: Whisper <leader>.
    local whisperOnly = {}
    local name, value
    for name, value in pairs(DUNGEON) do
        whisperOnly[name] = value
    end
    whisperOnly.acceptsAsk = false
    button:Update({ count = 1, fresh = {}, top = { kind = "newest", listing = whisperOnly } })
    test.assertEqual("Whisper Tool", button.askButton.label.text)
    click(button.askButton)
    test.assertEqual("Tool-Camelot", state.whispered[1])
    test.assertEqual(3, #state.asked)
end)

test.test("lfg button: requests stack under the open drawer with Invite and Decline", function()
    local button, state = newButton()
    local requests = {
        { key = "hammer", name = "Hammer", sender = "Hammer", classToken = "PALADIN", level = 24, role = "healer" },
        { key = "zap", name = "Zap", sender = "Zap", classToken = "MAGE", level = 25 },
    }
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = { size = 2, maxSize = 5 } },
        requests = requests })
    -- Closed: nothing shows.
    test.assertEqual(0, #button.toasts)

    button:OpenDrawer()
    test.assertEqual(2, #button.toasts)
    local first, second = button.toasts[1], button.toasts[2]
    test.assertTrue(first.shown and second.shown)
    test.assertEqual("|cfff58cbaHammer|r", first.name.text)
    test.assertEqual("Healer, 24", first.details.text)
    test.assertEqual("Zap", second.name.text)
    test.assertEqual("Level 25, wants to join", second.details.text)

    click(first.invite)
    click(second.decline)
    test.assertEqual("hammer", state.invited[1])
    test.assertEqual("zap", state.declined[1])

    -- One answered: only the other stays.
    button:Update({ count = 0, fresh = {}, top = { kind = "party", party = { size = 2, maxSize = 5 } },
        requests = { requests[2] } })
    test.assertTrue(first.shown)
    test.assertFalse(second.shown)

    button:CloseDrawer()
    test.assertFalse(first.shown)
end)

test.test("lfg drawer model: passes the requests on, and the newest group's own request", function()
    local addon = test.newAddon("Core/LfgDrawerModel.lua")
    local model = addon.LfgDrawerModel.Create()
    local listing = { id = "tool", listedAt = 0 }
    local requests = { { key = "hammer" } }
    local view = model:Update({ groups = { relevant = { listing } }, requests = requests, requestOf = function(id)
        return id == "tool" and { state = "pending" } or nil
    end })
    test.assertEqual("pending", view.top.request.state)
    test.assertEqual(requests, view.requests)
    test.assertEqual(0, #model:Update({}).requests)
end)

test.test("lfg requests: unanswered ones expire after two minutes", function()
    local addon = test.newAddon("Core/LfgRequests.lua")
    local LfgRequests = addon.LfgRequests
    local requests = LfgRequests.Create()
    requests:Add({ key = "hammer" }, 100)
    requests:Add({ key = "zap" }, 150)
    test.assertEqual(0, #requests:Expire(100 + LfgRequests.EXPIRE_SECONDS - 1))
    local expired = requests:Expire(100 + LfgRequests.EXPIRE_SECONDS)
    test.assertEqual(1, #expired)
    test.assertEqual("hammer", expired[1].key)
    test.assertEqual("zap", requests:List()[1].key)
    test.assertEqual(0, #requests:Expire(nil))
end)

test.test("lfg requests: a filled role declines its requests, and a full party all of them", function()
    local addon = test.newAddon("Core/LfgRequests.lua")
    local requests = addon.LfgRequests.Create()
    requests:Add({ key = "hammer", role = "healer" }, 0)
    requests:Add({ key = "tool", role = "tank" }, 0)
    requests:Add({ key = "zap", role = "dps" }, 0)

    -- The healer slot is taken: only Hammer's ask goes.
    local filled = requests:Filled({ "tank", "dps" }, false)
    test.assertEqual(1, #filled)
    test.assertEqual("hammer", filled[1].key)
    test.assertEqual(2, #requests:List())

    -- Not a dungeon: no roles to fill, nothing goes until it's full.
    requests:Add({ key = "bolt" }, 0)
    test.assertEqual(0, #requests:Filled(nil, false))
    test.assertEqual(3, #requests:Filled(nil, true))
    test.assertEqual(0, #requests:List())
end)
