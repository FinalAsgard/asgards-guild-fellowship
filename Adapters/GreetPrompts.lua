local _, addon = ...

-- Guild Greet's prompts: small boxes stacked down the left side of the
-- screen (the right side holds the quest log), oldest on top, each with just
-- the player's name, a Greet button, and a close button. Frames are made on first use and
-- reused. Like the other adapters, a failing frame call hides the prompts
-- rather than raising an error.
local GreetPrompts = {
    WIDTH = 250,
    HEIGHT = 40,
    GAP = 8,
    PADDING = 14,
    BUTTON_WIDTH = 72,
    BUTTON_HEIGHT = 24,
    CLOSE_SIZE = 24,
    -- The top prompt's place, relative to the screen's left edge.
    LEFT = 40,
    TOP = 120,
}
addon.GreetPrompts = GreetPrompts

local Prompts = {}
Prompts.__index = Prompts

function GreetPrompts.Create(client)
    return setmetatable({
        environment = client.environment,
        rows = {},
    }, Prompts)
end

function Prompts:row(index)
    if self.rows[index] ~= nil then
        return self.rows[index]
    end
    local createFrame = self.environment.CreateFrame
    local parent = self.environment.UIParent
    local frame = createFrame("Frame", nil, parent)
    frame:SetWidth(GreetPrompts.WIDTH)
    frame:SetHeight(GreetPrompts.HEIGHT)
    frame:SetPoint("LEFT", parent, "LEFT", GreetPrompts.LEFT,
        GreetPrompts.TOP - (index - 1) * (GreetPrompts.HEIGHT + GreetPrompts.GAP))
    if type(frame.SetFrameStrata) == "function" then
        frame:SetFrameStrata("MEDIUM")
    end
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0, 0, 0, 0.7)

    local row = { frame = frame }
    -- Close sits at the far right, Greet just left of it, and the name fills
    -- the rest, centered vertically with room on every side.
    row.close = createFrame("Button", nil, frame, "UIPanelCloseButton")
    row.close:SetWidth(GreetPrompts.CLOSE_SIZE)
    row.close:SetHeight(GreetPrompts.CLOSE_SIZE)
    row.close:SetPoint("RIGHT", frame, "RIGHT", -6, 0)

    row.greet = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    row.greet:SetWidth(GreetPrompts.BUTTON_WIDTH)
    row.greet:SetHeight(GreetPrompts.BUTTON_HEIGHT)
    row.greet:SetPoint("RIGHT", row.close, "LEFT", -6, 0)
    row.greet:SetText("Greet")

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
function Prompts:Show(prompts, handlers)
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
            row.frame:Show()
        end
        for index = #prompts + 1, #self.rows do
            self.rows[index].player = nil
            self.rows[index].frame:Hide()
        end
    end)
    return ok
end
