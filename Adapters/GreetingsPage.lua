local _, addon = ...

-- The greetings editor on the master frame's Greetings page, below Guild
-- Greet's settings, built with the Details! Framework like the roster: a
-- button per Guild Greet category, that category's greetings each with
-- Edit, a box to add a greeting or change (or delete) the one being edited,
-- Restore controls, and a key to the placeholders. Every change goes
-- through the GreetingLibrary, which saves it account-wide, so the next
-- prompt uses it. It is not unit tested; the in-game checklist covers it.
--
-- Create() draws it into a parent frame HEIGHT tall, and returns nil when
-- the framework fails to build it, so the caller can print a message
-- instead of raising Lua errors.
local GreetingsPage = {
    -- The narrowest it's drawn; on a wider page it takes the page's width.
    WIDTH = 560,
    -- Room for the editor's heading above it.
    TITLE_HEIGHT = 30,
    HEIGHT = 530,
    LINE_HEIGHT = 24,
    LINES = 8,
    -- How long a Restore button waits for its confirming second click.
    CONFIRM_SECONDS = 5,
}
addon.GreetingsPage = GreetingsPage

local Page = {}
Page.__index = Page

local ERROR_COLOR = "|cffff4040"
local DIM_COLOR = "|cff9d9d9d"

local function button(parent, text, width)
    local result = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    result:SetSize(width, 22)
    result:SetText(text)
    return result
end

local function build(page, framework, parent)
    local Library = addon.GreetingLibrary
    local lineHeight = GreetingsPage.LINE_HEIGHT
    -- As wide as the page it's drawn on, never narrower than WIDTH.
    local parentWidth = parent:GetWidth()
    local width = math.max(GreetingsPage.WIDTH, type(parentWidth) == "number" and parentWidth - 16 or 0)
    local top = GreetingsPage.TITLE_HEIGHT

    -- A heading like the settings' own, over a thin gold line, sets the
    -- editor apart from the settings above it.
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -2)
    rule:SetWidth(width - 12)
    rule:SetHeight(1)
    rule:SetColorTexture(0.83, 0.69, 0.22, 0.6)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -8)
    title:SetText("Greetings")
    local frameName = addon.Identity.addonName .. "Greetings"

    -- One button per category; the open one is disabled.
    page.tabs = {}
    local index
    for index = 1, #Library.CATEGORIES do
        local category = Library.CATEGORIES[index]
        local tab = button(parent, category.label, 124)
        tab:SetPoint("TOPLEFT", parent, "TOPLEFT", 12 + (index - 1) * 132, -top)
        tab:SetScript("OnClick", function()
            page:Select(category.id)
        end)
        page.tabs[category.id] = tab
    end

    page.when = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.when:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -top - 30)
    page.when:SetWidth(width - 28)
    page.when:SetJustifyH("LEFT")

    -- The category's greetings, each with Edit. The framework shows only the
    -- lines fetched with GetLine during a refresh and hides the rest, so a
    -- line is fetched only when it has a greeting; a shorter category then
    -- never shows a longer one's leftovers or empty rows with buttons.
    local function refreshLines(scroll, rows, offset, totalLines)
        local lineIndex
        for lineIndex = 1, totalLines do
            local row = rows[lineIndex + offset]
            if row ~= nil then
                local line = scroll:GetLine(lineIndex)
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(lineIndex - 1) * lineHeight)
                line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(lineIndex - 1) * lineHeight)
                line.position = row.position
                local text = row.text
                if row.position == page.editing then
                    text = "|cffffd100" .. text .. "|r"
                end
                line.text:SetText(text)
                line:Show()
            end
        end
    end
    local function newLine(scroll, lineIndex)
        local line = CreateFrame("Frame", nil, scroll)
        line:SetHeight(lineHeight)
        line:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(lineIndex - 1) * lineHeight)
        line:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -20, -(lineIndex - 1) * lineHeight)
        line.edit = button(line, "Edit", 50)
        line.edit:SetPoint("RIGHT", line, "RIGHT", -2, 0)
        line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line.text:SetPoint("LEFT", line, "LEFT", 6, 0)
        line.text:SetPoint("RIGHT", line.edit, "LEFT", -8, 0)
        line.text:SetJustifyH("LEFT")
        line.text:SetWordWrap(false)
        line.edit:SetScript("OnClick", function()
            if line.position ~= nil then
                page:StartEdit(line.position)
            end
        end)
        return line
    end
    local listHeight = GreetingsPage.LINES * lineHeight
    local scroll = framework:CreateScrollBox(parent, frameName .. "Scroll", refreshLines, {},
        width - 24, listHeight, GreetingsPage.LINES, lineHeight, newLine, true)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -top - 50)
    scroll:SetSize(width - 24, listHeight)
    scroll:CreateLines(newLine, GreetingsPage.LINES)
    page.scroll = scroll

    page.empty = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    page.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 6, -6)
    page.empty:SetText("No greetings, so this category shows no prompts.")

    -- The box for a new greeting, or the one being edited.
    local inputY = -top - 50 - listHeight - 14
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetSize(width - 264, 22)
    input:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, inputY)
    input:SetAutoFocus(false)
    -- Chat's limit is in bytes, and a letter like é takes two; the cap
    -- counts the terminating byte too.
    input:SetMaxBytes(Library.MAX_LENGTH + 1)
    page.input = input
    page.save = button(parent, "Add", 70)
    page.save:SetPoint("LEFT", input, "RIGHT", 8, 0)
    page.save:SetScript("OnClick", function()
        page:Save()
    end)
    -- Delete sits with the editor and removes the greeting being edited.
    page.delete = button(parent, "Delete", 70)
    page.delete:SetPoint("LEFT", page.save, "RIGHT", 4, 0)
    page.delete:SetScript("OnClick", function()
        if page.editing ~= nil then
            page:Delete(page.editing)
        end
    end)
    page.cancel = button(parent, "Cancel", 70)
    page.cancel:SetPoint("LEFT", page.delete, "RIGHT", 4, 0)
    page.cancel:SetScript("OnClick", function()
        page:CancelEdit()
    end)
    input:SetScript("OnEnterPressed", function()
        page:Save()
    end)
    input:SetScript("OnEscapePressed", function()
        page:CancelEdit()
        input:ClearFocus()
    end)

    page.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.status:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, inputY - 28)
    page.status:SetWidth(width - 28)
    page.status:SetJustifyH("LEFT")

    -- Restoring replaces greetings, so each button asks for a second click.
    page.restoreOne = button(parent, "Restore starter greetings", 200)
    page.restoreOne:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, inputY - 50)
    page.restoreOne:SetScript("OnClick", function()
        page:Restore(false)
    end)
    page.restoreAll = button(parent, "Restore all categories", 200)
    page.restoreAll:SetPoint("LEFT", page.restoreOne, "RIGHT", 8, 0)
    page.restoreAll:SetScript("OnClick", function()
        page:Restore(true)
    end)

    -- The placeholder key.
    local keyY = inputY - 86
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, keyY)
    header:SetText("Placeholders (upper or lower case both work)")
    for index = 1, #Library.PLACEHOLDERS do
        local placeholder = Library.PLACEHOLDERS[index]
        local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, keyY - 4 - index * 15)
        line:SetWidth(width - 36)
        line:SetJustifyH("LEFT")
        line:SetText("|cffffd100" .. placeholder[1] .. "|r  " .. placeholder[2])
    end
    local note = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, keyY - 4 - (#Library.PLACEHOLDERS + 1) * 15)
    note:SetWidth(width - 36)
    note:SetJustifyH("LEFT")
    note:SetText(DIM_COLOR .. "First and last parts only differ on WoW Forever's two-part names." ..
        " On Retail they're the whole name.|r")

    -- Showing the page shows the saved greetings as they are now.
    parent:HookScript("OnShow", function()
        page:Redraw()
    end)
end

-- Draws the editor into `parent`. `options.library()` returns the
-- GreetingLibrary to show and edit, fresh each time so it follows the saved
-- data. `options.after(seconds, callback)` runs a timer. Returns the page,
-- or nil and a reason.
function GreetingsPage.Create(framework, parent, options)
    local page = setmetatable({
        library = options.library,
        after = options.after,
        category = addon.GreetingLibrary.CATEGORIES[1].id,
    }, Page)
    local ok = pcall(build, page, framework, parent)
    if not ok then
        return nil, "the Details! Framework could not build the greetings editor"
    end
    page:Redraw()
    return page
end

function Page:setStatus(text, isError)
    self.status:SetText(text and ((isError and ERROR_COLOR or "") .. text .. (isError and "|r" or "")) or "")
end

-- Fills the editor from the library. Returns false instead of raising when
-- the framework misbehaves.
function Page:Redraw()
    return (pcall(function()
        local Library = addon.GreetingLibrary
        local index
        for index = 1, #Library.CATEGORIES do
            local category = Library.CATEGORIES[index]
            if category.id == self.category then
                self.tabs[category.id]:Disable()
                self.when:SetText(DIM_COLOR .. "Used when: |r" .. category.when)
            else
                self.tabs[category.id]:Enable()
            end
        end
        local greetings = self.library():Greetings(self.category)
        local rows = {}
        for index = 1, #greetings do
            rows[index] = { position = index, text = greetings[index] }
        end
        self.scroll:SetData(rows)
        self.scroll:Refresh()
        if #rows == 0 then
            self.empty:Show()
        else
            self.empty:Hide()
        end
        if self.editing ~= nil then
            self.save:SetText("Save")
            self.delete:Show()
            self.cancel:Show()
        else
            self.save:SetText("Add")
            self.delete:Hide()
            self.cancel:Hide()
        end
        self.restoreOne:SetText(self.confirming == "one" and "Click again to restore" or "Restore starter greetings")
        self.restoreAll:SetText(self.confirming == "all" and "Click again to restore all" or "Restore all categories")
    end))
end

-- Opens another category, dropping any unfinished edit.
function Page:Select(category)
    self.category = category
    self.editing = nil
    self.confirming = nil
    self.input:SetText("")
    self:setStatus(nil)
    self:Redraw()
end

-- Puts the greeting at `position` in the box to be changed.
function Page:StartEdit(position)
    local greetings = self.library():Greetings(self.category)
    if greetings[position] == nil then
        return
    end
    self.editing = position
    self.input:SetText(greetings[position])
    self.input:SetFocus()
    self:setStatus(nil)
    self:Redraw()
end

function Page:CancelEdit()
    self.editing = nil
    self.input:SetText("")
    self:setStatus(nil)
    self:Redraw()
end

-- Adds the box's text, or saves it over the greeting being edited.
function Page:Save()
    local library = self.library()
    local ok, reason
    if self.editing ~= nil then
        ok, reason = library:Edit(self.category, self.editing, self.input:GetText())
    else
        ok, reason = library:Add(self.category, self.input:GetText())
    end
    if not ok then
        self:setStatus("Not saved: " .. tostring(reason) .. ".", true)
        return
    end
    self:setStatus(self.editing ~= nil and "Greeting saved." or "Greeting added.")
    self.editing = nil
    self.input:SetText("")
    self.input:ClearFocus()
    self:Redraw()
end

function Page:Delete(position)
    local ok, reason = self.library():Remove(self.category, position)
    if not ok then
        self:setStatus("Not deleted: " .. tostring(reason) .. ".", true)
        return
    end
    if self.editing == position then
        self.input:SetText("")
    end
    self.editing = nil
    self:setStatus("Greeting deleted.")
    self:Redraw()
end

-- The first click arms the button and the second, within a few seconds,
-- restores this category's starters (`all` false) or every category's.
function Page:Restore(all)
    local which = all and "all" or "one"
    if self.confirming ~= which then
        self.confirming = which
        self:Redraw()
        if type(self.after) == "function" then
            self.after(GreetingsPage.CONFIRM_SECONDS, function()
                if self.confirming == which then
                    self.confirming = nil
                    self:Redraw()
                end
            end)
        end
        return
    end
    self.confirming = nil
    self.editing = nil
    self.input:SetText("")
    local ok, reason = self.library():Restore(not all and self.category or nil)
    if not ok then
        self:setStatus("Not restored: " .. tostring(reason) .. ".", true)
    else
        self:setStatus(all and "Starter greetings restored in every category."
            or "Starter greetings restored.")
    end
    self:Redraw()
end
