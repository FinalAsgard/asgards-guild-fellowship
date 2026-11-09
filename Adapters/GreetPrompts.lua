local _, addon = ...

-- Guild Greet's prompts: small boxes stacked down from an anchor, oldest on
-- top, each with just the player's name, a button named for the kind of
-- greeting ("Welcome Back"), and a close button. Every greeting button is
-- as wide as the longest label needs, so they line up.
-- The anchor defaults to the left side of the screen (the right side holds
-- the quest log). Unlocking it shows a handle above the stack that drags it
-- anywhere; the new place is saved when the drag ends. Frames are made on
-- first use and reused. Like the other adapters, a failing frame call hides
-- the prompts rather than raising an error.
local GreetPrompts = {
    HEIGHT = 40,
    GAP = 8,
    PADDING = 14,
    -- Room for the player's name, between the padding and the button.
    NAME_WIDTH = 118,
    -- The greeting button's width when the client can't measure its labels.
    BUTTON_WIDTH = 170,
    -- Room on either side of the longest label.
    BUTTON_TEXT_PADDING = 24,
    BUTTON_HEIGHT = 24,
    CLOSE_SIZE = 24,
    HANDLE_HEIGHT = 22,
    -- The top prompt's default place, relative to the screen's left edge.
    DEFAULT_ANCHOR = { point = "LEFT", x = 40, y = 120 },
    -- The greeting button's label for each kind of prompt (GreetPolicy's
    -- categories), and for any other.
    LABELS = {
        join = "Welcome to the Guild",
        login = "Greet",
        welcomeBack = "Welcome Back",
        longAbsence = "Long Time No See!",
    },
    DEFAULT_LABEL = "Greet",
    -- The widest countdown a locked button adds to its label.
    WIDEST_COUNTDOWN = " (88)",
}
addon.GreetPrompts = GreetPrompts

-- The greeting button's label for a prompt in `category`, with the
-- countdown while Greet is locked for `lockedFor` seconds.
function GreetPrompts.Label(category, lockedFor)
    local label = GreetPrompts.LABELS[category] or GreetPrompts.DEFAULT_LABEL
    if type(lockedFor) == "number" and lockedFor > 0 then
        return label .. " (" .. lockedFor .. ")"
    end
    return label
end

local Prompts = {}
Prompts.__index = Prompts

-- `options.loadAnchor()` returns the saved position ({ point, x, y }) or
-- nil; `options.saveAnchor(anchor)` saves a new one.
function GreetPrompts.Create(client, options)
    options = options or {}
    return setmetatable({
        environment = client.environment,
        loadAnchor = options.loadAnchor or function() return nil end,
        saveAnchor = options.saveAnchor or function() end,
        rows = {},
        unlocked = false,
    }, Prompts)
end

-- Places the anchor at the saved position, else the default.
function Prompts:placeAnchor()
    local ok, saved = pcall(self.loadAnchor)
    local anchor = ok and type(saved) == "table" and saved or GreetPrompts.DEFAULT_ANCHOR
    local parent = self.environment.UIParent
    self.anchor:ClearAllPoints()
    if not pcall(self.anchor.SetPoint, self.anchor, anchor.point, parent, anchor.point, anchor.x, anchor.y) then
        anchor = GreetPrompts.DEFAULT_ANCHOR
        self.anchor:ClearAllPoints()
        self.anchor:SetPoint(anchor.point, parent, anchor.point, anchor.x, anchor.y)
    end
end

-- How wide every greeting button is: the longest label with a countdown,
-- as the button's font draws it, plus padding. BUTTON_WIDTH when the client
-- can't measure text.
function Prompts:measureButton(parent)
    local createFrame = self.environment.CreateFrame
    local width
    pcall(function()
        local button = createFrame("Button", nil, parent, "UIPanelButtonTemplate")
        local fontString = button:GetFontString()
        local _, label
        for _, label in pairs(GreetPrompts.LABELS) do
            button:SetText(label .. GreetPrompts.WIDEST_COUNTDOWN)
            local textWidth = fontString:GetStringWidth()
            if type(textWidth) == "number" and textWidth > 0 and (width == nil or textWidth > width) then
                width = textWidth
            end
        end
        button:Hide()
    end)
    if width == nil then
        return GreetPrompts.BUTTON_WIDTH
    end
    return math.ceil(width) + GreetPrompts.BUTTON_TEXT_PADDING
end

-- A prompt's width: padding, the name, the greeting button and Close.
function Prompts:width()
    return GreetPrompts.PADDING + GreetPrompts.NAME_WIDTH + 10 + self.buttonWidth + 6
        + GreetPrompts.CLOSE_SIZE + 6
end

-- The invisible frame the stack hangs from, with the drag handle above it.
function Prompts:anchorFrame()
    if self.anchor ~= nil then
        return self.anchor
    end
    local createFrame = self.environment.CreateFrame
    local parent = self.environment.UIParent
    local anchor = createFrame("Frame", nil, parent)
    self.buttonWidth = self:measureButton(anchor)
    anchor:SetWidth(self:width())
    anchor:SetHeight(GreetPrompts.HEIGHT)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    self.anchor = anchor
    self:placeAnchor()

    local handle = createFrame("Frame", nil, anchor)
    handle:SetWidth(self:width())
    handle:SetHeight(GreetPrompts.HANDLE_HEIGHT)
    handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
    handle:SetFrameStrata("HIGH")
    local background = handle:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(handle)
    background:SetColorTexture(0.83, 0.69, 0.22, 0.85)
    local label = handle:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("CENTER", handle, "CENTER", 0, 0)
    label:SetText("Guild Greet prompts: drag to move")
    handle:EnableMouse(true)
    handle:RegisterForDrag("LeftButton")
    handle:SetScript("OnDragStart", function()
        anchor:StartMoving()
    end)
    handle:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
        self:saveCurrent()
    end)
    handle:Hide()
    self.handle = handle
    return anchor
end

-- Saves where the anchor was dropped, as its top-left corner's offset from
-- the screen's top-left, and re-pins it there.
function Prompts:saveCurrent()
    pcall(function()
        local parent = self.environment.UIParent
        local left, top = self.anchor:GetLeft(), self.anchor:GetTop()
        local parentTop = parent:GetTop()
        if left == nil or top == nil or parentTop == nil then
            return
        end
        local position = { point = "TOPLEFT", x = left, y = top - parentTop }
        self.anchor:ClearAllPoints()
        self.anchor:SetPoint(position.point, parent, position.point, position.x, position.y)
        self.saveAnchor(position)
    end)
end

function Prompts:IsUnlocked()
    return self.unlocked
end

-- Shows (true) or hides (false) the drag handle. Returns true, or nil and the
-- reason when the client can't draw it.
function Prompts:SetUnlocked(unlocked)
    if type(self.environment.CreateFrame) ~= "function" then
        return nil, "the prompts can't be drawn on this client"
    end
    local ok = pcall(function()
        self:anchorFrame()
        if unlocked then
            self.handle:Show()
        else
            self.handle:Hide()
        end
    end)
    if not ok then
        return nil, "the prompts can't be drawn on this client"
    end
    self.unlocked = unlocked == true
    return true
end

function Prompts:row(index)
    if self.rows[index] ~= nil then
        return self.rows[index]
    end
    local createFrame = self.environment.CreateFrame
    local anchor = self:anchorFrame()
    local frame = createFrame("Frame", nil, anchor)
    frame:SetWidth(self:width())
    frame:SetHeight(GreetPrompts.HEIGHT)
    frame:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0,
        -(index - 1) * (GreetPrompts.HEIGHT + GreetPrompts.GAP))
    if type(frame.SetFrameStrata) == "function" then
        frame:SetFrameStrata("MEDIUM")
    end
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0, 0, 0, 0.7)

    local row = { frame = frame }
    -- Close sits at the far right, the greeting button just left of it, and
    -- the name fills the rest, centered vertically with room on every side.
    row.close = createFrame("Button", nil, frame, "UIPanelCloseButton")
    row.close:SetWidth(GreetPrompts.CLOSE_SIZE)
    row.close:SetHeight(GreetPrompts.CLOSE_SIZE)
    row.close:SetPoint("RIGHT", frame, "RIGHT", -6, 0)

    row.greet = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    row.greet:SetWidth(self.buttonWidth)
    row.greet:SetHeight(GreetPrompts.BUTTON_HEIGHT)
    row.greet:SetPoint("RIGHT", row.close, "LEFT", -6, 0)
    row.greet:SetText(GreetPrompts.DEFAULT_LABEL)

    row.name = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    row.name:SetPoint("LEFT", frame, "LEFT", GreetPrompts.PADDING, 0)
    row.name:SetPoint("RIGHT", row.greet, "LEFT", -10, 0)
    row.name:SetJustifyH("LEFT")
    if type(row.name.SetWordWrap) == "function" then
        row.name:SetWordWrap(false)
    end

    row.greet:SetScript("OnClick", function()
        if row.player ~= nil and self.handlers ~= nil then
            self.handlers.greet(row.player)
        end
    end)

    row.close:SetScript("OnClick", function()
        if row.player ~= nil and self.handlers ~= nil then
            self.handlers.close(row.player)
        end
    end)

    self.rows[index] = row
    return row
end

-- Draws `prompts` (from GreetPromptQueue:Visible), hiding unused boxes.
-- `handlers.greet(player)` and `handlers.close(player)` answer the buttons.
-- Each greeting button is named for its prompt's category. While
-- `lockedFor` (whole seconds) is above 0, each is disabled and counts down,
-- as "Welcome Back (3)".
function Prompts:Show(prompts, handlers, lockedFor)
    if type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    self.handlers = handlers
    local ok = pcall(function()
        local index
        for index = 1, #prompts do
            local prompt = prompts[index]
            local row = self:row(index)
            row.player = prompt.player
            row.name:SetText(prompt.label or "")
            local locked = type(lockedFor) == "number" and lockedFor > 0
            row.greet:SetText(GreetPrompts.Label(prompt.category, lockedFor))
            if type(row.greet.SetEnabled) == "function" then
                row.greet:SetEnabled(not locked)
            end
            row.frame:Show()
        end
        for index = #prompts + 1, #self.rows do
            self.rows[index].player = nil
            self.rows[index].frame:Hide()
        end
    end)
    return ok
end
