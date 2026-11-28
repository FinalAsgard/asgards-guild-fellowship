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
-- once with no confirm.
--
-- It's built when the page is shown (Refresh), and again when the owner
-- says something changed (Update), keeping the list where it's scrolled.
local Theme = addon.Theme

local RankManagementPage = {
    TABS = {
        { id = "due", label = "Due" },
    },
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
    -- An automated cell's color, by its state.
    CELL_COLORS = { met = "green", missing = "red", overridden = "gold" },
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
--   onTick  function(key, item, ticked) -> true, or false and why not:
--           ticks or unticks officer check `item` for the player whose
--           profile character is `key`
-- `model` is called as model(search, rank), `rank` the rank promoted to
-- that was picked, or nil for Any rank.
function RankManagementPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options, query = "" }, Page)
    page:build()
    return page
end

function Page:build()
    local ui, content, owner = self.ui, self.content, self
    self.tabs = ui:Tabs(content, RankManagementPage.TABS, function() end)
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
    self.menu = ui:ContextMenu(content)
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
    self:placeList(false)
    self:labelPicker()
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
            owner:rebuild(false)
        end })
    end
    self.menu:Open(anchor, items)
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
            end
        end
    end
end

-- A player's row: the name and the rank promoted to, Ready or Due on the
-- right, and under them the characters to promote or what's missing.
function Page:buildRow(parent)
    local ui, owner = self.ui, self
    local row = ui:Panel(parent)
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
    local cell = ui:frame("Frame", row)
    cell:SetHeight(RankManagementPage.ROW_HEIGHT)
    cell.box = ui:CheckBox(cell, function(wanted)
        if row.entry ~= nil and cell.column ~= nil then
            owner:tick(row.entry, cell.column, wanted)
        end
    end)
    cell.box:SetPoint("LEFT", cell, "LEFT", 0, 0)
    cell.text = ui:Text(cell, "", "regular", "small", "text")
    cell.text:SetPoint("LEFT", cell, "LEFT", 0, 0)
    cell.text:SetPoint("RIGHT", cell, "RIGHT", -Theme.SPACING.xs, 0)
    cell.text:SetJustifyH("LEFT")
    cell.text:SetWordWrap(false)
    row.cells[index] = cell
    return cell
end

-- Ticks or unticks officer check `column` for `entry`'s player, at once.
function Page:tick(entry, column, wanted)
    local ok, why = true, nil
    if self.options.onTick ~= nil then
        ok, why = self.options.onTick(entry.key, column.id, wanted)
    end
    if ok == false and self.options.onError ~= nil then
        self.options.onError(entry.name .. "'s " .. column.label .. " wasn't " .. (wanted and "ticked" or "unticked")
            .. ": " .. tostring(why) .. ".")
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
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", frame, "TOPLEFT", cellLeft(index, width), 0)
            cell:SetWidth(width)
            setShown(cell.box, value.check)
            setShown(cell.text, not value.check)
            if value.check then
                cell.box:SetChecked(value.checked)
            else
                cell.text:SetText(value.text or "")
                cell.color = RankManagementPage.CELL_COLORS[value.state] or "text"
                cell.text:SetTextColor(Theme.Color(cell.color))
            end
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
    frame.name:SetText(entry.name .. "  |cff9d9d9d" .. entry.rankText .. "|r")
    frame.status:SetText(entry.status)
    local due = entry.status == addon.RankUpViewModel.DUE
    local color = "text"
    if entry.status == addon.RankUpViewModel.READY then
        color = "green"
    elseif due then
        color = "gold"
    end
    frame.status:SetTextColor(Theme.Color(color))
    if due then
        frame.sub:SetText("Waiting on: " .. (entry.waitingText or ""))
    else
        frame.sub:SetText("Promote: " .. (entry.promoteText or ""))
    end
    setShown(frame.snooze, due)
end

-- The list again from the rules engine; `keepPlace` leaves it scrolled
-- where it is, else it starts at the top.
function Page:rebuild(keepPlace)
    self.view = self.options.model(self.query, self.rank) or { rows = {}, count = 0, footer = "" }
    local grid = self.view.columns ~= nil
    self:placeList(grid)
    self:labelColumns(self.view.columns or {})
    if not keepPlace then
        self.list:ScrollTo(0)
    end
    self.list:SetRows(self.view.rows)
    self.footer:SetText(self.view.footer or "")
    local empty = RankManagementPage.EMPTY
    if self.query ~= "" and self.view.count > 0 then
        empty = RankManagementPage.NO_MATCHES
    elseif self.rankText ~= nil then
        empty = string.format(RankManagementPage.EMPTY_RANK, self.rankText)
    end
    self.empty:SetText(empty)
    setShown(self.empty, self.view.rows[1] == nil)
end

-- Builds the page again, from the top.
function Page:Refresh()
    self.tabs:Select("due")
    self:rebuild(false)
end

-- Something changed (a tick, a scan): the list again, in its place.
function Page:Update()
    self:rebuild(true)
end

-- The rows showing, for the owner.
function Page:Rows()
    return self.view and self.view.rows or {}
end
