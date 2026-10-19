local _, addon = ...

-- Guild Mail's window: rank check boxes, a line saying who in each player
-- gets the mail and who is skipped, a subject and a message, how many will
-- get it, the estimated cost and the officer's money, and Send (with a
-- confirmation in the window, then progress, with Stop beside it). Two Edit buttons open panels
-- beside the window, one at a time:
--   Preferences  the Send to choice (mains, most recently online character,
--                or every character) and two check boxes to skip players
--                with a Discord name on file and characters not online in
--                30 days
--   Recipients   the list of who will get the mail, each with a check box
--                to leave them out, and a warning on any whose mail is too
--                long once the placeholders are filled in; a search box
--                narrows it, and Check All / Uncheck All tick or untick
--                everyone it shows
--   Preview      the mail as the first ticked recipient gets it, and the
--                placeholders the subject and message can use
-- It only draws GuildMail's model and passes clicks and typing back. It opens beside the mailbox when opened from there, and can
-- be dragged anywhere. Officers open it from the mailbox's Guild Mail tab
-- (MailboxTab) or with /agf mail.
--
-- View in the Guild Mail tab shows a sent mail read-only on a page over the
-- window: its subject and message, state and progress, the first
-- recipient's mail, and every recipient with their status, with Send and
-- Skip on an unconfirmed one; Back, Resume, and Cancel or Remove below,
-- and the question for Cancel or Remove waiting for Yes or No.
--
-- The Guild Mail tab's Welcome mail button (MailboxTab) opens a page over
-- the window for the guild's welcome mail: its subject and message, Save, the on/off switch,
-- and the welcome as the officer's own character would get it.
--
-- The frames are made on first use and reused. Like the other adapters, a
-- failing frame call leaves the window as it was rather than raising.
local GuildMailWindow = {
    WIDTH = 440,
    HEIGHT = 630,
    PADDING = 14,
    RANK_COLUMNS = 2,
    RANK_ROW_HEIGHT = 22,
    -- Up to 10 guild ranks, in two columns.
    RANK_ROWS = 5,
    MODE_ROW_HEIGHT = 20,
    MESSAGE_HEIGHT = 190,
    PANEL_WIDTH = 360,
    PREFERENCES_HEIGHT = 190,
    -- The recipients panel is as tall as the window.
    LIST_HEIGHT = 560,
    LIST_ROW_HEIGHT = 18,
    BUTTON_WIDTH = 96,
    EDIT_BUTTON_WIDTH = 60,
    BUTTON_HEIGHT = 24,
    ENTRY_BODY_HEIGHT = 150,
    ENTRY_LIST_HEIGHT = 250,
    ENTRY_ROW_HEIGHT = 22,
    SMALL_BUTTON_WIDTH = 50,
    STRATA = "HIGH",
    STATUS_TEXT = {
        pending = "",
        sent = " |cff40ff40sent|r",
        failed = " |cffff4040failed|r",
        unconfirmed = " |cffffd100unconfirmed|r",
        skipped = " |cff999999skipped|r",
        cancelled = " |cff999999cancelled|r",
    },
}
addon.GuildMailWindow = GuildMailWindow

local Window = {}
Window.__index = Window

-- handlers (each optional):
--   onRank(index, checked), onMode(mode), onSubject(text), onBody(text)
--   onSkipDiscord(checked), onActiveOnly(checked)
--   onRecipient(key, checked)  a recipient ticked or unticked
--   onRecipientFilter(text)    typed in the recipient list's search
--   onCheckAll(), onUncheckAll()   Check All and Uncheck All
--   onSend()     Send pressed: ask for confirmation
--   onConfirm()  the confirmation's Send pressed
--   onCancel()   the confirmation's Cancel pressed
--   onStop()     Stop pressed while sending
--   onEnd()      End pressed after Stop
-- and on a sent mail's page (View):
--   onBack()     Back pressed
--   onResumeEntry(position), onCancelEntry(position),
--   onRemoveEntry(position)    `position` is the entry's place in the outbox
--   onSettle(index, send)      Send (true) or Skip on recipient `index`
--   onReuseEntry(position)     Use again
--   onConfirmAction(), onDismissAction()   Yes and No on the question
-- and for the welcome mail:
--   onWelcomeSubject(text), onWelcomeBody(text)   typed on its page
--   onWelcomeSave(), onWelcomeOn(checked), onWelcomeBack()
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
        onRecipientFilter = handler("onRecipientFilter"),
        onCheckAll = handler("onCheckAll"),
        onUncheckAll = handler("onUncheckAll"),
        onReuseEntry = handler("onReuseEntry"),
        onSend = handler("onSend"),
        onConfirm = handler("onConfirm"),
        onCancel = handler("onCancel"),
        onStop = handler("onStop"),
        onEnd = handler("onEnd"),
        onBack = handler("onBack"),
        onResumeEntry = handler("onResumeEntry"),
        onCancelEntry = handler("onCancelEntry"),
        onRemoveEntry = handler("onRemoveEntry"),
        onSettle = handler("onSettle"),
        onConfirmAction = handler("onConfirmAction"),
        onDismissAction = handler("onDismissAction"),
        onWelcomeSubject = handler("onWelcomeSubject"),
        onWelcomeBody = handler("onWelcomeBody"),
        onWelcomeSave = handler("onWelcomeSave"),
        onWelcomeOn = handler("onWelcomeOn"),
        onWelcomeBack = handler("onWelcomeBack"),
        entryRows = {},
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
    self.preview:Hide()
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
    subject:SetMaxLetters(addon.GuildMailComposer.SUBJECT_LETTERS)
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

    local messageLabel = self:label(frame, "Message", top - 4)
    self.editPreview = self:button(frame, "Preview", GuildMailWindow.EDIT_BUTTON_WIDTH + 10, function()
        self:togglePanel(self.preview)
    end)
    self.editPreview:SetPoint("LEFT", messageLabel, "RIGHT", 8, 0)
    local placeholderHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholderHint:SetPoint("LEFT", self.editPreview, "RIGHT", 8, 0)
    placeholderHint:SetText("|cff999999{name} and other placeholders work|r")
    local messageScroll = self:scrollArea(frame, top - 18, GuildMailWindow.MESSAGE_HEIGHT)
    local body = createFrame("EditBox", nil, messageScroll)
    body:SetMultiLine(true)
    body:SetFontObject("ChatFontNormal")
    body:SetTextInsets(6, 6, 4, 4)
    body:SetHeight(GuildMailWindow.MESSAGE_HEIGHT)
    body:SetAutoFocus(false)
    body:SetMaxLetters(addon.GuildMailComposer.BODY_LETTERS)
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
    self.stop = self:button(frame, "Stop", nil, function()
        if self.stopEnds then
            self.onEnd()
        else
            self.onStop()
        end
    end)
    self.stop:SetPoint("RIGHT", self.send, "LEFT", -6, 0)
    self.stop:Hide()
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
    self:previewPanel()
    self:entryPage()
    self:welcomePage()

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

-- The Preview panel: the mail as its first recipient gets it, then the
-- placeholder key, as in the Greetings window.
function Window:previewPanel()
    local panel = self:panel("Preview", GuildMailWindow.HEIGHT)
    self.preview = panel
    local padding = GuildMailWindow.PADDING
    local function text(top, template)
        local line = panel:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
        line:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, top)
        line:SetPoint("RIGHT", panel, "RIGHT", -padding, 0)
        line:SetJustifyH("LEFT")
        line:SetJustifyV("TOP")
        return line
    end
    self.previewTo = text(-36, "GameFontNormal")
    self.previewSubject = text(-56)
    self.previewBody = text(-80, "ChatFontNormal")
    self.previewBody:SetWordWrap(true)

    local placeholders = addon.GuildMailComposer.PLACEHOLDERS
    local keyTop = -GuildMailWindow.HEIGHT + 20 + (#placeholders + 2) * 15
    self.previewBody:SetPoint("BOTTOM", panel, "TOP", 0, keyTop + 8)
    text(keyTop, "GameFontNormal"):SetText("Placeholders (upper or lower case both work)")
    local index
    for index = 1, #placeholders do
        text(keyTop - index * 15, "GameFontHighlightSmall"):SetText(
            "|cffffd100" .. placeholders[index][1] .. "|r  " .. placeholders[index][2])
    end
    text(keyTop - (#placeholders + 1) * 15, "GameFontHighlightSmall"):SetText(
        "|cff999999First and last parts only differ on WoW Forever's two-part names.|r")
end

-- The Recipients panel: who will get the mail, each with a check box.
function Window:recipientsPanel()
    local panel = self:panel("Recipients", GuildMailWindow.HEIGHT)
    self.recipients = panel
    local padding = GuildMailWindow.PADDING
    local search = self.environment.CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    search:SetHeight(20)
    search:SetPoint("TOPLEFT", panel, "TOPLEFT", padding + 6, -36)
    search:SetPoint("RIGHT", panel, "RIGHT", -padding, 0)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(box, typed)
        if typed then
            self.onRecipientFilter(box:GetText())
        end
    end)
    search:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    self.recipientSearch = search
    local searchHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", search, "LEFT", 4, 0)
    searchHint:SetText("Search names")
    self.recipientSearchHint = searchHint
    self.checkAll = self:button(panel, "Check All", GuildMailWindow.BUTTON_WIDTH, function()
        self.onCheckAll()
    end)
    self.checkAll:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -62)
    self.uncheckAll = self:button(panel, "Uncheck All", GuildMailWindow.BUTTON_WIDTH, function()
        self.onUncheckAll()
    end)
    self.uncheckAll:SetPoint("LEFT", self.checkAll, "RIGHT", 6, 0)
    local listScroll = self:scrollArea(panel, -92, GuildMailWindow.LIST_HEIGHT - 56)
    local list = self.environment.CreateFrame("Frame", nil, listScroll)
    list:SetWidth(GuildMailWindow.PANEL_WIDTH - 2 * GuildMailWindow.PADDING - 22)
    list:SetHeight(GuildMailWindow.LIST_HEIGHT - 56)
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
    self:renderEntry(model.entry)
    self:renderWelcome(model.welcome)
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
    if model.preview ~= nil then
        self.previewTo:SetText("To: " .. model.preview.to)
        self.previewSubject:SetText("Subject: " .. model.preview.subject)
        self.previewBody:SetText(model.preview.body)
    else
        self.previewTo:SetText("Nobody is ticked to preview.")
        self.previewSubject:SetText("")
        self.previewBody:SetText("")
    end
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
        if row.warning ~= nil then
            line = line .. " |cffff4040" .. tostring(row.warning) .. "|r"
        end
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
        -- A mail that's too long can't be ticked.
        setEnabled(box, not model.sending and row.warning == nil)
        box:Show()
        box.line:Show()
    end
    for index = #model.recipients + 1, #self.recipientRows do
        self.recipientRows[index].recipientKey = nil
        self.recipientRows[index]:Hide()
        self.recipientRows[index].line:Hide()
    end
    self.list:SetHeight(math.max(GuildMailWindow.LIST_HEIGHT - 56,
        #model.recipients * GuildMailWindow.LIST_ROW_HEIGHT + 4))
    setText(self.recipientSearch, model.recipientFilter or "")
    if (model.recipientFilter or "") == "" then
        self.recipientSearchHint:Show()
    else
        self.recipientSearchHint:Hide()
    end
    setEnabled(self.checkAll, not model.sending)
    setEnabled(self.uncheckAll, not model.sending)

    self.cost:SetText(model.costText or "")
    self.money:SetText(model.moneyText or "")
    local status = {}
    if model.progressText ~= nil then
        table.insert(status, model.progressText)
    end
    if model.hint ~= nil then
        table.insert(status, model.hint)
    end
    if model.confirming and model.confirmWarning ~= nil then
        table.insert(status, model.confirmWarning)
    end
    self.status:SetText(table.concat(status, "\n"))

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
    if model.stopText ~= nil and not model.confirming then
        self.stopEnds = model.stopText == addon.GuildMail.END_TEXT
        self.stop:SetText(model.stopText)
        self.stop:Show()
        setEnabled(self.stop, model.canStop)
    else
        self.stopEnds = false
        self.stop:Hide()
    end
end

-- The page for a sent mail (View), over the whole window, hidden until an
-- entry is on view.
function Window:entryPage()
    local frame = self.frame
    local createFrame = self.environment.CreateFrame
    local padding = GuildMailWindow.PADDING
    local page = createFrame("Frame", nil, frame)
    page:SetAllPoints(frame)
    page:SetFrameLevel((frame:GetFrameLevel() or 0) + 10)
    page:EnableMouse(true)
    local background = page:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(page)
    background:SetColorTexture(0.05, 0.05, 0.08, 1)
    local heading = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOP", page, "TOP", 0, -10)
    heading:SetText("Sent Guild Mail")
    local function line(top, template)
        local text = page:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
        text:SetPoint("TOPLEFT", page, "TOPLEFT", padding, top)
        text:SetPoint("RIGHT", page, "RIGHT", -padding, 0)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")
        return text
    end
    self.entrySubject = line(-40, "GameFontNormal")
    self.entryState = line(-60, "GameFontHighlightSmall")
    self.entryTo = line(-82, "GameFontHighlightSmall")
    self.entryBody = line(-100, "ChatFontNormal")
    self.entryBody:SetHeight(GuildMailWindow.ENTRY_BODY_HEIGHT)
    self.entryBody:SetWordWrap(true)
    local listTop = -100 - GuildMailWindow.ENTRY_BODY_HEIGHT - 10
    line(listTop, "GameFontNormal"):SetText("Recipients")
    local scroll = self:scrollArea(page, listTop - 18, GuildMailWindow.ENTRY_LIST_HEIGHT)
    local list = createFrame("Frame", nil, scroll)
    list:SetWidth(GuildMailWindow.WIDTH - 2 * padding - 22)
    list:SetHeight(GuildMailWindow.ENTRY_LIST_HEIGHT)
    scroll:SetScrollChild(list)
    self.entryList = list

    self.entryBack = self:button(page, "Back", GuildMailWindow.EDIT_BUTTON_WIDTH + 10, function()
        self.onBack()
    end)
    self.entryBack:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", padding, padding)
    self.entryRemove = self:button(page, "Remove", nil, function()
        if self.entryPosition ~= nil then
            self.onRemoveEntry(self.entryPosition)
        end
    end)
    self.entryRemove:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -padding, padding)
    self.entryCancel = self:button(page, "Cancel", nil, function()
        if self.entryPosition ~= nil then
            self.onCancelEntry(self.entryPosition)
        end
    end)
    self.entryCancel:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -padding, padding)
    self.entryResume = self:button(page, "Resume", nil, function()
        if self.entryPosition ~= nil then
            self.onResumeEntry(self.entryPosition)
        end
    end)
    self.entryResume:SetPoint("RIGHT", self.entryCancel, "LEFT", -6, 0)
    self.entryReuse = self:button(page, "Use again", nil, function()
        if self.entryPosition ~= nil then
            self.onReuseEntry(self.entryPosition)
        end
    end)
    self.entryReuse:SetPoint("LEFT", self.entryBack, "RIGHT", 6, 0)

    local question = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    question:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", padding, padding + 34)
    question:SetPoint("RIGHT", page, "RIGHT", -padding - 2 * GuildMailWindow.EDIT_BUTTON_WIDTH - 12, 0)
    question:SetJustifyH("LEFT")
    self.entryQuestion = question
    self.entryNo = self:button(page, "No", GuildMailWindow.EDIT_BUTTON_WIDTH, function()
        self.onDismissAction()
    end)
    self.entryNo:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -padding, padding + 30)
    self.entryYes = self:button(page, "Yes", GuildMailWindow.EDIT_BUTTON_WIDTH, function()
        self.onConfirmAction()
    end)
    self.entryYes:SetPoint("RIGHT", self.entryNo, "LEFT", -6, 0)
    page:Hide()
    self.entryFrame = page
end

-- The line and Send and Skip buttons for recipient `position` on a sent
-- mail's page, made on first use.
function Window:entryRow(position)
    if self.entryRows[position] ~= nil then
        return self.entryRows[position]
    end
    local list = self.entryList
    local row = self.environment.CreateFrame("Frame", nil, list)
    row:SetHeight(GuildMailWindow.ENTRY_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(position - 1) * GuildMailWindow.ENTRY_ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    row.skip = self:button(row, "Skip", GuildMailWindow.SMALL_BUTTON_WIDTH, function()
        self.onSettle(row.index, false)
    end)
    row.skip:SetHeight(GuildMailWindow.ENTRY_ROW_HEIGHT - 2)
    row.skip:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.send = self:button(row, "Send", GuildMailWindow.SMALL_BUTTON_WIDTH, function()
        self.onSettle(row.index, true)
    end)
    row.send:SetHeight(GuildMailWindow.ENTRY_ROW_HEIGHT - 2)
    row.send:SetPoint("RIGHT", row.skip, "LEFT", -4, 0)
    local line = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line:SetPoint("LEFT", row, "LEFT", 4, 0)
    line:SetPoint("RIGHT", row.send, "LEFT", -6, 0)
    line:SetJustifyH("LEFT")
    row.line = line
    self.entryRows[position] = row
    return row
end

-- Draws the sent mail on view, or hides its page when there's none.
function Window:renderEntry(entry)
    if entry == nil then
        self.entryPosition = nil
        self.entryFrame:Hide()
        return
    end
    self.entryPosition = entry.position
    self.preferences:Hide()
    self.recipients:Hide()
    self.preview:Hide()
    self.openPanel = nil
    self.entrySubject:SetText("Subject: " .. entry.subject)
    local state = entry.stateText .. " · " .. entry.progressText
    if entry.whenText ~= nil then
        state = state .. " · sent " .. entry.whenText
    end
    self.entryState:SetText(state)
    if entry.preview ~= nil then
        self.entryTo:SetText("As " .. entry.preview.to .. " gets it: " .. entry.preview.subject)
        self.entryBody:SetText(entry.preview.body)
    else
        self.entryTo:SetText("")
        self.entryBody:SetText(entry.body)
    end
    local index
    for index = 1, #entry.recipients do
        local recipient = entry.recipients[index]
        local details = { recipient.rankName }
        if recipient.playerName ~= nil and recipient.playerName ~= recipient.name then
            table.insert(details, 1, recipient.playerName)
        end
        local text = recipient.name .. "  |cff999999" .. table.concat(details, " · ") .. "|r"
            .. (GuildMailWindow.STATUS_TEXT[recipient.status] or "")
        if recipient.reason ~= nil then
            text = text .. " (" .. tostring(recipient.reason) .. ")"
        end
        local row = self:entryRow(index)
        row.index = index
        row.line:SetText(text)
        if recipient.canSettle then
            row.send:Show()
            row.skip:Show()
        else
            row.send:Hide()
            row.skip:Hide()
        end
        row:Show()
    end
    for index = #entry.recipients + 1, #self.entryRows do
        self.entryRows[index].index = nil
        self.entryRows[index]:Hide()
    end
    self.entryList:SetHeight(math.max(GuildMailWindow.ENTRY_LIST_HEIGHT,
        #entry.recipients * GuildMailWindow.ENTRY_ROW_HEIGHT))
    if entry.canRemove then
        self.entryRemove:Show()
        self.entryCancel:Hide()
        self.entryResume:Hide()
    else
        self.entryRemove:Hide()
        self.entryCancel:Show()
        self.entryResume:Show()
        setEnabled(self.entryCancel, entry.canCancel)
        setEnabled(self.entryResume, entry.canResume)
    end
    if entry.canReuse then
        self.entryReuse:Show()
    else
        self.entryReuse:Hide()
    end
    if entry.actionText ~= nil then
        self.entryQuestion:SetText(entry.actionText)
        self.entryQuestion:Show()
        self.entryYes:Show()
        self.entryNo:Show()
    else
        self.entryQuestion:Hide()
        self.entryYes:Hide()
        self.entryNo:Hide()
    end
    self.entryFrame:Show()
end

-- The Welcome mail page, over the whole window, hidden until it's opened.
function Window:welcomePage()
    local frame = self.frame
    local createFrame = self.environment.CreateFrame
    local padding = GuildMailWindow.PADDING
    local page = createFrame("Frame", nil, frame)
    page:SetAllPoints(frame)
    page:SetFrameLevel((frame:GetFrameLevel() or 0) + 10)
    page:EnableMouse(true)
    local background = page:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(page)
    background:SetColorTexture(0.05, 0.05, 0.08, 1)
    local heading = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("TOP", page, "TOP", 0, -10)
    heading:SetText("Welcome mail")
    local about = self:label(page, "|cff999999The guild's welcome for newcomers, the same for every officer.|r",
        -36, "GameFontHighlightSmall")
    about:SetPoint("RIGHT", page, "RIGHT", -padding, 0)

    self.welcomeOn = self:checkBox(page, "Send the welcome mail to newcomers", -56, function(checked)
        self.onWelcomeOn(checked)
    end)

    local top = -88
    self:label(page, "Subject", top)
    local subject = createFrame("EditBox", nil, page, "InputBoxTemplate")
    subject:SetHeight(20)
    subject:SetPoint("TOPLEFT", page, "TOPLEFT", padding + 6, top - 16)
    subject:SetPoint("RIGHT", page, "RIGHT", -padding, 0)
    subject:SetAutoFocus(false)
    subject:SetMaxLetters(addon.GuildMailComposer.SUBJECT_LETTERS)
    subject:SetScript("OnTextChanged", function(box, typed)
        if typed then
            self.onWelcomeSubject(box:GetText())
        end
    end)
    subject:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    self.welcomeSubject = subject
    top = top - 46

    self:label(page, "Message", top - 4)
    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", page, "TOPLEFT", padding + 70, top - 6)
    hint:SetText("|cff999999{name} and Guild Mail's other placeholders work|r")
    local scroll = self:scrollArea(page, top - 18, GuildMailWindow.MESSAGE_HEIGHT)
    local body = createFrame("EditBox", nil, scroll)
    body:SetMultiLine(true)
    body:SetFontObject("ChatFontNormal")
    body:SetTextInsets(6, 6, 4, 4)
    body:SetHeight(GuildMailWindow.MESSAGE_HEIGHT)
    body:SetAutoFocus(false)
    body:SetMaxLetters(addon.GuildMailComposer.BODY_LETTERS)
    scroll:SetScrollChild(body)
    scroll:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            body:SetWidth(width)
        end
    end)
    scroll:SetScript("OnMouseDown", function()
        body:SetFocus()
    end)
    body:SetScript("OnTextChanged", function(box, typed)
        if typed then
            self.onWelcomeBody(box:GetText())
        end
    end)
    body:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    self.welcomeBody = body
    top = top - 18 - GuildMailWindow.MESSAGE_HEIGHT - 12

    local function line(at, template)
        local text = page:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", page, "TOPLEFT", padding, at)
        text:SetPoint("RIGHT", page, "RIGHT", -padding, 0)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")
        return text
    end
    self.welcomePreviewTo = line(top, "GameFontNormal")
    self.welcomePreviewBody = line(top - 20, "ChatFontNormal")
    self.welcomePreviewBody:SetWordWrap(true)
    self.welcomePreviewBody:SetPoint("BOTTOM", page, "BOTTOM", 0, padding + 52)
    self.welcomeHint = line(-GuildMailWindow.HEIGHT + padding + 46)

    self.welcomeBack = self:button(page, "Back", GuildMailWindow.EDIT_BUTTON_WIDTH + 10, function()
        self.onWelcomeBack()
    end)
    self.welcomeBack:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", padding, padding)
    self.welcomeSave = self:button(page, "Save", nil, function()
        self.onWelcomeSave()
    end)
    self.welcomeSave:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -padding, padding)
    page:Hide()
    self.welcomeFrame = page
end

-- Draws the Welcome mail page, or hides it when it isn't open.
function Window:renderWelcome(welcome)
    if welcome == nil then
        self.welcomeFrame:Hide()
        return
    end
    self.preferences:Hide()
    self.recipients:Hide()
    self.preview:Hide()
    self.openPanel = nil
    self.welcomeOn:SetChecked(welcome.on == true)
    setText(self.welcomeSubject, welcome.subject)
    setText(self.welcomeBody, welcome.body)
    if welcome.preview ~= nil then
        local to = "As " .. welcome.preview.to .. " would get it: " .. welcome.preview.subject
        if welcome.preview.warning ~= nil then
            to = to .. " |cffff4040" .. welcome.preview.warning .. "|r"
        end
        self.welcomePreviewTo:SetText(to)
        self.welcomePreviewBody:SetText(welcome.preview.body)
    else
        self.welcomePreviewTo:SetText("")
        self.welcomePreviewBody:SetText("")
    end
    self.welcomeHint:SetText(welcome.hint or "")
    setEnabled(self.welcomeSave, welcome.canSave)
    self.welcomeFrame:Show()
end
