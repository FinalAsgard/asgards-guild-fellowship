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
    DEFAULT_WIDTH = 640,
    DEFAULT_HEIGHT = 440,
    MIN_WIDTH = 480,
    MIN_HEIGHT = 240,
    LINE_HEIGHT = 22,
    -- How far an alt's name sits in from its player's header.
    INDENT = 18,
}
addon.RosterWindow = RosterWindow

local Window = {}
Window.__index = Window

-- Column layout: x offset and width of each text column in a line.
local COLUMNS = {
    { field = "name", header = "Name", x = 8, width = 240 },
    { field = "level", header = "Level", x = 254, width = 44 },
    { field = "rank", header = "Rank", x = 302, width = 120 },
    { field = "location", header = "Zone / Last online", x = 428, width = 180 },
}

-- Row backgrounds: a tint for player headers, and a faint stripe on every
-- other row so long lists stay easy to follow.
local HEADER_BACKGROUND = { 0.35, 0.27, 0.05, 0.35 }
local STRIPE_BACKGROUND = { 1, 1, 1, 0.04 }
local NO_BACKGROUND = { 0, 0, 0, 0 }

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

local function createLine(scroll, index, onToggleGroup)
    local line = CreateFrame("Button", nil, scroll)
    -- Clicking a player header collapses or expands its group.
    line:SetScript("OnClick", function(self)
        if self.row ~= nil and self.row.kind == "player" then
            onToggleGroup(self.row.id)
        end
    end)
    line:SetHeight(RosterWindow.LINE_HEIGHT)
    line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
    line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
    line.background = line:CreateTexture(nil, "BACKGROUND")
    line.background:SetAllPoints(line)
    line.cells = {}
    local columnIndex
    for columnIndex = 1, #COLUMNS do
        local column = COLUMNS[columnIndex]
        local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        cell:SetPoint("LEFT", line, "LEFT", column.x, 0)
        cell:SetWidth(column.width)
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(false)
        line.cells[column.field] = cell
    end
    return line
end

-- The text each column shows for a row. Headers show the player's label
-- with an expand/collapse marker and character count; a single-character
-- player's row shows its label; an alt's row shows its own name, and the
-- main is marked.
local function cellText(row, field)
    if row.kind == "player" then
        if field == "name" then
            local marker = row.collapsed and "+ " or "- "
            return "|cffffd100" .. marker .. row.label .. "|r  |cff9d9d9d" .. row.count .. " characters|r"
        end
        if field == "location" and row.online then
            return "|cff20ff20Online|r"
        end
        return ""
    end
    if field == "name" then
        if row.standalone then
            return row.coloredLabel
        end
        return row.coloredName .. (row.isMain and "  |cff9d9d9d(main)|r" or "")
    end
    local value = row[field]
    return value ~= nil and tostring(value) or ""
end

local function setBackground(line, color)
    line.background:SetColorTexture(color[1], color[2], color[3], color[4])
end

-- Draws only the visible slice of rows; the framework recycles line frames.
local function refreshLines(scroll, rows, offset, totalLines)
    local lineIndex
    for lineIndex = 1, totalLines do
        local dataIndex = lineIndex + offset
        local row = rows[dataIndex]
        if row ~= nil then
            local line = scroll:GetLine(lineIndex)
            line.row = row
            local columnIndex
            for columnIndex = 1, #COLUMNS do
                local column = COLUMNS[columnIndex]
                line.cells[column.field]:SetText(cellText(row, column.field))
            end

            -- Alts sit under their player's header.
            local nameCell = line.cells.name
            local indent = (row.kind == "character" and not row.standalone) and RosterWindow.INDENT or 0
            nameCell:ClearAllPoints()
            nameCell:SetPoint("LEFT", line, "LEFT", COLUMNS[1].x + indent, 0)
            nameCell:SetWidth(COLUMNS[1].width - indent)
            nameCell:SetFontObject(row.kind == "player" and "GameFontNormal" or "GameFontHighlight")

            if row.kind == "player" then
                setBackground(line, HEADER_BACKGROUND)
            elseif dataIndex % 2 == 0 then
                setBackground(line, STRIPE_BACKGROUND)
            else
                setBackground(line, NO_BACKGROUND)
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
    local function newLine(scrollBox, index)
        return createLine(scrollBox, index, options.onToggleGroup)
    end
    local scroll = framework:CreateScrollBox(
        panel,
        frameName .. "Scroll",
        refreshLines,
        {},
        RosterWindow.DEFAULT_WIDTH - 20,
        RosterWindow.DEFAULT_HEIGHT - 70,
        lineAmount,
        RosterWindow.LINE_HEIGHT,
        newLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -46)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 24)
    scroll:CreateLines(newLine, lineAmount)

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
-- options.saveGeometry(state) stores it;
-- options.onToggleGroup(playerId) runs when a player header is clicked.
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
