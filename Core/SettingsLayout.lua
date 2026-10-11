local _, addon = ...

-- Lays out a list of settings sections for drawing: where each section
-- header and each entry goes, how tall each one is, and how tall the whole
-- list is. Positions are offsets down from the top of the area, in pixels.
-- The total height is what makes a page scroll when it's taller than its
-- frame. Pure: it reads only the sections and a shown check, and returns
-- plain numbers.
local SettingsLayout = {
    -- Room above the first section.
    TOP = 8,
    -- One row: a check box, a button, a line of text, or a label.
    ROW = 26,
    -- A section header's own height.
    HEADER = 20,
    -- The gap after each section, and above a heading within one.
    SECTION_GAP = 12,
    -- A text line's height in a multi-line box, and the room around the
    -- text inside the box.
    INPUT_LINE_HEIGHT = 14,
    INPUT_INSET = 6,
}
addon.SettingsLayout = SettingsLayout

-- The lines of text an input entry's box shows: one, or `entry.lines`.
function SettingsLayout.InputLines(entry)
    if type(entry.lines) == "number" and entry.lines > 1 then
        return math.floor(entry.lines)
    end
    return 1
end

-- How many rows an entry's text box takes below its label.
function SettingsLayout.InputRows(entry)
    local lines = SettingsLayout.InputLines(entry)
    if lines == 1 then
        return 1
    end
    local height = lines * SettingsLayout.INPUT_LINE_HEIGHT + 2 * SettingsLayout.INPUT_INSET
    return math.ceil(height / SettingsLayout.ROW)
end

-- The room an entry takes: a text box its label's row plus the box's rows,
-- a slider or a color its label's row plus a row of controls, a heading a
-- gap and a row, and everything else one row. Returns the gap above it and
-- its height.
local function measure(entry)
    local row = SettingsLayout.ROW
    if entry.kind == "input" then
        return 0, (1 + SettingsLayout.InputRows(entry)) * row
    end
    if (entry.kind == "number" and entry.slider) or entry.kind == "color" then
        return 0, 2 * row
    end
    if entry.kind == "heading" then
        return SettingsLayout.SECTION_GAP, row
    end
    return 0, row
end

-- `sections` is a list of { id, label, entries }; `isShown(entry)` says
-- whether an entry is drawn (one that isn't takes no room). Returns
--   { items = { item, ... }, byId = { [entry id] = item }, height }
-- where each item is { kind = "header", section, y, height } or
-- { kind = "entry", entry, y, height }, in drawing order.
function SettingsLayout.Layout(sections, isShown)
    local layout = { items = {}, byId = {} }
    local y = SettingsLayout.TOP
    local sectionIndex, entryIndex
    for sectionIndex = 1, #sections do
        local section = sections[sectionIndex]
        table.insert(layout.items, { kind = "header", section = section, y = y, height = SettingsLayout.HEADER })
        y = y + SettingsLayout.HEADER
        for entryIndex = 1, #section.entries do
            local entry = section.entries[entryIndex]
            if isShown == nil or isShown(entry) then
                local gap, height = measure(entry)
                local item = { kind = "entry", entry = entry, y = y + gap, height = height }
                table.insert(layout.items, item)
                layout.byId[entry.id] = item
                y = y + gap + height
            end
        end
        y = y + SettingsLayout.SECTION_GAP
    end
    layout.height = y
    return layout
end
