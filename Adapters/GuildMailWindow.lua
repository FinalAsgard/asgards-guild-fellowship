local _, addon = ...

-- Guild Mail's window: rank check boxes, a line saying who in each player
-- gets the mail and who is skipped, a subject and a message, how many will
-- get it, the estimated cost and the officer's money, and Send (with a
-- confirmation in the window, then progress). Two Edit buttons open panels
-- beside the window, one at a time:
--   Preferences  the Send to choice (mains, most recently online character,
--                or every character) and two check boxes to skip players
--                with a Discord name on file and characters not online in
--                30 days
--   Recipients   the list of who will get the mail, each with a check box
--                to leave them out
-- It only draws GuildMail's model and passes clicks and typing back. It opens beside the mailbox when opened from there, and can
-- be dragged anywhere. Officers also get a Guild Mail button beside the
-- mailbox's Send Mail tab.
--
-- The frames are made on first use and reused. Like the other adapters, a
-- failing frame call leaves the window as it was rather than raising.
local GuildMailWindow = {
    WIDTH = 440,
    HEIGHT = 630,
    PADDING = 14,
    RANK_COLUMNS = 2,
    RANK_ROW_HEIGHT = 22,
    -- Up to 10 guild ranks, plus the temporary Tester rank (#205).
    RANK_ROWS = 6,
    MODE_ROW_HEIGHT = 20,
    MESSAGE_HEIGHT = 200,
    PANEL_WIDTH = 360,
    PREFERENCES_HEIGHT = 190,
    -- The recipients panel is as tall as the window.
    LIST_HEIGHT = 560,
    LIST_ROW_HEIGHT = 18,
    BUTTON_WIDTH = 96,
    EDIT_BUTTON_WIDTH = 60,
    BUTTON_HEIGHT = 24,
    MAILBOX_BUTTON_WIDTH = 96,
    -- The game's limits on a mail's subject and body.
    SUBJECT_LETTERS = 64,
    BODY_LETTERS = 500,
    STRATA = "HIGH",
    STATUS_TEXT = {
        pending = "",
        sent = " |cff40ff40sent|r",
        failed = " |cffff4040failed|r",
    },
}
addon.GuildMailWindow = GuildMailWindow

local Window = {}
Window.__index = Window

-- handlers (each optional):
--   onRank(index, checked), onMode(mode), onSubject(text), onBody(text)
--   onSkipDiscord(checked), onActiveOnly(checked)
--   onRecipient(key, checked)  a recipient ticked or unticked
--   onSend()     Send pressed: ask for confirmation
--   onConfirm()  the confirmation's Send pressed
--   onCancel()   the confirmation's Cancel pressed
--   onMailboxButton()  the mailbox's Guild Mail button pressed
function GuildMailWindow.Create(client, handlers)
    handlers = handlers or {}
    local function handler(name)
        return type(handlers[name]) == "function" and handlers[name] or function() end
    end
    return setmetatable({
        environment = client.environment,
        onRank = handler("onRank"),
        onMode = handler("onMode"),
        onSkipDiscord = handler("onSkipDiscord"),
        onActiveOnly = handler("onActiveOnly"),
        onSubject = handler("onSubject"),
        onBody = handler("onBody"),
        onRecipient = handler("onRecipient"),
        onSend = handler("onSend"),
        onConfirm = handler("onConfirm"),
        onCancel = handler("onCancel"),
        onMailboxButton = handler("onMailboxButton"),
        rankBoxes = {},
        modeButtons = {},
        recipientRows = {},
    }, Window)
end

function Window:button(parent, text, width, onClick)
    local button = self.environment.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetWidth(width or GuildMailWindow.BUTTON_WIDTH)
    button:SetHeight(GuildMailWindow.BUTTON_HEIGHT)
    button:SetText(text)
    button:SetScript("OnClick", function()
        onClick()
    end)
    return button
end

function Window:label(parent, text, top, template)
    local label = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", GuildMailWindow.PADDING, top)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end

-- A scroll frame `height` tall across the window, holding `child`.
function Window:scrollArea(parent, top, height)
    local scroll = self.environment.CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetHeight(height)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", GuildMailWindow.PADDING, top)
    -- Room on the right for the scroll bar.
    scroll:SetPoint("RIGHT", parent, "RIGHT", -GuildMailWindow.PADDING - 22, 0)
    local background = scroll:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(scroll)
    background:SetColorTexture(0, 0, 0, 0.5)
    return scroll
end

-- A panel beside the window, hidden until its Edit button is pressed.
function Window:panel(title, height)
    local frame = self.frame
    local panel = self.environment.CreateFrame("Frame", nil, frame)
    panel:SetWidth(GuildMailWindow.PANEL_WIDTH)
    panel:SetHeight(height)
    panel:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(panel)
    background:SetColorTexture(0.05, 0.05, 0.08, 0.95)
    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetPoint("TOP", panel, "TOP", 0, -12)
    heading:SetText(title)
    panel.heading = heading
    local close = self.environment.CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function()
        panel:Hide()
        self.openPanel = nil
    end)
    panel:Hide()
    return panel
end

-- Shows `panel`, or hides it when it's already up. Only one panel is up
-- at a time.
function Window:togglePanel(panel)
    local opening = self.openPanel ~= panel
    self.preferences:Hide()
    self.recipients:Hide()
    self.openPanel = nil
    if opening then
        panel:Show()
        self.openPanel = panel
    end
end

-- The window, made on first use.
function Window:window()
    if self.frame ~= nil then
        return self.frame
    end
    local createFrame = self.environment.CreateFrame
    local padding = GuildMailWindow.PADDING
    local frame = createFrame("Frame", nil, self.environment.UIParent)
    self.frame = frame
    frame:SetWidth(GuildMailWindow.WIDTH)
    frame:SetHeight(GuildMailWindow.HEIGHT)
    frame:SetFrameStrata(GuildMailWindow.STRATA)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(frame)
    background:SetColorTexture(0.05, 0.05, 0.08, 0.95)

    local heading = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOP", frame, "TOP", 0, -10)
    heading:SetText("Guild Mail")
    local close = createFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function()
        frame:Hide()
    end)

    local top = -40
    self:label(frame, "Send to these ranks", top)
    self.ranksTop = top - 18
    top = self.ranksTop - GuildMailWindow.RANK_ROWS * GuildMailWindow.RANK_ROW_HEIGHT - 8

    self.preferencesText = self:label(frame, "", top - 4, "GameFontHighlightSmall")
    self.preferencesText:SetPoint("RIGHT", frame, "RIGHT", -padding - GuildMailWindow.EDIT_BUTTON_WIDTH - 6, 0)
    self.editPreferences = self:button(frame, "Edit", GuildMailWindow.EDIT_BUTTON_WIDTH, function()
        self:togglePanel(self.preferences)
    end)
    self.editPreferences:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -padding, top)
    top = top - 32

    self:label(frame, "Subject", top)
    local subject = createFrame("EditBox", nil, frame, "InputBoxTemplate")
    subject:SetHeight(20)
    subject:SetPoint("TOPLEFT", frame, "TOPLEFT", padding + 6, top - 16)
    subject:SetPoint("RIGHT", frame, "RIGHT", -padding, 0)
    subject:SetAutoFocus(false)
    subject:SetMaxLetters(GuildMailWindow.SUBJECT_LETTERS)
    subject:SetScript("OnTextChanged", function(box, typed)
        if typed then
            self.onSubject(box:GetText())
        end
    end)
    subject:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    self.subject = subject
    top = top - 46

    self:label(frame, "Message", top)
    local messageScroll = self:scrollArea(frame, top - 18, GuildMailWindow.MESSAGE_HEIGHT)
    local body = createFrame("EditBox", nil, messageScroll)
    body:SetMultiLine(true)
    body:SetFontObject("ChatFontNormal")
    body:SetTextInsets(6, 6, 4, 4)
    body:SetHeight(GuildMailWindow.MESSAGE_HEIGHT)
    body:SetAutoFocus(false)
    body:SetMaxLetters(GuildMailWindow.BODY_LETTERS)
    messageScroll:SetScrollChild(body)
    messageScroll:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            body:SetWidth(width)
        end
    end)
    messageScroll:SetScript("OnMouseDown", function()
        body:SetFocus()
    end)
    body:SetScript("OnTextChanged", function(box, typed)
        if typed then
            self.onBody(box:GetText())
        end
    end)
    body:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    self.body = body
    top = top - 18 - GuildMailWindow.MESSAGE_HEIGHT - 10

    self.listLabel = self:label(frame, "Recipients", top - 4)
    self.editRecipients = self:button(frame, "Edit", GuildMailWindow.EDIT_BUTTON_WIDTH, function()
        self:togglePanel(self.recipients)
    end)
    self.editRecipients:SetPoint("LEFT", self.listLabel, "RIGHT", 8, 0)
    top = top - 30

    local cost = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cost:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, top)
    cost:SetPoint("RIGHT", frame, "RIGHT", -padding, 0)
    cost:SetJustifyH("LEFT")
    self.cost = cost
    local money = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    money:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, top - 18)
    money:SetJustifyH("LEFT")
    self.money = money
    top = top - 36

    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, top)
    status:SetPoint("RIGHT", frame, "RIGHT", -padding, 0)
    status:SetJustifyH("LEFT")
    self.status = status

    self.send = self:button(frame, "Send", nil, function()
        self.onSend()
    end)
    self.send:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
    self.cancel = self:button(frame, "Cancel", nil, function()
        self.onCancel()
    end)
    self.cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
    self.confirm = self:button(frame, "Send", nil, function()
        self.onConfirm()
    end)
    self.confirm:SetPoint("RIGHT", self.cancel, "LEFT", -6, 0)
    local confirmText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    confirmText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", padding, padding + 5)
    confirmText:SetJustifyH("LEFT")
    self.confirmText = confirmText

    self:preferencesPanel()
    self:recipientsPanel()

    frame:Hide()
    return frame
end

-- The Preferences panel: the Send to choice and the two skip boxes.
function Window:preferencesPanel()
    local panel = self:panel("Preferences", GuildMailWindow.PREFERENCES_HEIGHT)
    self.preferences = panel
    local top = -36
    self:label(panel, "Send to", top)
    local index
    for index = 1, #addon.GuildMail.MODES do
        local mode = addon.GuildMail.MODES[index]
        local radio = self.environment.CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
        radio:SetPoint("TOPLEFT", panel, "TOPLEFT", GuildMailWindow.PADDING + 4,
            top - 18 - (index - 1) * GuildMailWindow.MODE_ROW_HEIGHT)
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", radio, "RIGHT", 4, 0)
        label:SetText(mode.label)
        radio.modeId = mode.id
        radio:SetScript("OnClick", function(clicked)
            self.onMode(clicked.modeId)
        end)
        self.modeButtons[index] = radio
    end
    top = top - 18 - #addon.GuildMail.MODES * GuildMailWindow.MODE_ROW_HEIGHT - 8

    self.skipDiscord = self:checkBox(panel, "Skip players with a Discord name on file", top, function(checked)
        self.onSkipDiscord(checked)
    end)
    self.activeOnly = self:checkBox(panel, "Skip characters not online in the last " ..
        addon.GuildMail.ACTIVE_DAYS .. " days", top - 22, function(checked)
        self.onActiveOnly(checked)
    end)
end

-- The Recipients panel: who will get the mail, each with a check box.
function Window:recipientsPanel()
    local panel = self:panel("Recipients", GuildMailWindow.HEIGHT)
    self.recipients = panel
    local listScroll = self:scrollArea(panel, -36, GuildMailWindow.LIST_HEIGHT)
    local list = self.environment.CreateFrame("Frame", nil, listScroll)
    list:SetWidth(GuildMailWindow.PANEL_WIDTH - 2 * GuildMailWindow.PADDING - 22)
    list:SetHeight(GuildMailWindow.LIST_HEIGHT)
    listScroll:SetScrollChild(list)
    self.list = list
end

-- A check box with its label, across the window at `top`.
function Window:checkBox(parent, text, top, onClick)
    local box = self.environment.CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetWidth(22)
    box:SetHeight(22)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", GuildMailWindow.PADDING, top)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", box, "RIGHT", 2, 0)
    label:SetText(text)
    box:SetScript("OnClick", function(clicked)
        onClick(clicked:GetChecked() and true or false)
    end)
    return box
end

-- The check box for the rank in list position `position`, made on first
-- use, in RANK_COLUMNS columns.
function Window:rankBox(position)
    if self.rankBoxes[position] ~= nil then
        return self.rankBoxes[position]
    end
    local frame = self.frame
    local columns = GuildMailWindow.RANK_COLUMNS
    local columnWidth = (GuildMailWindow.WIDTH - 2 * GuildMailWindow.PADDING) / columns
    local column = (position - 1) % columns
    local row = math.floor((position - 1) / columns)
    local box = self.environment.CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    box:SetWidth(22)
    box:SetHeight(22)
    box:SetPoint("TOPLEFT", frame, "TOPLEFT", GuildMailWindow.PADDING + column * columnWidth,
        self.ranksTop - row * GuildMailWindow.RANK_ROW_HEIGHT)
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", box, "RIGHT", 2, 0)
    label:SetWidth(columnWidth - 28)
    label:SetJustifyH("LEFT")
    box.rankLabel = label
    box:SetScript("OnClick", function(clicked)
        if clicked.rankIndex ~= nil then
            self.onRank(clicked.rankIndex, clicked:GetChecked() and true or false)
        end
    end)
    self.rankBoxes[position] = box
    return box
end

-- The check box and line for the recipient in list position `position`,
-- made on first use.
function Window:recipientRow(position)
    if self.recipientRows[position] ~= nil then
        return self.recipientRows[position]
    end
    local list = self.list
    local box = self.environment.CreateFrame("CheckButton", nil, list, "UICheckButtonTemplate")
    box:SetWidth(GuildMailWindow.LIST_ROW_HEIGHT)
    box:SetHeight(GuildMailWindow.LIST_ROW_HEIGHT)
    box:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2 - (position - 1) * GuildMailWindow.LIST_ROW_HEIGHT)
    local line = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line:SetPoint("LEFT", box, "RIGHT", 2, 0)
    line:SetPoint("RIGHT", list, "RIGHT", -6, 0)
    line:SetJustifyH("LEFT")
    box.line = line
    box:SetScript("OnClick", function(clicked)
        if clicked.recipientKey ~= nil then
            self.onRecipient(clicked.recipientKey, clicked:GetChecked() and true or false)
        end
    end)
    self.recipientRows[position] = box
    return box
end

function Window:IsShown()
    return self.frame ~= nil and self.frame:IsShown() == true
end

-- Shows the window, beside the mailbox when `fromMailbox` and the game's
-- mail window is there, else in the middle of the screen.
function Window:Show(fromMailbox)
    local frame = self:window()
    local mailFrame = self.environment.MailFrame
    frame:ClearAllPoints()
    if not (fromMailbox and mailFrame ~= nil
        and pcall(frame.SetPoint, frame, "TOPLEFT", mailFrame, "TOPRIGHT", 4, 0))
    then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", self.environment.UIParent, "CENTER", 0, 0)
    end
    frame:Show()
end

function Window:Hide()
    if self.frame ~= nil then
        self.frame:Hide()
    end
end

-- The line beside Preferences' Edit button: "Send to: Mains only · Skip
-- Discord names · Skip inactive".
function GuildMailWindow.PreferencesText(model)
    local parts = {}
    local index
    for index = 1, #(model.modes or {}) do
        if model.modes[index].checked then
            table.insert(parts, "Send to: " .. model.modes[index].label)
        end
    end
    if model.skipDiscord then
        table.insert(parts, "Skip Discord names")
    end
    if model.activeOnly then
        table.insert(parts, "Skip inactive")
    end
    return table.concat(parts, " · ")
end

local function setText(box, text)
    -- Retyping the same text would move the cursor while someone types.
    if box:GetText() ~= text then
        box:SetText(text)
    end
end

local function setEnabled(widget, enabled)
    if enabled then
        widget:Enable()
    else
        widget:Disable()
    end
end

-- Draws GuildMail's model.
function Window:Render(model)
    self:window()
    local index
    for index = 1, #model.ranks do
        local rank = model.ranks[index]
        local box = self:rankBox(index)
        box.rankIndex = rank.index
        box.rankLabel:SetText(rank.name)
        box:SetChecked(rank.checked)
        setEnabled(box, not model.sending)
        box:Show()
        box.rankLabel:Show()
    end
    for index = #model.ranks + 1, #self.rankBoxes do
        self.rankBoxes[index].rankIndex = nil
        self.rankBoxes[index]:Hide()
        self.rankBoxes[index].rankLabel:Hide()
    end

    for index = 1, #self.modeButtons do
        local mode = model.modes and model.modes[index]
        -- A radio button clicked while sending, or on the choice already
        -- made, is put back to match the model.
        self.modeButtons[index]:SetChecked(mode ~= nil and mode.checked)
        setEnabled(self.modeButtons[index], not model.sending)
    end

    self.skipDiscord:SetChecked(model.skipDiscord == true)
    setEnabled(self.skipDiscord, not model.sending)
    self.activeOnly:SetChecked(model.activeOnly == true)
    setEnabled(self.activeOnly, not model.sending)

    setText(self.subject, model.subject)
    setText(self.body, model.body)

    self.preferencesText:SetText(GuildMailWindow.PreferencesText(model))
    self.listLabel:SetText("Recipients (" .. model.countText .. ")")
    self.recipients.heading:SetText("Recipients (" .. model.countText .. ")")
    for index = 1, #model.recipients do
        local row = model.recipients[index]
        local details = { row.rankName }
        if row.playerName ~= nil and row.playerName ~= row.name then
            table.insert(details, 1, row.playerName)
        end
        if row.lastSeen ~= nil and row.lastSeen ~= "" then
            table.insert(details, row.lastSeen)
        end
        local line = row.name .. "  |cff999999" .. table.concat(details, " · ") .. "|r"
        if row.status ~= nil then
            line = line .. (GuildMailWindow.STATUS_TEXT[row.status] or "")
            if row.reason ~= nil then
                line = line .. " (" .. tostring(row.reason) .. ")"
            end
        end
        local box = self:recipientRow(index)
        box.recipientKey = row.key
        box.line:SetText(line)
        -- A box clicked while sending is put back to match the model.
        box:SetChecked(row.checked ~= false)
        setEnabled(box, not model.sending)
        box:Show()
        box.line:Show()
    end
    for index = #model.recipients + 1, #self.recipientRows do
        self.recipientRows[index].recipientKey = nil
        self.recipientRows[index]:Hide()
        self.recipientRows[index].line:Hide()
    end
    self.list:SetHeight(math.max(GuildMailWindow.LIST_HEIGHT,
        #model.recipients * GuildMailWindow.LIST_ROW_HEIGHT + 4))

    self.cost:SetText(model.costText or "")
    self.money:SetText(model.moneyText or "")
    self.status:SetText(model.progressText or model.hint or "")

    if model.confirming then
        self.send:Hide()
        self.confirmText:SetText(model.confirmText)
        self.confirmText:Show()
        self.confirm:Show()
        self.cancel:Show()
    else
        self.confirmText:Hide()
        self.confirm:Hide()
        self.cancel:Hide()
        self.send:SetText(model.sendText or "Send")
        self.send:Show()
        setEnabled(self.send, model.canSend)
    end
end

-- Shows or hides the Guild Mail button beside the mailbox's Send Mail tab
-- (made on first use; only officers get it).
function Window:ShowMailboxButton(shown)
    local parent = self.environment.SendMailFrame
    if self.mailboxButton == nil then
        if not shown or parent == nil then
            return false
        end
        local button = self:button(parent, "Guild Mail", GuildMailWindow.MAILBOX_BUTTON_WIDTH, function()
            self.onMailboxButton()
        end)
        local mailFrame = self.environment.MailFrame or parent
        button:SetPoint("TOPLEFT", mailFrame, "TOPRIGHT", 4, -30)
        self.mailboxButton = button
    end
    if shown then
        self.mailboxButton:Show()
    else
        self.mailboxButton:Hide()
    end
    return true
end
