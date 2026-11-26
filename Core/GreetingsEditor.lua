local _, addon = ...

-- What the AGF window's Greetings page shows, without frames: the selected
-- category, a grey dot on each category that's switched off or has no
-- greetings, the selected one's "when" line (Welcome back's with the
-- current minutes), its switch, its greetings, and a short note while its
-- switch is off. The page is dimmed while greet prompts are off.
--
-- Greetings are read from the library each time View is asked, so a page
-- showing it reloads what's saved.
local GreetingsEditor = {
    OFF_NOTE = "Switched off: these greetings are kept, but not used.",
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

-- Selects category `id`. False for an unknown one, which changes nothing.
function Editor:Select(id)
    if category(id) == nil then
        return false
    end
    self.selected = id
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
    }
end
