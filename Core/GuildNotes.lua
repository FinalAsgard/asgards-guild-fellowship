local _, addon = ...

-- Writes the guild notes a NotePlan lists, a few at a time and never while
-- the player is busy (in combat, a boss encounter or a keystone run), then
-- prints one summary: how many notes were updated, which had free text cut,
-- and which were skipped and why. Each note is read live just before it's
-- written, so a note changed meanwhile is rewritten from what it says now.
--
-- options:
--   canEdit()             whether this character's rank can edit public notes
--   find(key)             -> the roster index and current public note of
--                            character `key`, or nil
--   write(index, note)    writes the public note; true when it was accepted
--   rules()               -> NoteWriter rules (twoPartNames, isName)
--   busy()                whether the player is busy
--   after(seconds, fn)    runs `fn` later; false when there are no timers
--   print(message)        tells the player
local GuildNotes = {
    -- Notes written per step, and the seconds between steps.
    PER_STEP = 3,
    STEP_SECONDS = 1,
    -- While the player is busy, check again this often.
    PAUSE_SECONDS = 2,
    NO_PERMISSION = "Guild notes weren't updated: your rank can't edit public notes.",
}
addon.GuildNotes = GuildNotes

local Notes = {}
Notes.__index = Notes

function GuildNotes.Create(options)
    return setmetatable({
        canEdit = options.canEdit,
        find = options.find,
        write = options.write,
        rules = options.rules or function()
            return {}
        end,
        busy = options.busy or function()
            return false
        end,
        after = options.after or function()
            return false
        end,
        print = options.print or function() end,
        queue = {},
        report = nil,
    }, Notes)
end

-- Queues every entry of `plan` (see NotePlan.Build). Without permission to
-- edit public notes, nothing is queued and the player is told so.
function Notes:Write(plan)
    if plan == nil or plan[1] == nil then
        return
    end
    local ok, allowed = pcall(self.canEdit)
    if not ok or allowed ~= true then
        self.print(GuildNotes.NO_PERMISSION)
        return
    end
    local index
    for index = 1, #plan do
        table.insert(self.queue, plan[index])
    end
    self.report = self.report or { updated = 0, cut = {}, skipped = {} }
    if not self.running then
        self.running = true
        self:Step()
    end
end

-- Writes one entry's note, recording what happened.
function Notes:WriteOne(entry)
    local found, index, note = pcall(self.find, entry.key)
    if not found or index == nil then
        table.insert(self.report.skipped, entry.name .. " (not in the guild roster)")
        return
    end
    local rules = self.rules()
    local wanted, wasCut, problem = addon.NoteWriter.Write(note, entry.markers, rules)
    if problem ~= nil then
        table.insert(self.report.skipped, entry.name .. " (the markers don't fit)")
        return
    end
    if wanted == nil then
        return
    end
    local written, accepted = pcall(self.write, index, wanted)
    if not written or accepted == false then
        table.insert(self.report.skipped, entry.name .. " (the game refused it)")
        return
    end
    self.report.updated = self.report.updated + 1
    if wasCut then
        table.insert(self.report.cut, entry.name)
    end
end

-- One step: waits while the player is busy, otherwise writes up to PER_STEP
-- notes. Without timers, everything is written now.
function Notes:Step()
    local function again(seconds)
        return self.after(seconds, function()
            self:Step()
        end)
    end
    if self.busy() and again(GuildNotes.PAUSE_SECONDS) then
        return
    end
    local count = 0
    while self.queue[1] ~= nil do
        if count >= GuildNotes.PER_STEP and again(GuildNotes.STEP_SECONDS) then
            return
        end
        self:WriteOne(table.remove(self.queue, 1))
        count = count + 1
    end
    self.running = false
    self:Summarize()
end

-- The one message after a batch; nothing when every note was already right.
function Notes:Summarize()
    local report = self.report
    self.report = nil
    if report == nil or (report.updated == 0 and report.skipped[1] == nil) then
        return
    end
    local parts = { "Guild notes: " .. report.updated .. " updated." }
    if report.cut[1] ~= nil then
        table.insert(parts, "Cut to fit: " .. table.concat(report.cut, ", ") .. ".")
    end
    if report.skipped[1] ~= nil then
        table.insert(parts, "Not written: " .. table.concat(report.skipped, ", ") .. ".")
    end
    self.print(table.concat(parts, " "))
end
