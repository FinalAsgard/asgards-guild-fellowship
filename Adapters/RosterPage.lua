local _, addon = ...

-- The Roster page in the AGF window. Across the top, the guild's player
-- and online counts and when it last synced, with Rescan on the right.
-- Under that, the left column lists one player card per player
-- (RosterListModel), in Online and Offline sections, in a pooled list:
-- only the cards in view have frames, so hundreds of players scroll
-- smoothly. The cards are the Friends page's (PlayerCards).
--
-- The right side shows the selected player in the shared player detail
-- panel (PlayerDetailPanel), with Whisper, Invite and the Friend star.
--
-- It's built when the page is shown (Refresh), and again when the owner
-- says the roster changed.
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
    -- The column's height to lay out for until the frame can say.
    VIEWPORT = 560,
    EMPTY = "No guildmates to show yet. The roster fills in once it's scanned.",
}
addon.RosterPage = RosterPage

local Page = {}
Page.__index = Page

-- Draws the page into `content` with widget factory `ui`. options:
--   model     function(selected) -> RosterListModel.Build's view, or nil
--             outside a guild
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
function RosterPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options }, Page)
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
    self.list:SetAllPoints(column)

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
    })
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
    })
    frame:SetSelected(row.playerId == self.selected)
end

-- Showing ---------------------------------------------------------------------

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

-- Builds the page again from saved data and the roster, keeping the
-- selection where that player still has a card, else selecting the first.
-- Given `focus` (a player id), selects that player instead. The selected
-- card is kept in view.
function Page:Refresh(focus)
    self.view = self.options.model(focus or self.selected)
    if self.view == nil then
        self.view = { rows = {}, cards = {}, header = "", sync = "" }
    end
    self.selected = focus or self.view.selected or self.view.default
    local parts = {}
    if self.view.header ~= "" then
        table.insert(parts, self.view.header)
    end
    if self.view.sync ~= "" then
        table.insert(parts, self.view.sync)
    end
    self.counts:SetText(table.concat(parts, DOT))
    self.list:SetRows(self.view.rows, rowOf(self.view, self.selected))
    self:showDetail()
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
    self.detail:ShowPlayer(view)
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

-- The selected player's id, or nil.
function Page:Selected()
    return self.selected
end
