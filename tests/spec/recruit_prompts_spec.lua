local test = require("tests.test_helper")

-- A stand-in for the game's frames, just enough to see where the Guild
-- Recruit window is placed and dragged: each frame records its last point,
-- its scripts and whether it's movable; every other method does nothing.
-- The screen is 1000 high with its top-left at (0, 1000).
local function newScreen()
    local screen = {}
    local function newFrame(parent)
        local frame = { parent = parent, shown = true, scripts = {} }
        function frame:SetPoint(point, relativeTo, relativePoint, x, y)
            self.point = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
        end
        function frame:ClearAllPoints() self.point = nil end
        function frame:SetScript(name, handler) self.scripts[name] = handler end
        function frame:Show() self.shown = true end
        function frame:Hide() self.shown = false end
        function frame:GetLeft() return self.left end
        function frame:GetTop() return self.top end
        function frame:GetHeight() return self.height end
        function frame:SetMovable(movable) self.movable = movable end
        function frame:RegisterForDrag(button) self.dragButton = button end
        function frame:StartMoving() self.moving = true end
        function frame:StopMovingOrSizing() self.moving = false end
        function frame:CreateTexture() return newFrame(frame) end
        function frame:CreateFontString() return newFrame(frame) end
        return setmetatable(frame, {
            __index = function()
                return function() end
            end,
        })
    end
    screen.UIParent = newFrame(nil)
    screen.UIParent.top = 1000
    screen.UIParent.height = 1000
    screen.CreateFrame = function(_, _, parent)
        return newFrame(parent)
    end
    return screen
end

local function newPrompts(saved)
    local addon = test.newAddon("Adapters/RecruitPrompts.lua")
    local screen = newScreen()
    local world = { saved = saved, screen = screen, saves = 0 }
    world.prompts = addon.RecruitPrompts.Create({ environment = screen }, {
        loadAnchor = function()
            return world.saved
        end,
        saveAnchor = function(anchor)
            world.saves = world.saves + 1
            world.saved = anchor
        end,
    })
    return world
end

local PROMPT = { { key = "trade", text = "Advertise in Trade?" } }

test.test("recruit prompts: without a saved place the window sits centered a way down the screen", function()
    local world = newPrompts(nil)

    world.prompts:Show(PROMPT, {})

    local point = world.prompts.frame.point
    test.assertEqual("TOP", point.point)
    test.assertEqual(0, point.x)
    test.assertEqual(-280, point.y)
end)

test.test("recruit prompts: the window opens where it was last dropped", function()
    local world = newPrompts({ point = "TOPLEFT", x = 600, y = -200 })

    world.prompts:Show(PROMPT, {})

    local point = world.prompts.frame.point
    test.assertEqual("TOPLEFT", point.point)
    test.assertEqual(world.screen.UIParent, point.relativeTo)
    test.assertEqual(600, point.x)
    test.assertEqual(-200, point.y)
end)

test.test("recruit prompts: the window can always be dragged, and dropping it saves the place", function()
    local world = newPrompts(nil)
    world.prompts:Show(PROMPT, {})
    local frame = world.prompts.frame

    -- No unlocking: it's movable and answers a left-button drag at once.
    test.assertTrue(frame.movable)
    test.assertEqual("LeftButton", frame.dragButton)

    frame.scripts.OnDragStart()
    test.assertTrue(frame.moving)
    -- Dropped so its top-left sits at (300, 700) on screen.
    frame.left, frame.top = 300, 700
    frame.scripts.OnDragStop()

    test.assertFalse(frame.moving)
    test.assertEqual(1, world.saves)
    test.assertEqual("TOPLEFT", world.saved.point)
    test.assertEqual(300, world.saved.x)
    test.assertEqual(-300, world.saved.y)
    -- It's pinned there by its top-left corner, so it grows downward.
    test.assertEqual("TOPLEFT", frame.point.point)
    test.assertEqual(-300, frame.point.y)
end)

test.test("recruit prompts: a saved place that can't be read falls back to the default", function()
    local world = newPrompts(nil)
    world.prompts.loadAnchor = function()
        error("saved data exploded")
    end

    world.prompts:Show(PROMPT, {})

    test.assertEqual("TOP", world.prompts.frame.point.point)
end)

test.test("recruit window position: saved account-wide, and an unusable one counts as none", function()
    local addon = test.newAddon("Core/FellowshipStore.lua")
    local database = { schemaVersion = 2, guilds = {} }
    local store = addon.FellowshipStore.Create(database)

    test.assertEqual(nil, store:RecruitAnchor())
    test.assertTrue(store:SetRecruitAnchor({ point = "TOPLEFT", x = 300, y = -300 }))
    local anchor = addon.FellowshipStore.Create(database):RecruitAnchor()
    test.assertEqual("TOPLEFT", anchor.point)
    test.assertEqual(300, anchor.x)
    test.assertEqual(-300, anchor.y)

    database.recruit.anchor = { point = "SIDEWAYS", x = 1, y = 1 }
    test.assertEqual(nil, store:RecruitAnchor())
    test.assertFalse(store:SetRecruitAnchor({ point = "TOPLEFT", x = "1", y = 1 }))
    -- Placing the window again replaces the unusable value.
    test.assertTrue(store:SetRecruitAnchor({ point = "TOPLEFT", x = 40, y = -120 }))
    test.assertEqual(40, store:RecruitAnchor().x)

    database.recruit = "corrupt"
    test.assertFalse(store:SetRecruitAnchor({ point = "TOPLEFT", x = 40, y = -120 }))
    test.assertEqual("corrupt", database.recruit)
end)
