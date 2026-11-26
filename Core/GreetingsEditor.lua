local _, addon = ...

-- What the AGF window's Greetings page shows, without frames: the selected
-- category, a grey dot on each category that's switched off or has no
-- greetings, the selected one's "when" line (Welcome back's with the
-- current minutes), its switch, its greetings, and a short note while its
-- switch is off. The page is dimmed while greet prompts are off.
--
-- One greeting at a time is open for editing (a row's position, or NEW for
-- + Add a greeting), with its draft. Save goes through the library: Add
-- for a new one (at the bottom), Save for an edit, greyed out while the
-- draft is empty or unchanged. A refused save keeps the draft and says why.
-- Selecting a category, or Cancel (another tab, another row, the window
-- closing), drops the draft quietly.
--
-- Greetings are read from the library each time View is asked, so a page
-- showing it reloads what's saved.
local GreetingsEditor = {
    OFF_NOTE = "Switched off: these greetings are kept, but not used.",
    NEW = "new",
    ADD = "Add",
    SAVE = "Save",
}
addon.GreetingsEditor = GreetingsEditor

local Editor = {}
Editor.__index = Editor

local function category(id)
    local categories = addon.GreetingLibrary.CATEGORIES
    local index
    for index = 1, #categories do
        if categories[index].id == id then
            return categories[index]
        end
    end
    return nil
end

-- options:
--   library     function() -> the GreetingLibrary, or nil when saved data is
--               unavailable
--   enabled     function(category) -> whether that category prompts
--   minutes     function() -> the welcome-back minutes
--   promptsOn   function() -> whether greet prompts are on at all
function GreetingsEditor.Create(options)
    return setmetatable({
        options = options or {},
        selected = addon.GreetingLibrary.CATEGORIES[1].id,
    }, Editor)
end

-- The line saying when category `id` is used; Welcome back's names the
-- minutes when they're known.
function GreetingsEditor.Description(id, minutes)
    local found = category(id)
    if found == nil then
        return ""
    end
    if found.whenMinutes ~= nil and type(minutes) == "number" then
        return string.format(found.whenMinutes, minutes, minutes == 1 and "minute" or "minutes")
    end
    return found.when
end

-- Selects category `id`, dropping any draft. False for an unknown one,
-- which changes nothing.
function Editor:Select(id)
    if category(id) == nil then
        return false
    end
    if id ~= self.selected then
        self:Cancel()
    end
    self.selected = id
    return true
end

-- Opens the greeting at `index` for editing, dropping any other draft.
-- False when there's no such greeting.
function Editor:StartEdit(index)
    local text = self:greetings(self.selected)[index]
    if text == nil then
        return false
    end
    self.open, self.original, self.draft, self.error = index, text, text, nil
    return true
end

-- Opens an empty box for a new greeting, dropping any other draft.
function Editor:StartAdd()
    self.open, self.original, self.draft, self.error = GreetingsEditor.NEW, "", "", nil
end

-- What's typed in the open box. A new draft clears the last error.
function Editor:SetDraft(text)
    if self.open == nil then
        return
    end
    self.draft = type(text) == "string" and text or ""
    self.error = nil
end

-- Forgets the last save error, keeping the draft.
function Editor:ClearError()
    self.error = nil
end

-- Closes the open box, dropping its draft.
function Editor:Cancel()
    self.open, self.original, self.draft, self.error = nil, nil, nil, nil
end

-- Whether the draft can be saved: something in it, and changed.
function Editor:canSave()
    if self.open == nil then
        return false
    end
    local tidied = addon.GreetingLibrary.Tidy(self.draft)
    return tidied ~= nil and tidied ~= addon.GreetingLibrary.Tidy(self.original)
end

-- Saves the draft through the library and closes the box. False when it
-- can't be saved; a refused save keeps the box open with the reason.
function Editor:Save()
    if not self:canSave() then
        return false
    end
    local library = self.options.library and self.options.library() or nil
    local saved, reason
    if library == nil then
        saved, reason = nil, "saved data is unavailable"
    elseif self.open == GreetingsEditor.NEW then
        saved, reason = library:Add(self.selected, self.draft)
    else
        saved, reason = library:Edit(self.selected, self.open, self.draft)
    end
    if not saved then
        self.error = "Can't save: " .. tostring(reason) .. "."
        return false
    end
    self:Cancel()
    return true
end

function Editor:Selected()
    return self.selected
end

function Editor:greetings(id)
    local library = self.options.library and self.options.library() or nil
    if library == nil then
        return {}
    end
    return library:Greetings(id)
end

function Editor:enabled(id)
    if self.options.enabled == nil then
        return true
    end
    return self.options.enabled(id) ~= false
end

-- What the page shows:
--   categories   { id, label, dot } in order; dot while it's off or empty
--   category     the selected category's id
--   description  when it's used
--   switchId     its switch's SettingsModel id; switchLabel its label
--   enabled      whether its switch is on
--   offNote      the note shown over its greetings while it's off, or nil
--   rows         its greetings, { index, text }, in saved order
--   dimmed       whether greet prompts are off, so the page is dimmed
--   open         the open greeting's position, NEW, or nil
--   draft        the open box's text
--   saveLabel    Add or Save; saveEnabled whether it can be clicked
--   error        why the last save failed, or nil
function Editor:View()
    local categories = {}
    local list = addon.GreetingLibrary.CATEGORIES
    local index
    for index = 1, #list do
        local id = list[index].id
        categories[index] = {
            id = id,
            label = list[index].label,
            dot = not self:enabled(id) or #self:greetings(id) == 0,
        }
    end
    local selected = category(self.selected)
    local enabled = self:enabled(selected.id)
    local rows = {}
    local greetings = self:greetings(selected.id)
    for index = 1, #greetings do
        rows[index] = { index = index, text = greetings[index] }
    end
    local minutes = self.options.minutes and self.options.minutes() or nil
    return {
        categories = categories,
        category = selected.id,
        description = GreetingsEditor.Description(selected.id, minutes),
        switchId = "greetCategory:" .. selected.id,
        switchLabel = selected.switch,
        enabled = enabled,
        offNote = not enabled and GreetingsEditor.OFF_NOTE or nil,
        rows = rows,
        dimmed = self.options.promptsOn ~= nil and self.options.promptsOn() == false,
        open = self.open,
        draft = self.draft,
        saveLabel = self.open == GreetingsEditor.NEW and GreetingsEditor.ADD or GreetingsEditor.SAVE,
        saveEnabled = self:canSave(),
        error = self.error,
    }
end
