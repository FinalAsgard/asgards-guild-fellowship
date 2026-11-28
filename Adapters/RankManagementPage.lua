local _, addon = ...

-- The officers' Rank management page in the AGF window. Its Due tab lists
-- the players up for a rank (RankUpViewModel.Due) in a pooled list: each
-- row names the player and the rank they'd be promoted to ("→ Member"),
-- says Ready, Match or Due, and lists the characters to promote or what
-- the player is still waiting on. A Due row has Snooze, which puts the
-- player off for their rank's snooze length in one click. A search box
-- narrows the list; the footer counts Ready, Match, Due and snoozed and
-- says that the promotion itself happens on the guild roster.
--
-- Promote to picks one rank (or Any rank): the list narrows to the players
-- up for it and becomes a grid, a column per requirement of the rank, each
-- headed by its label. An automated cell says met or missing with the
-- add-on's detail; an officer check is a check box, ticked or unticked at
-- once with no confirm. A check that needs a note asks for it first (Save
-- ticks it, Cancel leaves it unticked), and a ticked one shows its note or
-- who ticked it. Right-clicking a failed automated cell offers Override as
-- met... (with an optional reason), and an overridden one Remove override.
--
-- Missing picks one requirement of the picked rank (or of any rank): the
-- list keeps the Due players missing it, a chip with an X names it, its
-- column header is highlighted in the grid, and the footer counts them.
--
-- The All players tab (labelled with the player count) lists every player
-- with its status in words (RankUpViewModel.All), the soonest first, and
-- a status filter: All, Snoozed or Not yet.
--
-- The Requirements tab is the requirements editor (RequirementsEditor).
--
-- It's built when the page is shown (Refresh), and again when the owner
-- says something changed (Update), keeping the list where it's scrolled.
local Theme = addon.Theme

local RankManagementPage = {
    TABS = {
        { id = "due", label = "Due" },
        { id = "all", label = "All players" },
        { id = "requirements", label = "Requirements" },
    },
    ALL_LABEL = "All players (%d)",
    -- All players' status filter.
    FILTERS = {
        { id = "all", label = "All" },
        { id = "snoozed", label = "Snoozed" },
        { id = "notyet", label = "Not yet" },
    },
    FILTER_WIDTH = 240,
    EMPTY_ALL = "No players in the guild yet.",
    SEARCH_WIDTH = 260,
    SEARCH_PLACEHOLDER = "Search by alias or character name",
    ROW_HEIGHT = 54,
    STATUS_WIDTH = 70,
    SNOOZE_WIDTH = 80,
    PICKER_WIDTH = 200,
    -- The grid: the player's name and sub line, then a column per
    -- requirement, each a share of GRID_SPACE between its narrowest and
    -- widest.
    NAME_WIDTH = 190,
    GRID_SPACE = 440,
    CELL_MIN = 56,
    CELL_MAX = 110,
    HEADER_HEIGHT = 30,
    SCROLL_STEP = 54,
    VIEWPORT = 480,
    EMPTY = "Nobody is due a promotion right now.",
    NO_MATCHES = "No players match.",
    EMPTY_RANK = "Nobody is up for %s right now.",
    PROMOTE_TO = "Promote to: ",
    MISSING = "Missing...",
    MISSING_WIDTH = 100,
    MISSING_CHIP = "Missing: ",
    NO_MISSING = "Nobody due is missing that.",
    -- The filtered requirement's header.
    HIGHLIGHT = "gold",
    -- An automated cell's color, by its state.
    CELL_COLORS = { met = "green", missing = "red", overridden = "gold" },
    OVERRIDE = "Override as met...",
    REMOVE_OVERRIDE = "Remove override",
    -- The most a note or reason holds (PromotionChecks' limit).
    NOTE_LETTERS = 100,
}
addon.RankManagementPage = RankManagementPage

local Page = {}
Page.__index = Page

local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

-- Draws the page into `content` with widget factory `ui`. options:
--   model  function(search) -> RankUpViewModel.Due's view, or nil outside
--          a guild
--   onSnooze function(key) -> true, or false and why not: snoozes the
--          player whose profile character is `key`
--   onError function(text): tells the user why something didn't happen
--   targets function() -> RankUpViewModel.Targets' choices, for Promote to
--   missing function(rank) -> RankUpViewModel.MissingChoices' choices for
--           the picked rank (nil for Any rank), for Missing
--   players function(search, filter) -> RankUpViewModel.All's view, for All
--           players, or nil outside a guild
--   onSelect function(playerId): a click on a row, to show that player's
--           full checklist
--   requirements the Requirements tab's actions (see RequirementsEditor
--           .Create)
--   onTick  function(key, item, ticked, note) -> true, or false and why
--           not: ticks or unticks officer check `item` for the player whose
--           profile character is `key`, with `note` (a check's note, or an
--           override's reason); ticking a failed automated item overrides
--           it, and unticking it takes the override back
-- `model` is called as model(search, rank, missing), `rank` the rank
-- promoted to that was picked, or nil for Any rank, and `missing` the
-- Missing choice picked, or nil.
function RankManagementPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options, query = "", tab = "due",
        filter = "all" }, Page)
    page:build()
    return page
end

function Page:build()
    local ui, content, owner = self.ui, self.content, self
    self.tabs = ui:Tabs(content, RankManagementPage.TABS, function(id)
        owner:showTab(id)
    end)
    self.tabs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    self.tabs:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    self.search = ui:SearchBox(content, RankManagementPage.SEARCH_WIDTH, RankManagementPage.SEARCH_PLACEHOLDER,
        function(text)
            owner.query = text
            owner:rebuild(true)
        end)
    self.search:SetPoint("TOPLEFT", self.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    self.picker = ui:Button(content, "", "secondary", function(button)
        owner:pickerMenu(button)
    end)
    self.picker:SetWidth(RankManagementPage.PICKER_WIDTH)
    self.picker:SetPoint("LEFT", self.search, "RIGHT", Theme.SPACING.m, 0)
    self.missingPicker = ui:Button(content, RankManagementPage.MISSING, "secondary", function(button)
        owner:missingMenu(button)
    end)
    self.missingPicker:SetWidth(RankManagementPage.MISSING_WIDTH)
    self.missingPicker:SetPoint("LEFT", self.picker, "RIGHT", Theme.SPACING.m, 0)
    self.chip = ui:Chip(content, function()
        owner:filterMissing(nil)
    end)
    self.chip:SetPoint("LEFT", self.missingPicker, "RIGHT", Theme.SPACING.m, 0)
    self.chip:Hide()
    -- All players' status filter, where Promote to is on Due.
    self.filterBar = ui:Segmented(content, RankManagementPage.FILTERS, RankManagementPage.FILTER_WIDTH,
        function(id)
            owner.filter = id
            owner:rebuild(false)
        end)
    self.filterBar:SetPoint("LEFT", self.search, "RIGHT", Theme.SPACING.m, 0)
    self.filterBar:Hide()
    self.menu = ui:ContextMenu(content)
    self.prompt = ui:TextPrompt(content)
    -- The grid's column labels, over the list while a rank is picked.
    self.header = ui:frame("Frame", content)
    self.header:SetHeight(RankManagementPage.HEADER_HEIGHT)
    self.header:SetPoint("TOPLEFT", self.search, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    self.header:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    self.header.labels = {}
    self.footer = ui:Text(content, "", "regular", "body", "muted")
    self.footer:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    self.footer:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    self.footer:SetJustifyH("LEFT")
    self.list = ui:PooledList(content, {
        height = RankManagementPage.ROW_HEIGHT,
        gap = Theme.SPACING.xs,
        step = RankManagementPage.SCROLL_STEP,
        viewport = RankManagementPage.VIEWPORT,
        build = function(_, parent)
            return owner:buildRow(parent)
        end,
        fill = function(frame, row)
            owner:fillRow(frame, row)
        end,
    })
    self.empty = ui:Text(content, RankManagementPage.EMPTY, "regular", "body", "muted")
    -- The Requirements tab, under the tabs.
    self.editorHost = ui:frame("Frame", content)
    self.editorHost:SetPoint("TOPLEFT", self.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    self.editorHost:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    self.editor = addon.RequirementsEditor.Create(self.editorHost, ui, self.options.requirements or {})
    self.editorHost:Hide()
    self:placeList(false)
    self:labelPicker()
end

-- Shows tab `id`: Due's picker and Missing, or All players' filter.
function Page:showTab(id)
    self.tab = id
    local all, editing = id == "all", id == "requirements"
    local due = not all and not editing
    setShown(self.picker, due)
    setShown(self.missingPicker, due)
    setShown(self.chip, due and self.missing ~= nil)
    setShown(self.filterBar, all)
    -- The Requirements tab has none of the lists' parts.
    setShown(self.search, not editing)
    setShown(self.list, not editing)
    setShown(self.footer, not editing)
    setShown(self.editorHost, editing)
    if editing then
        self.header:Hide()
        self.empty:Hide()
    end
    self:rebuild(false)
end

-- The All players tab's label, with the player count.
function Page:labelAll(count)
    self.tabs:SetLabel("all", string.format(RankManagementPage.ALL_LABEL, count or 0))
end

-- The list under the search, or under the grid's header.
function Page:placeList(grid)
    self.list:ClearAllPoints()
    if grid then
        self.list:SetPoint("TOPLEFT", self.header, "BOTTOMLEFT", 0, 0)
    else
        self.list:SetPoint("TOPLEFT", self.search, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    end
    self.list:SetPoint("BOTTOMRIGHT", self.content, "BOTTOMRIGHT", 0, 24)
    self.empty:ClearAllPoints()
    self.empty:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, 0)
    setShown(self.header, grid)
end

function Page:labelPicker()
    self.picker:SetLabel(RankManagementPage.PROMOTE_TO .. (self.rankText or addon.RankUpViewModel.ANY_RANK))
end

-- Promote to's menu: Any rank, then each rank with requirements.
function Page:pickerMenu(anchor)
    local owner, items = self, {}
    local _, target
    for _, target in ipairs(self.options.targets ~= nil and self.options.targets() or {}) do
        local rank, label = target.rank, target.text
        table.insert(items, { label = label, onClick = function()
            owner.rank = rank
            owner.rankText = rank ~= nil and label or nil
            owner:labelPicker()
            -- A requirement of another rank isn't one this rank can miss.
            if owner.missing ~= nil and rank ~= nil and owner.missing.rank ~= rank then
                owner:filterMissing(nil)
            else
                owner:rebuild(false)
            end
        end })
    end
    self.menu:Open(anchor, items)
end

-- Missing's menu: the requirements the picked rank (or any rank) can miss.
function Page:missingMenu(anchor)
    local owner, items = self, {}
    local _, choice
    for _, choice in ipairs(self.options.missing ~= nil and self.options.missing(self.rank) or {}) do
        local picked = choice
        table.insert(items, { label = choice.text, onClick = function()
            owner:filterMissing(picked)
        end })
    end
    self.menu:Open(anchor, items)
end

-- Filters the list to the players missing `choice`, or clears the filter
-- for nil.
function Page:filterMissing(choice)
    self.missing = choice
    setShown(self.chip, choice ~= nil)
    if choice ~= nil then
        self.chip:SetLabel(RankManagementPage.MISSING_CHIP .. choice.text)
    end
    self:rebuild(false)
end

-- A grid column's width, for `count` columns.
local function cellWidth(count)
    local width = math.floor(RankManagementPage.GRID_SPACE / math.max(count, 1))
    return math.max(RankManagementPage.CELL_MIN, math.min(RankManagementPage.CELL_MAX, width))
end

-- Where column `index` starts on a row, or on the header.
local function cellLeft(index, width)
    return RankManagementPage.NAME_WIDTH + Theme.SPACING.m + (index - 1) * width
end

-- The header's labels for `columns`, a label per column.
function Page:labelColumns(columns)
    local width = cellWidth(#columns)
    local index
    for index = 1, math.max(#columns, #self.header.labels) do
        local label = self.header.labels[index]
        if label == nil and columns[index] ~= nil then
            label = self.ui:Text(self.header, "", "semibold", "small", "label")
            label:SetJustifyH("LEFT")
            label:SetJustifyV("BOTTOM")
            label:SetWordWrap(true)
            self.header.labels[index] = label
        end
        if label ~= nil then
            local column = columns[index]
            setShown(label, column ~= nil)
            if column ~= nil then
                label:ClearAllPoints()
                label:SetPoint("BOTTOMLEFT", self.header, "BOTTOMLEFT", cellLeft(index, width), Theme.SPACING.xs)
                label:SetWidth(width - Theme.SPACING.s)
                label:SetHeight(RankManagementPage.HEADER_HEIGHT - Theme.SPACING.xs)
                label:SetText(column.label)
                local missing = self.missing
                label.highlighted = missing ~= nil and missing.rank == self.rank and missing.id == column.id
                label:SetTextColor(Theme.Color(label.highlighted and RankManagementPage.HIGHLIGHT or "label"))
            end
        end
    end
end

-- A player's row: the name and the rank promoted to, Ready or Due on the
-- right, and under them the characters to promote or what's missing.
function Page:buildRow(parent)
    local ui, owner = self.ui, self
    local row = ui:Panel(parent)
    -- A click shows the player's full checklist.
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" and row.entry ~= nil and owner.options.onSelect ~= nil then
            owner.options.onSelect(row.entry.playerId)
        end
    end)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    row.name:SetJustifyH("LEFT")
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.status = ui:Text(row, "", "semibold", "body", "text")
    row.status:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.m, 0)
    row.status:SetWidth(RankManagementPage.STATUS_WIDTH)
    row.status:SetJustifyH("RIGHT")
    row.snooze = ui:Button(row, "Snooze", "secondary", function()
        if row.entry ~= nil then
            owner:snooze(row.entry)
        end
    end)
    row.snooze:SetWidth(RankManagementPage.SNOOZE_WIDTH)
    row.snooze:SetPoint("RIGHT", row.status, "LEFT", -Theme.SPACING.m, 0)
    row.cells = {}
    return row
end

-- Cell `index` of `row`, built the first time: a check box for an officer
-- check, a line of text for an automated one.
function Page:cellOf(row, index)
    if row.cells[index] ~= nil then
        return row.cells[index]
    end
    local ui, owner = self.ui, self
    -- A button, for an automated cell's right-click menu.
    local cell = ui:frame("Button", row)
    cell:SetHeight(RankManagementPage.ROW_HEIGHT)
    cell:RegisterForClicks("RightButtonUp")
    cell:SetScript("OnClick", function(_, button)
        if button == "RightButton" and row.entry ~= nil and cell.column ~= nil then
            owner:cellMenu(cell, row.entry, cell.column, cell.value)
        end
    end)
    cell.box = ui:CheckBox(cell, function(wanted)
        if row.entry ~= nil and cell.column ~= nil then
            owner:check(row.entry, cell.column, cell.value, wanted)
        end
    end)
    cell.box:SetPoint("LEFT", cell, "LEFT", 0, 0)
    cell.text = ui:Text(cell, "", "regular", "small", "text")
    cell.text:SetPoint("RIGHT", cell, "RIGHT", -Theme.SPACING.xs, 0)
    cell.text:SetJustifyH("LEFT")
    cell.text:SetWordWrap(false)
    row.cells[index] = cell
    return cell
end

-- A click on a check box: unticking, or ticking a check without a note,
-- saves at once; ticking one that needs a note asks for the note first.
function Page:check(entry, column, value, wanted)
    if not wanted or value == nil or not value.needsNote then
        self:tick(entry, column, wanted, nil, wanted and "ticked" or "unticked")
        return
    end
    local owner = self
    self.prompt:Open({
        title = column.label .. " for " .. entry.name,
        maxLetters = RankManagementPage.NOTE_LETTERS,
        onSave = function(note)
            owner:tick(entry, column, true, note, "ticked")
        end,
    })
end

-- An automated cell's right-click menu: Override as met... when it's
-- missing, Remove override when an override meets it.
function Page:cellMenu(anchor, entry, column, value)
    if value == nil or value.check then
        return
    end
    local owner, items = self, {}
    if value.state == addon.RankUpViewModel.MISSING then
        table.insert(items, { label = RankManagementPage.OVERRIDE, onClick = function()
            owner.prompt:Open({
                title = "Override " .. column.label .. " for " .. entry.name .. " (reason optional)",
                maxLetters = RankManagementPage.NOTE_LETTERS,
                onSave = function(reason)
                    owner:tick(entry, column, true, reason, "overridden")
                end,
            })
        end })
    elseif value.state == addon.RankUpViewModel.OVERRIDDEN then
        table.insert(items, { label = RankManagementPage.REMOVE_OVERRIDE, onClick = function()
            owner:tick(entry, column, false, nil, "un-overridden")
        end })
    end
    if items[1] ~= nil then
        self.menu:Open(anchor, items, entry.name)
    end
end

-- Ticks or unticks `column` for `entry`'s player, at once; `done` says
-- what didn't happen when it's refused ("ticked").
function Page:tick(entry, column, wanted, note, done)
    local ok, why = true, nil
    if self.options.onTick ~= nil then
        ok, why = self.options.onTick(entry.key, column.id, wanted, note)
    end
    if ok == false and self.options.onError ~= nil then
        self.options.onError(entry.name .. "'s " .. column.label .. " wasn't " .. done .. ": " .. tostring(why) .. ".")
    end
    self:Update()
end

-- The grid's cells on `frame` for `entry` (none outside the grid).
function Page:fillCells(frame, entry)
    local columns = self.view and self.view.columns or {}
    local cells = entry.cells or {}
    local width = cellWidth(#columns)
    local index
    for index = 1, math.max(#cells, #frame.cells) do
        local value = cells[index]
        local cell = value ~= nil and self:cellOf(frame, index) or frame.cells[index]
        setShown(cell, value ~= nil)
        if value ~= nil then
            cell.column = columns[index]
            cell.value = value
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", frame, "TOPLEFT", cellLeft(index, width), 0)
            cell:SetWidth(width)
            setShown(cell.box, value.check)
            cell.text:ClearAllPoints()
            cell.text:SetPoint("RIGHT", cell, "RIGHT", -Theme.SPACING.xs, 0)
            cell.text:SetText(value.text or "")
            if value.check then
                -- A ticked check's note, or who ticked it, after the box.
                cell.text:SetPoint("LEFT", cell.box, "RIGHT", Theme.SPACING.xs, 0)
                cell.box:SetChecked(value.checked)
                cell.color = "muted"
            else
                cell.text:SetPoint("LEFT", cell, "LEFT", 0, 0)
                cell.color = RankManagementPage.CELL_COLORS[value.state] or "text"
            end
            cell.text:SetTextColor(Theme.Color(cell.color))
        end
    end
end

-- Snooze on a Due row: one click, no menu.
function Page:snooze(entry)
    local ok, why = true, nil
    if self.options.onSnooze ~= nil then
        ok, why = self.options.onSnooze(entry.key)
    end
    if ok == false and self.options.onError ~= nil then
        self.options.onError(entry.name .. " wasn't snoozed: " .. tostring(why) .. ".")
    end
    self:Update()
end

function Page:fillRow(frame, entry)
    frame.entry = entry
    local grid = entry.cells ~= nil
    -- In the grid, the name and sub line keep to their column.
    frame.sub:ClearAllPoints()
    frame.sub:SetPoint("TOPLEFT", frame.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    if grid then
        frame.sub:SetWidth(RankManagementPage.NAME_WIDTH - Theme.SPACING.m)
        frame.name:SetWidth(RankManagementPage.NAME_WIDTH - Theme.SPACING.m)
    else
        frame.sub:SetPoint("RIGHT", frame, "RIGHT",
            -RankManagementPage.STATUS_WIDTH - RankManagementPage.SNOOZE_WIDTH - 3 * Theme.SPACING.m, 0)
        frame.name:SetWidth(0)
    end
    frame.name:SetWordWrap(false)
    self:fillCells(frame, entry)
    local RankUpViewModel = addon.RankUpViewModel
    frame.name:SetText(entry.name .. (entry.rankText and ("  |cff9d9d9d" .. entry.rankText .. "|r") or ""))
    frame.status:SetText(entry.status == RankUpViewModel.NONE and "" or entry.status)
    local due = entry.status == RankUpViewModel.DUE
    local color = "text"
    if entry.status == RankUpViewModel.READY then
        color = "green"
    elseif due then
        color = "gold"
    elseif entry.status == RankUpViewModel.SNOOZED or entry.status == RankUpViewModel.NOT_YET then
        color = "muted"
    end
    frame.status:SetTextColor(Theme.Color(color))
    if entry.statusText ~= nil then
        -- An All players row: its status in words, past what the column holds.
        local said = entry.status == RankUpViewModel.SNOOZED or entry.status == RankUpViewModel.NOT_YET
            or entry.status == RankUpViewModel.NONE
        frame.sub:SetText(said and entry.statusText or "")
    elseif due then
        frame.sub:SetText("Waiting on: " .. (entry.waitingText or ""))
    else
        frame.sub:SetText("Promote: " .. (entry.promoteText or ""))
    end
    setShown(frame.snooze, due)
end

-- The list again from the rules engine; `keepPlace` leaves it scrolled
-- where it is, else it starts at the top.
function Page:rebuild(keepPlace)
    if self.tab == "requirements" then
        self.editor:Refresh()
        return
    end
    if self.tab == "all" then
        self:rebuildAll(keepPlace)
        return
    end
    self.view = self.options.model(self.query, self.rank, self.missing) or { rows = {}, count = 0, footer = "" }
    local grid = self.view.columns ~= nil
    self:placeList(grid)
    self:labelColumns(self.view.columns or {})
    if not keepPlace then
        self.list:ScrollTo(0)
    end
    self.list:SetRows(self.view.rows)
    self.footer:SetText(self.view.footer or "")
    local empty = RankManagementPage.EMPTY
    if self.missing ~= nil then
        empty = RankManagementPage.NO_MISSING
    elseif self.query ~= "" and self.view.count > 0 then
        empty = RankManagementPage.NO_MATCHES
    elseif self.rankText ~= nil then
        empty = string.format(RankManagementPage.EMPTY_RANK, self.rankText)
    end
    self.empty:SetText(empty)
    setShown(self.empty, self.view.rows[1] == nil)
end

-- All players again, filtered and searched.
function Page:rebuildAll(keepPlace)
    local players = self.options.players
    self.view = players ~= nil and players(self.query, self.filter) or nil
    self.view = self.view or { rows = {}, count = 0, snoozed = 0, notYet = 0 }
    self:placeList(false)
    self:labelColumns({})
    if not keepPlace then
        self.list:ScrollTo(0)
    end
    self.list:SetRows(self.view.rows)
    self:labelAll(self.view.count)
    self.footer:SetText(self.view.count .. (self.view.count == 1 and " player" or " players") .. " · "
        .. (self.view.snoozed or 0) .. " snoozed · " .. (self.view.notYet or 0) .. " not yet")
    local empty = RankManagementPage.EMPTY_ALL
    if self.view.count > 0 then
        empty = RankManagementPage.NO_MATCHES
    end
    self.empty:SetText(empty)
    setShown(self.empty, self.view.rows[1] == nil)
end

-- Builds the page again, from the top, on Due.
function Page:Refresh()
    self.tabs:Select("due")
    local players = self.options.players ~= nil and self.options.players("", "all") or nil
    self:labelAll(players and players.count or 0)
    self:showTab("due")
end

-- Something changed (a tick, a scan): the list again, in its place.
function Page:Update()
    self:rebuild(true)
end

-- The rows showing, for the owner.
function Page:Rows()
    return self.view and self.view.rows or {}
end
