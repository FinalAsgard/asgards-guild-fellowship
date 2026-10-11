local _, addon = ...

-- Guild Recruit's prompts: one window of its own, centered horizontally
-- about a quarter to a third of the way down the screen, well away from
-- Guild Greet's prompts on the left. It has a "Guild Recruit" heading over
-- a deep blue panel with a blue edge, so it's never mistaken for a greet
-- prompt, and one row per prompt with its question and a Post button. The
-- frame is made on first use and reused. Like the other adapters, a failing
-- frame call hides the prompts rather than raising an error.
local RecruitPrompts = {
    WIDTH = 340,
    HEADER_HEIGHT = 30,
    ROW_HEIGHT = 36,
    PADDING = 12,
    EDGE = 2,
    BUTTON_WIDTH = 72,
    BUTTON_HEIGHT = 24,
    -- How far down the screen the window's top sits, as a share of the
    -- screen's height, and the offset used when the height is unknown.
    DOWN_SHARE = 0.28,
    DEFAULT_OFFSET = 220,
}
addon.RecruitPrompts = RecruitPrompts

local Prompts = {}
Prompts.__index = Prompts

function RecruitPrompts.Create(client)
    return setmetatable({
        environment = client.environment,
        rows = {},
    }, Prompts)
end

-- How far below the screen's top edge the window sits.
function Prompts:offset()
    local parent = self.environment.UIParent
    local ok, height = pcall(function()
        return parent:GetHeight()
    end)
    if ok and type(height) == "number" and height > 0 then
        return math.floor(height * RecruitPrompts.DOWN_SHARE)
    end
    return RecruitPrompts.DEFAULT_OFFSET
end

-- The window, made on first use.
function Prompts:window()
    if self.frame ~= nil then
        return self.frame
    end
    local createFrame = self.environment.CreateFrame
    local parent = self.environment.UIParent
    local frame = createFrame("Frame", nil, parent)
    frame:SetWidth(RecruitPrompts.WIDTH)
    frame:SetHeight(RecruitPrompts.HEADER_HEIGHT + RecruitPrompts.ROW_HEIGHT)
    frame:SetPoint("TOP", parent, "TOP", 0, -self:offset())
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)

    local edge = frame:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints(frame)
    edge:SetColorTexture(0.25, 0.55, 0.95, 0.95)
    local background = frame:CreateTexture(nil, "BORDER")
    background:SetPoint("TOPLEFT", frame, "TOPLEFT", RecruitPrompts.EDGE, -RecruitPrompts.EDGE)
    background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -RecruitPrompts.EDGE, RecruitPrompts.EDGE)
    background:SetColorTexture(0.04, 0.08, 0.2, 0.94)

    local heading = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOP", frame, "TOP", 0, -8)
    heading:SetText("Guild Recruit")

    frame:Hide()
    self.frame = frame
    return frame
end

function Prompts:row(index)
    if self.rows[index] ~= nil then
        return self.rows[index]
    end
    local createFrame = self.environment.CreateFrame
    local window = self:window()
    local frame = createFrame("Frame", nil, window)
    frame:SetWidth(RecruitPrompts.WIDTH)
    frame:SetHeight(RecruitPrompts.ROW_HEIGHT)
    frame:SetPoint("TOPLEFT", window, "TOPLEFT", 0,
        -RecruitPrompts.HEADER_HEIGHT - (index - 1) * RecruitPrompts.ROW_HEIGHT)

    local row = { frame = frame }
    row.post = createFrame("Button", nil, frame, "UIPanelButtonTemplate")
    row.post:SetWidth(RecruitPrompts.BUTTON_WIDTH)
    row.post:SetHeight(RecruitPrompts.BUTTON_HEIGHT)
    row.post:SetPoint("RIGHT", frame, "RIGHT", -RecruitPrompts.PADDING, 0)
    row.post:SetText("Post")

    row.text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.text:SetPoint("LEFT", frame, "LEFT", RecruitPrompts.PADDING, 0)
    row.text:SetPoint("RIGHT", row.post, "LEFT", -10, 0)
    row.text:SetJustifyH("LEFT")
    if type(row.text.SetWordWrap) == "function" then
        row.text:SetWordWrap(false)
    end

    row.post:SetScript("OnClick", function()
        if row.key ~= nil and self.handlers ~= nil then
            self.handlers.post(row.key)
        end
    end)

    self.rows[index] = row
    return row
end

-- Draws `prompts` ({ key, text } each), hiding the window when there are
-- none. `handlers.post(key)` answers Post.
function Prompts:Show(prompts, handlers)
    if type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    self.handlers = handlers
    local ok = pcall(function()
        if #prompts == 0 and self.frame == nil then
            return
        end
        local window = self:window()
        local index
        for index = 1, #prompts do
            local row = self:row(index)
            row.key = prompts[index].key
            row.text:SetText(prompts[index].text or "")
            row.frame:Show()
        end
        for index = #prompts + 1, #self.rows do
            self.rows[index].key = nil
            self.rows[index].frame:Hide()
        end
        if #prompts == 0 then
            window:Hide()
        else
            window:SetHeight(RecruitPrompts.HEADER_HEIGHT + #prompts * RecruitPrompts.ROW_HEIGHT
                + RecruitPrompts.PADDING / 2)
            window:Show()
        end
    end)
    return ok
end
