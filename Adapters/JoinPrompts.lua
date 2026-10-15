local _, addon = ...

-- Group Finder join requests, as the invitee sees them: one window, below
-- Guild Recruit's place, with a "Group Finder" heading and, stacked, one
-- block per request: who asks and for which dungeon with a Decline button,
-- then a button per option ("Healer — Hammer (24)"). An organizer's
-- prompts for guildmates offering to fill a slot stack in the same window,
-- with their own heading and Accept button. The frame is made on first use
-- and reused; a failing frame call hides the prompts rather than raising an
-- error, as in the other adapters.
local JoinPrompts = {
    WIDTH = 420,
    HEADER_HEIGHT = 30,
    ROW_HEIGHT = 26,
    PADDING = 12,
    EDGE = 2,
    BUTTON_HEIGHT = 22,
    DECLINE_WIDTH = 72,
    OPTION_WIDTH = 260,
    -- How far down the screen the window's top sits.
    DOWN_OFFSET = 360,
    STRATA = "DIALOG",
}
addon.JoinPrompts = JoinPrompts

local Prompts = {}
Prompts.__index = Prompts

function JoinPrompts.Create(client)
    return setmetatable({
        environment = client.environment,
        headers = {},
        options = {},
        prompts = {},
    }, Prompts)
end

function Prompts:window()
    if self.frame ~= nil then
        return self.frame
    end
    local frame = self.environment.CreateFrame("Frame", nil, self.environment.UIParent)
    frame:SetWidth(JoinPrompts.WIDTH)
    frame:SetHeight(JoinPrompts.HEADER_HEIGHT)
    frame:SetFrameStrata(JoinPrompts.STRATA)
    frame:SetClampedToScreen(true)
    frame:SetPoint("TOP", self.environment.UIParent, "TOP", 0, -JoinPrompts.DOWN_OFFSET)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)
    local edge = frame:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints(frame)
    edge:SetColorTexture(0.3, 0.75, 0.35, 0.95)
    local background = frame:CreateTexture(nil, "BORDER")
    background:SetPoint("TOPLEFT", frame, "TOPLEFT", JoinPrompts.EDGE, -JoinPrompts.EDGE)
    background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -JoinPrompts.EDGE, JoinPrompts.EDGE)
    background:SetColorTexture(0.04, 0.12, 0.05, 0.94)
    local heading = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOP", frame, "TOP", 0, -8)
    heading:SetText("Group Finder")
    self.frame = frame
    frame:Hide()
    return frame
end

-- A request's first row: who asks, for which dungeon, and Decline.
function Prompts:header(index)
    if self.headers[index] ~= nil then
        return self.headers[index]
    end
    local window = self:window()
    local frame = self.environment.CreateFrame("Frame", nil, window)
    frame:SetWidth(JoinPrompts.WIDTH)
    frame:SetHeight(JoinPrompts.ROW_HEIGHT)
    local row = { frame = frame }
    row.decline = self.environment.CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    row.decline:SetWidth(JoinPrompts.DECLINE_WIDTH)
    row.decline:SetHeight(JoinPrompts.BUTTON_HEIGHT)
    row.decline:SetPoint("RIGHT", frame, "RIGHT", -JoinPrompts.PADDING, 0)
    row.decline:SetText("Decline")
    row.decline:SetScript("OnClick", function()
        if row.id ~= nil and self.handlers ~= nil then
            self.handlers.decline(row.id)
        end
    end)
    row.text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.text:SetPoint("LEFT", frame, "LEFT", JoinPrompts.PADDING, 0)
    row.text:SetPoint("RIGHT", row.decline, "LEFT", -8, 0)
    row.text:SetJustifyH("LEFT")
    self.headers[index] = row
    return row
end

-- An option's button, made on first use.
function Prompts:option(index)
    if self.options[index] ~= nil then
        return self.options[index]
    end
    local button = self.environment.CreateFrame("Button", nil, self:window(), "UIPanelButtonTemplate")
    button:SetWidth(JoinPrompts.OPTION_WIDTH)
    button:SetHeight(JoinPrompts.BUTTON_HEIGHT)
    local option = { button = button }
    button:SetScript("OnClick", function()
        if option.id ~= nil and self.handlers ~= nil then
            self.handlers.accept(option.id, option.choice)
        end
    end)
    self.options[index] = option
    return option
end

-- "Toolbox asks you to join The Deadmines (17–26)", or the prompt's own
-- `heading` (an offer to the organizer).
function JoinPrompts.Heading(prompt)
    if prompt.heading ~= nil then
        return prompt.heading
    end
    local organizer = string.match(prompt.sender or "", "^([^%-]+)") or prompt.sender or "Someone"
    local dungeon = prompt.dungeon
    return organizer .. " asks you to join " .. dungeon.name .. " (" .. dungeon.minLevel .. "–" .. dungeon.maxLevel .. ")"
end

function Prompts:layout()
    if #self.prompts == 0 and self.frame == nil then
        return
    end
    local window = self:window()
    local top = JoinPrompts.HEADER_HEIGHT
    local optionCount = 0
    local index
    for index = 1, #self.prompts do
        local prompt = self.prompts[index]
        local header = self:header(index)
        header.id = prompt.id
        header.text:SetText(JoinPrompts.Heading(prompt))
        header.frame:ClearAllPoints()
        header.frame:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -top)
        header.frame:Show()
        top = top + JoinPrompts.ROW_HEIGHT
        local choice
        for choice = 1, #prompt.options do
            optionCount = optionCount + 1
            local option = self:option(optionCount)
            option.id = prompt.id
            option.choice = choice
            option.button:SetText(prompt.options[choice].label or addon.JoinRequests.OptionLabel(prompt.options[choice]))
            option.button:ClearAllPoints()
            option.button:SetPoint("TOPLEFT", window, "TOPLEFT", JoinPrompts.PADDING * 2, -top)
            option.button:Show()
            top = top + JoinPrompts.ROW_HEIGHT
        end
    end
    for index = #self.prompts + 1, #self.headers do
        self.headers[index].id = nil
        self.headers[index].frame:Hide()
    end
    for index = optionCount + 1, #self.options do
        self.options[index].id = nil
        self.options[index].button:Hide()
    end
    if #self.prompts == 0 then
        window:Hide()
    else
        window:SetHeight(top + JoinPrompts.PADDING / 2)
        window:Show()
    end
end

-- Draws `prompts` (JoinRequests:Pending()). `handlers.accept(id, choice)`
-- and `handlers.decline(id)` answer the buttons.
function Prompts:Show(prompts, handlers)
    if type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    self.handlers = handlers
    self.prompts = prompts or {}
    return (pcall(self.layout, self))
end
