local _, addon = ...

-- The add-on's new window, drawn with the Theme and Widgets rather than the
-- Details! Framework. Features move into it one at a time, each as a module
-- with a button in the sidebar; for now that's only the Guild LFG Board.
--
-- One fixed size (960x600), movable, with its position saved per character.
-- The left sidebar card holds the tree and the add-on's name, a button per
-- module, Settings pinned at the bottom, and the character and version. At
-- the top right are an X that closes the window and a gear that toggles the
-- current module's settings popup, pinned under the gear and titled with
-- the module's name. A click anywhere else in the window closes the popup,
-- and switching modules keeps it open, retitled. The Settings page holds
-- settings that belong to no module, in tabs across the top; each switch
-- there is a SettingsModel toggle, so it always agrees with the old window
-- and the slash commands.
--
-- The window is made on first open. Like the other adapters, a frame call
-- that fails is reported back rather than raised.
local Theme = addon.Theme

local AgfWindow = {
    WIDTH = 960,
    HEIGHT = 600,
    SIDEBAR_WIDTH = 200,
    MARGIN = 12,
    ICON_SIZE = 28,
    POPUP_WIDTH = 260,
    MODULE_ROW_HEIGHT = 32,
    SETTINGS_ROW_HEIGHT = 44,
    -- A color setting's swatches.
    SWATCH_SIZE = 20,
    -- The Settings page, which isn't a module.
    SETTINGS = "settings",
}
addon.AgfWindow = AgfWindow

local Window = {}
Window.__index = Window

-- options:
--   frameName     the window's global name, so Escape closes it
--   modules       a list of { id, label, title, draw(content, ui),
--                 settingsRows, onShow }: label names the sidebar button
--                 and the gear popup, title heads the page; draw is
--                 optional, settingsRows ({ id, label, info } toggles in
--                 `settings`) are the gear popup's switches, and onShow()
--                 (optional) runs each time the page is shown
--   settings      the SettingsModel the Settings page's switches use
--   settingsTabs  a list of { id, label, rows = { { id, label, info } } },
--                 each row a toggle in `settings`
--   character     function() -> { name, level, className, classColor }
--   version       the add-on's version text
--   loadPosition  function() -> saved { point, relativePoint, x, y } or nil
--   savePosition  function(position)
function AgfWindow.Create(client, options)
    local window = setmetatable({
        client = client,
        environment = client.environment,
        options = options,
        modules = options.modules or {},
        switches = {},
        colorRows = {},
        pages = {},
        moduleButtons = {},
    }, Window)
    window.current = window.modules[1] and window.modules[1].id or AgfWindow.SETTINGS
    window.gearModule = window.modules[1] and window.modules[1].id or nil
    if options.settings ~= nil then
        options.settings:OnChange(function(id)
            window:refreshSwitch(id)
        end)
    end
    return window
end

function Window:module(id)
    local index
    for index = 1, #self.modules do
        if self.modules[index].id == id then
            return self.modules[index]
        end
    end
    return nil
end

-- Building ------------------------------------------------------------------

function Window:buildBackground(frame)
    local ui = self.ui
    -- The window's rounded gray with its faint edge; the green sweep is laid
    -- over it, its own corners rounded to match.
    ui:Round(frame, Theme.RADIUS.window, "background", "border")
    local sweep = frame:CreateTexture(nil, "BORDER")
    sweep:SetTexture(Theme.TEXTURES.sweep)
    sweep:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    sweep:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
end

function Window:buildSidebar(frame)
    local ui = self.ui
    local margin = AgfWindow.MARGIN
    local sidebar = ui:Panel(frame, { fill = "surface" })
    sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", margin, -margin)
    sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", margin, margin)
    sidebar:SetWidth(AgfWindow.SIDEBAR_WIDTH)
    self.sidebar = sidebar

    local tree = sidebar:CreateTexture(nil, "ARTWORK")
    tree:SetTexture(Theme.TEXTURES.tree)
    tree:SetSize(30, 30)
    tree:SetPoint("TOPLEFT", sidebar, "TOPLEFT", margin, -margin)
    local name = ui:Text(sidebar, addon.Identity.displayName, "semibold", "body", "text")
    name:SetPoint("LEFT", tree, "RIGHT", Theme.SPACING.s, 0)
    name:SetPoint("RIGHT", sidebar, "RIGHT", -Theme.SPACING.s, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(true)

    local window = self
    local function moduleButton(id, label)
        local button = ui:frame("Button", sidebar)
        button:SetHeight(AgfWindow.MODULE_ROW_HEIGHT)
        button:SetPoint("LEFT", sidebar, "LEFT", Theme.SPACING.s, 0)
        button:SetPoint("RIGHT", sidebar, "RIGHT", -Theme.SPACING.s, 0)
        -- The button is its own rounded fill: a child panel would draw over
        -- the label.
        ui:Round(button, Theme.RADIUS.button, "surface", false)
        button.panel = button
        button.id = id
        button.label = ui:Text(button, label, "semibold", "body", "muted")
        button.label:SetPoint("LEFT", button, "LEFT", Theme.SPACING.m, 0)
        button:SetScript("OnEnter", function(self)
            if self.id ~= window.current then
                self.panel:SetFill("hover")
            end
        end)
        button:SetScript("OnLeave", function(self)
            if self.id ~= window.current then
                self.panel:SetFill("surface")
            end
        end)
        button:SetScript("OnClick", function(self)
            window:ShowPage(self.id)
        end)
        self.moduleButtons[#self.moduleButtons + 1] = button
        return button
    end
    local top = -margin - 30 - Theme.SPACING.l
    local index
    for index = 1, #self.modules do
        local button = moduleButton(self.modules[index].id, self.modules[index].label)
        button:SetPoint("TOP", sidebar, "TOP", 0, top - (index - 1) * (AgfWindow.MODULE_ROW_HEIGHT + 4))
    end

    -- At the bottom: the version, above it the character, and above that
    -- Settings.
    local version = ui:Text(sidebar, "Version " .. tostring(self.options.version or "unknown"), "regular", "small",
        "label")
    version:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", margin, margin)
    self.versionText = version
    local details = ui:Text(sidebar, "", "regular", "small", "muted")
    details:SetPoint("BOTTOMLEFT", version, "TOPLEFT", 0, Theme.SPACING.xs)
    self.characterDetails = details
    local character = ui:Text(sidebar, "", "semibold", "body", "text")
    character:SetPoint("BOTTOMLEFT", details, "TOPLEFT", 0, 2)
    self.characterName = character
    local settingsButton = moduleButton(AgfWindow.SETTINGS, "Settings")
    settingsButton:SetPoint("BOTTOM", character, "TOP", 0, Theme.SPACING.m)
    settingsButton:SetPoint("LEFT", sidebar, "LEFT", Theme.SPACING.s, 0)
    settingsButton:SetPoint("RIGHT", sidebar, "RIGHT", -Theme.SPACING.s, 0)
end

-- The area right of the sidebar a page draws into, with its title.
function Window:newPage(frame, title)
    local ui = self.ui
    local page = ui:frame("Frame", frame)
    page:SetPoint("TOPLEFT", self.sidebar, "TOPRIGHT", Theme.SPACING.xl, -Theme.SPACING.s)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Theme.SPACING.xl, Theme.SPACING.l)
    page.title = ui:Text(page, title, "semibold", "heading", "text")
    page.title:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -6)
    -- Where the page's own content goes, under its title.
    page.body = ui:frame("Frame", page)
    page.body:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -48)
    page.body:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page:Hide()
    return page
end

function Window:buildSettingsPage(frame)
    local ui = self.ui
    local page = self:newPage(frame, "Settings")
    local tabs = self.options.settingsTabs or {}
    local items, contents = {}, {}
    local index
    for index = 1, #tabs do
        items[index] = { id = tabs[index].id, label = tabs[index].label }
    end
    local window = self
    local row = ui:Tabs(page.body, items, function(id)
        window:showSettingsTab(id)
    end)
    row:SetPoint("TOPLEFT", page.body, "TOPLEFT", 0, 0)
    row:SetPoint("RIGHT", page.body, "RIGHT", 0, 0)
    self.settingsTabRow = row
    for index = 1, #tabs do
        local content = ui:frame("Frame", page.body)
        content:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -Theme.SPACING.l)
        content:SetPoint("BOTTOMRIGHT", page.body, "BOTTOMRIGHT", 0, 0)
        local rows = tabs[index].rows or {}
        local top = 0
        local position
        for position = 1, #rows do
            local entry = self.options.settings and self.options.settings:Entry(rows[position].id) or nil
            if entry ~= nil and entry.kind == "color" then
                top = top + self:buildColorRow(content, rows[position], entry, top) + Theme.SPACING.s
            else
                top = top + self:buildSwitchRow(content, rows[position], top) + Theme.SPACING.s
            end
        end
        contents[tabs[index].id] = content
    end
    self.settingsContents = contents
    self.pages[AgfWindow.SETTINGS] = page
    if items[1] ~= nil then
        self:showSettingsTab(items[1].id)
    end
end

-- A setting's card on the Settings page, `height` tall at `top`, with its
-- label and info at the top left.
function Window:settingCard(content, setting, top, height)
    local ui = self.ui
    local card = ui:Panel(content, { fill = "surface" })
    card:SetHeight(height)
    card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -top)
    card:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    card.label = ui:Text(card, setting.label, "semibold", "body", "text")
    card.label:SetPoint("TOPLEFT", card, "TOPLEFT", Theme.SPACING.l, -Theme.SPACING.m)
    if setting.info ~= nil then
        card.info = ui:Text(card, setting.info, "regular", "small", "muted")
        card.info:SetPoint("TOPLEFT", card.label, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    end
    return card
end

-- One on/off setting on the Settings page: its label and info on the
-- left, its switch on the right, on a card at `top`. Returns its height.
function Window:buildSwitchRow(content, setting, top)
    local height = AgfWindow.SETTINGS_ROW_HEIGHT + 12
    local card = self:settingCard(content, setting, top, height)
    local switch = self:newSwitch(card, setting)
    switch:SetPoint("RIGHT", card, "RIGHT", -Theme.SPACING.l, 0)
    return height
end

-- One color setting (SettingsModel `entry`) on the Settings page: its label
-- with a sample in the chosen color, then a row of swatches, the chosen one
-- outlined, on a card at `top`. Returns its height.
function Window:buildColorRow(content, setting, entry, top)
    local ui, window = self.ui, self
    local height = AgfWindow.SETTINGS_ROW_HEIGHT + 12 + AgfWindow.SWATCH_SIZE + Theme.SPACING.s
    local card = self:settingCard(content, setting, top, height)
    card.sample = ui:Text(card, entry.sample or "", "semibold", "body", "text")
    card.sample:SetPoint("LEFT", card.label, "RIGHT", Theme.SPACING.s, 0)
    card.id = setting.id
    card.swatches = {}
    local index
    for index = 1, #(entry.swatches or {}) do
        local choice = entry.swatches[index]
        local swatch = ui:frame("Button", card)
        swatch:SetSize(AgfWindow.SWATCH_SIZE, AgfWindow.SWATCH_SIZE)
        swatch:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT",
            Theme.SPACING.l + (index - 1) * (AgfWindow.SWATCH_SIZE + Theme.SPACING.s), Theme.SPACING.m)
        ui:Round(swatch, Theme.RADIUS.small, "surface", "border")
        swatch.fillShape:SetColor(Theme.Hex(choice.color))
        swatch.color = choice.color
        swatch.label = choice.label
        swatch:SetScript("OnClick", function(self)
            local changed, reason = window.options.settings:Set(setting.id, self.color)
            if not changed then
                window.client:Print(addon.Identity.chatPrefix .. " " .. setting.label .. " can't be changed: " ..
                    tostring(reason) .. ".")
            end
            window:refreshSwitch(setting.id)
        end)
        card.swatches[index] = swatch
    end
    self.colorRows[setting.id] = self.colorRows[setting.id] or {}
    table.insert(self.colorRows[setting.id], card)
    self:refreshSwitch(setting.id)
    return height
end

-- A switch for the SettingsModel toggle `setting`. Every switch for the
-- same setting shows what's saved, wherever it's drawn.
function Window:newSwitch(parent, setting)
    local settings = self.options.settings
    local window = self
    local switch = self.ui:Toggle(parent, function(wanted)
        local changed, reason = settings:Set(setting.id, wanted)
        if not changed then
            window.client:Print(addon.Identity.chatPrefix .. " " .. setting.label .. " can't be changed: " ..
                tostring(reason) .. ".")
        end
        -- Whatever happened, it shows what's saved now.
        window:refreshSwitch(setting.id)
    end)
    self.switches[setting.id] = self.switches[setting.id] or {}
    table.insert(self.switches[setting.id], switch)
    self:refreshSwitch(setting.id)
    return switch
end

-- Redraws what shows setting `id`: its switches, or its color rows (the
-- sample in the saved color, that swatch outlined).
function Window:refreshSwitch(id)
    local switches = self.switches[id] or {}
    local index
    for index = 1, #switches do
        switches[index]:SetOn(self.options.settings:Get(id) == true)
    end
    local cards = self.colorRows[id] or {}
    for index = 1, #cards do
        local card = cards[index]
        local color = self.options.settings:Get(id)
        local text = self.options.settings:Entry(id) and self.options.settings:Entry(id).sample or ""
        card.sample:SetText(type(color) == "string" and ("|cff" .. color .. text .. "|r") or text)
        local position
        for position = 1, #card.swatches do
            local swatch = card.swatches[position]
            swatch.selected = swatch.color == color
            swatch:SetBorder(swatch.selected and "text" or "border")
        end
    end
end

-- The switches drawn for setting `id`, in the order they were made.
function Window:Switches(id)
    return self.switches[id] or {}
end

function Window:showSettingsTab(id)
    self.settingsTab = id
    if self.settingsTabRow ~= nil then
        self.settingsTabRow:Select(id)
    end
    local tabId, content
    for tabId, content in pairs(self.settingsContents or {}) do
        if tabId == id then
            content:Show()
        else
            content:Hide()
        end
    end
end

-- The gear popup, pinned under the gear: the current module's name and its
-- settings. Above it in the window, a catcher covering the rest closes it
-- on any click there.
function Window:buildPopup(frame)
    local ui = self.ui
    local window = self
    local level = frame:GetFrameLevel() or 1
    local catcher = ui:frame("Button", frame)
    catcher:SetAllPoints(frame)
    catcher:SetFrameLevel(level + 40)
    catcher:RegisterForClicks("AnyDown")
    catcher:SetScript("OnClick", function()
        window:CloseSettingsPopup()
    end)
    catcher:Hide()
    self.catcher = catcher

    local popup = ui:Panel(frame, { fill = "raised" })
    popup:SetWidth(AgfWindow.POPUP_WIDTH)
    popup:SetHeight(120)
    popup:SetPoint("TOPRIGHT", self.gear, "BOTTOMRIGHT", 0, -6)
    popup:SetFrameLevel(level + 50)
    popup:EnableMouse(true)
    popup.title = ui:Text(popup, "", "semibold", "title", "text")
    popup.title:SetPoint("TOPLEFT", popup, "TOPLEFT", Theme.SPACING.l, -Theme.SPACING.m)
    popup.bodies = {}
    local index
    for index = 1, #self.modules do
        local module = self.modules[index]
        local body = ui:frame("Frame", popup)
        body:SetPoint("TOPLEFT", popup, "TOPLEFT", Theme.SPACING.l, -40)
        body:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -Theme.SPACING.l, Theme.SPACING.m)
        local rows = module.settingsRows or {}
        local position
        for position = 1, #rows do
            local label = ui:Text(body, rows[position].label, "regular", "body", "text")
            label:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(position - 1) * 30 - 4)
            local switch = self:newSwitch(body, rows[position])
            switch:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(position - 1) * 30)
        end
        body:Hide()
        popup.bodies[module.id] = body
    end
    popup:Hide()
    self.popup = popup
end

function Window:build()
    local environment = self.environment
    self.ui = addon.Widgets.Create(environment)
    local ui = self.ui
    local frame = environment.CreateFrame("Frame", self.options.frameName, environment.UIParent)
    frame:SetSize(AgfWindow.WIDTH, AgfWindow.HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    self.frame = frame
    self:place()
    local window = self
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        window:savePosition()
    end)
    frame:SetScript("OnHide", function()
        window:CloseSettingsPopup()
    end)
    -- Hidden until it's all built.
    frame:Hide()

    self:buildBackground(frame)
    self:buildSidebar(frame)

    local close = ui:IconButton(frame, Theme.TEXTURES.close, AgfWindow.ICON_SIZE, function()
        window:Close()
    end)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -AgfWindow.MARGIN, -AgfWindow.MARGIN)
    self.close = close
    local gear = ui:IconButton(frame, Theme.TEXTURES.gear, AgfWindow.ICON_SIZE, function()
        window:ToggleSettingsPopup()
    end)
    gear:SetPoint("RIGHT", close, "LEFT", -Theme.SPACING.xs, 0)
    self.gear = gear

    local index
    for index = 1, #self.modules do
        local module = self.modules[index]
        local page = self:newPage(frame, module.title or module.label)
        if module.draw ~= nil then
            module.draw(page.body, ui)
        end
        self.pages[module.id] = page
    end
    self:buildSettingsPage(frame)
    self:buildPopup(frame)
    -- The gear, the X and the sidebar's buttons stay clickable over the
    -- catcher, so switching modules keeps the popup open.
    local level = frame:GetFrameLevel() or 1
    close:SetFrameLevel(level + 50)
    gear:SetFrameLevel(level + 50)
    for index = 1, #self.moduleButtons do
        self.moduleButtons[index]:SetFrameLevel(level + 50)
    end
    -- Escape closes it, once it's built.
    if type(self.options.frameName) == "string" and type(environment.UISpecialFrames) == "table" then
        table.insert(environment.UISpecialFrames, self.options.frameName)
    end
end

-- Position ------------------------------------------------------------------

function Window:place()
    local frame = self.frame
    local saved = self.options.loadPosition and self.options.loadPosition() or nil
    frame:ClearAllPoints()
    if type(saved) == "table" and pcall(frame.SetPoint, frame, saved.point, self.environment.UIParent,
        saved.relativePoint, saved.x, saved.y)
    then
        return
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", self.environment.UIParent, "CENTER", 0, 0)
end

function Window:savePosition()
    if self.options.savePosition == nil then
        return
    end
    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    if type(point) == "string" and type(x) == "number" and type(y) == "number" then
        self.options.savePosition({ point = point, relativePoint = relativePoint or point, x = x, y = y })
    end
end

-- Showing -------------------------------------------------------------------

function Window:refreshCharacter()
    local character = self.options.character and self.options.character() or nil
    if type(character) ~= "table" then
        character = {}
    end
    local name = character.name or "Unknown"
    if type(character.classColor) == "string" then
        name = "|c" .. character.classColor .. name .. "|r"
    end
    self.characterName:SetText(name)
    local details = {}
    if type(character.level) == "number" then
        details[#details + 1] = "Level " .. character.level
    end
    if type(character.className) == "string" then
        details[#details + 1] = character.className
    end
    self.characterDetails:SetText(table.concat(details, " "))
end

-- Opens the window on page `id` (a module's id or "settings"; nil keeps
-- the page it showed last). True, or false and why it couldn't open.
function Window:Open(id)
    if self.frame == nil then
        local ok, failure = pcall(self.build, self)
        if not ok then
            -- What was built is put away, and the next open starts over.
            if self.frame ~= nil then
                self.frame:Hide()
            end
            self.frame = nil
            self.pages, self.moduleButtons, self.switches, self.colorRows = {}, {}, {}, {}
            return false, failure
        end
    end
    local ok, failure = pcall(function()
        self:refreshCharacter()
        self:ShowPage(id or self.current)
    end)
    if not ok then
        self:Close()
        return false, failure
    end
    self.frame:Show()
    self.open = true
    return true
end

function Window:Close()
    if self.frame ~= nil then
        self.frame:Hide()
    end
    self:CloseSettingsPopup()
    self.open = false
end

-- Whether the window is showing. Escape hides it without a Close, so the
-- frame is asked where it can say.
function Window:IsOpen()
    if self.frame == nil then
        return false
    end
    if type(self.frame.IsShown) == "function" then
        local shown = self.frame:IsShown()
        if shown ~= nil then
            return shown == true
        end
    end
    return self.open == true
end

-- The page showing (or that will show on the next open).
function Window:Page()
    return self.current
end

-- Shows page `id`: a module's or "settings". An unknown id keeps the
-- current page.
function Window:ShowPage(id)
    if id ~= AgfWindow.SETTINGS and self:module(id) == nil then
        id = self.current
    end
    self.current = id
    if self.frame == nil then
        return
    end
    local pageId, page
    for pageId, page in pairs(self.pages) do
        if pageId == id then
            page:Show()
        else
            page:Hide()
        end
    end
    local index
    for index = 1, #self.moduleButtons do
        local button = self.moduleButtons[index]
        local on = button.id == id
        button.panel:SetFill(on and "green" or "surface")
        button.label:SetTextColor(Theme.Color(on and "text" or "muted"))
    end
    -- The gear belongs to modules; Settings has its own page.
    if id == AgfWindow.SETTINGS then
        self:CloseSettingsPopup()
        self.gear:Hide()
    else
        self.gearModule = id
        self.gear:Show()
        if self.popupOpen then
            self:showPopupFor(id)
        end
        local module = self:module(id)
        if module.onShow ~= nil then
            module.onShow()
        end
    end
end

-- The gear popup -----------------------------------------------------------

function Window:showPopupFor(id)
    local module = self:module(id)
    if module == nil then
        return
    end
    self.popup.title:SetText(module.label)
    local bodyId, body
    for bodyId, body in pairs(self.popup.bodies) do
        if bodyId == id then
            body:Show()
        else
            body:Hide()
        end
    end
end

-- Opens the current module's settings popup, or closes it when open.
function Window:ToggleSettingsPopup()
    if self.popupOpen then
        self:CloseSettingsPopup()
        return
    end
    if self.frame == nil or self:module(self.gearModule) == nil then
        return
    end
    self.popupOpen = true
    self:showPopupFor(self.gearModule)
    self.catcher:Show()
    self.popup:Show()
    self.gear:SetSelected(true)
end

function Window:CloseSettingsPopup()
    self.popupOpen = false
    if self.popup ~= nil then
        self.popup:Hide()
        self.catcher:Hide()
        self.gear:SetSelected(false)
    end
end

-- Whether the gear popup is open, and its title.
function Window:SettingsPopupOpen()
    return self.popupOpen == true
end

function Window:SettingsPopupTitle()
    if self.popup == nil or not self.popupOpen then
        return nil
    end
    return self.popup.title:GetText()
end
