local _, addon = ...

-- Guild Greet's prompts: small boxes stacked down from the right side of the
-- screen, oldest on top, each with the player's name, the kind of greeting,
-- a Greet button, and a close button. Frames are made on first use and
-- reused. Like the other adapters, a failing frame call hides the prompts
-- rather than raising an error.
local GreetPrompts = {
    WIDTH = 230,
    HEIGHT = 50,
    GAP = 6,
    -- The top prompt's place, relative to the screen's right edge.
    RIGHT = -40,
    TOP = 120,
    LABELS = {
        join = "New member",
        login = "Login",
        welcomeBack = "Welcome back",
        longAbsence = "Long time no see",
    },
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
    frame:SetPoint("RIGHT", parent, "RIGHT", GreetPrompts.RIGHT,
        GreetPrompts.TOP - (index - 1) * (GreetPrompts.HEIGHT + GreetPrompts.GAP))
    if type(frame.SetFrameStrata) == "function" then
        frame:SetFrameStrata("MEDIUM")
    end
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0, 0, 0, 0.7)

    local row = { frame = frame }
    row.name = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -9)
    row.name:SetWidth(GreetPrompts.WIDTH - 100)
    row.name:SetJustifyH("LEFT")
    row.category = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.category:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)

    row.greet = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    row.greet:SetWidth(64)
    row.greet:SetHeight(22)
    row.greet:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
    row.greet:SetText("Greet")
    row.greet:SetScript("OnClick", function()
        if row.player ~= nil and self.handlers ~= nil then
            self.handlers.greet(row.player)
        end
    end)

    row.close = createFrame("Button", nil, frame, "UIPanelCloseButton")
    row.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
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
            row.category:SetText(GreetPrompts.LABELS[prompt.category] or "")
            row.frame:Show()
        end
        for index = #prompts + 1, #self.rows do
            self.rows[index].player = nil
            self.rows[index].frame:Hide()
        end
    end)
    return ok
end
