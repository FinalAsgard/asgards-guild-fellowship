local _, addon = ...

-- The Friends page in the AGF window. The left column holds the Friend
-- slots (FriendsViewModel): the pinned players as small player cards, then
-- "+ Add a friend" for each open slot. Hovering a Friend shows an X that
-- removes them; right-clicking one offers Replace... and Remove friend.
--
-- The right side shows the selected player, or how to add friends when
-- there are none. + Add a friend (or Replace...) swaps it for Choose a
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
    SCROLL_STEP = 44,
    SEARCH_WIDTH = 300,
    ADD_FRIEND = "+ Add a friend",
    CHOOSE_TITLE = "Choose a friend",
    SEARCH_PLACEHOLDER = "Search by alias or character name",
    NO_MATCHES = "No guildmates match.",
    EMPTY = "Pin up to 5 guildmates as Friends with + Add a friend. Friends get the star in greet prompts"
        .. " and on the LFG page.",
    SELECTED_HINT = "More about this player is coming to this side of the page.",
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
        card:SetPoint("TOPLEFT", column, "TOPLEFT", 0,
            -20 - (index - 1) * (addon.PlayerCards.SMALL_HEIGHT + Theme.SPACING.s))
        card:SetPoint("RIGHT", column, "RIGHT", 0, 0)
        card:Hide()
        self.cards[index] = card
    end
    self.menu = ui:ContextMenu(content)

    local side = ui:Panel(content)
    side:SetPoint("TOPLEFT", column, "TOPRIGHT", Theme.SPACING.l, 0)
    side:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    self.side = side
    self:buildDetail(side)
    self:buildPicker(side)
end

-- The right side until the player detail panel lands: the selected
-- player's name, or how to add friends.
function Page:buildDetail(side)
    local ui, pad = self.ui, Theme.SPACING.l
    local detail = ui:frame("Frame", side)
    detail:SetAllPoints(side)
    detail.name = ui:Text(detail, "", "semibold", "heading", "text")
    detail.name:SetPoint("TOPLEFT", detail, "TOPLEFT", pad, -pad)
    detail.sub = ui:Text(detail, "", "regular", "body", "muted")
    detail.sub:SetPoint("TOPLEFT", detail.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    detail.hint = ui:Text(detail, "", "regular", "body", "muted")
    detail.hint:SetPoint("TOPLEFT", detail, "TOPLEFT", pad, -pad - 60)
    detail.hint:SetPoint("RIGHT", detail, "RIGHT", -pad, 0)
    detail.hint:SetJustifyH("LEFT")
    detail.hint:SetWordWrap(true)
    self.detail = detail
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
-- and how often the user grouped with them on the right.
function Page:pickerRow(index)
    local picker = self.picker
    local row = picker.rows[index]
    if row ~= nil then
        return row
    end
    local ui, owner = self.ui, self
    row = ui:frame("Button", picker.list)
    row:SetHeight(FriendsPage.PICKER_ROW_HEIGHT - 4)
    ui:Round(row, Theme.RADIUS.button, "raised", false)
    row:SetPoint("TOPLEFT", picker.list, "TOPLEFT", 0, -(index - 1) * FriendsPage.PICKER_ROW_HEIGHT)
    row:SetPoint("RIGHT", picker.list, "RIGHT", 0, 0)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.s, -5)
    row.sub = ui:Text(row, "", "regular", "small", "muted")
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
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
-- selection where that player still has a card. Closes the picker.
function Page:Refresh()
    self.menu:Close()
    self.view = self.options.model(self.selected)
    if self.view == nil then
        self.view = { friends = {}, empty = 0, full = true }
    end
    self.selected = self.view.selected or self.view.default
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
    self:showPicker(false)
    self:showDetail()
end

-- The selected Friend's card fields, or nil.
function Page:selectedFriend()
    local index
    for index = 1, #self.view.friends do
        if self.view.friends[index].playerId == self.selected then
            return self.view.friends[index]
        end
    end
    return nil
end

function Page:showDetail()
    local detail, friend = self.detail, self:selectedFriend()
    if friend ~= nil then
        detail.name:SetText(friend.name)
        detail.sub:SetText(subLine(friend))
        detail.hint:SetText(FriendsPage.SELECTED_HINT)
    else
        detail.name:SetText("")
        detail.sub:SetText("")
        detail.hint:SetText(FriendsPage.EMPTY)
    end
end

function Page:showPicker(shown)
    self.pickerOpen = shown
    setShown(self.picker, shown)
    setShown(self.detail, not shown)
end

-- Lays out the picker's rows for what's typed.
function Page:showRows()
    local picker = self.picker
    local rows = self.options.picker(self.query or "") or {}
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
            row:Show()
        elseif picker.rows[index] ~= nil then
            picker.rows[index]:Hide()
        end
    end
    picker.list:SetHeight(math.max(1, #rows * FriendsPage.PICKER_ROW_HEIGHT))
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
    local index
    for index = 1, #self.cards do
        local other = self.cards[index]
        other:SetSelected(not other.empty and other.playerId == self.selected)
    end
    self:showPicker(false)
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

-- Pins the picked row's player, in the slot being replaced or an open one,
-- and selects them.
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
