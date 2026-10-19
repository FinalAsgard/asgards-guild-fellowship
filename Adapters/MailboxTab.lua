local _, addon = ...

-- The Guild Mail tab on the game's mailbox, after Inbox and Send Mail
-- (officers only). Its page lists the officer's guild mails: the draft
-- with Edit, then each outbox entry, newest first, with its progress and
-- state and View, Resume, Cancel and Remove. New starts a blank mail. A
-- question (cancel, remove, discard the draft) waits at the bottom for Yes
-- or No. Edit, New and View open the Guild Mail window, where the mail is
-- managed. Welcome mail, beside New, opens the guild's welcome mail
-- settings (GuildWelcome) in the window. The Welcome mails row (due welcomes, see GuildWelcome) has Edit
-- (the welcome mail's settings), View and Send, and the tab's title counts
-- the welcomes waiting: "Guild Mail (3)".
--
-- The tab copies the Send Mail tab's template and spacing; clicking it
-- hides the Inbox and Send Mail pages and shows this one over the inbox's
-- place, and clicking either of the game's tabs (their OnClick, and
-- MailFrameTab_OnClick) or the mailbox opening again hides it. Nothing of the game's is replaced. It only draws
-- GuildMail's OutboxModel and passes clicks back. Frames are made on first
-- use; a failing frame call leaves things as they were rather than raising.
local MailboxTab = {
    TAB_TEXT = "Guild Mail",
    -- The game's tab templates, newest client first.
    TAB_TEMPLATES = { "PanelTabButtonTemplate", "FriendsFrameTabTemplate", "CharacterFrameTabButtonTemplate" },
    PADDING = 10,
    -- Two lines of text, then the buttons below them.
    ROW_HEIGHT = 64,
    -- Rows made up front: the page shows this many; the list scrolls.
    LIST_HEIGHT = 300,
    BUTTON_WIDTH = 56,
    BUTTON_HEIGHT = 20,
    WELCOME_WIDTH = 96,
    -- Without the mailbox's content area (MailFrame.Inset), the page keeps
    -- this far inside the inbox's place: clear of the title bar and the
    -- mail icon at the top left.
    PAGE_TOP = 64,
    PAGE_SIDE = 8,
}
addon.MailboxTab = MailboxTab

local Tab = {}
Tab.__index = Tab

-- handlers (each optional):
--   onNew(), onEdit(), onView(position), onResume(position),
--   onCancel(position), onRemove(position)   a row's buttons; `position`
--                is the entry's place in the outbox
--   onConfirm(), onDismiss()   Yes and No on the question
--   onEditWelcome(), onSendWelcomes()   the Welcome mail button (and the
--                Welcome mails row's Edit), and the row's Send
--   onShown()    the page was shown (draw it)
function MailboxTab.Create(client, handlers)
    handlers = handlers or {}
    local function handler(name)
        return type(handlers[name]) == "function" and handlers[name] or function() end
    end
    return setmetatable({
        environment = client.environment,
        onNew = handler("onNew"),
        onEdit = handler("onEdit"),
        onView = handler("onView"),
        onResume = handler("onResume"),
        onCancel = handler("onCancel"),
        onRemove = handler("onRemove"),
        onConfirm = handler("onConfirm"),
        onDismiss = handler("onDismiss"),
        onShown = handler("onShown"),
        onEditWelcome = handler("onEditWelcome"),
        onSendWelcomes = handler("onSendWelcomes"),
        rows = {},
    }, Tab)
end

local function setEnabled(widget, enabled)
    if enabled then
        widget:Enable()
    else
        widget:Disable()
    end
end

function Tab:button(parent, text, width, onClick)
    local button = self.environment.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetWidth(width or MailboxTab.BUTTON_WIDTH)
    button:SetHeight(MailboxTab.BUTTON_HEIGHT)
    button:SetText(text)
    button:SetScript("OnClick", function(clicked)
        onClick(clicked)
    end)
    return button
end

-- The first of the game's tab templates the client knows; a plain button
-- when it can't say.
function Tab:tabTemplate()
    local xml = self.environment.C_XMLUtil
    if type(xml) ~= "table" or type(xml.GetTemplateInfo) ~= "function" then
        return "UIPanelButtonTemplate"
    end
    local index
    for index = 1, #MailboxTab.TAB_TEMPLATES do
        local ok, info = pcall(xml.GetTemplateInfo, MailboxTab.TAB_TEMPLATES[index])
        if ok and info ~= nil then
            return MailboxTab.TAB_TEMPLATES[index]
        end
    end
    return "UIPanelButtonTemplate"
end

-- The tab and its page, made on first use. False when the client has no
-- mailbox tabs to sit beside.
function Tab:build()
    if self.tab ~= nil then
        return true
    end
    local environment = self.environment
    local mailFrame, sendTab = environment.MailFrame, environment.MailFrameTab2
    if mailFrame == nil or sendTab == nil then
        return false
    end
    -- All or nothing: a tab whose page failed is hidden and not kept.
    local tab
    local ok = pcall(function()
        tab = environment.CreateFrame("Button", nil, mailFrame, self:tabTemplate())
        tab:SetText(MailboxTab.TAB_TEXT)
        -- Placed from Send Mail exactly as Send Mail is placed from Inbox, so
        -- it sits level with the game's tabs.
        local point, _, relativePoint, x, y = sendTab:GetPoint(1)
        tab:SetPoint(type(point) == "string" and point or "LEFT", sendTab,
            type(relativePoint) == "string" and relativePoint or "RIGHT",
            type(x) == "number" and x or 0, type(y) == "number" and y or 0)
        if type(environment.PanelTemplates_TabResize) == "function" then
            pcall(environment.PanelTemplates_TabResize, tab, 0)
        end
        -- Drawn as an unselected tab until it's clicked.
        if type(environment.PanelTemplates_DeselectTab) == "function" then
            pcall(environment.PanelTemplates_DeselectTab, tab)
        end
        tab:SetScript("OnClick", function()
            self:select()
        end)
        self:buildPage(mailFrame)
    end)
    if not ok then
        if tab ~= nil then
            pcall(tab.Hide, tab)
        end
        if self.page ~= nil then
            pcall(self.page.Hide, self.page)
            self.page = nil
        end
        return false
    end
    self.tab = tab
    -- Inbox or Send Mail clicked: each tab's own click, and the game's
    -- shared handler where the client has it (the mailbox opening on
    -- Inbox goes through it too). Either alone is enough.
    local index
    for index = 1, 2 do
        local gameTab = environment["MailFrameTab" .. index]
        if gameTab ~= nil then
            pcall(gameTab.HookScript, gameTab, "OnClick", function()
                self:deselect()
            end)
        end
    end
    if type(environment.hooksecurefunc) == "function" then
        pcall(environment.hooksecurefunc, "MailFrameTab_OnClick", function()
            self:deselect()
        end)
    end
    return true
end

-- The page over the inbox's place in the mailbox.
function Tab:buildPage(mailFrame)
    local environment = self.environment
    local padding = MailboxTab.PADDING
    local page = environment.CreateFrame("Frame", nil, mailFrame)
    -- The mailbox's content area where the client has one, else the
    -- inbox's place below the title bar and mail icon.
    local inset = type(mailFrame.Inset) == "table" and mailFrame.Inset or nil
    if inset ~= nil then
        page:SetAllPoints(inset)
    else
        local area = environment.InboxFrame or mailFrame
        page:SetPoint("TOPLEFT", area, "TOPLEFT", MailboxTab.PAGE_SIDE, -MailboxTab.PAGE_TOP)
        page:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -MailboxTab.PAGE_SIDE, MailboxTab.PAGE_SIDE)
    end
    page:SetFrameLevel((mailFrame:GetFrameLevel() or 0) + 5)
    page:EnableMouse(true)
    local background = page:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(page)
    background:SetColorTexture(0.05, 0.05, 0.08, 0.95)
    self.page = page

    local heading = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", page, "TOPLEFT", padding, -padding - 4)
    heading:SetText("Guild mails")
    self.new = self:button(page, "New", MailboxTab.BUTTON_WIDTH, function()
        self.onNew()
    end)
    self.new:SetPoint("TOPRIGHT", page, "TOPRIGHT", -padding, -padding)
    self.welcome = self:button(page, "Welcome mail", MailboxTab.WELCOME_WIDTH, function()
        self.onEditWelcome()
    end)
    self.welcome:SetPoint("RIGHT", self.new, "LEFT", -6, 0)

    local scroll = environment.CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", padding, -padding - 28)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -padding - 22, padding + 34)
    local list = environment.CreateFrame("Frame", nil, scroll)
    list:SetHeight(MailboxTab.LIST_HEIGHT)
    scroll:SetScrollChild(list)
    scroll:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            list:SetWidth(width)
        end
    end)
    self.list = list

    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4)
    empty:SetText("|cff999999No guild mails yet. New starts one.|r")
    self.empty = empty

    local question = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    question:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", padding, padding + 4)
    question:SetPoint("RIGHT", page, "RIGHT", -padding - 2 * MailboxTab.BUTTON_WIDTH - 12, 0)
    question:SetJustifyH("LEFT")
    self.question = question
    self.no = self:button(page, "No", MailboxTab.BUTTON_WIDTH, function()
        self.onDismiss()
    end)
    self.no:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -padding, padding)
    self.yes = self:button(page, "Yes", MailboxTab.BUTTON_WIDTH, function()
        self.onConfirm()
    end)
    self.yes:SetPoint("RIGHT", self.no, "LEFT", -6, 0)
    page:Hide()
end

-- Row `position` of the list, made on first use: the subject line and the
-- progress line across the whole row, and below them up to three buttons
-- from the left, so they never cover the text.
function Tab:row(position)
    if self.rows[position] ~= nil then
        return self.rows[position]
    end
    local environment = self.environment
    local list = self.list
    local row = environment.CreateFrame("Frame", nil, list)
    row:SetHeight(MailboxTab.ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(position - 1) * MailboxTab.ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    -- One line each, cut short rather than wrapped.
    local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    title:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    row.title = title
    local detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detail:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -22)
    detail:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    detail:SetJustifyH("LEFT")
    detail:SetWordWrap(false)
    row.detail = detail
    row.buttons = {}
    local index
    for index = 1, 3 do
        local button = self:button(row, "", MailboxTab.BUTTON_WIDTH, function(clicked)
            if clicked.action ~= nil then
                clicked.action()
            end
        end)
        if index == 1 then
            button:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -38)
        else
            button:SetPoint("LEFT", row.buttons[index - 1], "RIGHT", 4, 0)
        end
        row.buttons[index] = button
    end
    self.rows[position] = row
    return row
end

-- Sets a row's buttons from `buttons`: { text, enabled, action } each, at
-- most three, from the left.
local function setButtons(row, buttons)
    local index
    for index = 1, 3 do
        local button = row.buttons[index]
        local spec = buttons[index]
        if spec ~= nil then
            button:SetText(spec.text)
            button.action = spec.action
            setEnabled(button, spec.enabled ~= false)
            button:Show()
        else
            button.action = nil
            button:Hide()
        end
    end
end

-- Shows or hides the tab: officers get it. Returns false when the client
-- has no mailbox tabs to put it beside.
function Tab:Install(shown)
    if not shown then
        if self.tab ~= nil then
            self:deselect()
            self.tab:Hide()
        end
        return true
    end
    if not self:build() then
        return false
    end
    self.tab:Show()
    -- The mailbox opens on the game's own page, never on this one left up
    -- from last time.
    self:deselect()
    return true
end

-- The tab clicked: the game's pages give way to this one.
function Tab:select()
    local environment = self.environment
    local hide = { environment.InboxFrame, environment.SendMailFrame, environment.OpenMailFrame }
    local index
    for index = 1, 3 do
        if hide[index] ~= nil then
            pcall(hide[index].Hide, hide[index])
        end
    end
    local tabs = { environment.MailFrameTab1, environment.MailFrameTab2 }
    if type(environment.PanelTemplates_DeselectTab) == "function" then
        for index = 1, 2 do
            if tabs[index] ~= nil then
                pcall(environment.PanelTemplates_DeselectTab, tabs[index])
            end
        end
    end
    if type(environment.PanelTemplates_SelectTab) == "function" then
        pcall(environment.PanelTemplates_SelectTab, self.tab)
    end
    self.page:Show()
    self.selected = true
    self.onShown()
end

-- One of the game's tabs is back: this page hides.
function Tab:deselect()
    self.selected = false
    if self.page ~= nil then
        self.page:Hide()
    end
    if self.tab ~= nil and type(self.environment.PanelTemplates_DeselectTab) == "function" then
        pcall(self.environment.PanelTemplates_DeselectTab, self.tab)
    end
end

-- Whether its page is up: selected while the mailbox is open.
-- The tab's title, e.g. "Guild Mail (3)".
function Tab:SetTitle(text)
    if self.tab == nil or self.title == text then
        return
    end
    self.title = text
    self.tab:SetText(text)
    if type(self.environment.PanelTemplates_TabResize) == "function" then
        pcall(self.environment.PanelTemplates_TabResize, self.tab, 0)
    end
end

function Tab:IsShown()
    if not self.selected or self.page == nil then
        return false
    end
    local ok, shown = pcall(self.page.IsVisible, self.page)
    return not ok or shown ~= false
end

-- Draws GuildMail's OutboxModel.
function Tab:Render(model)
    if self.page == nil then
        return
    end
    setEnabled(self.new, model.canNew)
    setEnabled(self.welcome, model.canNew)
    local items = {}
    if model.draft ~= nil then
        table.insert(items, {
            title = model.draft.subject,
            detail = "|cff999999Draft, not sent yet|r",
            buttons = { { text = "Edit", action = function()
                self.onEdit()
            end } },
        })
    end
    local index
    for index = 1, #(model.entries or {}) do
        local entry = model.entries[index]
        local position = entry.position
        local buttons = {
            { text = "View", action = function()
                self.onView(position)
            end },
        }
        if entry.welcome then
            table.insert(buttons, 1, { text = "Edit", action = function()
                self.onEditWelcome()
            end })
            table.insert(buttons, { text = "Send", enabled = entry.canResume, action = function()
                self.onSendWelcomes()
            end })
        elseif entry.canRemove then
            table.insert(buttons, { text = "Remove", action = function()
                self.onRemove(position)
            end })
        else
            table.insert(buttons, { text = "Resume", enabled = entry.canResume, action = function()
                self.onResume(position)
            end })
            table.insert(buttons, { text = "Cancel", enabled = entry.canCancel, action = function()
                self.onCancel(position)
            end })
        end
        local detail = entry.progressText
        if entry.whenText ~= nil then
            detail = detail .. " · " .. entry.whenText
        end
        table.insert(items, {
            title = entry.subject .. "  |cff999999" .. entry.stateText .. "|r",
            detail = detail,
            buttons = buttons,
        })
    end
    for index = 1, #items do
        local row = self:row(index)
        row.title:SetText(items[index].title)
        row.detail:SetText(items[index].detail)
        setButtons(row, items[index].buttons)
        row:Show()
    end
    for index = #items + 1, #self.rows do
        setButtons(self.rows[index], {})
        self.rows[index]:Hide()
    end
    self.list:SetHeight(math.max(MailboxTab.LIST_HEIGHT, #items * MailboxTab.ROW_HEIGHT))
    if #items == 0 then
        self.empty:Show()
    else
        self.empty:Hide()
    end
    if model.actionText ~= nil then
        self.question:SetText(model.actionText)
        self.question:Show()
        self.yes:Show()
        self.no:Show()
    else
        self.question:Hide()
        self.yes:Hide()
        self.no:Hide()
    end
end
