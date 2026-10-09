local _, addon = ...

-- The one list of the add-on's settings, grouped into a section per feature.
-- The settings panel draws itself from it and slash commands change settings
-- through it, so the two can never disagree. A feature adds a setting by
-- adding one entry; nothing else needs to know about it.
--
-- Entry kinds:
--   toggle   get() -> boolean; set(boolean) -> true, or nil and a reason
--   action   run() performs it (a button, e.g. "Open Roster")
--   text     get() -> a line of text shown as is (e.g. the version)
-- `get`, `set` and `run` are called protected, so a failing feature never
-- breaks the panel or a slash command.
local SettingsModel = {
    KINDS = { toggle = true, action = true, text = true },
}
addon.SettingsModel = SettingsModel

local Model = {}
Model.__index = Model

function SettingsModel.Create()
    return setmetatable({
        sections = {},
        sectionsById = {},
        entries = {},
        listeners = {},
    }, Model)
end

local function isText(value)
    return type(value) == "string" and value ~= ""
end

-- Adds a section, shown in the order sections are added. False when the id
-- is unusable or already taken.
function Model:AddSection(id, label)
    if not isText(id) or not isText(label) or self.sectionsById[id] ~= nil then
        return false
    end
    local section = { id = id, label = label, entries = {} }
    self.sectionsById[id] = section
    table.insert(self.sections, section)
    return true
end

-- Returns nil when `entry` can be added, or why not.
local function entryProblem(entry)
    if type(entry) ~= "table" or not isText(entry.id) then
        return "entry has no id"
    end
    if not SettingsModel.KINDS[entry.kind] then
        return "entry kind is unknown"
    end
    if not isText(entry.label) and entry.kind ~= "text" then
        return "entry has no label"
    end
    if entry.kind == "action" then
        return type(entry.run) ~= "function" and "action has no run function" or nil
    end
    if type(entry.get) ~= "function" then
        return "entry has no get function"
    end
    if entry.kind == "toggle" and type(entry.set) ~= "function" then
        return "entry has no set function"
    end
    return nil
end

-- Adds `entry` to the end of a section. False when the section is unknown,
-- the id is taken, or the entry is incomplete.
function Model:Add(sectionId, entry)
    local section = self.sectionsById[sectionId]
    if section == nil or entryProblem(entry) ~= nil or self.entries[entry.id] ~= nil then
        return false
    end
    self.entries[entry.id] = entry
    table.insert(section.entries, entry)
    return true
end

-- The sections in order, each with its entries in order. For drawing only.
function Model:Sections()
    return self.sections
end

function Model:Entry(id)
    return self.entries[id]
end

-- The entry's current value, or nil when it has none or reading it failed.
function Model:Get(id)
    local entry = self.entries[id]
    if entry == nil or entry.get == nil then
        return nil
    end
    local ok, value = pcall(entry.get)
    if not ok then
        return nil
    end
    return value
end

-- Calls listener(id, value) after every successful change.
function Model:OnChange(listener)
    if type(listener) == "function" then
        table.insert(self.listeners, listener)
    end
end

function Model:notify(id)
    local value = self:Get(id)
    local index
    for index = 1, #self.listeners do
        pcall(self.listeners[index], id, value)
    end
end

-- Changes a setting. Returns true, or nil and a reason a player can read.
function Model:Set(id, value)
    local entry = self.entries[id]
    if entry == nil then
        return nil, "there is no such setting"
    end
    if entry.kind ~= "toggle" then
        return nil, "it can't be changed"
    end
    if type(value) ~= "boolean" then
        return nil, "it can only be on or off"
    end
    local ok, changed, reason = pcall(entry.set, value)
    if not ok then
        return nil, "it couldn't be saved"
    end
    if not changed then
        return nil, reason or "it couldn't be saved"
    end
    self:notify(id)
    return true
end

-- Flips a toggle. Returns its new value, or nil and a reason.
function Model:Toggle(id)
    local entry = self.entries[id]
    if entry == nil or entry.kind ~= "toggle" then
        return nil, "there is no such toggle"
    end
    local enabled = not self:Get(id)
    local changed, reason = self:Set(id, enabled)
    if not changed then
        return nil, reason
    end
    return enabled
end

-- Performs an action entry. False when it isn't one or it failed.
function Model:Run(id)
    local entry = self.entries[id]
    if entry == nil or entry.kind ~= "action" then
        return false
    end
    return (pcall(entry.run))
end
