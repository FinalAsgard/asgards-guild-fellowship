local _, addon = ...

-- The master frame: one window for the whole add-on, with its own picture
-- tabs down the right edge and a content area for each page. Built with the
-- Details! Framework panel the roster window used. It lives in Adapters/
-- because it uses game globals (CreateFrame, GameTooltip) and the framework
-- directly; it is not unit tested, and the in-game checklist covers it.
--
-- The tabs are drawn here rather than from a tab template, so they look and
-- work the same on WoW Forever and WoW Retail. Which page is showing is the
-- PageNavigator's job; this only draws it.
local MasterFrame = {
    DEFAULT_WIDTH = 760,
    DEFAULT_HEIGHT = 560,
    MIN_WIDTH = 560,
    MIN_HEIGHT = 360,
    TAB_SIZE = 40,
    TAB_GAP = 6,
    -- How far right of the frame a pop-out panel sits, clear of the tabs.
    SIDE_OFFSET = 48,
    -- Each tab's picture: stock game icons present on both clients, kept
    -- together so they're easy to swap after testing.
    ICONS = {
        roster = "Interface\\Icons\\INV_Misc_GroupNeedMore",
        settings = "Interface\\Icons\\INV_Misc_Gear_01",
    },
}
addon.MasterFrame = MasterFrame

local Host = {}
Host.__index = Host

local function setResizeBounds(frame)
    frame:SetResizable(true)
    if type(frame.SetResizeBounds) == "function" then
        frame:SetResizeBounds(MasterFrame.MIN_WIDTH, MasterFrame.MIN_HEIGHT)
    elseif type(frame.SetMinResize) == "function" then
        frame:SetMinResize(MasterFrame.MIN_WIDTH, MasterFrame.MIN_HEIGHT)
    end
end

local function restoreGeometry(frame, state, parent)
    if type(state) ~= "table" then
        return
    end
    if type(state.width) == "number" and type(state.height) == "number" then
        frame:SetSize(
            math.max(state.width, MasterFrame.MIN_WIDTH),
            math.max(state.height, MasterFrame.MIN_HEIGHT)
        )
    end
    if type(state.point) == "string" and type(state.relativePoint) == "string"
        and type(state.x) == "number" and type(state.y) == "number"
    then
        frame:ClearAllPoints()
        frame:SetPoint(state.point, parent, state.relativePoint, state.x, state.y)
    end
end

local function readGeometry(frame)
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    local width, height = frame:GetSize()
    return {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
        width = width,
        height = height,
    }
end

-- One picture tab: a dark square with the page's icon, a glow while its
-- page is showing, and the page's name on mouseover.
local function createTab(panel, index, onClick)
    local size = MasterFrame.TAB_SIZE
    local tab = CreateFrame("Button", nil, panel)
    tab:SetSize(size, size)
    tab:SetPoint("TOPLEFT", panel, "TOPRIGHT", 2, -28 - (index - 1) * (size + MasterFrame.TAB_GAP))
    tab.background = tab:CreateTexture(nil, "BACKGROUND")
    tab.background:SetAllPoints(tab)
    tab.background:SetColorTexture(0, 0, 0, 0.75)
    tab.icon = tab:CreateTexture(nil, "ARTWORK")
    tab.icon:SetPoint("TOPLEFT", tab, "TOPLEFT", 3, -3)
    tab.icon:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -3, 3)
    tab.selectedGlow = tab:CreateTexture(nil, "OVERLAY")
    tab.selectedGlow:SetAllPoints(tab)
    tab.selectedGlow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    tab.selectedGlow:SetBlendMode("ADD")
    tab.selectedGlow:Hide()
    tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    tab:SetScript("OnClick", function(self)
        onClick(self.pageId)
    end)
    tab:SetScript("OnEnter", function(self)
        if GameTooltip ~= nil then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.label or "")
            GameTooltip:Show()
        end
    end)
    tab:SetScript("OnLeave", function()
        if GameTooltip ~= nil then
            GameTooltip:Hide()
        end
    end)
    return tab
end

-- options:
--   navigator     the PageNavigator holding the pages and the current one
--   frameName     the global name for the panel
--   loadGeometry  function() -> saved geometry, or nil
--   saveGeometry  function(state)
-- Raises when the framework fails; the caller runs it in pcall.
function MasterFrame.Build(framework, options)
    local parent = UIParent
    -- The simple panel is movable, has a close button, and joins
    -- UISpecialFrames, so Escape closes it.
    local panel = framework:CreateSimplePanel(
        parent,
        MasterFrame.DEFAULT_WIDTH,
        MasterFrame.DEFAULT_HEIGHT,
        addon.Identity.displayName,
        options.frameName
    )
    panel:SetFrameStrata("HIGH")
    setResizeBounds(panel)
    restoreGeometry(panel, options.loadGeometry(), parent)

    local host = setmetatable({
        panel = panel,
        navigator = options.navigator,
        contents = {},
        tabs = {},
    }, Host)

    local pages = host.navigator:Tabs()
    local index
    for index = 1, #pages do
        local page = pages[index]
        local content = CreateFrame("Frame", nil, panel)
        content:SetAllPoints(panel)
        content:Hide()
        host.contents[page.id] = content
        local tab = createTab(panel, index, function(id)
            host:ShowPage(id)
        end)
        tab.pageId = page.id
        tab.label = page.label
        tab.icon:SetTexture(page.icon)
        host.tabs[index] = tab
    end

    local function save()
        options.saveGeometry(readGeometry(panel))
    end
    panel:HookScript("OnMouseUp", save)
    if type(framework.CreateResizeGrips) == "function" then
        local leftGrip, rightGrip = framework:CreateResizeGrips(panel)
        leftGrip:HookScript("OnMouseUp", save)
        rightGrip:HookScript("OnMouseUp", save)
    end
    panel:HookScript("OnHide", save)
    panel:Hide()
    host:ShowPage(host.navigator:Current())
    return host
end

-- The frame a page draws into: it covers the whole panel and shows only
-- while its tab is selected.
function Host:Content(id)
    return self.contents[id]
end

-- Selects the page `id` (an unknown id keeps the current page), then shows
-- only its content and marks only its tab as selected.
function Host:ShowPage(id)
    self.navigator:Select(id)
    local current = self.navigator:Current()
    local pageId, content
    for pageId, content in pairs(self.contents) do
        if pageId == current then
            content:Show()
        else
            content:Hide()
        end
    end
    local index
    for index = 1, #self.tabs do
        local tab = self.tabs[index]
        if tab.pageId == current then
            tab.selectedGlow:Show()
            tab.icon:SetAlpha(1)
        else
            tab.selectedGlow:Hide()
            tab.icon:SetAlpha(0.6)
        end
    end
end
