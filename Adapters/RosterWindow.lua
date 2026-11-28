local _, addon = ...

-- The old master frame (My Profile, Recruitment, Recent ads, Guild Log and
-- Settings; the roster lives in the AGF window now), with the guild note
-- Conflicts button on its Settings page, built with the Details! Framework. It lives in Adapters/ because it uses game globals
-- (CreateFrame, UIParent) and the framework directly; Core never sees
-- either. It is not unit tested; the in-game checklist covers it.
--
-- Create() returns nil when the framework is missing or fails to build the
-- frame (its behavior on WoW Forever is unconfirmed), so the caller can
-- print a message instead of raising Lua errors. The frame is created once,
-- then hidden and shown; it is never destroyed.
local RosterWindow = {
    LINE_HEIGHT = 22,
    -- Room on the right of a page's list for its scroll bar, which the
    -- framework draws just outside the list.
    SCROLL_BAR_ROOM = 34,
}
addon.RosterWindow = RosterWindow

local Window = {}
Window.__index = Window

-- Row backgrounds: a faint stripe on every other row, so long lists stay
-- easy to follow.
local STRIPE_BACKGROUND = { 1, 1, 1, 0.04 }
local NO_BACKGROUND = { 0, 0, 0, 0 }

local function setBackground(line, color)
    line.background:SetColorTexture(color[1], color[2], color[3], color[4])
end

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

-- The conflict review panel, in three sections, each with its own columns.
-- Changes to Player: one line per player with suggestions, saying how many
-- and who suggested them, with Review (see the bundle review below). Note
-- conflicts: one line per conflict, its live note, what it suggests, and
-- the current state wrapped in one column, with Accept and Reject (or
-- Dismiss, when there's nothing to apply). A member's own suggestions
-- follow, waiting for an officer. Accept all and Reject all decide
-- everything. Each section's heading line names its columns.
local CONFLICT_DETAILS = {
    { field = "name", header = "Character", x = 8, width = 140 },
    { field = "details", header = "Note (live), suggests, and currently", x = 152, width = 340, wrap = true },
}
local CONFLICT_SECTIONS = {
    changes = {
        heading = "Changes to Player",
        columns = {
            { field = "name", header = "Player", x = 8, width = 170 },
            { field = "changes", header = "Changes", x = 182, width = 90 },
            { field = "suggestedBy", header = "Suggested by", x = 276, width = 216 },
        },
    },
    notes = { heading = "Note conflicts", columns = CONFLICT_DETAILS },
    yours = { heading = "Your suggestions", columns = CONFLICT_DETAILS },
}
local CONFLICT_ORDER = { "changes", "notes", "yours" }
-- Room for the wrapped column's three lines, and a fourth when one wraps.
local CONFLICT_LINE_HEIGHT = 44
local CONFLICT_BUTTONS_X = 498
local CONFLICT_WIDTH = 680
local CONFLICT_HEIGHT = 420
local CONFLICT_TOP = 62

local function createConflictLine(scroll, index, options)
    local line = CreateFrame("Frame", nil, scroll)
    line:SetHeight(CONFLICT_LINE_HEIGHT)
    line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * CONFLICT_LINE_HEIGHT)
    line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * CONFLICT_LINE_HEIGHT)
    line.background = line:CreateTexture(nil, "BACKGROUND")
    line.background:SetAllPoints(line)
    -- One set of cells per section, shown for that section's lines.
    line.cells = {}
    local sectionIndex
    for sectionIndex = 1, #CONFLICT_ORDER do
        local section = CONFLICT_ORDER[sectionIndex]
        local columns = CONFLICT_SECTIONS[section].columns
        line.cells[section] = {}
        local columnIndex
        for columnIndex = 1, #columns do
            local column = columns[columnIndex]
            local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell:SetPoint("LEFT", line, "LEFT", column.x, 0)
            cell:SetWidth(column.width)
            cell:SetJustifyH("LEFT")
            -- No fixed height on the wrapped column, so a long line wraps
            -- instead of being cut off.
            cell:SetWordWrap(column.wrap == true)
            cell:Hide()
            line.cells[section][column.field] = cell
        end
    end
    line.accept = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
    line.accept:SetSize(56, 18)
    line.accept:SetPoint("LEFT", line, "LEFT", CONFLICT_BUTTONS_X, 0)
    line.accept:SetText("Accept")
    line.accept:SetScript("OnClick", function()
        if line.row == nil then
            return
        end
        if line.row.kind == "bundle" then
            options.onReviewBundle(line.row.group)
        else
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
    line.waiting = line:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    line.waiting:SetPoint("LEFT", line, "LEFT", CONFLICT_BUTTONS_X, 0)
    line.waiting:SetText("Waiting for an officer")
    line.waiting:Hide()
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
            local sectionIndex
            for sectionIndex = 1, #CONFLICT_ORDER do
                local section = CONFLICT_ORDER[sectionIndex]
                local columns = CONFLICT_SECTIONS[section].columns
                local columnIndex
                for columnIndex = 1, #columns do
                    local column = columns[columnIndex]
                    local cell = line.cells[section][column.field]
                    if section ~= row.section then
                        cell:Hide()
                    elseif row.kind == "heading" then
                        -- The heading names the section over the first
                        -- column and the other columns over theirs.
                        local text = columnIndex == 1 and row.name or column.header
                        cell:SetText("|cffffd100" .. text .. "|r")
                        cell:Show()
                    else
                        local value = row[column.field]
                        cell:SetText(value ~= nil and tostring(value) or "")
                        cell:Show()
                    end
                end
            end
            line.waiting:Hide()
            line.reject:Show()
            line.accept:SetText("Accept")
            if row.kind == "heading" then
                line.accept:Hide()
                line.reject:Hide()
            elseif row.kind == "bundle" then
                line.accept:SetText("Review")
                line.accept:Show()
                line.reject:Hide()
            elseif row.pending then
                line.accept:Hide()
                line.reject:Hide()
                line.waiting:Show()
            elseif row.canAccept then
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

-- The rows the conflict panel lists: Changes to Player, Note conflicts and
-- the member's own suggestions, each under a heading line when there are
-- any. A row's section comes from ConflictViewModel (`section`), or from
-- its kind for rows that don't say.
function RosterWindow.ConflictSections(rows)
    local sections = {}
    local index
    for index = 1, #CONFLICT_ORDER do
        sections[CONFLICT_ORDER[index]] = {}
    end
    for index = 1, #rows do
        local row = rows[index]
        local section = row.section
        if sections[section] == nil then
            section = row.kind == "bundle" and "changes" or (row.pending and "yours" or "notes")
        end
        table.insert(sections[section], row)
    end
    local listed = {}
    for index = 1, #CONFLICT_ORDER do
        local section = CONFLICT_ORDER[index]
        local sectionRows = sections[section]
        if sectionRows[1] ~= nil then
            table.insert(listed, { kind = "heading", section = section, name = CONFLICT_SECTIONS[section].heading })
            local rowIndex
            for rowIndex = 1, #sectionRows do
                local row = sectionRows[rowIndex]
                row.section = section
                table.insert(listed, row)
            end
        end
    end
    return listed
end

-- The bundle review: who suggested it, a before/after block for every
-- player it changes (removed lines in red, added lines in green), the live
-- guild note of each character involved, then one line per change with
-- Approve and Deny, and Approve all / Deny all.
local REVIEW_WIDTH = 620
local REVIEW_HEIGHT = 520
local REVIEW_LINES = 8
local REVIEW_LIST_TOP = 66
local REVIEW_LIST_HEIGHT = 216
local REVIEW_LIST_LINE_HEIGHT = 16
local REVIEW_SIDE_WIDTH = 280
local REVIEW_COLORS = { added = "|cff40ff40", removed = "|cffff4040" }

local function reviewText(line)
    local color = REVIEW_COLORS[line.mark]
    if color ~= nil then
        return color .. line.text .. "|r"
    end
    return line.text
end

-- The lines of the review's list (see BundleReviewViewModel): each player's
-- name in gold over its before and after sides, then the guild notes.
-- Each line is { before, after } text, colored by mark.
function RosterWindow.ReviewLines(model)
    local lines = {}
    local index
    for index = 1, #(model.players or {}) do
        local block = model.players[index]
        table.insert(lines, { before = "|cffffd100" .. block.name .. "|r", after = "" })
        local count = math.max(#block.before, #block.after)
        local lineIndex
        for lineIndex = 1, count do
            local before = block.before[lineIndex]
            local after = block.after[lineIndex]
            local beforeText = before and reviewText(before) or ""
            if lineIndex == 1 and before == nil then
                beforeText = "|cff9d9d9d(not a player of its own yet)|r"
            end
            table.insert(lines, { before = beforeText, after = after and reviewText(after) or "" })
        end
    end
    if model.notes ~= nil and model.notes[1] ~= nil then
        table.insert(lines, { before = "|cffffd100Guild notes|r", after = "" })
        for index = 1, #model.notes do
            local note = model.notes[index]
            table.insert(lines, {
                before = note.name .. ": " .. (note.note or "|cff9d9d9d(not in the roster)|r"),
                after = "",
            })
        end
    end
    return lines
end

local function createReviewListLine(scroll, index)
    local line = CreateFrame("Frame", nil, scroll)
    line:SetHeight(REVIEW_LIST_LINE_HEIGHT)
    line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * REVIEW_LIST_LINE_HEIGHT)
    line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * REVIEW_LIST_LINE_HEIGHT)
    local function side(x)
        local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetPoint("LEFT", line, "LEFT", x, 0)
        cell:SetWidth(REVIEW_SIDE_WIDTH)
        cell:SetJustifyH("LEFT")
        cell:SetWordWrap(false)
        return cell
    end
    line.before = side(4)
    line.after = side(REVIEW_SIDE_WIDTH + 12)
    return line
end

local function refreshReviewListLines(scroll, rows, offset, totalLines)
    local lineIndex
    for lineIndex = 1, totalLines do
        local row = rows[lineIndex + offset]
        if row ~= nil then
            local line = scroll:GetLine(lineIndex)
            line.before:SetText(row.before)
            line.after:SetText(row.after)
        end
    end
end

local function buildReviewPanel(framework, options, frameName, anchor)
    local panel = framework:CreateSimplePanel(UIParent, REVIEW_WIDTH, REVIEW_HEIGHT, "Review", frameName .. "Review")
    -- Like every panel here, closed only with its close button or Escape.
    panel.DontRightClickClose = true
    panel:SetFrameStrata("DIALOG")
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    local review = { panel = panel, lines = {} }
    review.suggestedBy = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    review.suggestedBy:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -30)
    local function header(x, title)
        local text = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -50)
        text:SetText(title)
    end
    header(14, "Before")
    header(REVIEW_SIDE_WIDTH + 22, "After")
    local listLines = math.floor(REVIEW_LIST_HEIGHT / REVIEW_LIST_LINE_HEIGHT)
    local list = framework:CreateScrollBox(panel, frameName .. "ReviewScroll", refreshReviewListLines, {},
        REVIEW_WIDTH - 20, REVIEW_LIST_HEIGHT, listLines, REVIEW_LIST_LINE_HEIGHT, createReviewListLine, true)
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -REVIEW_LIST_TOP)
    list:CreateLines(createReviewListLine, listLines)
    review.list = list
    local itemsTop = REVIEW_LIST_TOP + REVIEW_LIST_HEIGHT + 10
    local index
    for index = 1, REVIEW_LINES do
        local line = CreateFrame("Frame", nil, panel)
        line:SetHeight(RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -itemsTop - (index - 1) * RosterWindow.LINE_HEIGHT)
        line:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
        line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line.text:SetPoint("LEFT", line, "LEFT", 4, 0)
        line.text:SetPoint("RIGHT", line, "RIGHT", -132, 0)
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        line.approve = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
        line.approve:SetSize(62, 18)
        line.approve:SetPoint("RIGHT", line, "RIGHT", -66, 0)
        line.approve:SetText("Approve")
        line.approve:SetScript("OnClick", function()
            if line.item ~= nil then
                options.onAcceptConflict(line.item.character, line.item.kind)
            end
        end)
        line.deny = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
        line.deny:SetSize(62, 18)
        line.deny:SetPoint("RIGHT", line, "RIGHT", -2, 0)
        line.deny:SetText("Deny")
        line.deny:SetScript("OnClick", function()
            if line.item ~= nil then
                options.onRejectConflict(line.item.character, line.item.kind)
            end
        end)
        review.lines[index] = line
    end
    review.more = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    review.more:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -itemsTop - 4 - REVIEW_LINES * RosterWindow.LINE_HEIGHT)
    local approveAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    approveAll:SetSize(100, 22)
    approveAll:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
    approveAll:SetText("Approve all")
    approveAll:SetScript("OnClick", function()
        if review.group ~= nil then
            options.onDecideBundle(review.group, true)
        end
    end)
    local denyAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    denyAll:SetSize(100, 22)
    denyAll:SetPoint("LEFT", approveAll, "RIGHT", 6, 0)
    denyAll:SetText("Deny all")
    denyAll:SetScript("OnClick", function()
        if review.group ~= nil then
            options.onDecideBundle(review.group, false)
        end
    end)
    panel:HookScript("OnHide", function()
        review.group = nil
        options.onCloseReview()
    end)
    panel:Hide()
    return review
end

local function buildConflictPanel(framework, options, frameName)
    local panel = framework:CreateSimplePanel(
        UIParent,
        CONFLICT_WIDTH,
        CONFLICT_HEIGHT,
        addon.Identity.displayName .. " - Conflicts",
        frameName .. "Conflicts"
    )
    -- The framework hides its panels on a right-click anywhere inside;
    -- ours close only with the close button or Escape.
    panel.DontRightClickClose = true
    panel:SetFrameStrata("DIALOG")

    local explain = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    explain:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -30)
    explain:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -30)
    explain:SetJustifyH("LEFT")
    explain:SetText("Changes to Player: Review shows a player before and with the changes, to approve or " ..
        "deny. Note conflicts: guild notes that disagree with the roster; accepting applies the note, " ..
        "rejecting keeps the roster. Your suggestions wait here until an officer decides them.")

    local scrollHeight = CONFLICT_HEIGHT - CONFLICT_TOP - 40
    local lineAmount = math.floor(scrollHeight / CONFLICT_LINE_HEIGHT)
    local function newLine(scrollBox, index)
        return createConflictLine(scrollBox, index, options)
    end
    local scroll = framework:CreateScrollBox(
        panel,
        frameName .. "ConflictScroll",
        refreshConflictLines,
        {},
        CONFLICT_WIDTH - 20,
        scrollHeight,
        lineAmount,
        CONFLICT_LINE_HEIGHT,
        newLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -CONFLICT_TOP)
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

    local review = buildReviewPanel(framework, options, frameName, panel)
    panel:HookScript("OnHide", function()
        review.panel:Hide()
    end)
    panel:Hide()
    return { panel = panel, scroll = scroll, empty = empty, acceptAll = acceptAll, rejectAll = rejectAll,
        review = review }
end

-- A list of rows in columns, as the Recruiters leaderboard and the Recent
-- ads page show them: a heading row in gold naming the columns, rows on
-- faint stripes, and a grey line when the list is empty (see
-- RosterController:RecruitersView and RecentAdsView). A column marked
-- `action` shows a button instead of text on a row with an `action` (its
-- label); pressing it runs `onAction(row)`.
local function listLineCreator(columns, onAction)
    return function(scroll, index)
        local line = CreateFrame("Frame", nil, scroll)
        line:SetHeight(RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line.background = line:CreateTexture(nil, "BACKGROUND")
        line.background:SetAllPoints(line)
        line.cells = {}
        -- A row with `tooltip` lines shows them on hover.
        line:EnableMouse(true)
        line:SetScript("OnEnter", function(self)
            local lines = self.row and self.row.tooltip
            if type(lines) ~= "table" or GameTooltip == nil then
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local lineIndex
            for lineIndex = 1, #lines do
                GameTooltip:AddLine(lines[lineIndex], 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        line:SetScript("OnLeave", function()
            if GameTooltip ~= nil then
                GameTooltip:Hide()
            end
        end)
        local columnIndex
        for columnIndex = 1, #columns do
            local column = columns[columnIndex]
            local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell:SetPoint("LEFT", line, "LEFT", column.x, 0)
            cell:SetWidth(column.width)
            cell:SetJustifyH("LEFT")
            cell:SetWordWrap(false)
            line.cells[column.field] = cell
            if column.action then
                local button = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
                button:SetSize(100, RosterWindow.LINE_HEIGHT)
                button:SetPoint("LEFT", line, "LEFT", column.x, 0)
                button:SetScript("OnClick", function()
                    if line.row ~= nil and onAction ~= nil then
                        onAction(line.row)
                    end
                end)
                button:Hide()
                line.button = button
            end
        end
        return line
    end
end

local function listLineRefresher(columns)
    return function(scroll, rows, offset, totalLines)
        local lineIndex
        for lineIndex = 1, totalLines do
            local dataIndex = lineIndex + offset
            local row = rows[dataIndex]
            if row ~= nil then
                local line = scroll:GetLine(lineIndex)
                line.row = row
                if line.button ~= nil then
                    line.button:SetText(row.action or "")
                    if row.action ~= nil then
                        line.button:Show()
                    else
                        line.button:Hide()
                    end
                end
                local columnIndex
                for columnIndex = 1, #columns do
                    local field = columns[columnIndex].field
                    local text = tostring(row[field] or "")
                    local color = columns[columnIndex].color
                    if row.kind == "heading" then
                        text = "|cffffd100" .. text .. "|r"
                    elseif row.kind == "empty" then
                        text = "|cff9d9d9d" .. text .. "|r"
                    elseif color ~= nil and color(row) ~= nil then
                        text = "|cff" .. color(row) .. text .. "|r"
                    end
                    line.cells[field]:SetText(text)
                end
                if row.kind == "heading" or row.kind == "empty" then
                    setBackground(line, NO_BACKGROUND)
                elseif dataIndex % 2 == 0 then
                    setBackground(line, STRIPE_BACKGROUND)
                else
                    setBackground(line, NO_BACKGROUND)
                end
            end
        end
    end
end

-- Draws a titled list of `lines` rows in `columns`, `width` wide, into
-- `parent`, its buttons running `onAction(row)`. Returns { holder, scroll }.
local function buildList(framework, parent, scrollName, title, columns, width, lines, onAction)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetAllPoints(parent)
    local heading = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -4)
    heading:SetText(title)
    local height = lines * RosterWindow.LINE_HEIGHT
    local createLine = listLineCreator(columns, onAction)
    local scroll = framework:CreateScrollBox(
        holder,
        scrollName,
        listLineRefresher(columns),
        {},
        width,
        height,
        lines,
        RosterWindow.LINE_HEIGHT,
        createLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -30)
    scroll:SetSize(width, height)
    scroll:CreateLines(createLine, lines)
    return { holder = holder, scroll = scroll }
end

-- The officers' Recruiters leaderboard on the Recruitment page: players
-- ranked by ads in the last 30 days, then all time.
local RECRUITER_COLUMNS = {
    { field = "label", x = 8, width = 200 },
    { field = "recent", x = 214, width = 110 },
    { field = "total", x = 330, width = 60 },
}
local RECRUITERS_WIDTH = 420
local RECRUITER_LINES = 12
-- The room the leaderboard takes below the Recruitment settings.
RosterWindow.LEADERBOARD_HEIGHT = 30 + RECRUITER_LINES * RosterWindow.LINE_HEIGHT + 12

-- Draws the leaderboard into `parent` (LEADERBOARD_HEIGHT tall), hidden
-- until the controller hands over an officer's rows.
local function buildLeaderboard(framework, parent, frameName)
    local leaderboard = buildList(framework, parent, frameName .. "RecruiterScroll", "Recruiters",
        RECRUITER_COLUMNS, RECRUITERS_WIDTH, RECRUITER_LINES)
    leaderboard.holder:Hide()
    return leaderboard
end

-- The Recent Guild Advertisements page, for every member: each channel
-- advertised in lately, who posted, and how long ago, then the zones turned
-- off with Off here, each with a button to turn it back on.
local AD_COLUMNS = {
    { field = "label", x = 8, width = 270 },
    { field = "by", x = 284, width = 230 },
    { field = "recent", x = 520, width = 140, action = true },
}

-- Draws the Recent Guild Advertisements list onto its page, below the
-- frame's title bar, filling the page (clear of the scroll bar) with as
-- many lines as it holds; more lines are made as the frame grows.
local function buildRecentAds(framework, page, frameName, onTurnBackOn)
    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -28)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 10)
    local width, height = page:GetSize()
    local lines = math.max(1, math.floor((height - 70) / RosterWindow.LINE_HEIGHT))
    local ads = buildList(framework, holder, frameName .. "RecentAdsScroll", "Recent Guild Advertisements",
        AD_COLUMNS, width - 16 - RosterWindow.SCROLL_BAR_ROOM, lines, function(row)
            if row.zoneKey ~= nil and onTurnBackOn ~= nil then
                onTurnBackOn(row.zoneKey)
            end
        end)
    ads.scroll:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, 0)
    return ads
end

-- Each Guild Log event type's color (hex RGB), on its entries' Event
-- column and its filter check box: arrivals green, departures orange and
-- red, rank changes blue and purple.
local GUILD_LOG_TYPE_COLORS = {
    join = "40ff40", invite = "40e0d0", leave = "ff9933", kick = "ff4040", promote = "66b3ff", demote = "d080ff",
}

-- The officers' Guild Log page: every entry newest first, with its date,
-- what happened (in its type's color), the character, its player, and who
-- did it.
local GUILD_LOG_COLUMNS = {
    { field = "date", x = 8, width = 84 },
    { field = "event", x = 96, width = 170, color = function(row)
        return GUILD_LOG_TYPE_COLORS[row.eventType]
    end },
    { field = "character", x = 270, width = 130 },
    { field = "player", x = 404, width = 120 },
    { field = "actor", x = 528, width = 130 },
}

-- The Guild Log page's date ranges, in the order its Range button steps
-- through them: days back, or false for all.
local GUILD_LOG_RANGES = { false, 7, 30, 90 }
local GUILD_LOG_TYPE_LABELS = {
    join = "Join", invite = "Invite", leave = "Leave", kick = "Kick", promote = "Promote", demote = "Demote",
}

local function smallButton(parent, width, text, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 20)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

-- Draws the Guild Log page, below the frame's title bar: a search box, a
-- sort button, a date range button, and page buttons, then a check box for
-- each event type, then the list, filling the page (clear of the scroll
-- bar). Each control calls its `options` handler; SetGuildLog shows where
-- they stand.
local function buildGuildLog(framework, page, frameName, options)
    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -28)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 10)
    local controls = {}
    local search = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    search:SetSize(160, 20)
    search:SetPoint("TOPLEFT", holder, "TOPLEFT", 120, -2)
    search:SetAutoFocus(false)
    local placeholder = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", search, "LEFT", 2, 0)
    placeholder:SetText("Name, alias or main")
    search:SetScript("OnTextChanged", function(box)
        local text = box:GetText()
        if text == "" then
            placeholder:Show()
        else
            placeholder:Hide()
        end
        if options.onGuildLogSearch ~= nil then
            options.onGuildLogSearch(text)
        end
    end)
    search:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    search:SetScript("OnEnterPressed", function(box)
        box:ClearFocus()
    end)
    controls.sort = smallButton(holder, 96, "Sort: Date", function()
        if options.onGuildLogSort ~= nil and controls.state ~= nil then
            options.onGuildLogSort(controls.state.filters.sort == "name" and "date" or "name")
        end
    end)
    controls.sort:SetPoint("LEFT", search, "RIGHT", 10, 0)
    controls.range = smallButton(holder, 100, "Range: All", function()
        if options.onGuildLogRange == nil or controls.state == nil then
            return
        end
        local current = controls.state.filters.range or false
        local index, nextIndex = 1, 1
        for index = 1, #GUILD_LOG_RANGES do
            if GUILD_LOG_RANGES[index] == current then
                nextIndex = index % #GUILD_LOG_RANGES + 1
            end
        end
        options.onGuildLogRange(GUILD_LOG_RANGES[nextIndex] or nil)
    end)
    controls.range:SetPoint("LEFT", controls.sort, "RIGHT", 6, 0)
    controls.previous = smallButton(holder, 24, "<", function()
        if options.onGuildLogPage ~= nil and controls.state ~= nil then
            options.onGuildLogPage(controls.state.page - 1)
        end
    end)
    controls.previous:SetPoint("LEFT", controls.range, "RIGHT", 12, 0)
    controls.pageText = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    controls.pageText:SetPoint("LEFT", controls.previous, "RIGHT", 6, 0)
    controls.pageText:SetWidth(120)
    controls.next = smallButton(holder, 24, ">", function()
        if options.onGuildLogPage ~= nil and controls.state ~= nil then
            options.onGuildLogPage(controls.state.page + 1)
        end
    end)
    controls.next:SetPoint("LEFT", controls.pageText, "RIGHT", 6, 0)
    controls.types = {}
    local typeIndex
    for typeIndex = 1, #addon.GuildLog.TYPES do
        local eventType = addon.GuildLog.TYPES[typeIndex]
        local check = CreateFrame("CheckButton", nil, holder, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", holder, "TOPLEFT", 16 + (typeIndex - 1) * 96, -26)
        local label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        label:SetText("|cff" .. GUILD_LOG_TYPE_COLORS[eventType] .. GUILD_LOG_TYPE_LABELS[eventType] .. "|r")
        check:SetScript("OnClick", function(box)
            if options.onGuildLogType ~= nil then
                options.onGuildLogType(eventType, box:GetChecked() == true)
            end
        end)
        controls.types[eventType] = check
    end
    local listHolder = CreateFrame("Frame", nil, holder)
    listHolder:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -50)
    listHolder:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
    local width, height = page:GetSize()
    local lines = math.max(1, math.floor((height - 120) / RosterWindow.LINE_HEIGHT))
    local log = buildList(framework, listHolder, frameName .. "GuildLogScroll", "Guild Log",
        GUILD_LOG_COLUMNS, width - 16 - RosterWindow.SCROLL_BAR_ROOM, lines)
    log.scroll:SetPoint("BOTTOMRIGHT", listHolder, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, 0)
    log.controls = controls
    return log
end

-- What the Guild Log page's controls say, from the controller's state
-- (see RosterController:GuildLogView).
function RosterWindow.GuildLogControlText(state)
    local filters = state.filters
    return {
        sort = filters.sort == "name" and "Sort: Name" or "Sort: Date",
        range = filters.range ~= nil and ("Range: " .. filters.range .. " days") or "Range: All",
        page = "Page " .. state.page .. " of " .. state.pages .. " (" .. state.total ..
            (state.total == 1 and " entry)" or " entries)"),
    }
end

local function build(framework, options)
    local frameName = addon.Identity.addonName .. "RosterWindow"
    local host = addon.MasterFrame.Build(framework, {
        navigator = options.navigator,
        frameName = frameName,
        loadGeometry = options.loadGeometry,
        saveGeometry = options.saveGeometry,
    })
    -- The Conflicts panel and its review pop out beside the master frame.
    local frame = host.panel
    -- The other pages draw themselves; one that fails is left empty rather
    -- than taking the roster down with it. The Recruitment page hands back
    -- room below its settings for the officers' leaderboard.
    local recruiters
    local pageId, draw
    for pageId, draw in pairs(options.drawPages or {}) do
        local content = host:Content(pageId)
        if content ~= nil then
            local drawn, below = pcall(draw, content, framework)
            if drawn and pageId == "recruitment" and below ~= nil then
                local built, leaderboard = pcall(buildLeaderboard, framework, below, frameName)
                recruiters = built and leaderboard or nil
            end
        end
    end
    -- The Recent ads page, for everyone, when the frame has one.
    local recentAds
    local adsPage = host:Content("ads")
    if adsPage ~= nil then
        local built, ads = pcall(buildRecentAds, framework, adsPage, frameName, options.onTurnBackOn)
        recentAds = built and ads or nil
        -- Showing the page brings "how long ago" up to date.
        if options.onRecentAdsShown ~= nil then
            adsPage:HookScript("OnShow", options.onRecentAdsShown)
        end
    end
    -- The officers' Guild Log page, when the frame has one.
    local guildLog
    local logPage = host:Content("guildlog")
    if logPage ~= nil then
        local built, log = pcall(buildGuildLog, framework, logPage, frameName, options)
        guildLog = built and log or nil
        if options.onGuildLogShown ~= nil then
            logPage:HookScript("OnShow", options.onGuildLogShown)
        end
    end
    if options.onHide ~= nil then
        frame:HookScript("OnHide", options.onHide)
    end

    local conflicts = buildConflictPanel(framework, options, frameName)
    -- The guild note Conflicts button, at the foot of the Settings page
    -- (officers only, see SetConflictsShown), until #352 retires conflicts.
    local settingsPage = host:Content("settings") or frame
    local conflictsButton = CreateFrame("Button", nil, settingsPage, "UIPanelButtonTemplate")
    conflictsButton:SetSize(110, 22)
    conflictsButton:SetPoint("BOTTOMRIGHT", settingsPage, "BOTTOMRIGHT", -36, 10)
    conflictsButton:SetText("Conflicts (0)")
    conflictsButton:SetScript("OnClick", function()
        if conflicts.panel:IsShown() then
            conflicts.panel:Hide()
        else
            conflicts.panel:Show()
        end
    end)
    conflicts.button = conflictsButton
    frame:HookScript("OnHide", function()
        conflicts.panel:Hide()
    end)

    return host, conflicts, recruiters, recentAds, guildLog
end

-- options.navigator is the PageNavigator with the master frame's pages;
-- options.drawPages maps a page id to function(content, framework) that
-- draws that page into its content frame;
-- the Recruitment page's returns a frame LEADERBOARD_HEIGHT tall below its
-- settings, where the officers' leaderboard is drawn;
-- options.onHide() runs whenever the frame closes;
-- options.onRecentAdsShown() runs whenever the Recent ads page shows, and
-- options.onTurnBackOn(zoneKey) when a zone's "Turn back on" is pressed;
-- options.loadGeometry() returns saved geometry or nil;
-- options.saveGeometry(state) stores it;
-- options.onAcceptConflict(character, kind), onRejectConflict(character,
-- kind), onAcceptAll(), and onRejectAll() resolve conflicts;
-- options.onReviewBundle(group), onDecideBundle(group, approved) and
-- onCloseReview() drive the review of a member's bundle of suggestions.
function RosterWindow.Create(client, options)
    local framework = frameworkFrom(client)
    if framework == nil then
        return nil, "the Details! Framework is not available"
    end
    local ok, host, conflicts, recruiters, recentAds, guildLog = pcall(build, framework, options)
    if not ok or host == nil then
        return nil, "the Details! Framework could not build the window"
    end
    return setmetatable({
        host = host,
        panel = host.panel,
        conflicts = conflicts,
        recruiters = recruiters,
        recentAds = recentAds,
        guildLog = guildLog,
    }, Window)
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

-- Shows the page `id` on the master frame (see MasterFrame).
function Window:ShowPage(id)
    return (pcall(function()
        self.host:ShowPage(id)
    end))
end

function Window:SetTitle(title)
    if type(self.panel.SetTitle) == "function" then
        self.panel:SetTitle(title)
    elseif self.panel.Title ~= nil then
        self.panel.Title:SetText(title)
    end
end

-- Shows the pending conflicts and this member's own suggestions; the footer
-- button counts only the ones to review.
function Window:SetConflicts(rows)
    return (pcall(function()
        local conflicts = self.conflicts
        local count = addon.ConflictViewModel.CountToReview(rows)
        conflicts.button:SetText("Conflicts (" .. count .. ")")
        conflicts.scroll:SetData(RosterWindow.ConflictSections(rows))
        conflicts.scroll:Refresh()
        if #rows == 0 then
            conflicts.empty:Show()
        else
            conflicts.empty:Hide()
        end
        if count == 0 then
            conflicts.acceptAll:Disable()
            conflicts.rejectAll:Disable()
        else
            conflicts.acceptAll:Enable()
            conflicts.rejectAll:Enable()
        end
    end))
end

-- Shows or hides the Conflicts button; hiding it also closes the conflict
-- panel and its review (members never see them).
function Window:SetConflictsShown(shown)
    return (pcall(function()
        local conflicts = self.conflicts
        if shown then
            conflicts.button:Show()
            return
        end
        conflicts.button:Hide()
        conflicts.panel:Hide()
        if conflicts.review ~= nil then
            conflicts.review.panel:Hide()
        end
    end))
end

-- Shows the bundle review (see BundleReviewViewModel) beside the conflict
-- panel: who suggested it, each changed player before and after, the guild
-- notes, and its changes.
function Window:ShowReview(model)
    return (pcall(function()
        local review = self.conflicts.review
        review.group = model.group
        if type(review.panel.SetTitle) == "function" then
            review.panel:SetTitle(model.title)
        elseif review.panel.Title ~= nil then
            review.panel.Title:SetText(model.title)
        end
        review.suggestedBy:SetText(model.suggestedBy or "")
        review.list:SetData(RosterWindow.ReviewLines(model))
        review.list:Refresh()
        local index
        for index = 1, #review.lines do
            local line = review.lines[index]
            local item = model.items[index]
            line.item = item
            if item == nil then
                line:Hide()
            else
                line.text:SetText(item.text)
                line:Show()
            end
        end
        local hidden = #model.items - #review.lines
        review.more:SetText(hidden > 0 and ("And " .. hidden .. " more: Approve all and Deny all include them.") or "")
        review.panel:Show()
    end))
end

function Window:HideReview()
    self.conflicts.review.panel:Hide()
end

-- Shows the officers' Recruiters leaderboard on the Recruitment page (see
-- RosterController:RecruitersView), or, for nil, hides it. False when the
-- page has no leaderboard.
function Window:SetRecruiters(rows)
    local recruiters = self.recruiters
    if recruiters == nil then
        return false
    end
    return (pcall(function()
        if rows == nil then
            recruiters.holder:Hide()
            return
        end
        recruiters.holder:Show()
        recruiters.scroll:SetData(rows)
        recruiters.scroll:Refresh()
    end))
end

-- Shows the Guild Log page's rows and where its controls stand (see
-- RosterController:GuildLogView). False when the frame has no Guild Log
-- page.
function Window:SetGuildLog(rows, state)
    local guildLog = self.guildLog
    if guildLog == nil then
        return false
    end
    return (pcall(function()
        guildLog.scroll:SetData(rows or {})
        guildLog.scroll:Refresh()
        local controls = guildLog.controls
        if state == nil or controls == nil then
            return
        end
        controls.state = state
        local text = RosterWindow.GuildLogControlText(state)
        controls.sort:SetText(text.sort)
        controls.range:SetText(text.range)
        controls.pageText:SetText(text.page)
        if state.page > 1 then
            controls.previous:Enable()
        else
            controls.previous:Disable()
        end
        if state.page < state.pages then
            controls.next:Enable()
        else
            controls.next:Disable()
        end
        local eventType, check
        for eventType, check in pairs(controls.types) do
            check:SetChecked(state.filters.types[eventType] == true)
        end
    end))
end

function Window:SetRecentAds(rows)
    local recentAds = self.recentAds
    if recentAds == nil then
        return false
    end
    return (pcall(function()
        recentAds.scroll:SetData(rows or {})
        recentAds.scroll:Refresh()
    end))
end
