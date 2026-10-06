local _, addon = ...

-- The roster window, built with the Details! Framework. It lives in
-- Adapters/ because it uses game globals (CreateFrame, UIParent) and the
-- framework directly; Core never sees either. It is not unit tested; the
-- in-game checklist covers it.
--
-- Create() returns nil when the framework is missing or fails to build the
-- window (its behavior on WoW Forever is unconfirmed), so the caller can
-- print a message instead of raising Lua errors. The window is created once,
-- then hidden and shown; it is never destroyed.
local RosterWindow = {
    DEFAULT_WIDTH = 560,
    DEFAULT_HEIGHT = 420,
    MIN_WIDTH = 420,
    MIN_HEIGHT = 220,
    LINE_HEIGHT = 18,
}
addon.RosterWindow = RosterWindow

local Window = {}
Window.__index = Window

-- Column layout: x offset and width of each text column in a line.
local COLUMNS = {
    { field = "coloredName", header = "Name", x = 6, width = 170 },
    { field = "level", header = "Level", x = 180, width = 40 },
    { field = "rank", header = "Rank", x = 226, width = 110 },
    { field = "location", header = "Zone / Last online", x = 342, width = 190 },
}

local function frameworkFrom(client)
    local framework = client:GetGlobal("DetailsFramework")
    if type(framework) ~= "table" or framework.FrameWorkVersion == nil
        or type(framework.CreateSimplePanel) ~= "function"
        or type(framework.CreateScrollBox) ~= "function"
    then
        return nil
    end
    return framework
end

local function createLine(scroll, index)
    local line = CreateFrame("Button", nil, scroll)
    line:SetHeight(RosterWindow.LINE_HEIGHT)
    line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
    line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
    line.cells = {}
    local columnIndex
    for columnIndex = 1, #COLUMNS do
        local column = COLUMNS[columnIndex]
        local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("LEFT", line, "LEFT", column.x, 0)
        cell:SetWidth(column.width)
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(false)
        line.cells[column.field] = cell
    end
    return line
end

-- Draws only the visible slice of rows; the framework recycles line frames.
local function refreshLines(scroll, rows, offset, totalLines)
    local lineIndex
    for lineIndex = 1, totalLines do
        local row = rows[lineIndex + offset]
        if row ~= nil then
            local line = scroll:GetLine(lineIndex)
            local columnIndex
            for columnIndex = 1, #COLUMNS do
                local field = COLUMNS[columnIndex].field
                local value = row[field]
                line.cells[field]:SetText(value ~= nil and tostring(value) or "")
            end
        end
    end
end

local function setResizeBounds(frame)
    frame:SetResizable(true)
    if type(frame.SetResizeBounds) == "function" then
        frame:SetResizeBounds(RosterWindow.MIN_WIDTH, RosterWindow.MIN_HEIGHT)
    elseif type(frame.SetMinResize) == "function" then
        frame:SetMinResize(RosterWindow.MIN_WIDTH, RosterWindow.MIN_HEIGHT)
    end
end

local function restoreGeometry(frame, state, parent)
    if type(state) ~= "table" then
        return
    end
    if type(state.width) == "number" and type(state.height) == "number" then
        frame:SetSize(
            math.max(state.width, RosterWindow.MIN_WIDTH),
            math.max(state.height, RosterWindow.MIN_HEIGHT)
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

local function build(framework, options)
    local parent = UIParent
    local frameName = addon.Identity.addonName .. "RosterWindow"
    -- The simple panel is movable, has a close button, and joins
    -- UISpecialFrames, so Escape closes it.
    local panel = framework:CreateSimplePanel(
        parent,
        RosterWindow.DEFAULT_WIDTH,
        RosterWindow.DEFAULT_HEIGHT,
        addon.Identity.displayName,
        frameName
    )
    panel:SetFrameStrata("HIGH")
    setResizeBounds(panel)
    restoreGeometry(panel, options.loadGeometry(), parent)

    local headerIndex
    for headerIndex = 1, #COLUMNS do
        local column = COLUMNS[headerIndex]
        local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", panel, "TOPLEFT", 10 + column.x, -30)
        header:SetText(column.header)
    end

    local lineAmount = math.floor((RosterWindow.DEFAULT_HEIGHT - 70) / RosterWindow.LINE_HEIGHT)
    local scroll = framework:CreateScrollBox(
        panel,
        frameName .. "Scroll",
        refreshLines,
        {},
        RosterWindow.DEFAULT_WIDTH - 20,
        RosterWindow.DEFAULT_HEIGHT - 70,
        lineAmount,
        RosterWindow.LINE_HEIGHT,
        createLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -46)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 24)
    scroll:CreateLines(createLine, lineAmount)

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

    return panel, scroll
end

-- options.loadGeometry() returns saved geometry or nil;
-- options.saveGeometry(state) stores it.
function RosterWindow.Create(client, options)
    local framework = frameworkFrom(client)
    if framework == nil then
        return nil, "the Details! Framework is not available"
    end

    local ok, panel, scroll = pcall(build, framework, options)
    if not ok or panel == nil then
        return nil, "the Details! Framework could not build the window"
    end
    return setmetatable({ panel = panel, scroll = scroll }, Window)
end

function Window:IsShown()
    return self.panel:IsShown() == true
end

function Window:Show()
    self.panel:Show()
end

function Window:Hide()
    self.panel:Hide()
end

function Window:SetTitle(title)
    if type(self.panel.SetTitle) == "function" then
        self.panel:SetTitle(title)
    elseif self.panel.Title ~= nil then
        self.panel.Title:SetText(title)
    end
end

-- Returns false instead of raising when the framework misbehaves.
function Window:SetRows(rows)
    return (pcall(function()
        self.scroll:SetData(rows)
        self.scroll:Refresh()
    end))
end
