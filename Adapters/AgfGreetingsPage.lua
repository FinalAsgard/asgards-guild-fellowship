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
-- ✎ turns a row into an edit box in place, and + Add a greeting opens an
-- empty one at the bottom: one at a time, growing to four lines, with Add
-- or Save (Enter) and Cancel (Escape), and a short error under it when a
-- save is refused. Under the box, Insert chips put {name}, {main} or
-- {character} at the cursor (More ▼ has the rarer ones), and a preview
-- fills the draft in with the user's own names. Switching category or tab,
-- opening another row, or the page hiding (another module, the window
-- closing) drops the draft.
--
-- 🗑 turns into a red Delete? (Delete? (last one) on the last greeting)
-- that deletes on a second click within 5 seconds. An empty category says
-- it won't prompt until a greeting is added, above + Add a greeting.
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
    BUTTON_WIDTH = 80,
    ADD_WIDTH = 150,
    CONFIRM_WIDTH = 140,
    ADD_GREETING = "+ Add a greeting",
    CHIP_WIDTH = 92,
    MORE = "More ▼",
    MORE_MENU_WIDTH = 300,
    -- How long a save error shows under the box.
    ERROR_SECONDS = 5,
}
addon.AgfGreetingsPage = AgfGreetingsPage

local Page = {}
Page.__index = Page

-- Draws the page into `content` with widget factory `ui`. options:
--   editor    the GreetingsEditor
--   settings  the SettingsModel holding the category switches
--   onError   function(text): tells the user why something didn't happen
--   after     function(seconds, callback) (optional): a timer, to clear a
--             save error and a Delete? that wasn't clicked
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
    -- Leaving the page (another module, the window closing) drops a draft.
    content:SetScript("OnHide", function()
        if page.options.editor:View().open ~= nil then
            page.options.editor:Cancel()
            page:Refresh()
        end
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
        page.area:SetVerticalScroll(0)
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
    self:buildEditBox()
    self.empty = ui:Text(self.list, "", "regular", "body", "muted")
    self.empty:SetJustifyH("LEFT")
    self.empty:SetWordWrap(true)
    self.empty:Hide()
    self.add = ui:Button(self.list, AgfGreetingsPage.ADD_GREETING, "secondary", function()
        page.options.editor:StartAdd()
        page:Refresh()
        page:focus()
    end)
    self.add:SetWidth(AgfGreetingsPage.ADD_WIDTH)
end

-- The one edit box, moved to the open row (or the bottom for a new
-- greeting): the multiline input, Add or Save and Cancel beside it, and a
-- line for a save error under it.
function Page:buildEditBox()
    local ui, page = self.ui, self
    local Library = addon.GreetingLibrary
    local edit = ui:frame("Frame", self.list)
    edit.input = ui:TextInput(edit, 300, Library.MAX_LENGTH, function(text)
        page.options.editor:SetDraft(text)
        page:refreshEditButtons()
    end, {
        multiline = true,
        maxLines = 4,
        maxBytes = Library.MAX_LENGTH,
        onEnter = function()
            page:Save()
        end,
        onEscape = function()
            page:Cancel()
        end,
        onResize = function()
            page:layout()
        end,
    })
    edit.input:SetPoint("TOPLEFT", edit, "TOPLEFT", 0, 0)
    edit.cancel = ui:Button(edit, "Cancel", "secondary", function()
        page:Cancel()
    end)
    edit.cancel:SetWidth(AgfGreetingsPage.BUTTON_WIDTH)
    edit.cancel:SetPoint("TOPRIGHT", edit, "TOPRIGHT", 0, 0)
    edit.save = ui:Button(edit, addon.GreetingsEditor.SAVE, "primary", function()
        page:Save()
    end)
    edit.save:SetWidth(AgfGreetingsPage.BUTTON_WIDTH)
    edit.save:SetPoint("RIGHT", edit.cancel, "LEFT", -Theme.SPACING.xs, 0)
    edit.input:SetPoint("RIGHT", edit.save, "LEFT", -Theme.SPACING.s, 0)
    edit.error = ui:Text(edit, "", "regular", "small", "red")
    edit.error:SetPoint("TOPLEFT", edit.input, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    edit.error:SetJustifyH("LEFT")

    -- Under it: Insert and the chips, then More, then the preview.
    local groups = addon.GreetingLibrary.PlaceholderGroups()
    edit.chipRow = ui:frame("Frame", edit)
    edit.chipRow:SetHeight(addon.Widgets.BUTTON_HEIGHT)
    edit.chipRow:SetPoint("LEFT", edit, "LEFT", 0, 0)
    edit.chipRow:SetPoint("RIGHT", edit, "RIGHT", 0, 0)
    edit.insertLabel = ui:Text(edit.chipRow, "Insert", "semibold", "small", "muted")
    edit.insertLabel:SetPoint("LEFT", edit.chipRow, "LEFT", 0, 0)
    edit.chips = {}
    local previous = edit.insertLabel
    local index
    for index = 1, #groups.chips do
        local placeholder = groups.chips[index]
        local chip = ui:Button(edit.chipRow, placeholder.text, "secondary", function()
            page:Insert(placeholder.text)
        end)
        chip:SetWidth(AgfGreetingsPage.CHIP_WIDTH)
        chip:SetPoint("LEFT", previous, "RIGHT", Theme.SPACING.s, 0)
        chip.placeholder = placeholder
        self:tooltip(chip, placeholder.text, placeholder.fills)
        edit.chips[index] = chip
        previous = chip
    end
    edit.moreMenu = ui:ContextMenu(edit)
    edit.moreMenu:SetWidth(AgfGreetingsPage.MORE_MENU_WIDTH)
    edit.more = ui:Button(edit.chipRow, AgfGreetingsPage.MORE, "secondary", function()
        local items = {}
        local position
        for position = 1, #groups.more do
            local placeholder = groups.more[position]
            items[position] = { label = placeholder.text .. "  |cff9d9d9d" .. placeholder.fills .. "|r",
                onClick = function()
                    page:Insert(placeholder.text)
                end }
        end
        -- The note, as a line that can't be picked.
        items[#items + 1] = { label = "|cff9d9d9d" .. addon.GreetingLibrary.MORE_NOTE .. "|r", disabled = true }
        edit.moreMenu:Open(edit.more, items)
    end)
    edit.more:SetWidth(AgfGreetingsPage.CHIP_WIDTH)
    edit.more:SetPoint("LEFT", previous, "RIGHT", Theme.SPACING.s, 0)
    edit.preview = ui:Text(edit, "", "regular", "small", "muted")
    edit.preview:SetPoint("TOPLEFT", edit.chipRow, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    edit.preview:SetPoint("RIGHT", edit, "RIGHT", 0, 0)
    edit.preview:SetJustifyH("LEFT")
    edit.preview:SetWordWrap(true)
    edit:Hide()
    self.edit = edit
end

-- A tooltip over `frame` while hovered: `title`, then `text`.
function Page:tooltip(frame, title, text)
    local environment = self.ui.environment
    frame:HookScript("OnEnter", function(self)
        local tooltip = environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:SetOwner(self, "ANCHOR_TOP")
            tooltip:SetText(title, 1, 1, 1)
            tooltip:AddLine(text, nil, nil, nil, true)
            tooltip:Show()
        end
    end)
    frame:HookScript("OnLeave", function()
        local tooltip = environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:Hide()
        end
    end)
end

-- Inserts `placeholder` at the box's cursor, and puts the cursor after it.
function Page:Insert(placeholder)
    local box = self.edit.input.box
    local draft, cursor = self.options.editor:Insert(placeholder, box:GetCursorPosition())
    if draft == nil then
        return false
    end
    self.edit.input:SetValue(draft)
    box:SetFocus()
    box:SetCursorPosition(cursor)
    self:refreshEditButtons()
    return true
end

function Page:focus()
    if self.view ~= nil and self.view.open ~= nil then
        self.edit.input.box:SetFocus()
    end
end

-- Add or Save: its label, and greyed out while there's nothing to save.
function Page:refreshEditButtons()
    local view = self.options.editor:View()
    self.edit.save:SetLabel(view.saveLabel)
    self.edit.save:SetActive(view.saveEnabled)
    self.edit.error:SetText(view.error or "")
    self.edit.preview:SetText(view.preview and ("Preview: " .. view.preview) or "")
    -- The chips and the preview go under the box, below the error if any.
    self.edit.chipRow:ClearAllPoints()
    self.edit.chipRow:SetPoint("TOPLEFT", view.error and self.edit.error or self.edit.input, "BOTTOMLEFT", 0,
        -Theme.SPACING.xs)
    self.edit.chipRow:SetPoint("RIGHT", self.edit, "RIGHT", 0, 0)
    if view.open == nil then
        self.edit.moreMenu:Close()
    end
    self:layout()
end

-- Saves the open greeting; a refused save shows why under the box for a
-- few seconds.
function Page:Save()
    local editor = self.options.editor
    if editor:Save() then
        self:Refresh()
        return true
    end
    local error = editor:View().error
    self:refreshEditButtons()
    if error ~= nil and self.options.after ~= nil then
        local page = self
        self.options.after(AgfGreetingsPage.ERROR_SECONDS, function()
            if editor:View().error == error then
                editor:ClearError()
                page:refreshEditButtons()
            end
        end)
    end
    return false
end

-- Closes the open box without saving.
function Page:Cancel()
    self.options.editor:Cancel()
    self:Refresh()
end

-- The edit box's height: the input, and the error line while there is one.
function Page:editHeight()
    local height = rawget(self.edit.input, "height") or self.edit.input:GetHeight()
    if type(height) ~= "number" then
        height = addon.Widgets.INPUT_HEIGHT
    end
    if (self.edit.error:GetText() or "") ~= "" then
        height = height + 18
    end
    -- The chips, and the preview's line (two when it's long).
    height = height + Theme.SPACING.xs + addon.Widgets.BUTTON_HEIGHT
    local preview = self.edit.preview:GetText() or ""
    if preview ~= "" then
        local previewHeight = self.edit.preview:GetStringHeight()
        height = height + Theme.SPACING.xs + (type(previewHeight) == "number" and previewHeight or 14)
    end
    return height + Theme.SPACING.s
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
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    -- Two lines at most; the game ends a longer one in "…".
    if type(row.text.SetMaxLines) == "function" then
        row.text:SetMaxLines(2)
    end
    local function delete()
        if row.greeting ~= nil then
            page:Delete(row.greeting.index)
        end
    end
    row.delete = ui:IconButton(row, Theme.TEXTURES.trash, AgfGreetingsPage.ICON_SIZE, delete)
    row.delete:SetPoint("RIGHT", row, "RIGHT", -pad, 0)
    -- 🗑's armed state, in its place.
    row.confirm = ui:Button(row, addon.GreetingsEditor.DELETE, "danger", delete)
    row.confirm:SetWidth(AgfGreetingsPage.CONFIRM_WIDTH)
    row.confirm:SetPoint("RIGHT", row, "RIGHT", -pad, 0)
    row.confirm:Hide()
    row.edit = ui:IconButton(row, Theme.TEXTURES.pencil, AgfGreetingsPage.ICON_SIZE, function()
        if row.greeting ~= nil then
            page.options.editor:StartEdit(row.greeting.index)
            page:Refresh()
            page:focus()
        end
    end)
    local function inside(frame)
        return type(frame.IsMouseOver) == "function" and frame:IsMouseOver()
    end
    local function hovered(on)
        row.hovered = on
        row:SetFill(on and "hover" or "surface")
        if on then
            row.edit:Show()
        else
            row.edit:Hide()
        end
        if on and row.confirm.armed ~= true then
            row.delete:Show()
        else
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
    row.confirm:HookScript("OnLeave", leaveIcon)
    row.hover = hovered
    row.edit:Hide()
    row.delete:Hide()
    self:arm(row, nil)
    self.rows[index] = row
    return row
end

-- Shows row's Delete? labelled `confirm` in place of 🗑, or hides it (nil).
-- ✎ and the text make room for it.
function Page:arm(row, confirm)
    local pad = Theme.SPACING.m
    row.confirm.armed = confirm ~= nil
    local rightOf = AgfGreetingsPage.ICON_SIZE
    if confirm ~= nil then
        row.confirm:SetLabel(confirm)
        row.confirm:Show()
        row.delete:Hide()
        rightOf = AgfGreetingsPage.CONFIRM_WIDTH
    else
        row.confirm:Hide()
        if row.hovered then
            row.delete:Show()
        end
    end
    row.edit:ClearAllPoints()
    row.edit:SetPoint("RIGHT", row, "RIGHT", -pad - rightOf - Theme.SPACING.xs, 0)
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", row, "LEFT", pad, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -pad - rightOf - AgfGreetingsPage.ICON_SIZE - Theme.SPACING.s, 0)
end

-- 🗑 or Delete? on the row at `index`: arms the confirm, or deletes. A
-- Delete? left alone goes back to 🗑 when it expires.
function Page:Delete(index)
    local editor = self.options.editor
    local result, reason = editor:Delete(index)
    if result == nil and self.options.onError ~= nil then
        self.options.onError("Can't delete: " .. tostring(reason) .. ".")
    end
    self:Refresh()
    if result == "armed" and self.options.after ~= nil then
        local page = self
        -- The clock counts whole seconds, so look again shortly if it
        -- hasn't quite run out yet.
        local checks = 0
        local function expire()
            page:Refresh()
            checks = checks + 1
            if checks < 3 and page:armed() then
                page.options.after(1, expire)
            end
        end
        self.options.after(addon.GreetingsEditor.CONFIRM_SECONDS, expire)
    end
    return result
end

-- Whether any row's Delete? is showing.
function Page:armed()
    local index
    for index = 1, #self.view.rows do
        if self.view.rows[index].confirm ~= nil then
            return true
        end
    end
    return false
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
    self.empty:SetText(view.empty or "")
    self.offNote:SetText(view.offNote or "")
    if view.offNote ~= nil then
        self.offNote:Show()
    else
        self.offNote:Hide()
    end
    for index = 1, #view.rows do
        local row = self:row(index)
        row.greeting = view.rows[index]
        row.text:SetText(view.rows[index].text)
        row.text:SetTextColor(Theme.Color(view.enabled and "text" or "disabled"))
        self:arm(row, view.rows[index].confirm)
    end
    for index = #view.rows + 1, #self.rows do
        self.rows[index].greeting = nil
    end
    -- The edit box, filled from the draft when it's opened.
    if view.open ~= nil then
        if self.editing ~= view.open or self.editingCategory ~= view.category then
            self.edit.input:SetValue(view.draft)
        end
        self.edit:Show()
    else
        self.edit:Hide()
    end
    self.editing, self.editingCategory = view.open, view.open and view.category or nil
    self.greetingsTab:SetAlpha(view.dimmed and AgfGreetingsPage.DIMMED_ALPHA or 1)
    self.dimmed = view.dimmed
    self:refreshEditButtons()
end

-- Lays the list out top to bottom: the rows (or, with none, why the
-- category won't prompt), the open one swapped for the edit box, then the
-- edit box for a new greeting or + Add a greeting.
function Page:layout()
    local view = self.view
    if view == nil then
        return
    end
    local list = self.list
    local function place(frame, top, height)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top)
        frame:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        frame:SetHeight(height)
        frame:Show()
    end
    local top = 0
    if view.empty ~= nil then
        self.empty:ClearAllPoints()
        self.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
        self.empty:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        self.empty:Show()
        local height = self.empty:GetStringHeight()
        top = (type(height) == "number" and height or 14) + Theme.SPACING.m
    else
        self.empty:Hide()
    end
    local index
    for index = 1, #view.rows do
        local row = self.rows[index]
        if view.open == index then
            row:Hide()
            place(self.edit, top, self:editHeight())
            top = top + self:editHeight() + AgfGreetingsPage.ROW_GAP
        else
            place(row, top, AgfGreetingsPage.ROW_HEIGHT)
            top = top + AgfGreetingsPage.ROW_HEIGHT + AgfGreetingsPage.ROW_GAP
        end
    end
    for index = #view.rows + 1, #self.rows do
        self.rows[index]:Hide()
    end
    if view.open == addon.GreetingsEditor.NEW then
        place(self.edit, top, self:editHeight())
        top = top + self:editHeight() + AgfGreetingsPage.ROW_GAP
        self.add:Hide()
    else
        self.add:ClearAllPoints()
        self.add:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top)
        self.add:Show()
        top = top + addon.Widgets.BUTTON_HEIGHT
    end
    self.list:SetHeight(math.max(top, 1))
end

function Page:ShowTab(id)
    if id ~= self.tab and self.view ~= nil and self.view.open ~= nil then
        self.options.editor:Cancel()
        self:Refresh()
    end
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
