local _, addon = ...

-- The master frame with the roster on its Roster page, built with the
-- Details! Framework. It lives in Adapters/ because it uses game globals
-- (CreateFrame, UIParent) and the framework directly; Core never sees
-- either. It is not unit tested; the in-game checklist covers it.
--
-- Create() returns nil when the framework is missing or fails to build the
-- frame (its behavior on WoW Forever is unconfirmed), so the caller can
-- print a message instead of raising Lua errors. The frame is created once,
-- then hidden and shown; it is never destroyed.
local RosterWindow = {
    LINE_HEIGHT = 22,
    -- How far an alt's name sits in from its player's header.
    INDENT = 18,
    -- Room on the right of a page's list for its scroll bar, which the
    -- framework draws just outside the list.
    SCROLL_BAR_ROOM = 34,
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

local function createLine(scroll, index, onToggleGroup, onPurge, onRowMenu, onSelectRow)
    local line = CreateFrame("Button", nil, scroll)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Left-clicking a player header collapses or expands its group;
    -- right-clicking any row opens its organize menu.
    line:SetScript("OnClick", function(self, button)
        if self.row == nil then
            return
        end
        if button == "RightButton" then
            onRowMenu(self.row, self)
        elseif self.row.kind == "player" then
            onToggleGroup(self.row.id)
        else
            -- Left-clicking a character opens its player's edit panel.
            onSelectRow(self.row)
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
            return "|cff20ff20Online as " .. tostring(row.onlineAs) .. "|r"
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

-- Organize menu, alias dialog, and player picker ---------------------------

-- Shows a context menu with the client's menu system: MenuUtil on newer
-- clients, UIDropDownMenu otherwise. Returns false when neither exists.
local menuFrame
local function showContextMenu(owner, title, entries, onChoose)
    if type(MenuUtil) == "table" and type(MenuUtil.CreateContextMenu) == "function" then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle(title)
            local index
            for index = 1, #entries do
                local entry = entries[index]
                root:CreateButton(entry.text, function()
                    onChoose(entry)
                end)
            end
        end)
        return true
    end
    if type(UIDropDownMenu_Initialize) == "function" and type(ToggleDropDownMenu) == "function"
        and type(UIDropDownMenu_AddButton) == "function"
    then
        menuFrame = menuFrame or CreateFrame("Frame", addon.Identity.addonName .. "RowMenu", UIParent,
            "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(menuFrame, function(_, level)
            local info = { text = title, isTitle = true, notCheckable = true }
            UIDropDownMenu_AddButton(info, level)
            local index
            for index = 1, #entries do
                local entry = entries[index]
                UIDropDownMenu_AddButton({
                    text = entry.text,
                    notCheckable = true,
                    func = function()
                        onChoose(entry)
                    end,
                }, level)
            end
        end, "MENU")
        ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
        return true
    end
    return false
end

local function popupEditBox(popup)
    if popup.editBox ~= nil then
        return popup.editBox
    end
    if popup.EditBox ~= nil then
        return popup.EditBox
    end
    if type(popup.GetEditBox) == "function" then
        return popup:GetEditBox()
    end
    return nil
end

-- A text dialog for "Set alias…". Saving an empty alias clears it.
local function showAliasDialog(label, current, onSave)
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
        return false
    end
    local name = addon.Identity.addonName .. "_SET_ALIAS"
    if StaticPopupDialogs[name] == nil then
        local function save(popup, data)
            local box = popupEditBox(popup)
            if box ~= nil and data ~= nil then
                data.onSave(box:GetText())
            end
        end
        StaticPopupDialogs[name] = {
            text = "Alias for %s (leave empty to clear):",
            button1 = ACCEPT or "Accept",
            button2 = CANCEL or "Cancel",
            hasEditBox = true,
            maxLetters = 48,
            OnShow = function(popup, data)
                local box = popupEditBox(popup)
                if box ~= nil and data ~= nil then
                    box:SetText(data.current or "")
                    box:HighlightText()
                end
            end,
            OnAccept = save,
            EditBoxOnEnterPressed = function(box, data)
                local popup = box:GetParent()
                save(popup, data)
                popup:Hide()
            end,
            EditBoxOnEscapePressed = function(box)
                box:GetParent():Hide()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
    end
    StaticPopup_Show(name, label, nil, { current = current, onSave = onSave })
    return true
end

local PICKER_WIDTH = 360
local PICKER_HEIGHT = 380

-- The player picker ("Link as alt of…" and "Merge into player…"): a search
-- box and the matching players.
local function buildPicker(framework, frameName)
    local panel = framework:CreateSimplePanel(UIParent, PICKER_WIDTH, PICKER_HEIGHT, "Link as alt of", frameName .. "Picker")
    panel:SetFrameStrata("DIALOG")
    local prompt = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    prompt:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -30)
    prompt:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -30)
    prompt:SetJustifyH("LEFT")

    local search = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    search:SetSize(PICKER_WIDTH - 40, 20)
    search:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -48)
    search:SetAutoFocus(true)

    local picker = { panel = panel, prompt = prompt, search = search, results = {} }

    local lineAmount = math.floor((PICKER_HEIGHT - 100) / RosterWindow.LINE_HEIGHT)
    local function refreshResults(scroll, rows, offset, totalLines)
        local lineIndex
        for lineIndex = 1, totalLines do
            local row = rows[lineIndex + offset]
            if row ~= nil then
                local line = scroll:GetLine(lineIndex)
                -- Each line is placed by its slot on every refresh, so rows
                -- never stack on one another whatever order lines were made.
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(lineIndex - 1) * RosterWindow.LINE_HEIGHT)
                line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(lineIndex - 1) * RosterWindow.LINE_HEIGHT)
                line.row = row
                local text = row.label
                if row.matched ~= nil then
                    text = text .. "  |cff9d9d9d(" .. row.matched .. ")|r"
                end
                line.text:SetText(text)
            end
        end
    end
    local function newLine(scroll, index)
        local line = CreateFrame("Button", nil, scroll)
        line:SetHeight(RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line.text:SetPoint("LEFT", line, "LEFT", 6, 0)
        line.text:SetPoint("RIGHT", line, "RIGHT", -6, 0)
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        line:SetScript("OnClick", function(self)
            if self.row ~= nil and picker.onPick ~= nil then
                picker.onPick(self.row.id)
                panel:Hide()
            end
        end)
        return line
    end
    local scroll = framework:CreateScrollBox(panel, frameName .. "PickerScroll", refreshResults, {},
        PICKER_WIDTH - 20, PICKER_HEIGHT - 100, lineAmount, RosterWindow.LINE_HEIGHT, newLine, true)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -76)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 12)
    scroll:CreateLines(newLine, lineAmount)
    picker.scroll = scroll

    function picker.setTitle(title)
        if type(panel.SetTitle) == "function" then
            panel:SetTitle(title)
        elseif panel.Title ~= nil then
            panel.Title:SetText(title)
        end
    end
    function picker.update()
        local results = picker.search_fn and picker.search_fn(search:GetText()) or {}
        scroll:SetData(results)
        scroll:Refresh()
    end
    search:SetScript("OnTextChanged", function()
        picker.update()
    end)
    search:SetScript("OnEscapePressed", function()
        panel:Hide()
    end)
    panel:Hide()
    return picker
end

-- The player edit panel -------------------------------------------------------

local PANEL_WIDTH = 380
local PANEL_HEIGHT = 440

-- `actions.openSetAlias(key, title)` and `actions.openSetMain(key, name,
-- merge)` open the dialogs the right-click menu uses (`merge` titles the
-- picker "Merge into player").
local function buildPlayerPanel(framework, options, frameName, anchor, actions)
    local panel = framework:CreateSimplePanel(UIParent, PANEL_WIDTH, PANEL_HEIGHT, "Player", frameName .. "Player")
    panel:SetFrameStrata("HIGH")
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", addon.MasterFrame.SIDE_OFFSET, 0)
    local edit = { panel = panel }

    -- The alias, with Set alias… and Merge into player… buttons that open
    -- the same dialogs as the right-click menu.
    local aliasText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    aliasText:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -32)
    aliasText:SetPoint("RIGHT", panel, "RIGHT", -230, 0)
    aliasText:SetJustifyH("LEFT")
    aliasText:SetWordWrap(false)
    local setMain = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    setMain:SetSize(124, 20)
    setMain:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -28)
    setMain:SetText("Merge into player...")
    local setAlias = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    setAlias:SetSize(84, 20)
    setAlias:SetPoint("RIGHT", setMain, "LEFT", -4, 0)
    setAlias:SetText("Set alias...")
    local aliasSource = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    aliasSource:SetPoint("TOPLEFT", aliasText, "BOTTOMLEFT", 0, -6)
    setAlias:SetScript("OnClick", function()
        if edit.model ~= nil then
            actions.openSetAlias(edit.model.main, edit.model.label)
        end
    end)
    setMain:SetScript("OnClick", function()
        if edit.model ~= nil then
            actions.openSetMain(edit.model.main, edit.model.mainName, true)
        end
    end)
    edit.aliasText = aliasText
    edit.aliasSource = aliasSource

    -- "Don't sync": keep this client's own version of the player.
    local dontSync = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    dontSync:SetSize(20, 20)
    dontSync:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -160, -50)
    local dontSyncLabel = dontSync:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dontSyncLabel:SetPoint("LEFT", dontSync, "RIGHT", 2, 0)
    dontSync:SetScript("OnClick", function(button)
        if edit.model ~= nil then
            options.onSetDontSync(edit.model.main, button:GetChecked() == true)
        end
    end)
    edit.dontSync = dontSync
    edit.dontSyncLabel = dontSyncLabel

    local lineAmount = math.floor((PANEL_HEIGHT - 90) / RosterWindow.LINE_HEIGHT)
    local function newLine(scroll, index)
        local line = CreateFrame("Frame", nil, scroll)
        line:SetHeight(RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line.text:SetPoint("LEFT", line, "LEFT", 6, 0)
        line.text:SetPoint("RIGHT", line, "RIGHT", -128, 0)
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        line.makeMain = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
        line.makeMain:SetSize(62, 18)
        line.makeMain:SetPoint("RIGHT", line, "RIGHT", -62, 0)
        line.makeMain:SetText("Make main")
        line.makeMain:SetScript("OnClick", function()
            if line.row ~= nil then
                options.onMakeMain(line.row.key)
            end
        end)
        line.detach = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
        line.detach:SetSize(56, 18)
        line.detach:SetPoint("RIGHT", line, "RIGHT", -2, 0)
        line.detach:SetText("Detach")
        line.detach:SetScript("OnClick", function()
            if line.row ~= nil then
                options.onDetach(line.row.key)
            end
        end)
        return line
    end
    local function refreshLines(scroll, rows, offset, totalLines)
        local lineIndex
        for lineIndex = 1, totalLines do
            local row = rows[lineIndex + offset]
            if row ~= nil then
                local line = scroll:GetLine(lineIndex)
                line.row = row
                local text = ""
                if row.kind == "section" then
                    text = "|cffffd100" .. row.text .. "|r"
                elseif row.kind == "empty" then
                    text = "|cff9d9d9d" .. row.text .. "|r"
                elseif row.kind == "stat" then
                    text = row.text
                elseif row.kind == "character" then
                    text = "  " .. row.name .. (row.level and ("  |cff9d9d9d" .. row.level .. "|r") or "") ..
                        "  |cff9d9d9d" .. tostring(row.status) .. "|r" ..
                        (row.roles and ("  |cff9d9d9dRoles: " .. row.roles .. "|r") or "")
                    if not row.inGuild then
                        text = "  |cff7f7f7f" .. row.name .. " (left)|r"
                    end
                elseif row.kind == "history" then
                    text = "  " .. row.name .. "  |cff9d9d9d" .. row.role .. ", " .. row.reason ..
                        (row.dates ~= "" and (", " .. row.dates) or "") .. "|r"
                end
                line.text:SetText(text)
                if row.kind == "character" and row.canMakeMain then
                    line.makeMain:Show()
                else
                    line.makeMain:Hide()
                end
                if row.kind == "character" and row.canDetach then
                    line.detach:Show()
                else
                    line.detach:Hide()
                end
            end
        end
    end
    local scroll = framework:CreateScrollBox(panel, frameName .. "PlayerScroll", refreshLines, {},
        PANEL_WIDTH - 20, PANEL_HEIGHT - 90, lineAmount, RosterWindow.LINE_HEIGHT, newLine, true)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -72)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 12)
    scroll:CreateLines(newLine, lineAmount)
    edit.scroll = scroll

    panel:HookScript("OnHide", function()
        if edit.model ~= nil then
            edit.model = nil
            options.onClosePanel()
        end
    end)
    panel:Hide()
    return edit
end

-- The conflict review panel: one line per pending conflict, with Accept and
-- Reject (or Dismiss, when there's nothing to apply), plus Accept all and
-- Reject all. A member's own suggestions follow, waiting for an officer.
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
    line.waiting = line:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    line.waiting:SetPoint("LEFT", line, "LEFT", 748, 0)
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
            local columnIndex
            for columnIndex = 1, #CONFLICT_COLUMNS do
                local field = CONFLICT_COLUMNS[columnIndex].field
                local value = row[field]
                if field == "note" and value == nil then
                    value = "|cff9d9d9d(not in the roster)|r"
                end
                line.cells[field]:SetText(value ~= nil and tostring(value) or "")
            end
            line.waiting:Hide()
            line.reject:Show()
            if row.pending then
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
    explain:SetText("Guild notes that disagree with the roster, and members' suggestions. Accepting applies the " ..
        "suggestion; rejecting keeps the roster. Guild notes are never edited. Your own suggestions are listed " ..
        "last until an officer decides them.")

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

-- A list of rows in columns, as the Recruiters leaderboard and the Recent
-- ads page show them: a heading row in gold naming the columns, rows on
-- faint stripes, and a grey line when the list is empty (see
-- RosterController:RecruitersView and RecentAdsView).
local function listLineCreator(columns)
    return function(scroll, index)
        local line = CreateFrame("Frame", nil, scroll)
        line:SetHeight(RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(index - 1) * RosterWindow.LINE_HEIGHT)
        line.background = line:CreateTexture(nil, "BACKGROUND")
        line.background:SetAllPoints(line)
        line.cells = {}
        local columnIndex
        for columnIndex = 1, #columns do
            local column = columns[columnIndex]
            local cell = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell:SetPoint("LEFT", line, "LEFT", column.x, 0)
            cell:SetWidth(column.width)
            cell:SetJustifyH("LEFT")
            cell:SetWordWrap(false)
            line.cells[column.field] = cell
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
                local columnIndex
                for columnIndex = 1, #columns do
                    local field = columns[columnIndex].field
                    local text = tostring(row[field] or "")
                    if row.kind == "heading" then
                        text = "|cffffd100" .. text .. "|r"
                    elseif row.kind == "empty" then
                        text = "|cff9d9d9d" .. text .. "|r"
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
-- `parent`. Returns { holder, scroll }.
local function buildList(framework, parent, scrollName, title, columns, width, lines)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetAllPoints(parent)
    local heading = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -4)
    heading:SetText(title)
    local height = lines * RosterWindow.LINE_HEIGHT
    local createLine = listLineCreator(columns)
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
-- advertised in lately, who posted, and how long ago.
local AD_COLUMNS = {
    { field = "label", x = 8, width = 270 },
    { field = "by", x = 284, width = 230 },
    { field = "recent", x = 520, width = 140 },
}

-- Draws the Recent Guild Advertisements list onto its page, below the
-- frame's title bar, filling the page (clear of the scroll bar) with as
-- many lines as it holds; more lines are made as the frame grows.
local function buildRecentAds(framework, page, frameName)
    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -28)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 10)
    local width, height = page:GetSize()
    local lines = math.max(1, math.floor((height - 70) / RosterWindow.LINE_HEIGHT))
    local ads = buildList(framework, holder, frameName .. "RecentAdsScroll", "Recent Guild Advertisements",
        AD_COLUMNS, width - 16 - RosterWindow.SCROLL_BAR_ROOM, lines)
    ads.scroll:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, 0)
    return ads
end

local function build(framework, options)
    local frameName = addon.Identity.addonName .. "RosterWindow"
    local host = addon.MasterFrame.Build(framework, {
        navigator = options.navigator,
        frameName = frameName,
        loadGeometry = options.loadGeometry,
        saveGeometry = options.saveGeometry,
    })
    -- The roster's controls, list, and footer are drawn on the Roster page;
    -- the pop-out panels stay beside the master frame.
    local frame = host.panel
    local panel = host:Content("roster")
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
        local built, ads = pcall(buildRecentAds, framework, adsPage, frameName)
        recentAds = built and ads or nil
        -- Showing the page brings "how long ago" up to date.
        if options.onRecentAdsShown ~= nil then
            adsPage:HookScript("OnShow", options.onRecentAdsShown)
        end
    end
    if options.onHide ~= nil then
        frame:HookScript("OnHide", options.onHide)
    end

    -- Controls: search, online only, expand and collapse all.
    local search = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    search:SetSize(180, 20)
    search:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -30)
    search:SetAutoFocus(false)
    local placeholder = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", search, "LEFT", 2, 0)
    placeholder:SetText("Search names and aliases")
    search:SetScript("OnTextChanged", function(box)
        local text = box:GetText()
        if text == "" then
            placeholder:Show()
        else
            placeholder:Hide()
        end
        options.onSearch(text)
    end)
    search:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    search:SetScript("OnEnterPressed", function(box)
        box:ClearFocus()
    end)

    local onlineOnly = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    onlineOnly:SetSize(22, 22)
    onlineOnly:SetPoint("LEFT", search, "RIGHT", 10, 0)
    local onlineLabel = onlineOnly:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    onlineLabel:SetPoint("LEFT", onlineOnly, "RIGHT", 2, 0)
    onlineLabel:SetText("Online only")
    onlineOnly:SetScript("OnClick", function()
        options.onToggleOnlineOnly()
    end)

    local collapseAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    collapseAll:SetSize(90, 20)
    collapseAll:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -30)
    collapseAll:SetText("Collapse all")
    collapseAll:SetScript("OnClick", function()
        options.onCollapseAll()
    end)
    local expandAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    expandAll:SetSize(90, 20)
    expandAll:SetPoint("RIGHT", collapseAll, "LEFT", -4, 0)
    expandAll:SetText("Expand all")
    expandAll:SetScript("OnClick", function()
        options.onExpandAll()
    end)

    local headerIndex
    for headerIndex = 1, #COLUMNS do
        local column = COLUMNS[headerIndex]
        local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", panel, "TOPLEFT", 10 + column.x, -58)
        header:SetText(column.header)
    end

    -- Enough lines for the frame's restored height.
    local width, height = frame:GetSize()
    local lineAmount = math.floor((height - 120) / RosterWindow.LINE_HEIGHT)
    local picker = buildPicker(framework, frameName)
    -- "Link as alt of…" links `key` (named `name`) as an alt of the picked
    -- player. From the player panel it's "Merge into player…": the same link,
    -- made for the player's main.
    local function openSetMain(key, name, merge)
        if merge then
            picker.setTitle("Merge into player")
            picker.prompt:SetText("Merge " .. tostring(name) .. " into player:")
        else
            picker.setTitle("Link as alt of")
            picker.prompt:SetText("Link " .. tostring(name) .. " as an alt of:")
        end
        picker.search_fn = function(query)
            return options.searchPlayers(key, query)
        end
        picker.onPick = function(playerId)
            options.onSetMain(key, playerId)
        end
        picker.search:SetText("")
        picker.panel:Show()
        picker.update()
    end
    local function openSetAlias(key, title)
        if not showAliasDialog(title, options.aliasOf(key), function(text)
            options.onSetAlias(key, text)
        end) then
            options.onMenuUnavailable()
        end
    end
    local function openRowMenu(row, line)
        local entries = options.menuFor(row)
        if entries[1] == nil then
            return
        end
        local title = row.kind == "player" and row.label or (row.standalone and row.label or row.name)
        local shown = showContextMenu(line, title, entries, function(entry)
            if entry.action == "setMain" then
                openSetMain(entry.key, row.name)
            elseif entry.action == "makeMain" then
                options.onMakeMain(entry.key)
            elseif entry.action == "alias" then
                openSetAlias(entry.key, title)
            elseif entry.action == "detach" then
                options.onDetach(entry.key)
            elseif entry.action == "view" then
                options.onSelectCharacter(entry.key)
            end
        end)
        if not shown then
            options.onMenuUnavailable()
        end
    end
    local function onRowMenu(row, line)
        local ok = pcall(openRowMenu, row, line)
        if not ok then
            options.onMenuUnavailable()
        end
    end
    local function onSelectRow(row)
        if row.key ~= nil then
            options.onSelectCharacter(row.key)
        end
    end
    local function newLine(scrollBox, index)
        return createLine(scrollBox, index, options.onToggleGroup, options.onPurge, onRowMenu, onSelectRow)
    end
    local scroll = framework:CreateScrollBox(
        panel,
        frameName .. "Scroll",
        refreshLines,
        {},
        width - 20,
        height - 120,
        lineAmount,
        RosterWindow.LINE_HEIGHT,
        newLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -74)
    -- The scroll bar is drawn just outside the list's right edge, so the
    -- list stops short of the frame's edge to keep the bar inside it, clear
    -- of the tabs.
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, 40)
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

    local conflicts = buildConflictPanel(framework, options, frameName)
    local playerPanel = buildPlayerPanel(framework, options, frameName, frame, {
        openSetAlias = openSetAlias,
        openSetMain = openSetMain,
    })
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
        playerPanel.panel:Hide()
    end)

    return host, scroll, status, conflicts, playerPanel, recruiters, recentAds
end

-- options.navigator is the PageNavigator with the master frame's pages;
-- options.drawPages maps a page id to function(content, framework) that
-- draws that page into its content frame (the Roster page is drawn here);
-- the Recruitment page's returns a frame LEADERBOARD_HEIGHT tall below its
-- settings, where the officers' leaderboard is drawn;
-- options.onHide() runs whenever the frame closes;
-- options.onRecentAdsShown() runs whenever the Recent ads page shows;
-- options.loadGeometry() returns saved geometry or nil;
-- options.saveGeometry(state) stores it;
-- options.onToggleGroup(playerId) runs when a player header is clicked;
-- options.onRescan() runs when the Rescan button is clicked;
-- options.onAcceptConflict(character, kind), onRejectConflict(character,
-- kind), onAcceptAll(), and onRejectAll() resolve conflicts;
-- options.onToggleDeparted() returns whether departed characters are now
-- shown, and options.onPurge(key) / onPurgeAll() purge them;
-- options.menuFor(row) lists a row's organize actions, and onSetMain(key,
-- playerId), onMakeMain(key), onSetAlias(key, text), onDetach(key),
-- searchPlayers(key, query), aliasOf(key), and onMenuUnavailable() run them;
-- options.onSearch(text), onToggleOnlineOnly(), onExpandAll(), and
-- onCollapseAll() drive the controls row; options.onSelectCharacter(key)
-- opens a player's edit panel and onClosePanel() runs when it closes;
-- options.onSetDontSync(key, enabled) runs the panel's "Don't sync" toggle.
function RosterWindow.Create(client, options)
    local framework = frameworkFrom(client)
    if framework == nil then
        return nil, "the Details! Framework is not available"
    end

    local ok, host, scroll, status, conflicts, playerPanel, recruiters, recentAds = pcall(build, framework, options)
    if not ok or host == nil then
        return nil, "the Details! Framework could not build the window"
    end
    return setmetatable({
        host = host,
        panel = host.panel,
        scroll = scroll,
        status = status,
        conflicts = conflicts,
        playerPanel = playerPanel,
        recruiters = recruiters,
        recentAds = recentAds,
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
        conflicts.scroll:SetData(rows)
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

-- Shows the Recent ads page's rows (see RosterController:RecentAdsView).
-- False when the frame has no Recent ads page.
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

-- Shows the edit panel for a player (see PlayerPanelViewModel).
function Window:ShowPlayer(model)
    return (pcall(function()
        local edit = self.playerPanel
        edit.model = model
        if type(edit.panel.SetTitle) == "function" then
            edit.panel:SetTitle(model.dontSync and (model.label .. " |cffff8000(Don't sync)|r") or model.label)
        end
        edit.aliasText:SetText(model.alias and ("Alias: " .. model.alias) or "|cff9d9d9dNo alias|r")
        edit.aliasSource:SetText(model.alias and model.aliasSource and ("Alias " .. model.aliasSource) or "")
        edit.dontSync:SetChecked(model.dontSync == true)
        edit.dontSyncLabel:SetText(model.dontSync and "|cffff8000Don't sync: kept as yours|r" or "Don't sync")
        edit.scroll:SetData(model.rows)
        edit.scroll:Refresh()
        edit.panel:Show()
    end))
end

function Window:HidePlayer()
    return (pcall(function()
        self.playerPanel.model = nil
        self.playerPanel.panel:Hide()
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
