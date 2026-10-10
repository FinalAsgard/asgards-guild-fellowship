local _, addon = ...

-- The Greetings window, built with the Details! Framework like the roster:
-- a button per Guild Greet category, that category's greetings each with
-- Edit, a box to add a greeting or change (or delete) the one being edited,
-- Restore controls, and a key to the placeholders. Every change goes through the GreetingLibrary, which saves
-- it account-wide, so the next prompt uses it. It is not unit tested; the
-- in-game checklist covers it.
--
-- Create() returns nil when the framework is missing or fails to build the
-- window, so the caller can print a message instead of raising Lua errors.
-- The window is created once, then hidden and shown.
local GreetingsWindow = {
    WIDTH = 560,
    HEIGHT = 540,
    LINE_HEIGHT = 24,
    LINES = 8,
    -- How long a Restore button waits for its confirming second click.
    CONFIRM_SECONDS = 5,
}
addon.GreetingsWindow = GreetingsWindow

local Window = {}
Window.__index = Window

local ERROR_COLOR = "|cffff4040"
local DIM_COLOR = "|cff9d9d9d"

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

local function button(parent, text, width)
    local result = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    result:SetSize(width, 22)
    result:SetText(text)
    return result
end

local function build(window, framework)
    local Library = addon.GreetingLibrary
    local width, lineHeight = GreetingsWindow.WIDTH, GreetingsWindow.LINE_HEIGHT
    local frameName = addon.Identity.addonName .. "Greetings"
    local panel = framework:CreateSimplePanel(UIParent, width, GreetingsWindow.HEIGHT, "Greetings", frameName)
    panel:SetFrameStrata("HIGH")
    window.panel = panel

    -- One button per category; the open one is disabled.
    window.tabs = {}
    local index
    for index = 1, #Library.CATEGORIES do
        local category = Library.CATEGORIES[index]
        local tab = button(panel, category.label, 124)
        tab:SetPoint("TOPLEFT", panel, "TOPLEFT", 12 + (index - 1) * 132, -30)
        tab:SetScript("OnClick", function()
            window:Select(category.id)
        end)
        window.tabs[category.id] = tab
    end

    window.when = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.when:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -60)
    window.when:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    window.when:SetJustifyH("LEFT")

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
                if row.position == window.editing then
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
                window:StartEdit(line.position)
            end
        end)
        return line
    end
    local listHeight = GreetingsWindow.LINES * lineHeight
    local scroll = framework:CreateScrollBox(panel, frameName .. "Scroll", refreshLines, {},
        width - 24, listHeight, GreetingsWindow.LINES, lineHeight, newLine, true)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -80)
    scroll:SetSize(width - 24, listHeight)
    scroll:CreateLines(newLine, GreetingsWindow.LINES)
    window.scroll = scroll

    window.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    window.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 6, -6)
    window.empty:SetText("No greetings, so this category shows no prompts.")

    -- The box for a new greeting, or the one being edited.
    local inputY = -80 - listHeight - 14
    local input = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    input:SetSize(width - 264, 22)
    input:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, inputY)
    input:SetAutoFocus(false)
    input:SetMaxLetters(Library.MAX_LENGTH)
    window.input = input
    window.save = button(panel, "Add", 70)
    window.save:SetPoint("LEFT", input, "RIGHT", 8, 0)
    window.save:SetScript("OnClick", function()
        window:Save()
    end)
    -- Delete sits with the editor and removes the greeting being edited.
    window.delete = button(panel, "Delete", 70)
    window.delete:SetPoint("LEFT", window.save, "RIGHT", 4, 0)
    window.delete:SetScript("OnClick", function()
        if window.editing ~= nil then
            window:Delete(window.editing)
        end
    end)
    window.cancel = button(panel, "Cancel", 70)
    window.cancel:SetPoint("LEFT", window.delete, "RIGHT", 4, 0)
    window.cancel:SetScript("OnClick", function()
        window:CancelEdit()
    end)
    input:SetScript("OnEnterPressed", function()
        window:Save()
    end)
    input:SetScript("OnEscapePressed", function()
        window:CancelEdit()
        input:ClearFocus()
    end)

    window.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.status:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, inputY - 28)
    window.status:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    window.status:SetJustifyH("LEFT")

    -- Restoring replaces greetings, so each button asks for a second click.
    window.restoreOne = button(panel, "Restore starter greetings", 200)
    window.restoreOne:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, inputY - 50)
    window.restoreOne:SetScript("OnClick", function()
        window:Restore(false)
    end)
    window.restoreAll = button(panel, "Restore all categories", 200)
    window.restoreAll:SetPoint("LEFT", window.restoreOne, "RIGHT", 8, 0)
    window.restoreAll:SetScript("OnClick", function()
        window:Restore(true)
    end)

    -- The placeholder key.
    local keyY = inputY - 86
    local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, keyY)
    header:SetText("Placeholders (upper or lower case both work)")
    for index = 1, #Library.PLACEHOLDERS do
        local placeholder = Library.PLACEHOLDERS[index]
        local line = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, keyY - 4 - index * 15)
        line:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
        line:SetJustifyH("LEFT")
        line:SetText("|cffffd100" .. placeholder[1] .. "|r  " .. placeholder[2])
    end
    local note = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, keyY - 4 - (#Library.PLACEHOLDERS + 1) * 15)
    note:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    note:SetJustifyH("LEFT")
    note:SetText(DIM_COLOR .. "First and last parts only differ on WoW Forever's two-part names." ..
        " On Retail they're the whole name.|r")

    panel:Hide()
end

-- `options.library()` returns the GreetingLibrary to show and edit, fresh
-- each time so it follows the saved data. `options.after(seconds, callback)`
-- runs a timer.
function GreetingsWindow.Create(client, options)
    local framework = frameworkFrom(client)
    if framework == nil then
        return nil, "the Details! Framework is not available"
    end
    local window = setmetatable({
        library = options.library,
        after = options.after,
        category = addon.GreetingLibrary.CATEGORIES[1].id,
    }, Window)
    local ok = pcall(build, window, framework)
    if not ok or window.panel == nil then
        return nil, "the Details! Framework could not build the window"
    end
    return window
end

function Window:IsShown()
    return self.panel:IsShown() == true
end

-- Shows the window on the open category.
function Window:Open()
    self:Redraw()
    self.panel:Show()
end

function Window:Hide()
    self.panel:Hide()
end

function Window:setStatus(text, isError)
    self.status:SetText(text and ((isError and ERROR_COLOR or "") .. text .. (isError and "|r" or "")) or "")
end

-- Fills the window from the library. Returns false instead of raising when
-- the framework misbehaves.
function Window:Redraw()
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
function Window:Select(category)
    self.category = category
    self.editing = nil
    self.confirming = nil
    self.input:SetText("")
    self:setStatus(nil)
    self:Redraw()
end

-- Puts the greeting at `position` in the box to be changed.
function Window:StartEdit(position)
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

function Window:CancelEdit()
    self.editing = nil
    self.input:SetText("")
    self:setStatus(nil)
    self:Redraw()
end

-- Adds the box's text, or saves it over the greeting being edited.
function Window:Save()
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

function Window:Delete(position)
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
function Window:Restore(all)
    local which = all and "all" or "one"
    if self.confirming ~= which then
        self.confirming = which
        self:Redraw()
        if type(self.after) == "function" then
            self.after(GreetingsWindow.CONFIRM_SECONDS, function()
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
