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
-- 🗑 asks first: the first click arms that row's red Delete? (Delete?
-- (last one) on a category's last greeting), and a second click within
-- CONFIRM_SECONDS deletes it. An empty category says so, and that it won't
-- prompt until a greeting is added.
--
-- Greetings are read from the library each time View is asked, so a page
-- showing it reloads what's saved.
local GreetingsEditor = {
    OFF_NOTE = "Switched off: these greetings are kept, but not used.",
    NEW = "new",
    ADD = "Add",
    SAVE = "Save",
    DELETE = "Delete?",
    DELETE_LAST = "Delete? (last one)",
    CONFIRM_SECONDS = 5,
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
--   names       function() -> the user's own names for the preview, keyed
--               like GuildGreet:Names (name, main, character, ...)
--   now         function() -> the time in seconds, for the delete confirm
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
        self.confirm = nil
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

-- Inserts `placeholder` into the draft at byte `cursor` (0 is the start;
-- nil or out of range is the end, and a cursor inside a letter like é
-- moves to its start). Returns the new draft and the cursor after the
-- placeholder, or nil when nothing is open or it wouldn't fit in one chat
-- message.
function Editor:Insert(placeholder, cursor)
    if self.open == nil or type(placeholder) ~= "string" then
        return nil
    end
    local draft = self.draft or ""
    if type(cursor) ~= "number" or cursor < 0 or cursor > #draft then
        cursor = #draft
    end
    cursor = math.floor(cursor)
    while cursor > 0 and cursor < #draft do
        local byte = string.byte(draft, cursor + 1)
        if byte < 0x80 or byte >= 0xC0 then
            break
        end
        cursor = cursor - 1
    end
    local result = string.sub(draft, 1, cursor) .. placeholder .. string.sub(draft, cursor + 1)
    if #result > addon.GreetingLibrary.MAX_LENGTH then
        return nil
    end
    self:SetDraft(result)
    return result, cursor + #placeholder
end

-- The draft as a greeting would read for the user themself, or nil while
-- nothing's open or the draft is empty. Placeholders ignore case.
function Editor:preview()
    local tidied = self.open ~= nil and addon.GreetingLibrary.Tidy(self.draft) or nil
    if tidied == nil then
        return nil
    end
    local names = self.options.names and self.options.names() or {}
    return addon.GreetingLibrary.Render(tidied, names)
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

function Editor:now()
    local now = self.options.now and self.options.now() or nil
    return type(now) == "number" and now or 0
end

-- Whether the row at `index` has its Delete? showing: armed on that
-- greeting less than CONFIRM_SECONDS ago.
function Editor:confirming(index, greetings)
    local confirm = self.confirm
    return confirm ~= nil and confirm.index == index and confirm.category == self.selected
        and (greetings or self:greetings(self.selected))[index] == confirm.text
        and self:now() - confirm.at < GreetingsEditor.CONFIRM_SECONDS
end

-- 🗑 on the greeting at `index`: the first click arms its Delete?, and a
-- second while it shows deletes the greeting through the library. Returns
-- "armed" or "deleted", or nil and the reason it can't be deleted.
function Editor:Delete(index)
    local greetings = self:greetings(self.selected)
    if greetings[index] == nil then
        self.confirm = nil
        return nil, "that greeting is gone"
    end
    if not self:confirming(index, greetings) then
        self.confirm = { index = index, category = self.selected, text = greetings[index], at = self:now() }
        return "armed"
    end
    self.confirm = nil
    local library = self.options.library and self.options.library() or nil
    if library == nil then
        return nil, "saved data is unavailable"
    end
    local removed, reason = library:Remove(self.selected, index)
    if not removed then
        return nil, reason
    end
    -- The open box follows its greeting, or closes with it.
    if self.open == index then
        self:Cancel()
    elseif type(self.open) == "number" and self.open > index then
        self.open = self.open - 1
    end
    return "deleted"
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
--   rows         its greetings, { index, text, confirm }, in saved order;
--                confirm is the Delete? label while that row's is armed
--   empty        what the list says while it has no greetings, or nil
--   dimmed       whether greet prompts are off, so the page is dimmed
--   open         the open greeting's position, NEW, or nil
--   draft        the open box's text
--   saveLabel    Add or Save; saveEnabled whether it can be clicked
--   error        why the last save failed, or nil
--   preview      the draft filled in with the user's own names, or nil
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
        local confirm
        if self:confirming(index, greetings) then
            confirm = (#greetings == 1 and selected.lastOne) and GreetingsEditor.DELETE_LAST or GreetingsEditor.DELETE
        end
        rows[index] = { index = index, text = greetings[index], confirm = confirm }
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
        empty = #rows == 0 and selected.empty or nil,
        dimmed = self.options.promptsOn ~= nil and self.options.promptsOn() == false,
        open = self.open,
        draft = self.draft,
        saveLabel = self.open == GreetingsEditor.NEW and GreetingsEditor.ADD or GreetingsEditor.SAVE,
        saveEnabled = self:canSave(),
        error = self.error,
        preview = self:preview(),
    }
end
