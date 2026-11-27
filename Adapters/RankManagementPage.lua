local _, addon = ...

-- The officers' Rank management page in the AGF window. Its Due tab lists
-- the players up for a rank (RankUpViewModel.Due) in a pooled list: each
-- row names the player and the rank they'd be promoted to ("→ Member"),
-- says Ready or Due, and lists the characters to promote or what the
-- player is still waiting on. A search box narrows the list; the footer
-- counts Ready and Due and says that the promotion itself happens on the
-- guild roster.
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
    SCROLL_STEP = 54,
    VIEWPORT = 480,
    EMPTY = "Nobody is due a promotion right now.",
    NO_MATCHES = "No players match.",
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
    self.list:SetPoint("TOPLEFT", self.search, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    self.list:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 24)
    self.empty = ui:Text(content, RankManagementPage.EMPTY, "regular", "body", "muted")
    self.empty:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, 0)
end

-- A player's row: the name and the rank promoted to, Ready or Due on the
-- right, and under them the characters to promote or what's missing.
function Page:buildRow(parent)
    local ui = self.ui
    local row = ui:Panel(parent)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -RankManagementPage.STATUS_WIDTH - 2 * Theme.SPACING.m, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.status = ui:Text(row, "", "semibold", "body", "text")
    row.status:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.m, 0)
    return row
end

function Page:fillRow(frame, entry)
    frame.entry = entry
    frame.name:SetText(entry.name .. "  |cff9d9d9d" .. entry.rankText .. "|r")
    frame.status:SetText(entry.status)
    local ready = entry.status == addon.RankUpViewModel.READY
    frame.status:SetTextColor(Theme.Color(ready and "green" or "gold"))
    if ready then
        frame.sub:SetText("Promote: " .. (entry.promoteText or ""))
    else
        frame.sub:SetText("Waiting on: " .. (entry.waitingText or ""))
    end
end

-- The list again from the rules engine; `keepPlace` leaves it scrolled
-- where it is, else it starts at the top.
function Page:rebuild(keepPlace)
    self.view = self.options.model(self.query) or { rows = {}, count = 0, footer = "" }
    if not keepPlace then
        self.list:ScrollTo(0)
    end
    self.list:SetRows(self.view.rows)
    self.footer:SetText(self.view.footer or "")
    self.empty:SetText(self.query ~= "" and self.view.count > 0 and RankManagementPage.NO_MATCHES
        or RankManagementPage.EMPTY)
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
