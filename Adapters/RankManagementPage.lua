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
--   onSnooze function(key) -> true, or false and why not: snoozes the
--          player whose profile character is `key`
--   onError function(text): tells the user why something didn't happen
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
    local ui, owner = self.ui, self
    local row = ui:Panel(parent)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    row.sub:SetPoint("RIGHT", row, "RIGHT",
        -RankManagementPage.STATUS_WIDTH - RankManagementPage.SNOOZE_WIDTH - 3 * Theme.SPACING.m, 0)
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
    return row
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
