local _, addon = ...

-- The Greetings page in the AGF window, drawn with the Theme and Widgets.
-- Two tabs, Greetings and Settings. The Greetings tab has the categories in
-- a segmented control (each with a grey dot while it's off or empty), a
-- line saying when the selected one is used beside its switch, and its
-- greetings: spacious rows of at most two lines, the full text on
-- mouseover, ✎ and 🗑 on hover, scrolled with the mouse wheel. While the
-- category's switch is off its greetings are dimmed under a short note;
-- while greet prompts are off the whole tab is dimmed but still usable.
--
-- Everything it shows comes from GreetingsEditor and the SettingsModel;
-- Refresh redraws it from them (and so from saved data).
local Theme = addon.Theme

local AgfGreetingsPage = {
    TABS = {
        { id = "greetings", label = "Greetings" },
        { id = "settings", label = "Settings" },
    },
    SEGMENT_WIDTH = 480,
    ROW_HEIGHT = 52,
    ROW_GAP = 6,
    SCROLL_STEP = 58,
    ICON_SIZE = 22,
    DIMMED_ALPHA = 0.5,
}
addon.AgfGreetingsPage = AgfGreetingsPage

local Page = {}
Page.__index = Page

-- Draws the page into `content` with widget factory `ui`. options:
--   editor    the GreetingsEditor
--   settings  the SettingsModel holding the category switches
--   onError   function(text): tells the user why something didn't happen
--   onEdit    function(category, index) (optional): a row's ✎
--   onDelete  function(category, index) (optional): a row's 🗑
function AgfGreetingsPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options, rows = {} }, Page)
    page:build()
    page:ShowTab(AgfGreetingsPage.TABS[1].id)
    return page
end

function Page:build()
    local ui, content, page = self.ui, self.content, self
    self.tabs = ui:Tabs(content, AgfGreetingsPage.TABS, function(id)
        page:ShowTab(id)
    end)
    self.tabs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    self.tabs:SetPoint("RIGHT", content, "RIGHT", 0, 0)

    local function tab()
        local frame = ui:frame("Frame", content)
        frame:SetPoint("TOPLEFT", self.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.l)
        frame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
        return frame
    end
    self.greetingsTab = tab()
    self.settingsTab = tab()

    local body = self.greetingsTab
    local items = {}
    local categories = addon.GreetingLibrary.CATEGORIES
    local index
    for index = 1, #categories do
        items[index] = { id = categories[index].id, label = categories[index].label }
    end
    self.categories = ui:Segmented(body, items, AgfGreetingsPage.SEGMENT_WIDTH, function(id)
        page.options.editor:Select(id)
        page:Refresh()
    end)
    self.categories:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)

    self.switch = ui:Toggle(body, function(wanted)
        local view = page.view
        if view == nil then
            return
        end
        local changed, reason = page.options.settings:Set(view.switchId, wanted)
        if not changed and page.options.onError ~= nil then
            page.options.onError(view.switchLabel .. " can't be changed: " .. tostring(reason) .. ".")
        end
        page:Refresh()
    end)
    self.switch:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -AgfGreetingsPage.ROW_GAP - 32)
    self.switchLabel = ui:Text(body, "", "semibold", "body", "text")
    self.switchLabel:SetPoint("RIGHT", self.switch, "LEFT", -Theme.SPACING.s, 0)
    self.description = ui:Text(body, "", "regular", "body", "muted")
    self.description:SetPoint("LEFT", body, "LEFT", 0, 0)
    self.description:SetPoint("TOP", self.switch, "TOP", 0, -2)
    self.description:SetPoint("RIGHT", self.switchLabel, "LEFT", -Theme.SPACING.m, 0)
    self.description:SetJustifyH("LEFT")
    self.offNote = ui:Text(body, "", "regular", "small", "muted")
    self.offNote:SetPoint("TOPLEFT", self.description, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    self.offNote:SetJustifyH("LEFT")

    self.area, self.list = ui:ScrollList(body, AgfGreetingsPage.SCROLL_STEP)
    self.area:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -110)
    self.area:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
end

-- Row `index` of the list, made on first use: the greeting on a card, its
-- full text on mouseover, ✎ and 🗑 while hovered.
function Page:row(index)
    local row = self.rows[index]
    if row ~= nil then
        return row
    end
    local ui, page = self.ui, self
    row = ui:frame("Button", self.list)
    ui:Round(row, Theme.RADIUS.card, "surface", "border")
    row:SetHeight(AgfGreetingsPage.ROW_HEIGHT)
    local pad = Theme.SPACING.m
    row.text = ui:Text(row, "", "regular", "body", "text")
    row.text:SetPoint("LEFT", row, "LEFT", pad, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -pad - 2 * AgfGreetingsPage.ICON_SIZE - Theme.SPACING.s, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    -- Two lines at most; the game ends a longer one in "…".
    if type(row.text.SetMaxLines) == "function" then
        row.text:SetMaxLines(2)
    end
    local function act(callback)
        return function()
            if callback ~= nil and row.greeting ~= nil then
                callback(page.view.category, row.greeting.index)
            end
        end
    end
    row.delete = ui:IconButton(row, Theme.TEXTURES.trash, AgfGreetingsPage.ICON_SIZE, act(self.options.onDelete))
    row.delete:SetPoint("RIGHT", row, "RIGHT", -pad, 0)
    row.edit = ui:IconButton(row, Theme.TEXTURES.pencil, AgfGreetingsPage.ICON_SIZE, act(self.options.onEdit))
    row.edit:SetPoint("RIGHT", row.delete, "LEFT", -Theme.SPACING.xs, 0)
    local function inside(frame)
        return type(frame.IsMouseOver) == "function" and frame:IsMouseOver()
    end
    local function hovered(on)
        row.hovered = on
        row:SetFill(on and "hover" or "surface")
        if on then
            row.edit:Show()
            row.delete:Show()
        else
            row.edit:Hide()
            row.delete:Hide()
        end
        local tooltip = ui.environment.GameTooltip
        if type(tooltip) == "table" then
            if on and row.greeting ~= nil then
                tooltip:SetOwner(row, "ANCHOR_TOP")
                tooltip:SetText(row.greeting.text, 1, 1, 1, 1, true)
                tooltip:Show()
            else
                tooltip:Hide()
            end
        end
    end
    row:SetScript("OnEnter", function()
        hovered(true)
    end)
    row:SetScript("OnLeave", function()
        -- Moving onto ✎ or 🗑 leaves the row but keeps them.
        if not inside(row) then
            hovered(false)
        end
    end)
    local function leaveIcon()
        if not inside(row) then
            hovered(false)
        end
    end
    row.edit:HookScript("OnLeave", leaveIcon)
    row.delete:HookScript("OnLeave", leaveIcon)
    row.hover = hovered
    row.edit:Hide()
    row.delete:Hide()
    self.rows[index] = row
    return row
end

-- Redraws the Greetings tab from the editor's view.
function Page:Refresh()
    local view = self.options.editor:View()
    self.view = view
    local index
    for index = 1, #view.categories do
        self.categories:SetDot(view.categories[index].id, view.categories[index].dot)
    end
    self.categories:Select(view.category)
    self.description:SetText(view.description)
    self.switchLabel:SetText(view.switchLabel or "")
    self.switch:SetOn(view.enabled)
    self.offNote:SetText(view.offNote or "")
    if view.offNote ~= nil then
        self.offNote:Show()
    else
        self.offNote:Hide()
    end
    local top = 0
    for index = 1, #view.rows do
        local row = self:row(index)
        row.greeting = view.rows[index]
        row.text:SetText(view.rows[index].text)
        row.text:SetTextColor(Theme.Color(view.enabled and "text" or "disabled"))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, -top)
        row:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
        row:Show()
        top = top + AgfGreetingsPage.ROW_HEIGHT + AgfGreetingsPage.ROW_GAP
    end
    for index = #view.rows + 1, #self.rows do
        self.rows[index].greeting = nil
        self.rows[index]:Hide()
    end
    self.list:SetHeight(math.max(top, 1))
    self.greetingsTab:SetAlpha(view.dimmed and AgfGreetingsPage.DIMMED_ALPHA or 1)
    self.dimmed = view.dimmed
end

function Page:ShowTab(id)
    self.tab = id
    self.tabs:Select(id)
    if id == "settings" then
        self.greetingsTab:Hide()
        self.settingsTab:Show()
    else
        self.settingsTab:Hide()
        self.greetingsTab:Show()
    end
end

-- The tab showing.
function Page:Tab()
    return self.tab
end
