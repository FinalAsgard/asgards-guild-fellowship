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
-- Discord is the player's, so it shows on a player's header (or a lone
-- character's row), not on each alt.
local COLUMNS = {
    { field = "name", header = "Name", x = 8, width = 200 },
    { field = "level", header = "Level", x = 214, width = 40 },
    { field = "rank", header = "Rank", x = 258, width = 100 },
    { field = "discord", header = "Discord", x = 364, width = 120 },
    { field = "location", header = "Zone / Last online", x = 490, width = 140 },
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
        if field == "discord" then
            return row.discord or ""
        end
        return ""
    end
    if field == "name" then
        local text
        if row.standalone then
            -- A declared main on its own is a confirmed player, unlike a
            -- character nobody has organized.
            text = row.coloredLabel .. (row.declared and "  |cff9d9d9d(declared main)|r" or "")
        elseif row.declared then
            text = row.coloredName .. "  |cff9d9d9d(declared main)|r"
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
    -- Officers see who is ready for promotion (see RosterViewModel.MarkReady).
    if field == "rank" and row.ready then
        -- First, so a long rank name never hides it.
        return "|cff40ff40Ready|r " .. tostring(row.rank or "")
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

-- A one-line text dialog, registered as `id`: `prompt` names `label` (%s),
-- the box starts with `current` and holds at most `maxLetters`.
local function showTextDialog(id, prompt, maxLetters, label, current, onSave)
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
        return false
    end
    local name = addon.Identity.addonName .. "_" .. id
    if StaticPopupDialogs[name] == nil then
        local function save(popup, data)
            local box = popupEditBox(popup)
            if box ~= nil and data ~= nil then
                data.onSave(box:GetText())
            end
        end
        StaticPopupDialogs[name] = {
            text = prompt,
            button1 = ACCEPT or "Accept",
            button2 = CANCEL or "Cancel",
            hasEditBox = true,
            maxLetters = maxLetters,
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

-- A text dialog for "Set alias…". Saving an empty alias clears it.
local function showAliasDialog(label, current, onSave)
    return showTextDialog("SET_ALIAS", "Alias for %s (leave empty to clear):", 48, label, current, onSave)
end

-- A text dialog for "Set Discord…". Saving empty clears it.
local function showDiscordDialog(label, current, onSave)
    return showTextDialog("SET_DISCORD", "Discord username for %s (leave empty to clear):",
        addon.FellowshipStore.PROFILE_FIELDS.discord, label, current, onSave)
end

local PICKER_WIDTH = 360
local PICKER_HEIGHT = 380

-- The player picker ("Link as alt of…" and "Merge into player…"): a search
-- box and the matching players.
local function buildPicker(framework, frameName)
    local panel = framework:CreateSimplePanel(UIParent, PICKER_WIDTH, PICKER_HEIGHT, "Link as alt of", frameName .. "Picker")
    -- Like every panel here, closed only with its close button or Escape.
    panel.DontRightClickClose = true
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
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, 12)
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
-- The action bar along the panel's bottom: its buttons' gap from the edge,
-- and the room the list leaves for it.
local PANEL_BAR_MARGIN = 10
local PANEL_BAR_HEIGHT = 40

-- `actions.openSetAlias(key, title)` and `actions.openSetMain(key, name,
-- merge)` open the dialogs the right-click menu uses (`merge` titles the
-- picker "Merge into player"); `actions.openSetDiscord(key, title,
-- current)` opens the "Set Discord…" dialog.
local function buildPlayerPanel(framework, options, frameName, anchor, actions)
    local panel = framework:CreateSimplePanel(UIParent, PANEL_WIDTH, PANEL_HEIGHT, "Player", frameName .. "Player")
    -- Like every panel here, closed only with its close button or Escape.
    panel.DontRightClickClose = true
    panel:SetFrameStrata("HIGH")
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", addon.MasterFrame.SIDE_OFFSET, 0)
    local edit = { panel = panel }

    -- "Don't sync": keep this client's own version of the player.
    local dontSync = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    dontSync:SetSize(20, 20)
    dontSync:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -160, -28)
    local dontSyncLabel = dontSync:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dontSyncLabel:SetPoint("LEFT", dontSync, "RIGHT", 2, 0)
    dontSync:SetScript("OnClick", function(button)
        if edit.model ~= nil then
            options.onSetDontSync(edit.model.main, button:GetChecked() == true)
        end
    end)
    edit.dontSync = dontSync
    edit.dontSyncLabel = dontSyncLabel

    -- The alias and where it came from, beside "Don't sync".
    local aliasText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    aliasText:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -32)
    aliasText:SetPoint("RIGHT", dontSync, "LEFT", -8, 0)
    aliasText:SetJustifyH("LEFT")
    aliasText:SetWordWrap(false)
    local aliasSource = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    aliasSource:SetPoint("TOPLEFT", aliasText, "BOTTOMLEFT", 0, -6)

    -- The action bar along the bottom: Set alias… and Merge into player…,
    -- which open the same dialogs as the right-click menu, with Set
    -- Discord… between them (official for an officer, a suggestion for a
    -- member). Its buttons sit left to right in `edit.actions` order.
    local setAlias = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    setAlias:SetSize(84, 20)
    setAlias:SetText("Set alias...")
    local setDiscord = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    setDiscord:SetSize(100, 20)
    setDiscord:SetText("Set Discord...")
    local setMain = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    setMain:SetSize(124, 20)
    setMain:SetText("Merge into player...")
    edit.actions = { setAlias, setDiscord, setMain }
    local actionIndex
    for actionIndex = 1, #edit.actions do
        local button = edit.actions[actionIndex]
        if actionIndex == 1 then
            button:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, PANEL_BAR_MARGIN)
        else
            button:SetPoint("LEFT", edit.actions[actionIndex - 1], "RIGHT", 4, 0)
        end
    end
    setAlias:SetScript("OnClick", function()
        if edit.model ~= nil then
            actions.openSetAlias(edit.model.main, edit.model.label)
        end
    end)
    setDiscord:SetScript("OnClick", function()
        if edit.model ~= nil then
            actions.openSetDiscord(edit.model.main, edit.model.label, edit.model.discord)
        end
    end)
    setMain:SetScript("OnClick", function()
        if edit.model ~= nil then
            actions.openSetMain(edit.model.main, edit.model.mainName, true)
        end
    end)
    edit.aliasText = aliasText
    edit.aliasSource = aliasSource
    edit.setMain = setMain

    local lineAmount = math.floor((PANEL_HEIGHT - 72 - PANEL_BAR_HEIGHT) / RosterWindow.LINE_HEIGHT)
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
        -- A promotion row's button: Tick, Untick, Override and Undo override
        -- work here; a note, a reason, or a promotion with unmet items opens
        -- the character on the Promotions tab instead.
        line.act = CreateFrame("Button", nil, line, "UIPanelButtonTemplate")
        line.act:SetSize(96, 18)
        line.act:SetPoint("RIGHT", line, "RIGHT", -2, 0)
        line.act:SetScript("OnClick", function()
            local row = line.row
            if row == nil or row.kind ~= "promotion" then
                return
            end
            local function call(handler, ...)
                if options[handler] ~= nil then
                    pcall(options[handler], ...)
                end
            end
            if row.promote then
                call(row.confirm and "onPromotionsFocus" or "onPromotionsPromote", row.key)
            elseif not row.ticked and (row.needsNote or row.askReason) then
                call("onPromotionsFocus", row.key)
            else
                call("onPromotionsTick", row.key, row.item, not row.ticked)
            end
        end)
        line.act:SetScript("OnEnter", function(self)
            local tooltip = line.row and line.row.tooltip
            if tooltip ~= nil and GameTooltip ~= nil then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local index
                for index = 1, #tooltip do
                    GameTooltip:AddLine(tooltip[index], 1, 1, 1, true)
                end
                GameTooltip:Show()
            end
        end)
        line.act:SetScript("OnLeave", function()
            if GameTooltip ~= nil then
                GameTooltip:Hide()
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
                elseif row.kind == "about" then
                    text = "  " .. row.text
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
                elseif row.kind == "promotion" then
                    text = "  " .. row.text
                end
                -- Only character rows and promotion rows with an action have
                -- buttons; the others' text uses the line's full width.
                local acts = row.kind == "promotion" and row.action ~= nil
                line.text:ClearAllPoints()
                line.text:SetPoint("LEFT", line, "LEFT", 6, 0)
                line.text:SetPoint("RIGHT", line, "RIGHT", row.kind == "character" and -128 or (acts and -100 or -6), 0)
                line.text:SetText(text)
                if acts then
                    line.act:SetText(row.action)
                    line.act:Show()
                else
                    line.act:Hide()
                end
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
        PANEL_WIDTH - 20, PANEL_HEIGHT - 72 - PANEL_BAR_HEIGHT, lineAmount, RosterWindow.LINE_HEIGHT, newLine, true)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -72)
    -- Room on the right for the scroll bar, which sits beside the list, and
    -- below for the action bar.
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, PANEL_BAR_HEIGHT)
    scroll:CreateLines(newLine, lineAmount)
    edit.scroll = scroll
    -- Measures text in the lines' font, to wrap the bio to their width.
    local measure = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    measure:Hide()
    edit.measure = measure

    panel:HookScript("OnHide", function()
        if edit.model ~= nil then
            edit.model = nil
            options.onClosePanel()
        end
    end)
    panel:Hide()
    return edit
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

-- The officers' Guild Log page: every entry newest first, with its date,
-- what happened, the character, its player, and who did it.
local GUILD_LOG_COLUMNS = {
    { field = "date", x = 8, width = 84 },
    { field = "event", x = 96, width = 170 },
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
        label:SetText(GUILD_LOG_TYPE_LABELS[eventType])
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

-- The Promotions list's columns.
local PROMOTION_COLUMNS = {
    { field = "character", x = 8, width = 230 },
    { field = "ranks", x = 242, width = 160 },
    { field = "progress", x = 406, width = 80 },
    { field = "highest", x = 490, width = 120 },
    { field = "button", x = 614, width = 1, action = true },
}

-- The officers' Promotions page, below the frame's title bar. It opens on
-- the list, one page at a time, under a search box, Ready and In progress
-- filters, page buttons, and a filter per rank: each character at a rank
-- with requirements, its ranks,
-- progress and its player's highest rank; Open shows its checklist, where
-- Tick and Untick work each item (an item that needs a note asks for one
-- first, in the page), an automated item shows its detail with Override
-- (asking for an optional reason) or Undo override, and hovering a tick or
-- override says who made it, when, and the note or reason. Edit
-- requirements switches to the editor: < and > pick a rank, a warning
-- shows when the rank was set up under another name, a box adds an item
-- (its kind button steps through the kinds; an automated kind takes a
-- number) or edits one's label and number, and each item has Up, Down,
-- Edit and Delete. Delete asks first, in the page itself. Each control calls
-- its `options` handler, which returns true, or false and why not (shown
-- in the page); SetPromotions shows the models (see
-- PromotionsViewModel.Editor and List).
local function buildPromotions(framework, page, frameName, options)
    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -28)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 10)
    local listHolder = CreateFrame("Frame", nil, page)
    listHolder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -28)
    listHolder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 10)
    local editor = { rows = {} }
    local function call(handler, ...)
        local callback = options[handler]
        if callback == nil then
            return
        end
        local ok, done, reason = pcall(callback, ...)
        local text = ""
        if ok and done == false then
            text = "|cffff8040" .. tostring(reason or "That didn't work") .. ".|r"
        end
        editor.message:SetText(text)
        if editor.listMessage ~= nil then
            editor.listMessage:SetText(text)
        end
        return ok and done ~= false
    end
    local previous = smallButton(holder, 24, "<", function()
        call("onPromotionsRank", -1)
    end)
    previous:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -2)
    editor.rankText = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    editor.rankText:SetPoint("LEFT", previous, "RIGHT", 8, 0)
    editor.rankText:SetWidth(220)
    editor.rankText:SetJustifyH("LEFT")
    local nextButton = smallButton(holder, 24, ">", function()
        call("onPromotionsRank", 1)
    end)
    nextButton:SetPoint("LEFT", editor.rankText, "RIGHT", 8, 0)
    editor.nextText = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editor.nextText:SetPoint("LEFT", nextButton, "RIGHT", 12, 0)
    editor.mismatch = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editor.mismatch:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -28)
    editor.mismatch:SetWidth(680)
    editor.mismatch:SetJustifyH("LEFT")

    local box = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    box:SetSize(240, 20)
    box:SetPoint("TOPLEFT", holder, "TOPLEFT", 22, -50)
    box:SetAutoFocus(false)
    box:SetMaxLetters(addon.RankRequirements.MAX_LABEL)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    editor.box = box
    -- The new item's kind: each click steps to the next one. An automated
    -- kind shows the number box (its days, or the level).
    local kindIndex = 1
    local numberBox = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    numberBox:SetSize(40, 20)
    numberBox:SetAutoFocus(false)
    numberBox:SetMaxLetters(4)
    numberBox:SetNumeric(true)
    numberBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    editor.numberBox = numberBox
    local kindButton = smallButton(holder, 170, "", nil)
    kindButton:SetPoint("LEFT", box, "RIGHT", 8, 0)
    numberBox:SetPoint("LEFT", kindButton, "RIGHT", 10, 0)
    local function showKind()
        local kind = addon.RankRequirements.KIND_ORDER[kindIndex]
        kindButton:SetText(addon.RankRequirements.KINDS[kind])
        if addon.RankRequirements.IsAutomated(kind) then
            numberBox:Show()
        else
            numberBox:Hide()
        end
    end
    kindButton:SetScript("OnClick", function()
        kindIndex = kindIndex % #addon.RankRequirements.KIND_ORDER + 1
        showKind()
    end)
    showKind()
    editor.kindButton = kindButton
    local function stopRenaming()
        editor.renaming = nil
        editor.save:SetText("Add")
        editor.cancel:Hide()
        kindButton:Show()
        showKind()
        box:SetText("")
        numberBox:SetText("")
    end
    editor.save = smallButton(holder, 70, "Add", function()
        local text = box:GetText()
        local number = numberBox:IsShown() and numberBox:GetText() or nil
        local done
        if editor.renaming ~= nil then
            done = call("onPromotionsRename", editor.renaming, text, number)
        else
            done = call("onPromotionsAdd", text, addon.RankRequirements.KIND_ORDER[kindIndex], number)
        end
        if done then
            stopRenaming()
            box:ClearFocus()
            numberBox:ClearFocus()
        end
    end)
    editor.save:SetPoint("LEFT", kindButton, "RIGHT", 58, 0)
    numberBox:SetScript("OnEnterPressed", function()
        editor.save:Click()
    end)
    box:SetScript("OnEnterPressed", function()
        editor.save:Click()
    end)
    editor.cancel = smallButton(holder, 70, "Cancel", stopRenaming)
    editor.cancel:SetPoint("LEFT", editor.save, "RIGHT", 6, 0)
    editor.cancel:Hide()
    editor.message = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editor.message:SetPoint("TOPLEFT", holder, "TOPLEFT", 22, -74)
    editor.message:SetWidth(680)
    editor.message:SetJustifyH("LEFT")

    -- Asking before a delete, in the page.
    local confirm = CreateFrame("Frame", nil, holder)
    confirm:SetSize(680, 24)
    confirm:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -90)
    confirm.text = confirm:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    confirm.text:SetPoint("LEFT", confirm, "LEFT", 0, 0)
    confirm.text:SetWidth(470)
    confirm.text:SetJustifyH("LEFT")
    local yes = smallButton(confirm, 80, "Delete", function()
        local id = confirm.id
        confirm:Hide()
        if id ~= nil then
            call("onPromotionsDelete", id)
        end
    end)
    yes:SetPoint("LEFT", confirm.text, "RIGHT", 8, 0)
    local no = smallButton(confirm, 70, "Cancel", function()
        confirm:Hide()
    end)
    no:SetPoint("LEFT", yes, "RIGHT", 6, 0)
    confirm:Hide()
    editor.confirm = confirm

    editor.empty = holder:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    editor.empty:SetPoint("TOPLEFT", holder, "TOPLEFT", 22, -120)
    editor.empty:SetWidth(660)
    editor.empty:SetJustifyH("LEFT")
    local index
    for index = 1, addon.RankRequirements.MAX_ITEMS do
        local row = CreateFrame("Frame", nil, holder)
        row:SetSize(700, RosterWindow.LINE_HEIGHT)
        row:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -118 - (index - 1) * RosterWindow.LINE_HEIGHT)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.label:SetWidth(260)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.kind = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.kind:SetPoint("LEFT", row, "LEFT", 272, 0)
        row.kind:SetWidth(180)
        row.kind:SetJustifyH("LEFT")
        row.up = smallButton(row, 44, "Up", function()
            call("onPromotionsMove", row.item.id, -1)
        end)
        row.up:SetPoint("LEFT", row, "LEFT", 458, 0)
        row.down = smallButton(row, 50, "Down", function()
            call("onPromotionsMove", row.item.id, 1)
        end)
        row.down:SetPoint("LEFT", row.up, "RIGHT", 2, 0)
        row.rename = smallButton(row, 64, "Edit", function()
            editor.renaming = row.item.id
            box:SetText(row.item.label)
            box:SetFocus()
            editor.save:SetText("Save")
            editor.cancel:Show()
            kindButton:Hide()
            if row.item.n ~= nil then
                numberBox:SetText(tostring(row.item.n))
                numberBox:Show()
            else
                numberBox:Hide()
            end
        end)
        row.rename:SetPoint("LEFT", row.down, "RIGHT", 2, 0)
        row.delete = smallButton(row, 60, "Delete", function()
            confirm.id = row.item.id
            confirm.text:SetText("Delete \"" .. row.item.label .. "\"? Its ticks are dropped too.")
            confirm:Show()
        end)
        row.delete:SetPoint("LEFT", row.rename, "RIGHT", 2, 0)
        row:Hide()
        editor.rows[index] = row
    end

    -- The list's controls: a search box, Ready and In progress check
    -- boxes, page buttons, and below them a check box per rank with
    -- requirements (made as SetPromotions names them).
    local controls = { ranks = {} }
    editor.controls = controls
    local search = CreateFrame("EditBox", nil, listHolder, "InputBoxTemplate")
    search:SetSize(150, 20)
    search:SetPoint("TOPLEFT", listHolder, "TOPLEFT", 22, -2)
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
        call("onPromotionsSearch", text)
    end)
    search:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    search:SetScript("OnEnterPressed", function(box)
        box:ClearFocus()
    end)
    controls.search = search
    local function filterBox(text, x, y, onClick)
        local check = CreateFrame("CheckButton", nil, listHolder, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", listHolder, "TOPLEFT", x, y)
        check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        check.text:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check.text:SetWidth(64)
        check.text:SetJustifyH("LEFT")
        check.text:SetWordWrap(false)
        check.text:SetText(text)
        check:SetScript("OnClick", onClick)
        return check
    end
    controls.ready = filterBox("Ready", 184, -1, function(box)
        call("onPromotionsFilter", "ready", box:GetChecked() == true)
    end)
    controls.progress = filterBox("In progress", 254, -1, function(box)
        call("onPromotionsFilter", "progress", box:GetChecked() == true)
    end)
    controls.previous = smallButton(listHolder, 24, "<", function()
        if controls.state ~= nil then
            call("onPromotionsPage", controls.state.page - 1)
        end
    end)
    controls.previous:SetPoint("TOPLEFT", listHolder, "TOPLEFT", 350, -2)
    controls.pageText = listHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    controls.pageText:SetPoint("LEFT", controls.previous, "RIGHT", 6, 0)
    controls.pageText:SetWidth(150)
    controls.next = smallButton(listHolder, 24, ">", function()
        if controls.state ~= nil then
            call("onPromotionsPage", controls.state.page + 1)
        end
    end)
    controls.next:SetPoint("LEFT", controls.pageText, "RIGHT", 6, 0)
    -- The check box for the `index`th rank, made the first time it's needed.
    controls.rankBox = function(index)
        if controls.ranks[index] == nil then
            local check
            check = filterBox("", 16 + (index - 1) * 86, -24, function(box)
                if check.rank ~= nil then
                    call("onPromotionsFilter", check.rank, box:GetChecked() == true)
                end
            end)
            controls.ranks[index] = check
        end
        return controls.ranks[index]
    end

    -- The list, with the note prompt above it.
    local listArea = CreateFrame("Frame", nil, listHolder)
    listArea:SetPoint("TOPLEFT", listHolder, "TOPLEFT", 0, -46)
    listArea:SetPoint("BOTTOMRIGHT", listHolder, "BOTTOMRIGHT", 0, 0)
    local width, height = page:GetSize()
    local lines = math.max(1, math.floor((height - 156) / RosterWindow.LINE_HEIGHT))
    local noteBar = CreateFrame("Frame", nil, listArea)
    noteBar:SetSize(560, 24)
    noteBar:SetPoint("TOPLEFT", listArea, "TOPLEFT", 120, 0)
    noteBar.text = noteBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    noteBar.text:SetPoint("LEFT", noteBar, "LEFT", 0, 0)
    noteBar.text:SetWidth(150)
    noteBar.text:SetJustifyH("LEFT")
    noteBar.text:SetWordWrap(false)
    local noteBox = CreateFrame("EditBox", nil, noteBar, "InputBoxTemplate")
    noteBox:SetSize(240, 20)
    noteBox:SetPoint("LEFT", noteBar.text, "RIGHT", 8, 0)
    noteBox:SetAutoFocus(false)
    noteBox:SetMaxLetters(addon.PromotionChecks.MAX_NOTE)
    local function tickWithNote()
        local row = noteBar.row
        if row ~= nil and call("onPromotionsTick", row.key, row.item, true, noteBox:GetText()) then
            noteBar:Hide()
        end
    end
    noteBox:SetScript("OnEnterPressed", tickWithNote)
    noteBox:SetScript("OnEscapePressed", function()
        noteBar:Hide()
    end)
    local tick = smallButton(noteBar, 70, "Tick", tickWithNote)
    tick:SetPoint("LEFT", noteBox, "RIGHT", 6, 0)
    local cancelNote = smallButton(noteBar, 60, "Cancel", function()
        noteBar:Hide()
    end)
    cancelNote:SetPoint("LEFT", tick, "RIGHT", 4, 0)
    noteBar:Hide()
    editor.noteBar = noteBar
    -- Asking before promoting a character with unmet items, in the page.
    local promoteBar = CreateFrame("Frame", nil, listArea)
    promoteBar:SetSize(560, 24)
    promoteBar:SetPoint("TOPLEFT", listArea, "TOPLEFT", 120, 0)
    promoteBar.text = promoteBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    promoteBar.text:SetPoint("LEFT", promoteBar, "LEFT", 0, 0)
    promoteBar.text:SetWidth(380)
    promoteBar.text:SetJustifyH("LEFT")
    promoteBar.text:SetWordWrap(false)
    local promoteYes = smallButton(promoteBar, 110, "Promote", function()
        local key = promoteBar.key
        promoteBar:Hide()
        if key ~= nil then
            call("onPromotionsPromote", key)
        end
    end)
    promoteYes:SetPoint("LEFT", promoteBar.text, "RIGHT", 6, 0)
    local promoteNo = smallButton(promoteBar, 60, "Cancel", function()
        promoteBar:Hide()
    end)
    promoteNo:SetPoint("LEFT", promoteYes, "RIGHT", 4, 0)
    promoteBar:Hide()
    editor.promoteBar = promoteBar
    editor.list = buildList(framework, listArea, frameName .. "PromotionsScroll", "Promotions",
        PROMOTION_COLUMNS, width - 16 - RosterWindow.SCROLL_BAR_ROOM, lines, function(row)
            if row.kind == "character" then
                call("onPromotionsExpand", row.key)
            elseif row.kind == "promote" then
                noteBar:Hide()
                if row.confirm ~= nil then
                    promoteBar.key = row.key
                    promoteBar.text:SetText(row.confirm)
                    promoteYes:SetText(row.action)
                    promoteBar:Show()
                else
                    call("onPromotionsPromote", row.key)
                end
            elseif row.kind == "item" then
                promoteBar:Hide()
                if not row.ticked and (row.needsNote or row.askReason) then
                    noteBar.row = row
                    if row.askReason then
                        noteBar.text:SetText("Reason (optional):")
                        tick:SetText("Override")
                    else
                        noteBar.text:SetText("Note for " .. tostring(row.label) .. ":")
                        tick:SetText("Tick")
                    end
                    noteBox:SetText("")
                    noteBar:Show()
                    noteBox:SetFocus()
                else
                    call("onPromotionsTick", row.key, row.item, not row.ticked)
                end
            end
        end)
    editor.list.scroll:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", -RosterWindow.SCROLL_BAR_ROOM, 24)
    editor.listMessage = listHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    editor.listMessage:SetPoint("BOTTOMLEFT", listHolder, "BOTTOMLEFT", 16, 4)
    editor.listMessage:SetWidth(680)
    editor.listMessage:SetJustifyH("LEFT")

    -- Switching between the list and the editor.
    local mode = smallButton(page, 130, "Edit requirements", nil)
    mode:SetPoint("TOPRIGHT", page, "TOPRIGHT", -20, -30)
    local function showList(list)
        if list then
            holder:Hide()
            listHolder:Show()
            mode:SetText("Edit requirements")
        else
            listHolder:Hide()
            holder:Show()
            mode:SetText("Back to list")
        end
    end
    mode:SetScript("OnClick", function()
        showList(not listHolder:IsShown())
    end)
    showList(true)
    return editor
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

-- The guild-size counts line: its text, and on hover a tooltip with the
-- breakdown. Made with `environment`'s CreateFrame and GameTooltip, so
-- specs can draw it with fake frames. Hidden until :Set gives it text.
local CountsLine = {}
CountsLine.__index = CountsLine

function RosterWindow.CountsLine(environment, parent)
    local frame = environment.CreateFrame("Frame", nil, parent)
    frame:SetHeight(14)
    frame:EnableMouse(true)
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", frame, "LEFT", 0, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    local line = setmetatable({ environment = environment, frame = frame, text = text, lines = {} }, CountsLine)
    frame:SetScript("OnEnter", function()
        line.hovering = true
        line:ShowTooltip()
    end)
    frame:SetScript("OnLeave", function()
        line.hovering = false
        local tooltip = environment.GameTooltip
        if tooltip ~= nil then
            pcall(tooltip.Hide, tooltip)
        end
    end)
    frame:Hide()
    return line
end

-- Shows `text` with tooltip `lines` (see RosterViewModel.CountsTooltip), or,
-- for nil, hides the line. A tooltip already showing is redrawn.
function CountsLine:Set(text, lines)
    if text == nil then
        self.frame:Hide()
        return
    end
    self.text:SetText(text)
    -- Only the text is hoverable.
    self.frame:SetWidth((self.text:GetStringWidth() or 0) + 4)
    self.lines = lines or {}
    self.frame:Show()
    if self.hovering then
        self:ShowTooltip()
    end
end

function CountsLine:ShowTooltip()
    local tooltip = self.environment.GameTooltip
    if tooltip == nil then
        return
    end
    pcall(function()
        tooltip:SetOwner(self.frame, "ANCHOR_BOTTOMRIGHT")
        -- The first line is the tooltip's title.
        tooltip:AddLine(self.lines[1])
        local index
        for index = 2, #self.lines do
            tooltip:AddLine(self.lines[index], 1, 1, 1)
        end
        tooltip:Show()
    end)
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
    -- The officers' Promotions page, when the frame has one.
    local promotions
    local promotionsPage = host:Content("promotions")
    if promotionsPage ~= nil then
        local built, editor = pcall(buildPromotions, framework, promotionsPage, frameName, options)
        promotions = built and editor or nil
        if options.onPromotionsShown ~= nil then
            promotionsPage:HookScript("OnShow", options.onPromotionsShown)
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
    placeholder:SetText("Search names, aliases and Discord")
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

    -- How big the guild is, under the controls.
    local counts = RosterWindow.CountsLine(_G, panel)
    counts.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -58)

    local headerIndex
    for headerIndex = 1, #COLUMNS do
        local column = COLUMNS[headerIndex]
        local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", panel, "TOPLEFT", 10 + column.x, -76)
        header:SetText(column.header)
    end

    -- Enough lines for the frame's restored height.
    local width, height = frame:GetSize()
    local lineAmount = math.floor((height - 138) / RosterWindow.LINE_HEIGHT)
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
    local function openSetDiscord(key, title, current)
        if not showDiscordDialog(title, current, function(text)
            options.onSetDiscord(key, text)
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
        height - 138,
        lineAmount,
        RosterWindow.LINE_HEIGHT,
        newLine,
        true
    )
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -92)
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
        openSetDiscord = openSetDiscord,
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

    return host, scroll, status, conflicts, playerPanel, recruiters, recentAds, counts
end

-- options.navigator is the PageNavigator with the master frame's pages;
-- options.drawPages maps a page id to function(content, framework) that
-- draws that page into its content frame (the Roster page is drawn here);
-- the Recruitment page's returns a frame LEADERBOARD_HEIGHT tall below its
-- settings, where the officers' leaderboard is drawn;
-- options.onHide() runs whenever the frame closes;
-- options.onRecentAdsShown() runs whenever the Recent ads page shows, and
-- options.onTurnBackOn(zoneKey) when a zone's "Turn back on" is pressed;
-- options.loadGeometry() returns saved geometry or nil;
-- options.saveGeometry(state) stores it;
-- options.onToggleGroup(playerId) runs when a player header is clicked;
-- options.onRescan() runs when the Rescan button is clicked;
-- options.onAcceptConflict(character, kind), onRejectConflict(character,
-- kind), onAcceptAll(), and onRejectAll() resolve conflicts;
-- options.onReviewBundle(group), onDecideBundle(group, approved) and
-- onCloseReview() drive the review of a member's bundle of suggestions;
-- options.onToggleDeparted() returns whether departed characters are now
-- shown, and options.onPurge(key) / onPurgeAll() purge them;
-- options.menuFor(row) lists a row's organize actions, and onSetMain(key,
-- playerId), onMakeMain(key), onSetAlias(key, text), onDetach(key),
-- onSetDiscord(key, text) (from the player panel),
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

    local ok, host, scroll, status, conflicts, playerPanel, recruiters, recentAds, counts =
        pcall(build, framework, options)
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
        guildLog = guildLog,
        promotions = promotions,
        counts = counts,
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

-- Shows the Recent ads page's rows (see RosterController:RecentAdsView).
-- False when the frame has no Recent ads page.
-- Shows the Promotions page's editor model, list rows, and where the list's
-- controls stand, with the ready count on its tab (see
-- PromotionsViewModel.Editor, List and Controls). False when the frame has
-- no Promotions page.
function Window:SetPromotions(model, rows, state)
    local editor = self.promotions
    if editor == nil or type(model) ~= "table" then
        return false
    end
    return (pcall(function()
        if rows ~= nil then
            editor.list.scroll:SetData(rows)
            editor.list.scroll:Refresh()
        end
        local controls = editor.controls
        if state ~= nil and controls ~= nil then
            controls.state = state
            controls.ready:SetChecked(state.ready)
            controls.progress:SetChecked(state.progress)
            controls.pageText:SetText(state.pageText)
            if state.page > 1 then controls.previous:Enable() else controls.previous:Disable() end
            if state.page < state.pages then controls.next:Enable() else controls.next:Disable() end
            local index
            for index = 1, math.max(#state.ranks, #controls.ranks) do
                local rank = state.ranks[index]
                if rank == nil then
                    controls.ranks[index]:Hide()
                else
                    local check = controls.rankBox(index)
                    check.rank = rank.rank
                    check.text:SetText(rank.name)
                    check:SetChecked(rank.shown)
                    check:Show()
                end
            end
            if self.host ~= nil and type(self.host.SetLabel) == "function" then
                self.host:SetLabel("promotions", state.tabLabel, state.badge)
            end
        end
        editor.rankText:SetText(model.rankText or "")
        editor.nextText:SetText(model.nextText or "")
        editor.mismatch:SetText(model.mismatch and ("|cffff8040" .. model.mismatch .. "|r") or "")
        editor.empty:SetText(model.empty or "")
        if editor.confirm.id ~= nil and editor.confirm:IsShown() then
            local found = false
            local itemIndex
            for itemIndex = 1, #model.items do
                found = found or model.items[itemIndex].id == editor.confirm.id
            end
            if not found then
                editor.confirm:Hide()
            end
        end
        local index
        for index = 1, #editor.rows do
            local row, item = editor.rows[index], model.items[index]
            row.item = item
            if item == nil then
                row:Hide()
            else
                row.label:SetText(item.label)
                row.kind:SetText(item.kindText or "")
                if item.canUp then row.up:Enable() else row.up:Disable() end
                if item.canDown then row.down:Enable() else row.down:Disable() end
                row:Show()
            end
        end
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

-- The bio's lines as they fit the player panel: `text` wrapped at spaces
-- to the width an about row's text has, measured in its font. Without a
-- way to measure, lines of PlayerPanelViewModel.BIO_LINE bytes.
function Window:WrapAbout(text)
    local measure = self.playerPanel and self.playerPanel.measure
    if measure == nil or type(measure.GetStringWidth) ~= "function" then
        return addon.PlayerPanelViewModel.Wrap(text, addon.PlayerPanelViewModel.BIO_LINE)
    end
    -- The list's width, less the line's inset from it, the text's margins
    -- and the two spaces an about row starts with.
    local width = PANEL_WIDTH - 10 - RosterWindow.SCROLL_BAR_ROOM - 20 - 12
    measure:SetText("  ")
    width = width - (measure:GetStringWidth() or 0)
    return addon.PlayerPanelViewModel.Wrap(text, width, function(part)
        measure:SetText(part)
        return measure:GetStringWidth() or 0
    end)
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
        -- A player with alts can't be merged into another.
        if model.canMerge then
            edit.setMain:Enable()
        else
            edit.setMain:Disable()
        end
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

-- Shows the guild-size counts line (see RosterViewModel.CountsText) with
-- its tooltip `lines`, or, for nil, hides it.
function Window:SetCounts(text, lines)
    self.counts:Set(text, lines)
end

-- Returns false instead of raising when the framework misbehaves.
function Window:SetRows(rows)
    return (pcall(function()
        self.scroll:SetData(rows)
        self.scroll:Refresh()
    end))
end
