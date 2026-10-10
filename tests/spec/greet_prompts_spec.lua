local test = require("tests.test_helper")

-- A stand-in for the game's frames, just enough to see where prompts are
-- placed: each frame records its last point and its shown state, and the
-- screen is 1000 high with its top-left at (0, 1000).
local function newScreen()
    local screen = { frames = {} }
    local function newFrame(parent)
        local frame = { parent = parent, shown = true, scripts = {} }
        function frame:SetPoint(point, relativeTo, relativePoint, x, y)
            self.point = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
        end
        function frame:ClearAllPoints()
            self.point = nil
        end
        function frame:SetScript(name, handler)
            self.scripts[name] = handler
        end
        function frame:Show()
            self.shown = true
        end
        function frame:Hide()
            self.shown = false
        end
        function frame:GetLeft()
            return self.left
        end
        function frame:GetTop()
            return self.top
        end
        function frame:CreateTexture()
            return { SetAllPoints = function() end, SetColorTexture = function() end }
        end
        function frame:CreateFontString()
            return {
                SetPoint = function() end, SetText = function(fontString, text) fontString.text = text end,
                SetJustifyH = function() end, SetWordWrap = function() end,
            }
        end
        local name
        for _, name in ipairs({
            "SetWidth", "SetHeight", "SetMovable", "SetClampedToScreen", "SetFrameStrata",
            "EnableMouse", "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetText",
        }) do
            frame[name] = function() end
        end
        table.insert(screen.frames, frame)
        return frame
    end
    screen.UIParent = newFrame(nil)
    screen.UIParent.top = 1000
    screen.CreateFrame = function(_, _, parent)
        return newFrame(parent)
    end
    return screen
end

local function newPrompts(saved)
    local addon = test.newAddon("Adapters/GreetPrompts.lua")
    local screen = newScreen()
    local world = { saved = saved, screen = screen }
    world.prompts = addon.GreetPrompts.Create({ environment = screen }, {
        loadAnchor = function()
            return world.saved
        end,
        saveAnchor = function(anchor)
            world.saved = anchor
        end,
    })
    return world, addon
end

local function prompt(player)
    return { player = player, label = "Player " .. player }
end

test.test("greet prompts: without a saved place they stack from the left side of the screen", function()
    local world = newPrompts(nil)

    world.prompts:Show({ prompt(1), prompt(2) }, {})

    local anchor = world.prompts.anchor
    test.assertEqual("LEFT", anchor.point.point)
    test.assertEqual(40, anchor.point.x)
    test.assertEqual(120, anchor.point.y)
    -- Each prompt hangs from the anchor, one below the other.
    test.assertEqual(anchor, world.prompts.rows[1].frame.point.relativeTo)
    test.assertEqual(0, world.prompts.rows[1].frame.point.y)
    test.assertEqual(-48, world.prompts.rows[2].frame.point.y)
end)

test.test("greet prompts: they stack from a saved place", function()
    local world = newPrompts({ point = "TOPLEFT", x = 600, y = -200 })

    world.prompts:Show({ prompt(1) }, {})

    local point = world.prompts.anchor.point
    test.assertEqual("TOPLEFT", point.point)
    test.assertEqual(world.screen.UIParent, point.relativeTo)
    test.assertEqual(600, point.x)
    test.assertEqual(-200, point.y)
end)

test.test("greet prompts: unlocking shows the drag handle, dropping it saves the place, locking hides it", function()
    local world = newPrompts(nil)

    test.assertFalse(world.prompts:IsUnlocked())
    test.assertTrue(world.prompts:SetUnlocked(true))
    test.assertTrue(world.prompts:IsUnlocked())
    test.assertTrue(world.prompts.handle.shown)

    -- Dragged so the stack's top-left sits at (300, 700) on screen.
    world.prompts.handle.scripts.OnDragStart()
    world.prompts.anchor.left, world.prompts.anchor.top = 300, 700
    world.prompts.handle.scripts.OnDragStop()

    test.assertEqual("TOPLEFT", world.saved.point)
    test.assertEqual(300, world.saved.x)
    test.assertEqual(-300, world.saved.y)
    test.assertEqual(-300, world.prompts.anchor.point.y)

    test.assertTrue(world.prompts:SetUnlocked(false))
    test.assertFalse(world.prompts.handle.shown)
    test.assertFalse(world.prompts:IsUnlocked())
end)

test.test("greet prompts: a client that can't draw them refuses to unlock", function()
    local addon = test.newAddon("Adapters/GreetPrompts.lua")
    local prompts = addon.GreetPrompts.Create({ environment = {} })

    local ok, reason = prompts:SetUnlocked(true)

    test.assertEqual(nil, ok)
    test.assertContains(reason, "can't be drawn")
    test.assertFalse(prompts:IsUnlocked())
end)

test.test("greet prompt position: saved account-wide, and an unusable one counts as none", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 1, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertEqual(nil, store:GreetAnchor())
    test.assertTrue(store:SetGreetAnchor({ point = "TOPLEFT", x = 300, y = -300 }))
    local anchor = addon.FellowshipStore.Create(database):GreetAnchor()
    test.assertEqual("TOPLEFT", anchor.point)
    test.assertEqual(300, anchor.x)
    test.assertEqual(-300, anchor.y)

    local unusable = {
        "corrupt",
        { point = "SIDEWAYS", x = 1, y = 1 },
        { point = "TOPLEFT", x = "1", y = 1 },
        { point = "TOPLEFT", x = 0 / 0, y = 1 },
        { point = "TOPLEFT", x = 1, y = math.huge },
    }
    local index
    for index = 1, #unusable do
        database.greet.anchor = unusable[index]
        test.assertEqual(nil, store:GreetAnchor(), tostring(index))
        test.assertFalse(store:SetGreetAnchor(unusable[index]), tostring(index))
    end
    -- Placing the prompts again replaces the unusable value.
    test.assertTrue(store:SetGreetAnchor({ point = "LEFT", x = 40, y = 120 }))
    test.assertEqual("LEFT", store:GreetAnchor().point)

    database.greet = "corrupt"
    test.assertFalse(store:SetGreetAnchor({ point = "LEFT", x = 40, y = 120 }))
    test.assertEqual("corrupt", database.greet)
end)
