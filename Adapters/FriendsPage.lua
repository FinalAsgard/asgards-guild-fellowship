local _, addon = ...

-- The Friends page in the AGF window. The left column holds the Friend
-- slots (FriendsViewModel): the pinned players as small player cards, then
-- "+ Add a friend" for each open slot. Hovering a Friend shows an X that
-- removes them; right-clicking one offers Replace... and Remove friend.
-- Under them, Most grouped with shows the players grouped with most who
-- aren't Friends, each with their party count; right-clicking one offers
-- Add as friend, greyed out while every slot is taken.
--
-- The right side shows the selected player in the shared player detail
-- panel (PlayerDetailPanel), or how to add friends when there are none. + Add a friend (or Replace...) swaps it for Choose a
-- friend: a search box over the guildmates who could be pinned, a list of
-- them, and Cancel. Picking one fills the slot.
--
-- Both are built when the page is shown (Refresh); nothing updates while
-- it's open.
local Theme = addon.Theme
local DOT = " · "

local FriendsPage = {
    COLUMN_WIDTH = 260,
    PICKER_ROW_HEIGHT = 44,
    -- A picker row's third line, naming the alts a search found.
    ALT_LINE_HEIGHT = 16,
    SCROLL_STEP = 44,
    SEARCH_WIDTH = 300,
    ADD_FRIEND = "+ Add a friend",
    CHOOSE_TITLE = "Choose a friend",
    SEARCH_PLACEHOLDER = "Search by alias or character name",
    NO_MATCHES = "No guildmates match.",
    EMPTY = "Pin up to 5 guildmates as Friends with + Add a friend. Friends get the star in greet prompts"
        .. " and on the LFG page.",
    NO_HISTORY = "The guildmates you group with most will show here.",
}
addon.FriendsPage = FriendsPage

local Page = {}
Page.__index = Page

-- Draws the page into `content` with widget factory `ui`. options:
--   model     function(selected) -> FriendsViewModel.Build's view, or nil
--             outside a guild
--   picker    function(query) -> FriendsViewModel.Picker's rows
--   onAdd     function(key) -> true, or false and why not
--   onRemove  function(playerId)
--   onReplace function(playerId, key) -> true, or false and why not
--   onError   function(text): tells the user why something didn't happen
--   detail    function(playerId, groupedShown) -> PlayerDetailViewModel
--             .Build's view (showing `groupedShown` Grouped parties, nil for
--             the first page), or nil when the player is gone
--   formatDate function(at) -> text, for the Grouped tab
--   onWhisper function(target): whispers that character
--   onInvite  function(target): invites that character
function FriendsPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options, cards = {} }, Page)
    page:build()
    return page
end

-- `text` in `color` ("ffrrggbb"), where it's known.
local function colored(text, color)
    if type(color) ~= "string" then
        return text
    end
    return "|c" .. color .. text .. "|r"
end

local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

-- "Level 60 Warrior" in the class color, leaving out what isn't known.
local function levelAndClass(card)
    local parts = {}
    if type(card.level) == "number" then
        table.insert(parts, "Level " .. card.level)
    end
    if type(card.className) == "string" then
        table.insert(parts, card.className)
    end
    if parts[1] == nil then
        return nil
    end
    return colored(table.concat(parts, " "), card.color)
end

-- The card's sub line: the main's name when the big name is an alias, then
-- level and class, or "Left the guild".
local function subLine(card)
    if card.left then
        return card.status
    end
    local parts = {}
    if card.alias ~= nil then
        table.insert(parts, card.mainName)
    end
    table.insert(parts, levelAndClass(card))
    return table.concat(parts, DOT)
end

-- Building ------------------------------------------------------------------

function Page:build()
    local ui, content = self.ui, self.content
    local owner = self
    local column = ui:frame("Frame", content)
    column:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    column:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    column:SetWidth(FriendsPage.COLUMN_WIDTH)
    self.column = column
    self.friendsLabel = ui:SectionLabel(column, "Friends")
    self.friendsLabel:SetPoint("TOPLEFT", column, "TOPLEFT", 0, 0)
    local slots = addon.FellowshipStore.FRIEND_SLOTS
    local step = addon.PlayerCards.SMALL_HEIGHT + Theme.SPACING.xs
    local index
    for index = 1, slots do
        local card = addon.PlayerCards.Small(ui, column, {
            onClick = function(clicked)
                owner:clickCard(clicked)
            end,
            onRightClick = function(clicked)
                owner:friendMenu(clicked)
            end,
            onRemove = function(clicked)
                owner:remove(clicked.playerId)
            end,
        })
        card:SetPoint("TOPLEFT", column, "TOPLEFT", 0, -20 - (index - 1) * step)
        card:SetPoint("RIGHT", column, "RIGHT", 0, 0)
        card:Hide()
        self.cards[index] = card
    end
    local mostTop = 20 + slots * step + Theme.SPACING.s
    self.mostLabel = ui:SectionLabel(column, "Most grouped with")
    self.mostLabel:SetPoint("TOPLEFT", column, "TOPLEFT", 0, -mostTop)
    self.noHistory = ui:Text(column, FriendsPage.NO_HISTORY, "regular", "body", "muted")
    self.noHistory:SetPoint("TOPLEFT", column, "TOPLEFT", 0, -mostTop - 20)
    self.noHistory:SetPoint("RIGHT", column, "RIGHT", 0, 0)
    self.noHistory:SetJustifyH("LEFT")
    self.noHistory:SetWordWrap(true)
    self.mostCards = {}
    for index = 1, addon.GroupFriends.TOP_SIZE do
        local card = addon.PlayerCards.Small(ui, column, {
            onClick = function(clicked)
                owner:clickCard(clicked)
            end,
            onRightClick = function(clicked)
                owner:mostGroupedMenu(clicked)
            end,
        })
        card:SetPoint("TOPLEFT", column, "TOPLEFT", 0, -mostTop - 20 - (index - 1) * step)
        card:SetPoint("RIGHT", column, "RIGHT", 0, 0)
        card:Hide()
        self.mostCards[index] = card
    end
    self.menu = ui:ContextMenu(content)

    local side = ui:Panel(content)
    side:SetPoint("TOPLEFT", column, "TOPRIGHT", Theme.SPACING.l, 0)
    side:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    self.side = side
    self:buildDetail(side)
    self:buildPicker(side)
end

-- The right side: the selected player's detail panel, or how to add
-- friends.
function Page:buildDetail(side)
    local owner = self
    self.detail = addon.PlayerDetailPanel.Create(self.ui, side, {
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
    })
end

-- Choose a friend: a title, the search box, a scrolling list and Cancel.
function Page:buildPicker(side)
    local ui, pad = self.ui, Theme.SPACING.l
    local owner = self
    local picker = ui:frame("Frame", side)
    picker:SetAllPoints(side)
    picker.title = ui:Text(picker, FriendsPage.CHOOSE_TITLE, "semibold", "title", "text")
    picker.title:SetPoint("TOPLEFT", picker, "TOPLEFT", pad, -pad)
    picker.search = ui:SearchBox(picker, FriendsPage.SEARCH_WIDTH, FriendsPage.SEARCH_PLACEHOLDER, function(text)
        owner.query = text
        owner:showRows()
    end)
    picker.search:SetPoint("TOPLEFT", picker.title, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    picker.cancel = ui:Button(picker, "Cancel", "secondary", function()
        owner:ClosePicker()
    end)
    picker.cancel:SetWidth(90)
    picker.cancel:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -pad, pad)

    local area = ui:frame("ScrollFrame", picker)
    area:SetPoint("TOPLEFT", picker.search, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    area:SetPoint("BOTTOMRIGHT", picker.cancel, "TOPRIGHT", 0, Theme.SPACING.m)
    local list = ui:frame("Frame", area)
    list:SetSize(400, 1)
    area:SetScrollChild(list)
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(self, delta)
        local most = self:GetVerticalScrollRange() or 0
        local scroll = (self:GetVerticalScroll() or 0) - delta * FriendsPage.SCROLL_STEP
        self:SetVerticalScroll(math.max(0, math.min(most, scroll)))
    end)
    area:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            list:SetWidth(width)
        end
    end)
    picker.area, picker.list = area, list
    picker.empty = ui:Text(list, FriendsPage.NO_MATCHES, "regular", "body", "muted")
    picker.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    picker.rows = {}
    picker:Hide()
    self.picker = picker
end

-- A picker row: the player's name and main, class, alts and online status,
-- and how often the user grouped with them on the right. A search that
-- found them by an alt's name adds a third line naming it.
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
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.s, -5)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.alt = ui:Text(row, "", "regular", "small", "text")
    row.alt:SetPoint("TOPLEFT", row.sub, "BOTTOMLEFT", 0, -3)
    row.alt:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.s, 0)
    row.alt:SetJustifyH("LEFT")
    row.alt:SetWordWrap(false)
    row.grouped = ui:Text(row, "", "regular", "small", "muted")
    row.grouped:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.s, 0)
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

-- Showing ---------------------------------------------------------------------

-- Builds the page again from saved data and the roster, keeping the
-- selection where that player still has a card. Given `focus` (a player
-- id), shows that player on the right instead, with their card selected
-- when they have one and none when they don't. Closes the picker.
function Page:Refresh(focus)
    self.menu:Close()
    self.view = self.options.model(focus or self.selected)
    if self.view == nil then
        self.view = { friends = {}, empty = 0, full = true, mostGrouped = {} }
    end
    self.view.mostGrouped = self.view.mostGrouped or {}
    self.selected = focus or self.view.selected or self.view.default
    local index
    for index = 1, #self.cards do
        local card, friend = self.cards[index], self.view.friends[index]
        if friend ~= nil then
            card.playerId = friend.playerId
            card.friend = friend
            card:ShowPlayer({
                name = friend.name,
                sub = subLine(friend),
                color = friend.color,
                star = true,
                online = friend.online,
                greyed = friend.left,
            })
            card:SetSelected(friend.playerId == self.selected)
        elseif index <= #self.view.friends + self.view.empty then
            card.playerId, card.friend = nil, nil
            card:ShowEmpty(FriendsPage.ADD_FRIEND)
        else
            card:Hide()
        end
    end
    for index = 1, #self.mostCards do
        local card, entry = self.mostCards[index], self.view.mostGrouped[index]
        if entry ~= nil then
            card.playerId = entry.playerId
            card.friend = entry
            card:ShowPlayer({
                name = entry.name,
                sub = subLine(entry),
                color = entry.color,
                star = true,
                count = entry.countText,
                greyed = entry.left,
            })
            card:SetSelected(entry.playerId == self.selected)
        else
            card.playerId, card.friend = nil, nil
            card:Hide()
        end
    end
    setShown(self.noHistory, self.view.mostGrouped[1] == nil)
    self:showPicker(false)
    self:showDetail()
end

-- The selected player's card fields (a Friend's or a Most grouped
-- player's), or nil.
function Page:selectedFriend()
    local _, list
    for _, list in ipairs({ self.view.friends, self.view.mostGrouped }) do
        local index
        for index = 1, #list do
            if list[index].playerId == self.selected then
                return list[index]
            end
        end
    end
    return nil
end

-- What the detail panel shows for a card whose player is gone (a Friend
-- purged from the guild): the card's name and status, and the star button
-- to remove them.
local function fallbackView(friend, isFriend)
    return {
        playerId = friend.playerId,
        header = {
            name = friend.name,
            status = friend.status,
            left = friend.left,
            key = friend.key,
            badge = isFriend and { kind = addon.PlayerDetailViewModel.FRIEND } or nil,
            isFriend = isFriend,
            canToggle = isFriend,
        },
        tiles = {},
    }
end

function Page:showDetail()
    local friend = self:selectedFriend()
    if friend == nil and self.selected ~= nil then
        -- A player with no card, opened from elsewhere.
        friend = { playerId = self.selected }
    end
    if friend == nil then
        self.detail:ShowEmpty(FriendsPage.EMPTY)
        return
    end
    -- Another player's Grouped tab starts at its first page.
    if self.detailFor ~= friend.playerId then
        self.detailFor, self.groupedShown = friend.playerId, nil
    end
    local view = self.options.detail ~= nil and self.options.detail(friend.playerId, self.groupedShown) or nil
    if view == nil and friend.name == nil then
        self.selected = nil
        self.detail:ShowEmpty(FriendsPage.EMPTY)
        return
    end
    self.detail:ShowPlayer(view or fallbackView(friend, self:isFriend(friend.playerId)))
end

-- Whether `playerId` is one of the pinned Friends.
function Page:isFriend(playerId)
    local index
    for index = 1, #self.view.friends do
        if self.view.friends[index].playerId == playerId then
            return true
        end
    end
    return false
end

function Page:showPicker(shown)
    self.pickerOpen = shown
    setShown(self.picker, shown)
    setShown(self.detail, not shown)
end

-- Lays out the picker's rows for what's typed, top to bottom, each as tall
-- as its lines, from the top of the list: a list
-- scrolled down before a search would otherwise hide its few matches
-- above the visible part.
function Page:showRows()
    local picker = self.picker
    local rows = self.options.picker(self.query or "") or {}
    picker.area:SetVerticalScroll(0)
    local top = 0
    local index
    for index = 1, math.max(#rows, #picker.rows) do
        local entry = rows[index]
        if entry ~= nil then
            local row = self:pickerRow(index)
            row.entry = entry
            row.name:SetText(colored(entry.name, entry.alias == nil and entry.color or nil))
            local parts = {}
            if entry.alias ~= nil then
                table.insert(parts, colored(entry.mainName, entry.color))
            end
            table.insert(parts, levelAndClass(entry))
            if entry.alts > 0 then
                table.insert(parts, entry.alts == 1 and "1 alt" or (entry.alts .. " alts"))
            end
            table.insert(parts, entry.online and "Online" or "Offline")
            row.sub:SetText(table.concat(parts, DOT))
            row.grouped:SetText(entry.grouped)
            local height = FriendsPage.PICKER_ROW_HEIGHT
            if entry.matchedAlts ~= nil then
                row.alt:SetText("|cff9d9d9d" .. (#entry.matchedAlts == 1 and "Alt: " or "Alts: ") .. "|r"
                    .. table.concat(entry.matchedAlts, ", "))
                row.alt:Show()
                height = height + FriendsPage.ALT_LINE_HEIGHT
            else
                row.alt:SetText("")
                row.alt:Hide()
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", picker.list, "TOPLEFT", 0, -top)
            row:SetPoint("RIGHT", picker.list, "RIGHT", 0, 0)
            row:SetHeight(height - 4)
            top = top + height
            row:Show()
        elseif picker.rows[index] ~= nil then
            picker.rows[index]:Hide()
        end
    end
    picker.list:SetHeight(math.max(1, top))
    setShown(picker.empty, rows[1] == nil)
    self.pickerRows = rows
end

-- Opens Choose a friend, filling an open slot or, given `playerId`,
-- replacing that Friend.
function Page:OpenPicker(playerId)
    self.menu:Close()
    self.replacing = playerId
    self.query = ""
    self.picker.search:SetValue("")
    self:showRows()
    self:showPicker(true)
end

function Page:ClosePicker()
    self.replacing = nil
    self:showPicker(false)
end

-- Whether Choose a friend is showing.
function Page:PickerOpen()
    return self.pickerOpen == true
end

-- Interactions ----------------------------------------------------------------

function Page:clickCard(card)
    if card.empty then
        self:OpenPicker(nil)
        return
    end
    self.selected = card.playerId
    local _, cards
    for _, cards in ipairs({ self.cards, self.mostCards }) do
        local index
        for index = 1, #cards do
            local other = cards[index]
            other:SetSelected(not other.empty and other.playerId == self.selected)
        end
    end
    -- Leaving Choose a friend without a choice drops a Replace… too.
    self:ClosePicker()
    self:showDetail()
end

function Page:friendMenu(card)
    local owner, playerId = self, card.playerId
    self.menu:Open(card, {
        { label = "Replace…", onClick = function()
            owner:OpenPicker(playerId)
        end },
        { label = "Remove friend", onClick = function()
            owner:remove(playerId)
        end },
    }, card.friend and card.friend.name or nil)
end

function Page:mostGroupedMenu(card)
    local owner, entry = self, card.friend
    self.menu:Open(card, {
        { label = "Add as friend", disabled = self.view.full, onClick = function()
            -- Into an open slot, never one being replaced.
            owner.replacing = nil
            owner:pick(entry)
        end },
    }, entry and entry.name or nil)
end

function Page:remove(playerId)
    if playerId == nil then
        return
    end
    self.options.onRemove(playerId)
    if self.selected == playerId then
        self.selected = nil
    end
    self:Refresh()
end

-- The detail panel's star button: removes a Friend, or pins the player in
-- an open slot. They stay selected.
function Page:toggleFriend(view)
    local header = view.header
    if header.isFriend then
        self.options.onRemove(view.playerId)
        -- They stay shown, with or without a card.
        self:Refresh(view.playerId)
        return
    end
    self.replacing = nil
    self:pick({ playerId = view.playerId, key = header.key })
end

-- Pins the picked row's (or Most grouped card's) player, in the slot being
-- replaced or an open one, and selects them.
function Page:pick(entry)
    if entry == nil then
        return
    end
    local ok, why
    if self.replacing ~= nil then
        ok, why = self.options.onReplace(self.replacing, entry.key)
    else
        ok, why = self.options.onAdd(entry.key)
    end
    if not ok then
        if self.options.onError ~= nil then
            self.options.onError("That friend wasn't added: " .. tostring(why) .. ".")
        end
        return
    end
    self.replacing = nil
    self.selected = entry.playerId
    self:Refresh()
end

-- The selected player's id, or nil.
function Page:Selected()
    return self.selected
end
