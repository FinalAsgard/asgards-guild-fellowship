local _, addon = ...

-- Rank management's Requirements tab: the promotion requirements editor in
-- the new window's style. On the left, every rank that can have
-- requirements, named by the rank promoted to ("→ Member") with how many
-- it has (PromotionsViewModel.RankList); on the right, the picked rank's
-- editor (PromotionsViewModel.Editor):
--   Automated checks  a switch each, with its number (days or level) where
--                     it takes one
--   Officer checks    each with ▲ ▼ to reorder, Rename and Delete (which
--                     asks first: the check's ticks go with it), then Add
--                     check and Add check needing a note
--   Rank settings     the "Alts should match this rank" switch and the
--                     snooze length
-- Every change goes through `actions` (each true, or false and why not),
-- which save and share it with the other officers; the editor is drawn
-- again from what was saved.
local Theme = addon.Theme

local RequirementsEditor = {
    LIST_WIDTH = 190,
    RANK_HEIGHT = 44,
    LINE_HEIGHT = 30,
    ITEM_HEIGHT = 40,
    SCROLL_STEP = 40,
    MOVE_WIDTH = 24,
    ACTION_WIDTH = 60,
    ADD_WIDTH = 190,
    AUTOMATED = "Automated checks",
    CHECKS = "Officer checks",
    SETTINGS = "Rank settings",
    ADD = "Add check",
    ADD_NOTE = "Add check needing a note",
    RENAME = "Rename",
    DELETE = "Delete",
    CONFIRM_DELETE = "Delete \"%s\"? Every tick and note on it is dropped too.",
    CANCEL = "Cancel",
    MATCH_ALTS = "Alts should match this rank",
    SNOOZE = "Snooze length (days)",
    NO_RANKS = "The guild's ranks aren't known yet.",
    -- A number an automated check starts with when it's switched on.
    DEFAULT_NUMBER = 7,
}
addon.RequirementsEditor = RequirementsEditor

local Editor = {}
Editor.__index = Editor

local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

-- Draws the tab into `parent` with widget factory `ui`. actions:
--   ranks      function() -> PromotionsViewModel.RankList's list, or nil
--              outside a guild
--   view       function(rank) -> PromotionsViewModel.Editor's model for
--              `rank`, or nil
--   add        function(rank, label, needsNote)
--   rename     function(rank, id, label)
--   automated  function(rank, kind, enabled, n)
--   matchAlts  function(rank, on)
--   snoozeDays function(rank, days)
--   move       function(rank, id, step)
--   delete     function(rank, id)
--   onError    function(text): why a change didn't happen
-- Refresh() draws it again from saved data.
function RequirementsEditor.Create(parent, ui, actions)
    local editor = setmetatable({ parent = parent, ui = ui, actions = actions, rankRows = {}, automatedRows = {},
        itemRows = {} }, Editor)
    editor:build()
    return editor
end

function Editor:build()
    local ui, parent, owner = self.ui, self.parent, self
    self.frame = ui:frame("Frame", parent)
    self.frame:SetAllPoints(parent)
    self.ranks = ui:frame("Frame", self.frame)
    self.ranks:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
    self.ranks:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 0, 0)
    self.ranks:SetWidth(RequirementsEditor.LIST_WIDTH)
    self.area, self.list = ui:ScrollList(self.frame, RequirementsEditor.SCROLL_STEP, 400)
    self.area:SetPoint("TOPLEFT", self.ranks, "TOPRIGHT", Theme.SPACING.l, 0)
    self.area:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
    local list = self.list
    self.title = ui:Text(list, "", "semibold", "heading", "text")
    self.sub = ui:Text(list, "", "regular", "body", "muted")
    self.mismatch = ui:Text(list, "", "regular", "small", "red")
    self.mismatch:SetJustifyH("LEFT")
    self.mismatch:SetWordWrap(true)
    self.empty = ui:Text(list, "", "regular", "body", "muted")
    self.automatedLabel = ui:SectionLabel(list, RequirementsEditor.AUTOMATED)
    self.checksLabel = ui:SectionLabel(list, RequirementsEditor.CHECKS)
    self.settingsLabel = ui:SectionLabel(list, RequirementsEditor.SETTINGS)
    self.noChecks = ui:Text(list, "", "regular", "body", "muted")
    self.add = ui:Button(list, RequirementsEditor.ADD, "secondary", function()
        owner:askLabel(RequirementsEditor.ADD, "", function(label)
            owner:run("add", owner.rank, label, false)
        end)
    end)
    self.add:SetWidth(RequirementsEditor.ADD_WIDTH)
    self.addNote = ui:Button(list, RequirementsEditor.ADD_NOTE, "secondary", function()
        owner:askLabel(RequirementsEditor.ADD_NOTE, "", function(label)
            owner:run("add", owner.rank, label, true)
        end)
    end)
    self.addNote:SetWidth(RequirementsEditor.ADD_WIDTH)
    self.matchAlts = ui:Toggle(list, function(wanted)
        owner:run("matchAlts", owner.rank, wanted)
    end)
    self.matchAltsText = ui:Text(list, RequirementsEditor.MATCH_ALTS, "regular", "body", "text")
    self.snooze = ui:Stepper(list, {
        min = addon.RankRequirements.SNOOZE_MIN,
        max = addon.RankRequirements.SNOOZE_MAX,
        onChange = function(value)
            owner:run("snoozeDays", owner.rank, value)
        end,
    })
    self.snoozeText = ui:Text(list, RequirementsEditor.SNOOZE, "regular", "body", "text")
    self.prompt = ui:TextPrompt(self.frame)
    self.noRanks = ui:Text(self.frame, RequirementsEditor.NO_RANKS, "regular", "body", "muted")
    self.noRanks:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
end

function Editor:Show()
    self.frame:Show()
end

function Editor:Hide()
    self.frame:Hide()
end

-- Runs action `name` with its arguments; a refusal says why. Draws the
-- editor again either way.
function Editor:run(name, ...)
    local ok, why = true, nil
    if self.actions[name] ~= nil then
        ok, why = self.actions[name](...)
    end
    if ok == false and self.actions.onError ~= nil then
        self.actions.onError("The requirements weren't changed: " .. tostring(why) .. ".")
    end
    self:Refresh()
end

-- Asks for a check's label, titled `title` and starting at `text`.
function Editor:askLabel(title, text, onSave)
    self.prompt:Open({
        title = title,
        text = text,
        maxLetters = addon.RankRequirements.MAX_LABEL,
        onSave = onSave,
    })
end

-- Rank `index` on the left, made on first use: the rank promoted to and,
-- under it, how many requirements it has; green while picked.
function Editor:rankRow(index)
    local row = self.rankRows[index]
    if row ~= nil then
        return row
    end
    local ui, owner = self.ui, self
    row = ui:frame("Button", self.ranks)
    ui:Round(row, Theme.RADIUS.button, "surface", false)
    row:SetHeight(RequirementsEditor.RANK_HEIGHT)
    row.label = ui:Text(row, "", "semibold", "body", "text")
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    row.count = ui:Text(row, "", "regular", "small", "muted")
    row.count:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    row:SetScript("OnClick", function(self)
        owner.rank = self.rank
        owner.confirming = nil
        owner.area:SetVerticalScroll(0)
        owner:Refresh()
    end)
    self.rankRows[index] = row
    return row
end

-- Automated check line `index`, made on first use: its switch and words,
-- and a stepper for its number.
function Editor:automatedRow(index)
    local row = self.automatedRows[index]
    if row ~= nil then
        return row
    end
    local ui, owner = self.ui, self
    row = ui:frame("Frame", self.list)
    row:SetHeight(RequirementsEditor.LINE_HEIGHT)
    row.toggle = ui:Toggle(row, function(wanted)
        local line = row.line
        if line ~= nil then
            owner:run("automated", owner.rank, line.kind, wanted, line.numberText and row.stepper:GetValue() or nil)
        end
    end)
    row.toggle:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.text = ui:Text(row, "", "regular", "body", "text")
    row.text:SetPoint("LEFT", row.toggle, "RIGHT", Theme.SPACING.s, 0)
    row.stepper = ui:Stepper(row, {
        min = 1,
        max = 3650,
        onChange = function(value)
            -- A number counts once the check is on; until then it waits.
            local line = row.line
            if line ~= nil and line.enabled then
                owner:run("automated", owner.rank, line.kind, true, value)
            end
        end,
    })
    row.stepper:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.number = ui:Text(row, "", "regular", "small", "muted")
    row.number:SetPoint("RIGHT", row.stepper, "LEFT", -Theme.SPACING.s, 0)
    self.automatedRows[index] = row
    return row
end

-- Officer check line `index`, made on first use: its label and kind, ▲ ▼,
-- Rename and Delete; and while Delete asks, the warning with Delete and
-- Cancel.
function Editor:itemRow(index)
    local row = self.itemRows[index]
    if row ~= nil then
        return row
    end
    local ui, owner = self.ui, self
    row = ui:Panel(self.list)
    row.label = ui:Text(row, "", "semibold", "body", "text")
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.xs)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.kind = ui:Text(row, "", "regular", "small", "muted")
    row.kind:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -2)
    row.delete = ui:TextButton(row, RequirementsEditor.DELETE, RequirementsEditor.ACTION_WIDTH, function()
        owner.confirming = row.item and row.item.id or nil
        owner:Refresh()
    end)
    row.delete:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.s, 0)
    row.rename = ui:TextButton(row, RequirementsEditor.RENAME, RequirementsEditor.ACTION_WIDTH, function()
        local item = row.item
        if item ~= nil then
            owner:askLabel(RequirementsEditor.RENAME .. " " .. item.label, item.label, function(label)
                owner:run("rename", owner.rank, item.id, label)
            end)
        end
    end)
    row.rename:SetPoint("RIGHT", row.delete, "LEFT", -Theme.SPACING.xs, 0)
    row.down = ui:TextButton(row, "▼", RequirementsEditor.MOVE_WIDTH, function()
        if row.item ~= nil and row.item.canDown then
            owner:run("move", owner.rank, row.item.id, 1)
        end
    end)
    row.down:SetPoint("RIGHT", row.rename, "LEFT", -Theme.SPACING.xs, 0)
    row.up = ui:TextButton(row, "▲", RequirementsEditor.MOVE_WIDTH, function()
        if row.item ~= nil and row.item.canUp then
            owner:run("move", owner.rank, row.item.id, -1)
        end
    end)
    row.up:SetPoint("RIGHT", row.down, "LEFT", -Theme.SPACING.xs, 0)
    row.label:SetPoint("RIGHT", row.up, "LEFT", -Theme.SPACING.s, 0)
    -- Delete's confirm, over the row.
    row.warning = ui:Text(row, "", "regular", "small", "red")
    row.warning:SetPoint("LEFT", row, "LEFT", Theme.SPACING.m, 0)
    row.warning:SetJustifyH("LEFT")
    row.warning:SetWordWrap(true)
    row.cancel = ui:Button(row, RequirementsEditor.CANCEL, "secondary", function()
        owner.confirming = nil
        owner:Refresh()
    end)
    row.cancel:SetWidth(RequirementsEditor.ACTION_WIDTH + 10)
    row.cancel:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.s, 0)
    row.confirm = ui:Button(row, RequirementsEditor.DELETE, "danger", function()
        local item = row.item
        owner.confirming = nil
        if item ~= nil then
            owner:run("delete", owner.rank, item.id)
        end
    end)
    row.confirm:SetWidth(RequirementsEditor.ACTION_WIDTH + 10)
    row.confirm:SetPoint("RIGHT", row.cancel, "LEFT", -Theme.SPACING.xs, 0)
    row.warning:SetPoint("RIGHT", row.confirm, "LEFT", -Theme.SPACING.s, 0)
    self.itemRows[index] = row
    return row
end

-- Places `frame` at height `top` of the editor, `left` in.
local function place(list, frame, top, left)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", list, "TOPLEFT", left or 0, -top)
    frame:Show()
end

-- Draws the rank list and the picked rank's editor from saved data.
function Editor:Refresh()
    local ranks = self.actions.ranks ~= nil and self.actions.ranks() or nil
    ranks = ranks or {}
    local found = false
    local index
    for index = 1, #ranks do
        if ranks[index].rank == self.rank then
            found = true
        end
    end
    if not found then
        -- The newest members' rank, or the first that has requirements.
        self.rank = ranks[1] and ranks[1].rank or nil
        for index = 1, #ranks do
            if ranks[index].count > 0 then
                self.rank = ranks[index].rank
                break
            end
        end
    end
    for index = 1, math.max(#ranks, #self.rankRows) do
        local entry = ranks[index]
        local row = entry ~= nil and self:rankRow(index) or self.rankRows[index]
        setShown(row, entry ~= nil)
        if entry ~= nil then
            row.rank = entry.rank
            row.label:SetText(entry.text)
            row.count:SetText(entry.countText)
            row.selected = entry.rank == self.rank
            row:SetFill(row.selected and "green" or "surface")
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.ranks, "TOPLEFT", 0, -(index - 1) * (RequirementsEditor.RANK_HEIGHT
                + Theme.SPACING.xs))
            row:SetPoint("RIGHT", self.ranks, "RIGHT", 0, 0)
        end
    end
    local model = self.rank ~= nil and self.actions.view ~= nil and self.actions.view(self.rank) or nil
    setShown(self.noRanks, model == nil)
    setShown(self.area, model ~= nil)
    self.model = model
    if model == nil then
        return
    end
    self:drawEditor(model, ranks)
end

function Editor:drawEditor(model, ranks)
    local list = self.list
    local top = 0
    local title
    local index
    for index = 1, #ranks do
        if ranks[index].rank == self.rank then
            title = ranks[index].text
        end
    end
    self.title:SetText(title or "")
    place(list, self.title, top)
    top = top + 26
    self.sub:SetText(model.rankText .. " · " .. model.nextText)
    place(list, self.sub, top)
    top = top + 22
    setShown(self.mismatch, model.mismatch ~= nil)
    if model.mismatch ~= nil then
        self.mismatch:SetText(model.mismatch)
        place(list, self.mismatch, top)
        self.mismatch:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        top = top + 34
    end
    top = top + Theme.SPACING.m

    -- Automated checks: a switch each, with its number.
    place(list, self.automatedLabel, top)
    top = top + 22
    local automated = model.automated or {}
    for index = 1, math.max(#automated, #self.automatedRows) do
        local line = automated[index]
        local row = line ~= nil and self:automatedRow(index) or self.automatedRows[index]
        setShown(row, line ~= nil)
        if line ~= nil then
            row.line = line
            place(list, row, top)
            row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
            row.toggle:SetOn(line.enabled)
            row.text:SetText(line.text)
            setShown(row.stepper, line.numberText ~= nil)
            setShown(row.number, line.numberText ~= nil)
            if line.numberText ~= nil then
                local range = addon.RankRequirements.AUTOMATED[line.kind] or {}
                row.number:SetText(line.numberText)
                row.stepper:SetValue(math.max(range.low or 1, math.min(range.high or 3650,
                    line.n or RequirementsEditor.DEFAULT_NUMBER)))
            end
            top = top + RequirementsEditor.LINE_HEIGHT
        end
    end
    top = top + Theme.SPACING.m

    -- Officer checks.
    place(list, self.checksLabel, top)
    top = top + 22
    local items = model.items or {}
    setShown(self.noChecks, items[1] == nil)
    if items[1] == nil then
        self.noChecks:SetText(model.empty or "")
        place(list, self.noChecks, top)
        top = top + RequirementsEditor.LINE_HEIGHT
    end
    for index = 1, math.max(#items, #self.itemRows) do
        local item = items[index]
        local row = item ~= nil and self:itemRow(index) or self.itemRows[index]
        setShown(row, item ~= nil)
        if item ~= nil then
            row.item = item
            place(list, row, top)
            row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
            row:SetHeight(RequirementsEditor.ITEM_HEIGHT)
            local confirming = self.confirming == item.id
            row.label:SetText(item.label)
            row.kind:SetText(item.kindText)
            row.warning:SetText(string.format(RequirementsEditor.CONFIRM_DELETE, item.label))
            local parts = { row.label, row.kind, row.delete, row.rename, row.up, row.down }
            local part
            for _, part in ipairs(parts) do
                setShown(part, not confirming)
            end
            setShown(row.up, not confirming and item.canUp)
            setShown(row.down, not confirming and item.canDown)
            setShown(row.warning, confirming)
            setShown(row.confirm, confirming)
            setShown(row.cancel, confirming)
            top = top + RequirementsEditor.ITEM_HEIGHT + Theme.SPACING.xs
        end
    end
    place(list, self.add, top + Theme.SPACING.xs)
    place(list, self.addNote, top + Theme.SPACING.xs, RequirementsEditor.ADD_WIDTH + Theme.SPACING.s)
    top = top + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.l

    -- Rank settings.
    place(list, self.settingsLabel, top)
    top = top + 22
    place(list, self.matchAlts, top)
    self.matchAlts:SetOn(model.matchAlts == true)
    self.matchAltsText:ClearAllPoints()
    self.matchAltsText:SetPoint("LEFT", self.matchAlts, "RIGHT", Theme.SPACING.s, 0)
    top = top + RequirementsEditor.LINE_HEIGHT
    place(list, self.snooze, top)
    self.snooze:SetValue(model.snoozeDays or addon.RankRequirements.SNOOZE_DEFAULT)
    self.snoozeText:ClearAllPoints()
    self.snoozeText:SetPoint("LEFT", self.snooze, "RIGHT", Theme.SPACING.s, 0)
    top = top + RequirementsEditor.LINE_HEIGHT
    list:SetHeight(math.max(top, 1))
end
