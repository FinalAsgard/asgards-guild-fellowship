local _, addon = ...

-- The My Profile tab of the master frame: the player of the logged-in
-- character (ProfileViewModel), drawn each time the tab comes into view.
-- Each character shows in its class color with its level. The logged-in
-- character gets a check box for each role its class can fill; the others
-- show their roles read-only, with a hint to log in on them to change
-- them. Above the characters, the player's alias, Discord, location and
-- bio can be edited, each with a count of characters used; Enter (or
-- leaving the box) saves a change, Escape undoes it. Each alt has Make main
-- and Remove (split off as its own player); Add alt… opens a picker of the
-- guild's other characters, warning when the one picked belongs to another
-- player. Below the characters, "Your other characters on this computer"
-- offers the characters this install has logged in on that aren't linked
-- yet, each with Add as alt and Dismiss; nothing is ever linked without that
-- click. A Do Not Disturb check box sits along the bottom. Out of a guild,
-- or before the roster knows the character, the tab shows a short message
-- instead.
--
-- Like the other adapters, it reaches the game only through the client's
-- environment (CreateFrame), so specs can draw it with fake frames.
local ProfilePage = {
    PADDING = 12,
    -- Where the About me fields start, below the title bar and heading.
    ABOUT_TOP = 60,
    ABOUT_HEIGHT = 26,
    ABOUT_LABEL_WIDTH = 70,
    ABOUT_COUNTER_WIDTH = 60,
    -- Where the character list starts, below the alias and About me fields.
    LIST_TOP = 60 + 4 * 26 + 8,
    BUTTON_HEIGHT = 20,
    -- The Add alt picker: how many matches it lists.
    PICKER_ROWS = 8,
    PICKER_ROW_HEIGHT = 18,
    -- One suggested own character, and the heading above them.
    SUGGEST_HEIGHT = 24,
    LIST_WIDTH = 520,
    -- One character: its name, then its roles.
    ROW_HEIGHT = 48,
    CHECK_SIZE = 24,
    ROLE_WIDTH = 90,
    FOOTER_BOTTOM = 18,
}
addon.ProfilePage = ProfilePage

local Page = {}
Page.__index = Page

-- "Toolbox (80, main)", the name already colored.
function ProfilePage.CharacterLine(character)
    local details = {}
    if character.level ~= nil then
        table.insert(details, tostring(character.level))
    end
    if character.isMain then
        table.insert(details, "main")
    end
    if character.isSelf then
        table.insert(details, "logged in")
    end
    if #details == 0 then
        return character.coloredName
    end
    return character.coloredName .. "  |cff9d9d9d(" .. table.concat(details, ", ") .. ")|r"
end

-- options:
--   model()               the ProfileViewModel to draw
--   setRole(role, on)     sets whether the logged-in character is willing to
--                         play `role`
--   setDnd(on)            turns Do Not Disturb on or off
--   setText(kind, text)   saves the player's "alias", "discord", "location"
--                         or "bio"
--   makeMain(key)         makes that character the player's main
--   removeAlt(key)        splits that alt off as its own player
--   candidates(query)     -> characters the player could add as alts (see
--                         ProfileViewModel.AltCandidates)
--   addAlt(key)           adds that character to the player as an alt
--   dismiss(key)          stops suggesting that own character
-- `host` is the master frame's content frame for the tab. Returns nil and
-- the reason when there's none, or the tab can't be drawn.
function ProfilePage.Create(client, host, options)
    if host == nil then
        return nil, "there's no tab to draw it on"
    end
    local page = setmetatable({
        environment = client.environment,
        panel = host,
        model = options.model,
        setRole = options.setRole or function() end,
        setDnd = options.setDnd or function() end,
        setText = options.setText or function() end,
        makeMain = options.makeMain or function() end,
        removeAlt = options.removeAlt or function() end,
        candidates = options.candidates or function()
            return {}
        end,
        addAlt = options.addAlt or function() end,
        dismiss = options.dismiss or function() end,
        rows = {},
        suggestRows = {},
        aboutRows = {},
    }, Page)
    local ok, reason = pcall(page.build, page)
    if not ok then
        return nil, tostring(reason)
    end
    return page
end

function Page:build()
    local createFrame = self.environment.CreateFrame
    local padding = ProfilePage.PADDING
    local panel = self.panel
    -- Coming into view (the tab picked, or the frame opened on it) brings
    -- everything up to date.
    panel:HookScript("OnShow", function()
        self:Refresh()
    end)

    self.heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.heading:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -34)
    self.heading:SetPoint("RIGHT", panel, "RIGHT", -padding, 0)
    self.heading:SetJustifyH("LEFT")

    self.messageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.messageText:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -ProfilePage.ABOUT_TOP)
    self.messageText:SetPoint("RIGHT", panel, "RIGHT", -padding, 0)
    self.messageText:SetJustifyH("LEFT")

    local scroll = createFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -ProfilePage.LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -padding - 22,
        ProfilePage.FOOTER_BOTTOM + ProfilePage.CHECK_SIZE + 8)
    local list = createFrame("Frame", nil, scroll)
    list:SetWidth(ProfilePage.LIST_WIDTH)
    list:SetHeight(ProfilePage.ROW_HEIGHT)
    scroll:SetScrollChild(list)
    self.scroll = scroll
    self.list = list

    -- The alias, then the About me fields.
    local index
    for index = 1, #addon.ProfileViewModel.ABOUT + 1 do
        self.aboutRows[index] = self:aboutRow(index)
    end

    self.addAltButton = self:button(panel, "Add alt...", 90, function()
        self:OpenPicker()
    end)
    self.addAltButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -padding - 8, -32)
    self:buildPicker()

    local dnd = createFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    dnd:SetWidth(ProfilePage.CHECK_SIZE)
    dnd:SetHeight(ProfilePage.CHECK_SIZE)
    dnd:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", padding, ProfilePage.FOOTER_BOTTOM)
    dnd:SetScript("OnClick", function(button)
        pcall(self.setDnd, button:GetChecked() == true)
        self:Refresh()
    end)
    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", dnd, "RIGHT", 2, 0)
    label:SetText("Do Not Disturb (no group requests, on every character)")
    self.dndButton = dnd
end

function Page:button(parent, text, width, onClick)
    local made = self.environment.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    made:SetWidth(width)
    made:SetHeight(ProfilePage.BUTTON_HEIGHT)
    made:SetText(text)
    made:SetScript("OnClick", onClick)
    return made
end

-- The Add alt picker, over the character list: a search box, the matching
-- characters, a warning about the one picked, and Add and Cancel.
function Page:buildPicker()
    local createFrame = self.environment.CreateFrame
    local padding = ProfilePage.PADDING
    local panel = self.panel
    local picker = createFrame("Frame", nil, panel)
    picker:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -ProfilePage.LIST_TOP)
    picker:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -padding, ProfilePage.FOOTER_BOTTOM + ProfilePage.CHECK_SIZE + 8)
    picker:SetFrameLevel((panel:GetFrameLevel() or 0) + 10)
    local background = picker:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(picker)
    background:SetColorTexture(0, 0, 0, 0.9)
    local prompt = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    prompt:SetPoint("TOPLEFT", picker, "TOPLEFT", 6, -6)
    prompt:SetText("Add an alt: search the guild's characters")
    local search = createFrame("EditBox", nil, picker, "InputBoxTemplate")
    search:SetHeight(20)
    search:SetWidth(220)
    search:SetPoint("TOPLEFT", picker, "TOPLEFT", 12, -26)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function()
        self:DrawPicker()
    end)
    search:SetScript("OnEscapePressed", function()
        self:ClosePicker()
    end)
    local results = {}
    local index
    for index = 1, ProfilePage.PICKER_ROWS do
        local line = createFrame("Button", nil, picker)
        line:SetHeight(ProfilePage.PICKER_ROW_HEIGHT)
        line:SetPoint("TOPLEFT", picker, "TOPLEFT", 8, -52 - (index - 1) * ProfilePage.PICKER_ROW_HEIGHT)
        line:SetPoint("RIGHT", picker, "RIGHT", -8, 0)
        line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("LEFT", line, "LEFT", 4, 0)
        text:SetJustifyH("LEFT")
        local result = { button = line, text = text }
        line:SetScript("OnClick", function()
            if result.candidate ~= nil then
                self.picked = result.candidate
                self:DrawPicker()
            end
        end)
        results[index] = result
    end
    local warning = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    warning:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 8, 34)
    warning:SetPoint("RIGHT", picker, "RIGHT", -8, 0)
    warning:SetJustifyH("LEFT")
    local add = self:button(picker, "Add", 80, function()
        if self.picked ~= nil then
            local key = self.picked.key
            self:ClosePicker()
            pcall(self.addAlt, key)
            self:Refresh()
        end
    end)
    add:SetPoint("BOTTOMLEFT", picker, "BOTTOMLEFT", 8, 8)
    local cancel = self:button(picker, "Cancel", 80, function()
        self:ClosePicker()
    end)
    cancel:SetPoint("LEFT", add, "RIGHT", 6, 0)
    picker:Hide()
    self.picker = { frame = picker, search = search, results = results, warning = warning, add = add }
end

-- Opens the Add alt picker with an empty search.
function Page:OpenPicker()
    self.picked = nil
    self.picker.search:SetText("")
    self.picker.frame:Show()
    self:DrawPicker()
end

function Page:ClosePicker()
    self.picked = nil
    self.picker.frame:Hide()
end

-- Lists the characters matching the search, marks the one picked, and
-- says what adding it would do.
function Page:DrawPicker()
    local picker = self.picker
    local ok, found = pcall(self.candidates, picker.search:GetText() or "")
    found = ok and type(found) == "table" and found or {}
    local index
    for index = 1, #picker.results do
        local result = picker.results[index]
        local candidate = found[index]
        result.candidate = candidate
        if candidate == nil then
            result.button:Hide()
        else
            local text = candidate.coloredName .. (candidate.level and ("  |cff9d9d9d" .. candidate.level .. "|r") or "")
            if candidate.owner ~= nil then
                text = text .. "  |cff9d9d9d(" .. candidate.owner .. ")|r"
            end
            if self.picked ~= nil and self.picked.key == candidate.key then
                text = "> " .. text
            end
            result.text:SetText(text)
            result.button:Show()
        end
    end
    if self.picked == nil then
        picker.warning:SetText(found[1] == nil and "No characters match." or "Pick a character to add.")
        picker.add:Disable()
    else
        picker.warning:SetText(self.picked.warning and ("|cffff9900" .. self.picked.warning .. "|r")
            or ("Add " .. self.picked.name .. " as an alt."))
        picker.add:Enable()
    end
end

-- An About me field's row: its label, a text box, and how many characters
-- are used of how many.
function Page:aboutRow(index)
    local createFrame = self.environment.CreateFrame
    local padding = ProfilePage.PADDING
    local panel = self.panel
    local top = -ProfilePage.ABOUT_TOP - (index - 1) * ProfilePage.ABOUT_HEIGHT
    local row = {}
    row.label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, top - 4)
    row.label:SetWidth(ProfilePage.ABOUT_LABEL_WIDTH)
    row.label:SetJustifyH("LEFT")
    row.box = createFrame("EditBox", nil, panel, "InputBoxTemplate")
    row.box:SetHeight(20)
    row.box:SetPoint("TOPLEFT", panel, "TOPLEFT", padding + ProfilePage.ABOUT_LABEL_WIDTH + 6, top)
    row.box:SetPoint("RIGHT", panel, "RIGHT", -padding - ProfilePage.ABOUT_COUNTER_WIDTH, 0)
    row.box:SetAutoFocus(false)
    row.counter = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.counter:SetPoint("LEFT", row.box, "RIGHT", 6, 0)
    row.counter:SetWidth(ProfilePage.ABOUT_COUNTER_WIDTH - 6)
    row.counter:SetJustifyH("LEFT")
    local function count()
        row.counter:SetText(#(row.box:GetText() or "") .. "/" .. tostring(row.max or 0))
    end
    local function save()
        local text = string.gsub(row.box:GetText() or "", "^%s*(.-)%s*$", "%1")
        if row.kind ~= nil and text ~= row.saved then
            row.saved = text
            pcall(self.setText, row.kind, text)
        end
        self:Refresh()
    end
    row.box:SetScript("OnTextChanged", count)
    row.box:SetScript("OnEnterPressed", function(box)
        box:ClearFocus()
        save()
    end)
    row.box:SetScript("OnEditFocusLost", save)
    row.box:SetScript("OnEscapePressed", function(box)
        box:SetText(row.saved or "")
        count()
        box:ClearFocus()
    end)
    row.count = count
    return row
end

function Page:drawAbout(about)
    local index
    for index = 1, #self.aboutRows do
        local row = self.aboutRows[index]
        local field = about and about[index]
        if field == nil then
            row.kind = nil
            row.label:Hide()
            row.box:Hide()
            row.counter:Hide()
        else
            row.kind = field.kind
            row.max = field.max
            row.saved = field.text
            row.label:SetText(field.label)
            -- At most `max` bytes (the game counts the end of the text too).
            row.box:SetMaxBytes(field.max + 1)
            -- Text being typed isn't replaced underneath the player.
            if not row.box:HasFocus() then
                row.box:SetText(field.text)
            end
            row.count()
            row.label:Show()
            row.box:Show()
            row.counter:Show()
        end
    end
end

-- The character list's row `index`, made on first use: the character's
-- name, a check box per role (for the logged-in character), and its roles
-- as text with a hint (for the others).
function Page:row(index)
    if self.rows[index] ~= nil then
        return self.rows[index]
    end
    local createFrame = self.environment.CreateFrame
    local frame = createFrame("Frame", nil, self.list)
    frame:SetHeight(ProfilePage.ROW_HEIGHT)
    frame:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, -(index - 1) * ProfilePage.ROW_HEIGHT)
    frame:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
    local name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -2)
    name:SetJustifyH("LEFT")
    local rolesText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rolesText:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -22)
    rolesText:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    rolesText:SetJustifyH("LEFT")
    local row = { frame = frame, name = name, rolesText = rolesText, checks = {} }
    row.remove = self:button(frame, "Remove", 70, function()
        if row.key ~= nil then
            pcall(self.removeAlt, row.key)
            self:Refresh()
        end
    end)
    row.remove:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, 0)
    row.makeMain = self:button(frame, "Make main", 80, function()
        if row.key ~= nil then
            pcall(self.makeMain, row.key)
            self:Refresh()
        end
    end)
    row.makeMain:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
    local roleIndex
    for roleIndex = 1, #addon.RoleCatalog.ROLES do
        local check = createFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        check:SetWidth(ProfilePage.CHECK_SIZE)
        check:SetHeight(ProfilePage.CHECK_SIZE)
        check:SetPoint("TOPLEFT", frame, "TOPLEFT", 8 + (roleIndex - 1) * ProfilePage.ROLE_WIDTH, -18)
        local checkLabel = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        checkLabel:SetPoint("LEFT", check, "RIGHT", 2, 0)
        local entry = { button = check, label = checkLabel }
        check:SetScript("OnClick", function(button)
            if entry.role ~= nil then
                pcall(self.setRole, entry.role, button:GetChecked() == true)
            end
            self:Refresh()
        end)
        row.checks[roleIndex] = entry
    end
    self.rows[index] = row
    return row
end

-- The suggested own characters' row `index`, made on first use: its name
-- and level (and owner), with Add as alt and Dismiss.
function Page:suggestRow(index)
    if self.suggestRows[index] ~= nil then
        return self.suggestRows[index]
    end
    local frame = self.environment.CreateFrame("Frame", nil, self.list)
    frame:SetHeight(ProfilePage.SUGGEST_HEIGHT)
    frame:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", frame, "LEFT", 8, 0)
    text:SetJustifyH("LEFT")
    local row = { frame = frame, text = text }
    row.dismiss = self:button(frame, "Dismiss", 70, function()
        if row.key ~= nil then
            pcall(self.dismiss, row.key)
            self:Refresh()
        end
    end)
    row.dismiss:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
    row.add = self:button(frame, "Add as alt", 84, function()
        if row.key ~= nil then
            pcall(self.addAlt, row.key)
            self:Refresh()
        end
    end)
    row.add:SetPoint("RIGHT", row.dismiss, "LEFT", -4, 0)
    self.suggestRows[index] = row
    return row
end

-- Draws the suggested own characters below `top` (pixels down the list);
-- returns how far down the list now reaches.
function Page:drawSuggested(suggested, top)
    if self.suggestHeading == nil then
        self.suggestHeading = self.list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    end
    local index
    if suggested[1] == nil then
        self.suggestHeading:Hide()
        for index = 1, #self.suggestRows do
            self.suggestRows[index].frame:Hide()
        end
        return top
    end
    self.suggestHeading:ClearAllPoints()
    self.suggestHeading:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, -top - 6)
    self.suggestHeading:SetText("Your other characters on this computer")
    self.suggestHeading:Show()
    top = top + ProfilePage.SUGGEST_HEIGHT
    for index = 1, #suggested do
        local row = self:suggestRow(index)
        local candidate = suggested[index]
        row.key = candidate.key
        local text = candidate.coloredName .. (candidate.level and ("  |cff9d9d9d" .. candidate.level .. "|r") or "")
        if candidate.owner ~= nil then
            text = text .. "  |cffff9900(belongs to " .. candidate.owner .. ")|r"
        end
        row.text:SetText(text)
        row.frame:ClearAllPoints()
        row.frame:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, -top)
        row.frame:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
        row.frame:Show()
        top = top + ProfilePage.SUGGEST_HEIGHT
    end
    for index = #suggested + 1, #self.suggestRows do
        self.suggestRows[index].frame:Hide()
    end
    return top
end

function Page:drawRow(row, character)
    row.frame:Show()
    row.key = character.key
    if character.canMakeMain then
        row.makeMain:Show()
    else
        row.makeMain:Hide()
    end
    if character.canRemove then
        row.remove:Show()
    else
        row.remove:Hide()
    end
    row.name:SetText(ProfilePage.CharacterLine(character))
    local index
    for index = 1, #row.checks do
        local entry = row.checks[index]
        local role = character.editable and character.roles[index] or nil
        entry.role = role and role.role or nil
        if role ~= nil then
            entry.label:SetText(role.label)
            entry.button:SetChecked(role.checked)
            entry.button:Show()
        else
            entry.button:Hide()
        end
    end
    if character.editable then
        row.rolesText:Hide()
    else
        row.rolesText:SetText("Roles: " .. character.rolesText .. "  |cff9d9d9d" .. tostring(character.hint) .. "|r")
        row.rolesText:Show()
    end
end

function Page:draw()
    local ok, model = pcall(self.model)
    if not ok or type(model) ~= "table" then
        model = { message = addon.ProfileViewModel.NOT_READY }
    end
    self.dndButton:SetChecked(model.dnd == true)
    local fields = {}
    if model.message == nil then
        fields[1] = { kind = "alias", label = "Alias", text = model.alias or "", max = model.aliasMax or 48 }
        local index
        for index = 1, #(model.about or {}) do
            table.insert(fields, model.about[index])
        end
    end
    self:drawAbout(fields)
    local characters = model.characters or {}
    if model.message ~= nil then
        self.heading:SetText("My Profile")
        self.messageText:SetText(model.message)
        self.messageText:Show()
        self.scroll:Hide()
        self.addAltButton:Hide()
        self:ClosePicker()
    else
        self.heading:SetText(model.label)
        self.messageText:Hide()
        self.scroll:Show()
        self.addAltButton:Show()
        if self.picker.frame:IsShown() then
            self:DrawPicker()
        end
    end
    local index
    for index = 1, #characters do
        self:drawRow(self:row(index), characters[index])
    end
    for index = #characters + 1, #self.rows do
        self.rows[index].frame:Hide()
    end
    local bottom = self:drawSuggested(model.suggested or {}, #characters * ProfilePage.ROW_HEIGHT)
    self.list:SetHeight(math.max(ProfilePage.ROW_HEIGHT, bottom))
end

-- Redraws the tab while it's showing; a closed tab is drawn when it opens.
function Page:Refresh()
    if self:IsShown() then
        pcall(self.draw, self)
    end
end

-- Whether the tab is in view: picked, with the frame open.
function Page:IsShown()
    local ok, visible = pcall(self.panel.IsVisible, self.panel)
    if ok and type(visible) == "boolean" then
        return visible
    end
    local shown
    ok, shown = pcall(self.panel.IsShown, self.panel)
    return ok and shown == true
end
