local _, addon = ...

-- The My Profile tab of the master frame: the player of the logged-in
-- character (ProfileViewModel), drawn each time the tab comes into view.
-- Each character shows in its class color with its level. The logged-in
-- character gets a check box for each role its class can fill; the others
-- show their roles read-only, with a hint to log in on them to change
-- them. A Do Not Disturb check box sits along the bottom. Out of a guild,
-- or before the roster knows the character, the tab shows a short message
-- instead.
--
-- Like the other adapters, it reaches the game only through the client's
-- environment (CreateFrame), so specs can draw it with fake frames.
local ProfilePage = {
    PADDING = 12,
    -- Where the character list starts, below the title bar and heading.
    LIST_TOP = 60,
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
        rows = {},
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
    self.messageText:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -ProfilePage.LIST_TOP)
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

function Page:drawRow(row, character)
    row.frame:Show()
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
    local characters = model.characters or {}
    if model.message ~= nil then
        self.heading:SetText("My Profile")
        self.messageText:SetText(model.message)
        self.messageText:Show()
        self.scroll:Hide()
    else
        self.heading:SetText(model.label)
        self.messageText:Hide()
        self.scroll:Show()
    end
    local index
    for index = 1, #characters do
        self:drawRow(self:row(index), characters[index])
    end
    for index = #characters + 1, #self.rows do
        self.rows[index].frame:Hide()
    end
    self.list:SetHeight(math.max(1, #characters) * ProfilePage.ROW_HEIGHT)
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
