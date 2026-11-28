local _, addon = ...

-- The Roster page in the AGF window. Across the top, the guild's player
-- and online counts and when it last synced, with Rescan on the right.
-- Under that, the left column has a search box, Sort and Rank buttons that
-- open menus of their choices, and an Online only switch; under them it
-- lists one player card per player (RosterListModel), in a pooled list:
-- only the cards in view have frames, so hundreds of players scroll
-- smoothly. The cards are the Friends page's (PlayerCards).
--
-- The right side shows the selected player in the shared player detail
-- panel (PlayerDetailPanel), with the Friend star and a ⋯ menu.
--
-- Right-clicking a player card, or a character card in the panel's
-- Characters tab, opens the old roster's organizing actions for it
-- (RosterController's entries, so a member only gets what they may do to
-- their own player); the panel's ⋯ button has the player-wide ones. Link as
-- alt of... and Merge into player... swap the panel for a player picker
-- with a search box, as the Friends page's is. Set alias..., Set Discord...
-- and the Bio tab's Edit ask for the text in a small prompt.
--
-- Officers get tabs across the top: Members (all of the above), Departed
-- (a table of the characters that left the guild, each with Purge, and
-- Purge all departed, which asks first) and Review (members' suggestions,
-- each with Approve and Deny, Approve all and Deny all, and Review for a
-- change to a main or its alts, which shows the player before and after).
-- Members get no tabs.
--
-- It's built when the page is shown (Refresh). When the roster changes on
-- its own (Update), the cards show what's new but keep their order and the
-- list its place, so it doesn't jump while it's being scrolled; a sort,
-- filter or search change sorts it again.
local Theme = addon.Theme
local DOT = " · "

local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

local RosterPage = {
    COLUMN_WIDTH = 260,
    HEADER_HEIGHT = 28,
    RESCAN_WIDTH = 90,
    SECTION_HEIGHT = 24,
    -- A card and the gap under it.
    CARD_HEIGHT = addon.PlayerCards.SMALL_HEIGHT + Theme.SPACING.xs,
    SCROLL_STEP = 48,
    SEARCH_PLACEHOLDER = "Search players",
    ANY_RANK = "Any rank",
    ONLINE_ONLY = "Online only",
    -- The column's height to lay out for until the frame can say.
    VIEWPORT = 560,
    EMPTY = "No guildmates to show yet. The roster fills in once it's scanned.",
    PICKER_ROW_HEIGHT = 44,
    PICKER_SEARCH = "Search by alias or character name",
    NO_MATCHES = "No players match.",
    ALIAS_LETTERS = 48,
    TABS = {
        { id = "members", label = "Members" },
        { id = "departed", label = "Departed" },
        { id = "review", label = "Review" },
    },
    TABS_HEIGHT = 28,
    DEPARTED_ROW_HEIGHT = 54,
    PURGE_WIDTH = 80,
    PURGE_ALL_WIDTH = 160,
    NO_DEPARTED = "Nobody has left the guild.",
    WHOLE_PLAYER_LEFT = "The whole player left",
    REVIEW_EMPTY = "No suggestions are waiting.",
    REVIEW_ROW_HEIGHT = 54,
    REVIEW_LINE_HEIGHT = 18,
    DECIDE_WIDTH = 76,
    -- The review's before side; the after side starts here.
    REVIEW_SIDE_WIDTH = 320,
}
addon.RosterPage = RosterPage

local Page = {}
Page.__index = Page

-- Draws the page into `content` with widget factory `ui`. options:
--   model     function(selected, filters) -> RosterListModel.Build's view,
--             or nil outside a guild; filters is { search, sort, rank,
--             onlineOnly }, as Build takes them
--   detail    function(playerId, groupedShown) -> PlayerDetailViewModel
--             .Build's view (showing `groupedShown` Grouped parties, nil for
--             the first page), or nil when the player is gone
--   formatDate function(at) -> text, for the Grouped tab
--   onWhisper function(target): whispers that character
--   onInvite  function(target): invites that character
--   onToggleFriend function(view) -> true, or false and why not: the star
--             button, pinning or unpinning the panel's player
--   onRescan  function(): rescans the guild roster
--   countsTooltip function() -> lines: what hovering the counts shows (the
--             guild's size, as RosterViewModel.CountsTooltip words it)
--   isOfficer function() -> whether the user is an officer, who gets the tabs
--   departed  function() -> RosterListModel.Departed's rows
--   onPurge   function(key): purges one departed character
--   onPurgeAll function(): purges every departed character
--   suggestions function() -> RosterListModel.Suggestions' rows
--   onApprove, onDeny function(character, kind): decides one suggestion
--   onApproveAll, onDenyAll function(): decides every suggestion
--   reviewOf  function(group) -> { title, suggestedBy, lines = { { before,
--             after } } }: a bundle's before and after, or nil
--   onError   function(text): tells the user why something didn't happen
--   onRankTick, onSnooze  the panel's Rank tab (see
--             PlayerDetailPanel.RankCallbacks)
-- and, for organizing players (RosterController's calls, by character key):
--   menuFor   function(target) -> { { text, action, key } }: the right-click
--             entries for { kind = "player", id } or { kind = "character",
--             key }; action is "alias", "view", "setMain", "makeMain" or
--             "detach"
--   canEdit   function(key) -> whether the user may change key's player
--   playerOf  function(key) -> key's player id
--   aliasOf   function(key) -> the alias to start Set alias... with
--   searchPlayers function(key, query) -> { { id, label, matched } }: the
--             players `key` may be linked to
--   onSetAlias, onSetDiscord, onSetMain(key, playerId), onMakeMain(key),
--   onDetach(key), onSetProfileText(key, field, text)
function RosterPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options, query = "",
        sort = addon.RosterListModel.SORTS[1].id, onlineOnly = false }, Page)
    page:build()
    return page
end

-- Building ------------------------------------------------------------------

function Page:build()
    local ui = self.ui
    local owner = self
    self:buildTabs()
    -- The Members tab: everything but the officers' other tabs.
    local content = ui:frame("Frame", self.content)
    self.membersBody = content
    self.counts = ui:Text(content, "", "regular", "body", "muted")
    self.counts:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -6)
    -- Hovering the counts shows the guild's size in full: characters,
    -- alts, who's active.
    self.countsHover = ui:frame("Frame", content)
    self.countsHover:SetPoint("TOPLEFT", self.counts, "TOPLEFT", 0, 0)
    self.countsHover:SetPoint("BOTTOMRIGHT", self.counts, "BOTTOMRIGHT", 0, 0)
    self.countsHover:EnableMouse(true)
    self.countsHover:SetScript("OnEnter", function(frame)
        owner:showCountsTooltip(frame)
    end)
    self.countsHover:SetScript("OnLeave", function()
        local tooltip = ui.environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:Hide()
        end
    end)
    self.rescan = ui:Button(content, "Rescan", "secondary", function()
        if owner.options.onRescan ~= nil then
            owner.options.onRescan()
        end
    end)
    self.rescan:SetWidth(RosterPage.RESCAN_WIDTH)
    self.rescan:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)

    local column = ui:frame("Frame", content)
    column:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -RosterPage.HEADER_HEIGHT - Theme.SPACING.m)
    column:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    column:SetWidth(RosterPage.COLUMN_WIDTH)
    self.column = column
    local bottom = self:buildControls(column)
    self.list = ui:PooledList(column, {
        height = function(row)
            return row.kind == "section" and RosterPage.SECTION_HEIGHT or RosterPage.CARD_HEIGHT
        end,
        gap = Theme.SPACING.xs,
        step = RosterPage.SCROLL_STEP,
        viewport = RosterPage.VIEWPORT,
        build = function(kind, parent)
            return owner:buildRow(kind, parent)
        end,
        fill = function(frame, row)
            owner:fillRow(frame, row)
        end,
    })
    self.list:SetPoint("TOPLEFT", bottom, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    self.list:SetPoint("BOTTOMRIGHT", column, "BOTTOMRIGHT", 0, 0)
    self.menu = ui:ContextMenu(content)
    self.prompt = ui:TextPrompt(content)

    local side = ui:Panel(content)
    side:SetPoint("TOPLEFT", column, "TOPRIGHT", Theme.SPACING.l, 0)
    side:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    self.side = side
    local onRankTick, onRankSnooze = addon.PlayerDetailPanel.RankCallbacks(self.options, function()
        owner:showDetail()
    end)
    self.detail = addon.PlayerDetailPanel.Create(ui, side, {
        onRankTick = onRankTick,
        onRankSnooze = onRankSnooze,
        onWhisper = function(target)
            if owner.options.onWhisper ~= nil then
                owner.options.onWhisper(target)
            end
        end,
        onInvite = function(target)
            if owner.options.onInvite ~= nil then
                owner.options.onInvite(target)
            end
        end,
        onToggleFriend = function(view)
            owner:toggleFriend(view)
        end,
        onMoreGrouped = function()
            owner.groupedShown = (owner.groupedShown or addon.LfgHistoryView.PAGE_SIZE)
                + addon.LfgHistoryView.PAGE_SIZE
            owner:showDetail()
        end,
        formatDate = function(at)
            return owner.options.formatDate and owner.options.formatDate(at) or nil
        end,
        onCharacterMenu = function(card, character)
            owner:openMenu(card, { kind = "character", key = character.key }, character.name)
        end,
        onActions = function(button, view)
            owner:actionsMenu(button, view)
        end,
        onEditProfile = function(field, view)
            owner:editProfile(field, view)
        end,
    })
    self:buildPicker(side)
end

-- The player picker for Link as alt of... and Merge into player...: a
-- title, what's being linked, the search box, a scrolling list and Cancel.
function Page:buildPicker(side)
    local ui, pad = self.ui, Theme.SPACING.l
    local owner = self
    local picker = ui:frame("Frame", side)
    picker:SetAllPoints(side)
    picker.title = ui:Text(picker, "", "semibold", "title", "text")
    picker.title:SetPoint("TOPLEFT", picker, "TOPLEFT", pad, -pad)
    picker.prompt = ui:Text(picker, "", "regular", "body", "muted")
    picker.prompt:SetPoint("TOPLEFT", picker.title, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    picker.search = ui:SearchBox(picker, 300, RosterPage.PICKER_SEARCH, function(text)
        owner:showPickerRows(text)
    end)
    picker.search:SetPoint("TOPLEFT", picker.prompt, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    picker.cancel = ui:Button(picker, "Cancel", "secondary", function()
        owner:ClosePicker()
    end)
    picker.cancel:SetWidth(90)
    picker.cancel:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -pad, pad)
    picker.area, picker.list = ui:ScrollList(picker, RosterPage.PICKER_ROW_HEIGHT)
    picker.area:SetPoint("TOPLEFT", picker.search, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    picker.area:SetPoint("BOTTOMRIGHT", picker.cancel, "TOPRIGHT", 0, Theme.SPACING.m)
    picker.empty = ui:Text(picker.list, RosterPage.NO_MATCHES, "regular", "body", "muted")
    picker.empty:SetPoint("TOPLEFT", picker.list, "TOPLEFT", 0, 0)
    picker.rows = {}
    picker:Hide()
    self.picker = picker
end

-- A picker row: the player's name, and the character a search found them
-- by.
function Page:pickerRow(index)
    local picker = self.picker
    local row = picker.rows[index]
    if row ~= nil then
        return row
    end
    local ui, owner = self.ui, self
    row = ui:frame("Button", picker.list)
    ui:Round(row, Theme.RADIUS.button, "raised", false)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.s, -6)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row:SetScript("OnEnter", function(self)
        self:SetFill("hover")
    end)
    row:SetScript("OnLeave", function(self)
        self:SetFill("raised")
    end)
    row:SetScript("OnClick", function(self)
        owner:pick(self.entry)
    end)
    picker.rows[index] = row
    return row
end

-- The officers' tabs, and the Departed and Review tabs' bodies.
function Page:buildTabs()
    local ui, owner, content = self.ui, self, self.content
    self.tab = RosterPage.TABS[1].id
    self.tabs = ui:Tabs(content, RosterPage.TABS, function(id)
        owner:ShowTab(id)
    end)
    self.tabs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    self.tabs:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    self.tabs:Hide()
    self.departedBody = ui:frame("Frame", content)
    self:buildDeparted(self.departedBody)
    self.reviewBody = ui:frame("Frame", content)
    self:buildReview(self.reviewBody)
end

-- The Review tab: how many wait, Approve all and Deny all, over a
-- full-width list; Review swaps the list for one bundle's before and after.
function Page:buildReview(body)
    local ui, owner = self.ui, self
    self.reviewSummary = ui:Text(body, "", "regular", "body", "muted")
    self.reviewSummary:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -6)
    self.denyAll = ui:Button(body, "Deny all", "danger", function()
        owner:call("onDenyAll")
        owner:refreshReview()
    end)
    self.denyAll:SetWidth(100)
    self.denyAll:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    self.approveAll = ui:Button(body, "Approve all", "primary", function()
        owner:call("onApproveAll")
        owner:refreshReview()
    end)
    self.approveAll:SetWidth(110)
    self.approveAll:SetPoint("RIGHT", self.denyAll, "LEFT", -Theme.SPACING.s, 0)
    self.reviewList = ui:PooledList(body, {
        height = RosterPage.REVIEW_ROW_HEIGHT,
        gap = Theme.SPACING.xs,
        step = RosterPage.SCROLL_STEP,
        viewport = RosterPage.VIEWPORT,
        build = function(_, parent)
            return owner:buildReviewRow(parent)
        end,
        fill = function(frame, row)
            owner:fillReviewRow(frame, row)
        end,
    })
    self.reviewList:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -RosterPage.HEADER_HEIGHT - Theme.SPACING.m)
    self.reviewList:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    self.reviewEmpty = ui:Text(body, RosterPage.REVIEW_EMPTY, "regular", "body", "muted")
    self.reviewEmpty:SetPoint("TOPLEFT", self.reviewList, "TOPLEFT", 0, 0)

    -- One bundle's before and after, over the list.
    local view = ui:Panel(body)
    view:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    view:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    local pad = Theme.SPACING.l
    view.title = ui:Text(view, "", "semibold", "title", "text")
    view.title:SetPoint("TOPLEFT", view, "TOPLEFT", pad, -pad)
    view.suggestedBy = ui:Text(view, "", "regular", "body", "muted")
    view.suggestedBy:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    view.beforeLabel = ui:SectionLabel(view, "Before")
    view.beforeLabel:SetPoint("TOPLEFT", view.suggestedBy, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    view.afterLabel = ui:SectionLabel(view, "After")
    view.back = ui:Button(view, "Back", "secondary", function()
        owner:CloseReview()
    end)
    view.back:SetWidth(90)
    view.back:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -pad, pad)
    view.area, view.list = ui:ScrollList(view, RosterPage.REVIEW_LINE_HEIGHT * 3)
    view.area:SetPoint("TOPLEFT", view.beforeLabel, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    view.area:SetPoint("BOTTOMRIGHT", view.back, "TOPRIGHT", 0, Theme.SPACING.m)
    view.afterLabel:SetPoint("BOTTOMLEFT", view.area, "TOPLEFT", RosterPage.REVIEW_SIDE_WIDTH, Theme.SPACING.s)
    view.lines = {}
    view:Hide()
    self.reviewView = view
end

-- A suggestion's row: the player and character, what's suggested, what it
-- is now and who suggested it, then Approve, Deny and (for a change to a
-- main or its alts) Review.
function Page:buildReviewRow(parent)
    local ui, owner = self.ui, self
    local row = ui:Panel(parent)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -3 * RosterPage.DECIDE_WIDTH - 4 * Theme.SPACING.s, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    local function decide(option)
        return function()
            if row.entry ~= nil then
                owner:call(option, row.entry.character, row.entry.kind)
                owner:refreshReview()
            end
        end
    end
    row.deny = ui:Button(row, "Deny", "secondary", decide("onDeny"))
    row.deny:SetWidth(RosterPage.DECIDE_WIDTH)
    row.deny:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.m, 0)
    row.approve = ui:Button(row, "Approve", "primary", decide("onApprove"))
    row.approve:SetWidth(RosterPage.DECIDE_WIDTH)
    row.approve:SetPoint("RIGHT", row.deny, "LEFT", -Theme.SPACING.s, 0)
    row.review = ui:Button(row, "Review", "secondary", function()
        if row.entry ~= nil then
            owner:OpenReview(row.entry.group)
        end
    end)
    row.review:SetWidth(RosterPage.DECIDE_WIDTH)
    row.review:SetPoint("RIGHT", row.approve, "LEFT", -Theme.SPACING.s, 0)
    return row
end

function Page:fillReviewRow(frame, entry)
    frame.entry = entry
    frame.name:SetText(tostring(entry.player) .. DOT .. tostring(entry.name))
    frame.sub:SetText(tostring(entry.suggests) .. DOT .. "now " .. tostring(entry.current) .. DOT
        .. "Suggested by " .. tostring(entry.suggestedBy))
    setShown(frame.review, entry.reviewable == true)
end

-- The Review tab again, from the suggestion queue, with its count in the
-- tab. A review open on a bundle that's all decided closes.
function Page:refreshReview()
    local rows = self:call("suggestions") or {}
    self.reviewRows = rows
    self.reviewList:SetRows(rows)
    self.tabs:SetLabel("review", rows[1] ~= nil and ("Review" .. DOT .. #rows) or "Review")
    self.reviewSummary:SetText(#rows == 1 and "1 suggestion is waiting."
        or (#rows .. " suggestions are waiting."))
    setShown(self.reviewEmpty, rows[1] == nil)
    self.approveAll:SetActive(rows[1] ~= nil)
    self.denyAll:SetActive(rows[1] ~= nil)
    if self.reviewing ~= nil then
        self:OpenReview(self.reviewing)
    end
end

-- Line `index` of the review's list: the before side and the after side.
function Page:reviewLine(index)
    local view = self.reviewView
    local line = view.lines[index]
    if line == nil then
        local ui = self.ui
        line = ui:frame("Frame", view.list)
        line:SetHeight(RosterPage.REVIEW_LINE_HEIGHT)
        line:SetPoint("TOPLEFT", view.list, "TOPLEFT", 0, -(index - 1) * RosterPage.REVIEW_LINE_HEIGHT)
        line:SetPoint("RIGHT", view.list, "RIGHT", 0, 0)
        line.before = ui:Text(line, "", "regular", "body", "text")
        line.before:SetPoint("LEFT", line, "LEFT", 0, 0)
        line.before:SetWidth(RosterPage.REVIEW_SIDE_WIDTH - Theme.SPACING.m)
        line.before:SetJustifyH("LEFT")
        line.before:SetWordWrap(false)
        line.after = ui:Text(line, "", "regular", "body", "text")
        line.after:SetPoint("LEFT", line, "LEFT", RosterPage.REVIEW_SIDE_WIDTH, 0)
        line.after:SetPoint("RIGHT", line, "RIGHT", 0, 0)
        line.after:SetJustifyH("LEFT")
        line.after:SetWordWrap(false)
        view.lines[index] = line
    end
    return line
end

-- Review on bundle `group`: its player before and after the change, as the
-- old window's review shows it. Closes when the bundle is gone.
function Page:OpenReview(group)
    local model = self:call("reviewOf", group)
    if model == nil then
        self:CloseReview()
        return
    end
    self.reviewing = group
    local view = self.reviewView
    view.title:SetText("Review: " .. tostring(model.title))
    view.suggestedBy:SetText(model.suggestedBy or "")
    local lines = model.lines or {}
    local index
    for index = 1, math.max(#lines, #view.lines) do
        local entry = lines[index]
        if entry ~= nil then
            local line = self:reviewLine(index)
            line.before:SetText(entry.before or "")
            line.after:SetText(entry.after or "")
            line:Show()
        elseif view.lines[index] ~= nil then
            view.lines[index]:Hide()
        end
    end
    view.list:SetHeight(math.max(1, #lines * RosterPage.REVIEW_LINE_HEIGHT))
    view:Show()
end

function Page:CloseReview()
    self.reviewing = nil
    self.reviewView:Hide()
end

-- The Departed tab: a line saying how many left and Purge all departed
-- (a second click confirms, Cancel backs out), over a full-width list.
function Page:buildDeparted(body)
    local ui, owner = self.ui, self
    self.departedSummary = ui:Text(body, "", "regular", "body", "muted")
    self.departedSummary:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -6)
    self.purgeAll = ui:Button(body, "Purge all departed", "danger", function()
        owner:confirmPurgeAll()
    end)
    self.purgeAll:SetWidth(RosterPage.PURGE_ALL_WIDTH)
    self.purgeAll:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    self.purgeCancel = ui:Button(body, "Cancel", "secondary", function()
        owner:cancelPurgeAll()
    end)
    self.purgeCancel:SetWidth(90)
    self.purgeCancel:SetPoint("RIGHT", self.purgeAll, "LEFT", -Theme.SPACING.s, 0)
    self.purgeCancel:Hide()
    self.departedList = ui:PooledList(body, {
        height = RosterPage.DEPARTED_ROW_HEIGHT,
        gap = Theme.SPACING.xs,
        step = RosterPage.SCROLL_STEP,
        viewport = RosterPage.VIEWPORT,
        build = function(_, parent)
            return owner:buildDepartedRow(parent)
        end,
        fill = function(frame, row)
            owner:fillDepartedRow(frame, row)
        end,
    })
    self.departedList:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -RosterPage.HEADER_HEIGHT - Theme.SPACING.m)
    self.departedList:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    self.noDeparted = ui:Text(body, RosterPage.NO_DEPARTED, "regular", "body", "muted")
    self.noDeparted:SetPoint("TOPLEFT", self.departedList, "TOPLEFT", 0, 0)
end

-- A departed character's row: the name in class color with level and
-- class, then the player, when they left and who's still in the guild,
-- and Purge on the right.
function Page:buildDepartedRow(parent)
    local ui, owner = self.ui, self
    local row = ui:Panel(parent)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -RosterPage.PURGE_WIDTH - 2 * Theme.SPACING.m, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.purge = ui:Button(row, "Purge", "secondary", function()
        if row.entry ~= nil then
            owner:call("onPurge", row.entry.key)
            owner:refreshDeparted()
        end
    end)
    row.purge:SetWidth(RosterPage.PURGE_WIDTH)
    row.purge:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.m, 0)
    return row
end

function Page:fillDepartedRow(frame, entry)
    frame.entry = entry
    local facts = {}
    if type(entry.level) == "number" then
        table.insert(facts, "Level " .. entry.level)
    end
    if type(entry.className) == "string" then
        table.insert(facts, entry.className)
    end
    local name = type(entry.color) == "string" and ("|c" .. entry.color .. entry.name .. "|r") or entry.name
    if facts[1] ~= nil then
        name = name .. "  |cff9d9d9d" .. table.concat(facts, " ") .. "|r"
    end
    frame.name:SetText(name)
    local still = RosterPage.WHOLE_PLAYER_LEFT
    if entry.remaining[1] ~= nil then
        still = "Still in the guild: " .. table.concat(entry.remaining, ", ")
    end
    frame.sub:SetText(table.concat({ entry.player, entry.left, still }, DOT))
end

-- The Departed tab again, from saved data, with its count in the tab.
function Page:refreshDeparted()
    local rows = self:call("departed") or {}
    self.departedRows = rows
    self.departedList:SetRows(rows)
    self.tabs:SetLabel("departed", "Departed" .. DOT .. #rows)
    self.departedSummary:SetText(#rows == 1 and "1 character has left the guild."
        or (#rows .. " characters have left the guild."))
    if rows[1] == nil then
        self.noDeparted:Show()
        self.purgeAll:SetActive(false)
    else
        self.noDeparted:Hide()
        self.purgeAll:SetActive(true)
    end
    self:cancelPurgeAll()
end

-- Purge all departed: the first click asks, the second purges.
function Page:confirmPurgeAll()
    if not self.confirmingPurge then
        self.confirmingPurge = true
        self.purgeAll:SetLabel("Purge all " .. #(self.departedRows or {}) .. "?")
        self.purgeCancel:Show()
        return
    end
    self:call("onPurgeAll")
    self:refreshDeparted()
end

function Page:cancelPurgeAll()
    self.confirmingPurge = false
    self.purgeAll:SetLabel("Purge all departed")
    self.purgeCancel:Hide()
end

-- Shows tab `id` ("members", "departed" or "review").
function Page:ShowTab(id)
    self.tab = id
    self.tabs:Select(id)
    self.menu:Close()
    setShown(self.membersBody, id == "members")
    setShown(self.departedBody, id == "departed")
    setShown(self.reviewBody, id == "review")
    if id == "departed" then
        self:refreshDeparted()
    elseif id == "review" then
        self:refreshReview()
    end
end

-- The tabs for an officer, with each tab's body under them; none for a
-- member, whose Members body fills the page.
function Page:layoutTabs()
    local officer = self:call("isOfficer") == true
    local top = officer and -(RosterPage.TABS_HEIGHT + Theme.SPACING.m) or 0
    local _, body
    for _, body in ipairs({ self.membersBody, self.departedBody, self.reviewBody }) do
        body:ClearAllPoints()
        body:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, top)
        body:SetPoint("BOTTOMRIGHT", self.content, "BOTTOMRIGHT", 0, 0)
    end
    setShown(self.tabs, officer)
    if officer then
        self:refreshDeparted()
        self:refreshReview()
    end
    self:ShowTab(officer and self.tab or "members")
end

-- The column's controls, top to bottom: the search box, Sort and Rank side
-- by side, and Online only. Returns the lowest, for the list to sit under.
function Page:buildControls(column)
    local ui, owner = self.ui, self
    local gap = Theme.SPACING.s
    self.search = ui:SearchBox(column, RosterPage.COLUMN_WIDTH, RosterPage.SEARCH_PLACEHOLDER, function(text)
        owner.query = text
        owner:applyFilters()
    end)
    self.search:SetPoint("TOPLEFT", column, "TOPLEFT", 0, 0)
    local half = (RosterPage.COLUMN_WIDTH - gap) / 2
    self.sortButton = ui:Button(column, "", "secondary", function(button)
        owner:sortMenu(button)
    end)
    self.sortButton:SetWidth(half)
    self.sortButton:SetPoint("TOPLEFT", self.search, "BOTTOMLEFT", 0, -gap)
    self.rankButton = ui:Button(column, "", "secondary", function(button)
        owner:rankMenu(button)
    end)
    self.rankButton:SetWidth(half)
    self.rankButton:SetPoint("LEFT", self.sortButton, "RIGHT", gap, 0)
    self.onlineSwitch = ui:Toggle(column, function(wanted)
        owner.onlineOnly = wanted
        owner.onlineSwitch:SetOn(wanted)
        owner:applyFilters()
    end)
    self.onlineSwitch:SetPoint("TOPLEFT", self.sortButton, "BOTTOMLEFT", 0, -gap)
    self.onlineLabel = ui:Text(column, RosterPage.ONLINE_ONLY, "regular", "body", "text")
    self.onlineLabel:SetPoint("LEFT", self.onlineSwitch, "RIGHT", gap, 0)
    self:labelControls()
    return self.onlineSwitch
end

-- The sort's label, by its id.
local function sortLabel(id)
    local _, sort
    for _, sort in ipairs(addon.RosterListModel.SORTS) do
        if sort.id == id then
            return sort.label
        end
    end
    return id
end

-- Sort and Rank name what they're set to.
function Page:labelControls()
    self.sortButton:SetLabel("Sort: " .. sortLabel(self.sort))
    self.rankButton:SetLabel(self.rank == nil and RosterPage.ANY_RANK or ("Rank: " .. tostring(self.rankName)))
end

-- Sort's menu: each sort, picking one re-sorts the list.
function Page:sortMenu(anchor)
    local owner, items = self, {}
    local _, sort
    for _, sort in ipairs(addon.RosterListModel.SORTS) do
        local id = sort.id
        table.insert(items, { label = sort.label, onClick = function()
            owner.sort = id
            owner:applyFilters()
        end })
    end
    self.menu:Open(anchor, items)
end

-- Rank's menu: Any rank, then each rank a player holds, highest first.
function Page:rankMenu(anchor)
    local owner = self
    local items = { { label = RosterPage.ANY_RANK, onClick = function()
        owner.rank, owner.rankName = nil, nil
        owner:applyFilters()
    end } }
    local _, rank
    for _, rank in ipairs(self.view and self.view.ranks or {}) do
        local index, name = rank.index, rank.name
        table.insert(items, { label = name, onClick = function()
            owner.rank, owner.rankName = index, name
            owner:applyFilters()
        end })
    end
    self.menu:Open(anchor, items)
end

-- The counts' tooltip, on `frame`: a title, then a line each.
function Page:showCountsTooltip(frame)
    local tooltip = self.ui.environment.GameTooltip
    local lines = self:call("countsTooltip")
    if type(tooltip) ~= "table" or type(lines) ~= "table" or lines[1] == nil then
        return
    end
    tooltip:SetOwner(frame, "ANCHOR_BOTTOMLEFT")
    tooltip:SetText(lines[1], 1, 1, 1)
    local index
    for index = 2, #lines do
        tooltip:AddLine(lines[index], nil, nil, nil, true)
    end
    tooltip:Show()
end

-- A new frame for the list: a section's label, or a player card.
function Page:buildRow(kind, parent)
    local ui, owner = self.ui, self
    if kind == "section" then
        local holder = ui:frame("Frame", parent)
        holder.label = ui:SectionLabel(holder, "")
        holder.label:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, Theme.SPACING.xs)
        return holder
    end
    return addon.PlayerCards.Small(ui, parent, {
        onClick = function(card)
            owner:select(card.playerId)
        end,
        onRightClick = function(card)
            owner:openMenu(card, { kind = "player", id = card.playerId }, card.entry and card.entry.name)
        end,
    })
end

function Page:fillRow(frame, row)
    if row.kind == "section" then
        frame.label:SetText(Theme.Label(row.text .. DOT .. row.count))
        return
    end
    frame.playerId = row.playerId
    frame.entry = row
    frame:ShowPlayer({
        name = row.name,
        sub = row.sub,
        color = row.color,
        star = row.star,
        online = row.online,
        tag = row.tag,
    })
    frame:SetSelected(row.playerId == self.selected)
end

-- Showing ---------------------------------------------------------------------

-- The picker's rows for what's typed, from the top.
function Page:showPickerRows(query)
    local picker = self.picker
    local rows = {}
    if self.options.searchPlayers ~= nil and self.linking ~= nil then
        rows = self.options.searchPlayers(self.linking.key, query or "") or {}
    end
    picker.area:SetVerticalScroll(0)
    local index
    for index = 1, math.max(#rows, #picker.rows) do
        local entry = rows[index]
        if entry ~= nil then
            local row = self:pickerRow(index)
            row.entry = entry
            row.name:SetText(entry.label or "")
            row.sub:SetText(entry.matched ~= nil and ("matches " .. entry.matched) or "")
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", picker.list, "TOPLEFT", 0, -(index - 1) * RosterPage.PICKER_ROW_HEIGHT)
            row:SetPoint("RIGHT", picker.list, "RIGHT", 0, 0)
            row:SetHeight(RosterPage.PICKER_ROW_HEIGHT - 4)
            row:Show()
        elseif picker.rows[index] ~= nil then
            picker.rows[index]:Hide()
        end
    end
    picker.list:SetHeight(math.max(1, #rows * RosterPage.PICKER_ROW_HEIGHT))
    if rows[1] == nil then
        picker.empty:Show()
    else
        picker.empty:Hide()
    end
end

-- Opens the picker to link character `key` (named `name`) to another
-- player: as an alt (Link as alt of...), or, with `merge`, its whole
-- player (Merge into player..., for the main).
function Page:OpenPicker(key, name, merge)
    self.menu:Close()
    self.linking = { key = key }
    local picker = self.picker
    if merge then
        picker.title:SetText("Merge into player")
        picker.prompt:SetText("Merge " .. tostring(name) .. " into player:")
    else
        picker.title:SetText("Link as alt of")
        picker.prompt:SetText("Link " .. tostring(name) .. " as an alt of:")
    end
    picker.search:SetValue("")
    self:showPickerRows("")
    picker:Show()
    self.detail:Hide()
end

function Page:ClosePicker()
    self.linking = nil
    self.picker:Hide()
    self.detail:Show()
end

-- Whether the player picker is showing.
function Page:PickerOpen()
    return self.linking ~= nil
end

-- The row index of player `playerId`'s card in the view, or nil.
local function rowOf(view, playerId)
    local index
    for index = 1, #view.rows do
        if view.rows[index].playerId == playerId then
            return index
        end
    end
    return nil
end

-- The list's rows again for the search and filters, keeping the selection
-- where that player still has a card, else selecting the first. Given
-- `focus` (a player id), selects that player instead. The selected card is
-- kept in view.
function Page:rebuild(focus, keepOrder)
    self.view = self.options.model(focus or self.selected, {
        search = self.query,
        sort = self.sort,
        rank = self.rank,
        -- An update keeps the cards of players who went offline (keepOrder).
        onlineOnly = self.onlineOnly and not keepOrder,
    })
    if self.view == nil then
        self.view = { rows = {}, cards = {}, ranks = {}, header = "", sync = "" }
    end
    if keepOrder then
        self:keepOrder()
    end
    self.order = {}
    local index
    for index = 1, #self.view.cards do
        self.order[index] = self.view.cards[index].playerId
    end
    self.selected = focus or self.view.selected or self.view.default
    self:labelControls()
    local parts = {}
    if self.view.header ~= "" then
        table.insert(parts, self.view.header)
    end
    if self.view.sync ~= "" then
        table.insert(parts, self.view.sync)
    end
    self.counts:SetText(table.concat(parts, DOT))
    -- An update leaves the list where it's scrolled to.
    self.list:SetRows(self.view.rows, not keepOrder and rowOf(self.view, self.selected) or nil)
end

-- Puts the new view's cards back in the order shown before, under each
-- section's label, with players new to the list after the rest. Under
-- Online only, a player who went offline keeps their card, and only those
-- online are new.
function Page:keepOrder()
    local view, before = self.view, {}
    local index
    for index = 1, #(self.order or {}) do
        local playerId = self.order[index]
        before[playerId] = index
    end
    local sections, current = {}, nil
    for index = 1, #view.rows do
        local row = view.rows[index]
        if row.kind == "section" or current == nil then
            current = { label = row.kind == "section" and row or nil, cards = {} }
            table.insert(sections, current)
        end
        if row.kind ~= "section"
            and (before[row.playerId] ~= nil or not self.onlineOnly or row.online)
        then
            table.insert(current.cards, row)
        end
    end
    local rows, cards = {}, {}
    local _, section
    for _, section in ipairs(sections) do
        -- A stable sort: the cards' new order breaks ties among the new ones.
        local position = {}
        for index = 1, #section.cards do
            local entry = section.cards[index]
            position[entry] = index
        end
        table.sort(section.cards, function(a, b)
            local first, second = before[a.playerId], before[b.playerId]
            if first ~= nil and second ~= nil then
                return first < second
            end
            if (first ~= nil) ~= (second ~= nil) then
                return first ~= nil
            end
            return position[a] < position[b]
        end)
        if section.label ~= nil and section.cards[1] ~= nil then
            table.insert(rows, { kind = "section", text = section.label.text, count = #section.cards })
        end
        for index = 1, #section.cards do
            table.insert(rows, section.cards[index])
            table.insert(cards, section.cards[index])
        end
    end
    view.rows, view.cards = rows, cards
    view.default = cards[1] and cards[1].playerId or nil
    if rowOf(view, view.selected) == nil then
        view.selected = nil
    end
end

-- Builds the page again from saved data and the roster (see rebuild), and
-- the selected player's panel.
function Page:Refresh(focus)
    self.menu:Close()
    self:layoutTabs()
    self:rebuild(focus)
    self:showDetail()
end

-- The roster changed on its own (someone came online, a sync): the cards
-- and the panel show what's new, in the order and place they're in.
function Page:Update()
    self:rebuild(nil, true)
    self:showDetail()
    if self.tab == "departed" then
        self:refreshDeparted()
    end
    -- The Review tab's count stays current wherever the officer is.
    if self:call("isOfficer") == true then
        self:refreshReview()
    end
end

-- Shows the selected player again, and the page, after an organizing
-- change.
function Page:changed()
    if self.linking ~= nil then
        self:ClosePicker()
    end
    self:Refresh()
end

-- The search or a filter changed: the list again, and the panel only when
-- the selected player changed with it.
function Page:applyFilters()
    local before = self.selected
    self:rebuild()
    if self.selected ~= before then
        self:showDetail()
    end
end

function Page:showDetail()
    if self.selected == nil then
        self.detail:ShowEmpty(RosterPage.EMPTY)
        return
    end
    -- Another player's Grouped tab starts at its first page.
    if self.detailFor ~= self.selected then
        self.detailFor, self.groupedShown = self.selected, nil
    end
    local view = self.options.detail ~= nil and self.options.detail(self.selected, self.groupedShown) or nil
    if view == nil then
        self.detail:ShowEmpty(RosterPage.EMPTY)
        return
    end
    -- The ⋯ button and the Bio tab's Edit, for a player the user may change.
    local main = view.panel and view.panel.main or nil
    view.canEdit = main ~= nil and self.options.canEdit ~= nil and self.options.canEdit(main) == true
    self.detail:ShowPlayer(view)
    -- The roster changing while the picker is open doesn't cover it.
    if self.linking ~= nil then
        self.detail:Hide()
    end
end

-- Interactions ----------------------------------------------------------------

function Page:select(playerId)
    if playerId == nil then
        return
    end
    self.selected = playerId
    -- Refills the cards in view, moving the green border.
    self.list.Layout()
    self:showDetail()
end

-- The detail panel's star button: pins or unpins the player as a Friend.
-- They stay selected, and their card's star follows.
function Page:toggleFriend(view)
    local ok, why = true, nil
    if self.options.onToggleFriend ~= nil then
        ok, why = self.options.onToggleFriend(view)
    end
    if ok == false and self.options.onError ~= nil then
        self.options.onError("That friend wasn't changed: " .. tostring(why) .. ".")
    end
    self:Refresh(view.playerId)
end

-- Organizing ----------------------------------------------------------------

-- The right-click menu for `target` (see menuFor), under `anchor`, titled
-- `title`.
function Page:openMenu(anchor, target, title)
    local entries = self.options.menuFor ~= nil and self.options.menuFor(target) or {}
    if entries[1] == nil then
        return
    end
    local owner, items = self, {}
    local index
    for index = 1, #entries do
        local entry = entries[index]
        table.insert(items, { label = entry.text, onClick = function()
            owner:run(entry, title)
        end })
    end
    self.menu:Open(anchor, items, title)
end

-- The ⋯ menu: Whisper and Invite (greyed out while the player is
-- offline), then, for a player the user may change, Set alias..., Set
-- Discord... and Merge into player... (Merge only while it's just the
-- main).
function Page:actionsMenu(anchor, view)
    local panel = view.panel or {}
    local main, name = panel.main, view.header and view.header.name
    local target = view.header and view.header.target or nil
    local owner = self
    local items = {
        { label = "Whisper", disabled = target == nil, onClick = function()
            owner:call("onWhisper", target)
        end },
        { label = "Invite", disabled = target == nil, onClick = function()
            owner:call("onInvite", target)
        end },
    }
    if view.canEdit then
        table.insert(items, { label = "Set alias...", onClick = function()
            owner:run({ action = "alias", key = main }, name)
        end })
        table.insert(items, { label = "Set Discord...", onClick = function()
            owner:run({ action = "discord", key = main, current = panel.discord }, name)
        end })
    end
    if view.canEdit and panel.canMerge then
        table.insert(items, { label = "Merge into player...", onClick = function()
            owner:run({ action = "merge", key = main }, name)
        end })
    end
    self.menu:Open(anchor, items, name)
end

-- Calls option `name` with the arguments, when it's there.
function Page:call(name, ...)
    local callback = self.options[name]
    if callback == nil then
        return nil
    end
    return callback(...)
end

-- Runs a menu entry ({ action, key }) for the player or character `title`
-- names.
function Page:run(entry, title)
    local owner, key = self, entry.key
    local action = entry.action
    if action == "view" then
        local playerId = self:call("playerOf", key)
        if playerId ~= nil then
            self:Refresh(playerId)
        end
    elseif action == "setMain" or action == "merge" then
        self:OpenPicker(key, title, action == "merge")
    elseif action == "makeMain" then
        self:call("onMakeMain", key)
        self:changed()
    elseif action == "detach" then
        self:call("onDetach", key)
        self:changed()
    elseif action == "alias" then
        self.prompt:Open({
            title = "Alias for " .. tostring(title) .. " (leave empty to clear)",
            text = self:call("aliasOf", key) or "",
            maxLetters = RosterPage.ALIAS_LETTERS,
            onSave = function(text)
                owner:call("onSetAlias", key, text)
                owner:changed()
            end,
        })
    elseif action == "discord" then
        self.prompt:Open({
            title = "Discord username for " .. tostring(title) .. " (leave empty to clear)",
            text = entry.current or "",
            maxLetters = addon.FellowshipStore.PROFILE_FIELDS.discord,
            onSave = function(text)
                owner:call("onSetDiscord", key, text)
                owner:changed()
            end,
        })
    end
end

-- The Bio tab's Edit: asks for the player's new location or bio.
function Page:editProfile(field, view)
    local panel = view.panel or {}
    local owner, key = self, panel.main
    local limit = addon.FellowshipStore.PROFILE_FIELDS[field]
    self.prompt:Open({
        title = (field == "bio" and "Bio" or "Location") .. " for " .. tostring(view.header and view.header.name)
            .. " (leave empty to clear)",
        text = panel[field] or "",
        maxLetters = limit,
        maxBytes = field == "bio" and limit or nil,
        multiline = field == "bio",
        onSave = function(text)
            owner:call("onSetProfileText", key, field, text)
            owner:changed()
        end,
    })
end

-- Links the character being linked to the picked player.
function Page:pick(entry)
    if entry == nil or self.linking == nil then
        return
    end
    self:call("onSetMain", self.linking.key, entry.id)
    self:changed()
end

-- Shows tab `id` of the selected player's panel (the Rank tab when Rank
-- management opens a player), when it has that tab.
function Page:ShowDetailTab(id)
    local view = self.detail.view
    if view ~= nil and (id ~= "rank" or view.rank ~= nil) then
        self.detail:ShowTab(id)
    end
end

-- The selected player's id, or nil.
function Page:Selected()
    return self.selected
end
