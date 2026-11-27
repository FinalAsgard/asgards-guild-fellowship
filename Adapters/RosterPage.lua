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
-- panel (PlayerDetailPanel), with Whisper, Invite and the Friend star.
--
-- Right-clicking a player card, or a character card in the panel's
-- Characters tab, opens the old roster's organizing actions for it
-- (RosterController's entries, so a member only gets what they may do to
-- their own player); the panel's ⋯ button has the player-wide ones. Link as
-- alt of... and Merge into player... swap the panel for a player picker
-- with a search box, as the Friends page's is. Set alias..., Set Discord...
-- and the Bio tab's Edit ask for the text in a small prompt.
--
-- It's built when the page is shown (Refresh). When the roster changes on
-- its own (Update), the cards show what's new but keep their order and the
-- list its place, so it doesn't jump while it's being scrolled; a sort,
-- filter or search change sorts it again.
local Theme = addon.Theme
local DOT = " · "

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
--   onError   function(text): tells the user why something didn't happen
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
    local ui, content = self.ui, self.content
    local owner = self
    self.counts = ui:Text(content, "", "regular", "body", "muted")
    self.counts:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -6)
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
    self.detail = addon.PlayerDetailPanel.Create(ui, side, {
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
        onlineOnly = self.onlineOnly,
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
-- section's label, with players new to the list after the rest.
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
        if row.kind ~= "section" then
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
        if section.label ~= nil then
            table.insert(rows, section.label)
        end
        for index = 1, #section.cards do
            table.insert(rows, section.cards[index])
            table.insert(cards, section.cards[index])
        end
    end
    view.rows, view.cards = rows, cards
    view.default = cards[1] and cards[1].playerId or nil
end

-- Builds the page again from saved data and the roster (see rebuild), and
-- the selected player's panel.
function Page:Refresh(focus)
    self.menu:Close()
    self:rebuild(focus)
    self:showDetail()
end

-- The roster changed on its own (someone came online, a sync): the cards
-- and the panel show what's new, in the order and place they're in.
function Page:Update()
    self:rebuild(nil, true)
    self:showDetail()
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

-- The ⋯ menu: Set alias..., Set Discord... and Merge into player..., for a
-- player the user may change (Merge only while it's just the main).
function Page:actionsMenu(anchor, view)
    local panel = view.panel or {}
    local main, name = panel.main, view.header and view.header.name
    if not view.canEdit then
        return
    end
    local owner = self
    local items = {
        { label = "Set alias...", onClick = function()
            owner:run({ action = "alias", key = main }, name)
        end },
        { label = "Set Discord...", onClick = function()
            owner:run({ action = "discord", key = main, current = panel.discord }, name)
        end },
    }
    if panel.canMerge then
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

-- The selected player's id, or nil.
function Page:Selected()
    return self.selected
end
