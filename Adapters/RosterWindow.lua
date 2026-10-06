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

local function createLine(scroll, index, onToggleGroup, onPurge)
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
    -- Departed characters can be purged one at a time.
    line.purge = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    line.purge:SetSize(52, 18)
    line.purge:SetPoint("RIGHT", line, "RIGHT", -4, 0)
    line.purge:SetText("Purge")
    line.purge:SetScript("OnClick", function()
        if line.row ~= nil and line.row.departed then
            onPurge(line.row.key)
        end
    end)
    line.purge:Hide()
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
        local text
        if row.standalone then
            text = row.coloredLabel
        else
            text = row.coloredName .. (row.isMain and "  |cff9d9d9d(main)|r" or "")
        end
        if row.departed then
            -- Grey and plain, so departed characters read as history.
            text = "|cff7f7f7f" .. (row.standalone and row.label or row.name) .. " (left)|r"
        end
        return text
    end
    if row.departed and field == "location" then
        return "|cff7f7f7f" .. tostring(row.location) .. "|r"
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

            if row.departed then
                line.purge:Show()
            else
                line.purge:Hide()
            end

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

-- The conflict review panel: one line per pending conflict, with Accept and
-- Reject (or Dismiss, when there's nothing to apply), plus Accept all and
-- Reject all.
local CONFLICT_COLUMNS = {
    { field = "name", header = "Character", x = 8, width = 140 },
    { field = "note", header = "Note (live)", x = 152, width = 170 },
    { field = "suggests", header = "Note suggests", x = 326, width = 170 },
    { field = "current", header = "Currently", x = 500, width = 150 },
    { field = "source", header = "Source", x = 654, width = 90 },
}
local CONFLICT_WIDTH = 900
local CONFLICT_HEIGHT = 360

local function createConflictLine(scroll, index, options)
    local line = CreateFrame("Frame", nil, scroll)
    line:SetHeight(RosterWindow.LINE_HEIGHT)
    line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
    line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
    line.background = line:CreateTexture(nil, "BACKGROUND")
    line.background:SetAllPoints(line)
    line.cells = {}
    local columnIndex
    for columnIndex = 1, #CONFLICT_COLUMNS do
        local column = CONFLICT_COLUMNS[columnIndex]
        local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("LEFT", line, "LEFT", column.x, 0)
        cell:SetWidth(column.width)
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(false)
        line.cells[column.field] = cell
    end
    line.accept = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    line.accept:SetSize(56, 18)
    line.accept:SetPoint("LEFT", line, "LEFT", 748, 0)
    line.accept:SetText("Accept")
    line.accept:SetScript("OnClick", function()
        if line.row ~= nil then
            options.onAcceptConflict(line.row.character, line.row.kind)
        end
    end)
    line.reject = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    line.reject:SetSize(56, 18)
    line.reject:SetPoint("LEFT", line.accept, "RIGHT", 4, 0)
    line.reject:SetScript("OnClick", function()
        if line.row ~= nil then
            options.onRejectConflict(line.row.character, line.row.kind)
        end
    end)
    return line
end

local function refreshConflictLines(scroll, rows, offset, totalLines)
    local lineIndex
    for lineIndex = 1, totalLines do
        local dataIndex = lineIndex + offset
        local row = rows[dataIndex]
        if row ~= nil then
            local line = scroll:GetLine(lineIndex)
            line.row = row
            local columnIndex
            for columnIndex = 1, #CONFLICT_COLUMNS do
                local field = CONFLICT_COLUMNS[columnIndex].field
                local value = row[field]
                if field == "note" and value == nil then
                    value = "|cff9d9d9d(not in the roster)|r"
                end
                line.cells[field]:SetText(value ~= nil and tostring(value) or "")
            end
            if row.canAccept then
                line.accept:Show()
                line.reject:SetText("Reject")
            else
                line.accept:Hide()
                line.reject:SetText("Dismiss")
            end
            if dataIndex % 2 == 0 then
                setBackground(line, STRIPE_BACKGROUND)
            else
                setBackground(line, NO_BACKGROUND)
            end
        end
    end
end

local function buildConflictPanel(framework, options, frameName)
    local panel = framework:CreateSimplePanel(
        UIParent,
        CONFLICT_WIDTH,
        CONFLICT_HEIGHT,
        addon.Identity.displayName .. " - Conflicts",
        frameName .. "Conflicts"
    )
    panel:SetFrameStrata("DIALOG")

    local explain = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    explain:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -30)
    explain:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -30)
    explain:SetJustifyH("LEFT")
    explain:SetText("Guild notes that disagree with the roster. Accepting applies the note's suggestion; " ..
        "rejecting keeps the roster and hides that suggestion until the note changes. Guild notes are never edited.")

    local headerIndex
    for headerIndex = 1, #CONFLICT_COLUMNS do
        local column = CONFLICT_COLUMNS[headerIndex]
        local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", panel, "TOPLEFT", 10 + column.x, -50)
        header:SetText(column.header)
    end

    local lineAmount = math.floor((CONFLICT_HEIGHT - 110) / RosterWindow.LINE_HEIGHT)
    local function newLine(scrollBox, index)
        return createConflictLine(scrollBox, index, options)
    end
    local scroll = framework:CreateScrollBox(
        panel,
        frameName .. "ConflictScroll",
        refreshConflictLines,
        {},
        CONFLICT_WIDTH - 20,
        CONFLICT_HEIGHT - 110,
        lineAmount,
        RosterWindow.LINE_HEIGHT,
        newLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -66)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 40)
    scroll:CreateLines(newLine, lineAmount)

    local acceptAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    acceptAll:SetSize(100, 22)
    acceptAll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
    acceptAll:SetText("Accept all")
    acceptAll:SetScript("OnClick", function()
        options.onAcceptAll()
    end)
    local rejectAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    rejectAll:SetSize(100, 22)
    rejectAll:SetPoint("LEFT", acceptAll, "RIGHT", 6, 0)
    rejectAll:SetText("Reject all")
    rejectAll:SetScript("OnClick", function()
        options.onRejectAll()
    end)
    local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    empty:SetPoint("CENTER", panel, "CENTER", 0, 0)
    empty:SetText("No conflicts. The roster and the guild notes agree.")

    panel:Hide()
    return { panel = panel, scroll = scroll, empty = empty, acceptAll = acceptAll, rejectAll = rejectAll }
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
        return createLine(scrollBox, index, options.onToggleGroup, options.onPurge)
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
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 40)
    scroll:CreateLines(newLine, lineAmount)

    -- Footer: a Rescan button and what the last scan found.
    local rescan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    rescan:SetSize(90, 22)
    rescan:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
    rescan:SetText("Rescan")
    rescan:SetScript("OnClick", function()
        options.onRescan()
    end)
    local conflictsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    conflictsButton:SetSize(110, 22)
    conflictsButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -36, 10)
    conflictsButton:SetText("Conflicts (0)")

    -- Departed characters are hidden unless this is checked.
    local departed = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    departed:SetSize(22, 22)
    departed:SetPoint("LEFT", rescan, "RIGHT", 8, 0)
    local departedLabel = departed:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    departedLabel:SetPoint("LEFT", departed, "RIGHT", 2, 0)
    departedLabel:SetText("Show departed")
    local purgeAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    purgeAll:SetSize(130, 22)
    purgeAll:SetPoint("LEFT", departedLabel, "RIGHT", 8, 0)
    purgeAll:SetText("Purge all departed")
    purgeAll:SetScript("OnClick", function()
        options.onPurgeAll()
    end)
    purgeAll:Hide()
    departed:SetScript("OnClick", function()
        if options.onToggleDeparted() then
            purgeAll:Show()
        else
            purgeAll:Hide()
        end
    end)

    local status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", purgeAll, "RIGHT", 10, 0)
    status:SetPoint("RIGHT", conflictsButton, "LEFT", -10, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)

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

    local conflicts = buildConflictPanel(framework, options, frameName)
    conflictsButton:SetScript("OnClick", function()
        if conflicts.panel:IsShown() then
            conflicts.panel:Hide()
        else
            conflicts.panel:Show()
        end
    end)
    conflicts.button = conflictsButton
    panel:HookScript("OnHide", function()
        conflicts.panel:Hide()
    end)

    return panel, scroll, status, conflicts
end

-- options.loadGeometry() returns saved geometry or nil;
-- options.saveGeometry(state) stores it;
-- options.onToggleGroup(playerId) runs when a player header is clicked;
-- options.onRescan() runs when the Rescan button is clicked;
-- options.onAcceptConflict(character, kind), onRejectConflict(character,
-- kind), onAcceptAll(), and onRejectAll() resolve conflicts;
-- options.onToggleDeparted() returns whether departed characters are now
-- shown, and options.onPurge(key) / onPurgeAll() purge them.
function RosterWindow.Create(client, options)
    local framework = frameworkFrom(client)
    if framework == nil then
        return nil, "the Details! Framework is not available"
    end

    local ok, panel, scroll, status, conflicts = pcall(build, framework, options)
    if not ok or panel == nil then
        return nil, "the Details! Framework could not build the window"
    end
    return setmetatable({ panel = panel, scroll = scroll, status = status, conflicts = conflicts }, Window)
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

-- Shows the pending conflicts and their count on the footer button.
function Window:SetConflicts(rows)
    return (pcall(function()
        local conflicts = self.conflicts
        conflicts.button:SetText("Conflicts (" .. #rows .. ")")
        conflicts.scroll:SetData(rows)
        conflicts.scroll:Refresh()
        if #rows == 0 then
            conflicts.empty:Show()
            conflicts.acceptAll:Disable()
            conflicts.rejectAll:Disable()
        else
            conflicts.empty:Hide()
            conflicts.acceptAll:Enable()
            conflicts.rejectAll:Enable()
        end
    end))
end

function Window:SetStatus(text)
    self.status:SetText(text or "")
end

-- Returns false instead of raising when the framework misbehaves.
function Window:SetRows(rows)
    return (pcall(function()
        self.scroll:SetData(rows)
        self.scroll:Refresh()
    end))
end
