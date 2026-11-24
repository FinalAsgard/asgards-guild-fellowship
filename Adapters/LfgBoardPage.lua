local _, addon = ...

-- The Guild LFG Board page in the AGF window. At the top is the card for
-- the player's own party: "You're not in a party" with Start a group when
-- they aren't listed, their listing in view mode (Edit, Not looking) when
-- they are, and an inline editor (What's it for?, the kind's fields, the
-- note, Save and Cancel) while editing. Below it are the Relevant Parties,
-- Other Parties and History tabs. For now every listing heard from
-- guildmates shows as a small greyed card on Other Parties; an empty tab
-- shows one line.
--
-- It draws what it's handed and calls back for every change; it keeps no
-- listing of its own.
local Theme = addon.Theme
local Widgets = addon.Widgets

local DOT = " \194\183 "
local DASH = "\226\128\147"

local LfgBoardPage = {
    SOLO_HEIGHT = 64,
    VIEW_HEIGHT = 104,
    EDIT_HEIGHT = 312,
    SMALL_CARD_HEIGHT = 52,
    -- The most small cards a tab shows, two per row; more are counted.
    SMALL_CARDS = 8,
    EDIT_SMALL_CARDS = 4,
    -- The most rows the dungeon list shows, its "Other levels" line
    -- included.
    DUNGEON_ROWS = 7,
    DUNGEON_ROW_HEIGHT = 20,
    FIELD_WIDTH = 320,
    KINDS = {
        { id = "dungeon", label = "Dungeon" },
        { id = "questing", label = "Questing" },
        { id = "raid", label = "Raid" },
        { id = "other", label = "Other" },
    },
    EMPTY = {
        relevant = "No relevant groups for you right now.",
        other = "No other groups right now.",
        history = "No parties in your history yet.",
    },
    RAID_EXPLANATION = "A raid is listed as a big party: anyone can ask to join, with no role rules.",
}
addon.LfgBoardPage = LfgBoardPage

local Page = {}
Page.__index = Page

-- Draws the page into `content` with widget factory `ui`. options:
--   listing       the player's LfgListing (read only)
--   members       function() -> the party as the listing announces it
--   level         function() -> the player's level
--   zone          function() -> the player's zone name, or nil
--   catalog       function() -> the DungeonCatalog to search
--   listings      function() -> the board's listings (LfgBoard:Listings)
--   onSave        function(purpose, note) -> true, or false and why not
--   onNotLooking  function()
function LfgBoardPage.Create(content, ui, options)
    local page = setmetatable({ content = content, ui = ui, options = options, tab = "relevant" }, Page)
    page:build()
    page:Refresh()
    return page
end

local function range(minLevel, maxLevel)
    if minLevel == nil or maxLevel == nil then
        return nil
    end
    return minLevel .. DASH .. maxLevel
end

local function join(parts)
    local kept = {}
    local index
    for index = 1, #parts do
        if parts[index] ~= nil and parts[index] ~= "" then
            table.insert(kept, parts[index])
        end
    end
    return table.concat(kept, DOT)
end

-- Building --------------------------------------------------------------------

function Page:build()
    local ui, content = self.ui, self.content
    local card = ui:Panel(content)
    card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    card:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    self.card = card
    self:buildSolo(card)
    self:buildView(card)
    self:buildEditor(card)

    local owner = self
    self.tabs = ui:Tabs(content, {
        { id = "relevant", label = "Relevant Parties" },
        { id = "other", label = "Other Parties" },
        { id = "history", label = "History" },
    }, function(id)
        owner.tab = id
        owner:refreshTab()
    end)
    self.area = ui:frame("Frame", content)
    self.area:SetPoint("TOPLEFT", self.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    self.area:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    self.emptyText = ui:Text(self.area, "", "regular", "body", "muted")
    self.emptyText:SetPoint("TOPLEFT", self.area, "TOPLEFT", 0, 0)
    self.moreText = ui:Text(self.area, "", "regular", "small", "label")
    self.smallCards = {}
end

function Page:buildSolo(card)
    local ui = self.ui
    local solo = ui:frame("Frame", card)
    solo:SetAllPoints(card)
    solo.text = ui:Text(solo, "You're not in a party", "semibold", "title", "text")
    solo.text:SetPoint("LEFT", solo, "LEFT", Theme.SPACING.l, 0)
    local owner = self
    self.startButton = ui:Button(solo, "Start a group", "primary", function()
        owner:StartEditing()
    end)
    self.startButton:SetWidth(120)
    self.startButton:SetPoint("RIGHT", solo, "RIGHT", -Theme.SPACING.l, 0)
    self.solo = solo
end

function Page:buildView(card)
    local ui = self.ui
    local view = ui:frame("Frame", card)
    view:SetAllPoints(card)
    local pad = Theme.SPACING.l
    view.label = ui:SectionLabel(view, "Your listing")
    view.label:SetPoint("TOPLEFT", view, "TOPLEFT", pad, -pad)
    view.purpose = ui:Text(view, "", "semibold", "heading", "text")
    view.purpose:SetPoint("TOPLEFT", view.label, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    view.details = ui:Text(view, "", "regular", "body", "muted")
    view.details:SetPoint("TOPLEFT", view.purpose, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    view.note = ui:Text(view, "", "italic", "small", "muted")
    view.note:SetPoint("TOPLEFT", view.details, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    local owner = self
    self.notLookingButton = ui:Button(view, "Not looking", "secondary", function()
        owner.options.onNotLooking()
        owner:Refresh()
    end)
    self.notLookingButton:SetWidth(100)
    self.notLookingButton:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -pad, pad)
    self.editButton = ui:Button(view, "Edit", "secondary", function()
        owner:StartEditing()
    end)
    self.editButton:SetWidth(70)
    self.editButton:SetPoint("RIGHT", self.notLookingButton, "LEFT", -Theme.SPACING.s, 0)
    view.tiles = self:roleTiles(view, 22)
    view.tiles[1]:SetPoint("TOPRIGHT", view, "TOPRIGHT", -pad - 4 * 26, -pad)
    self.view = view
end

-- A party's five role tiles in a row: Tank, Healer and three DPS.
function Page:roleTiles(parent, size)
    local tiles = {}
    local roles = { "tank", "healer", "dps", "dps", "dps" }
    local index
    for index = 1, #roles do
        tiles[index] = self.ui:RoleTile(parent, roles[index], size, size)
        tiles[index].label:SetText("")
        if index > 1 then
            tiles[index]:SetPoint("LEFT", tiles[index - 1], "RIGHT", 4, 0)
        end
    end
    return tiles
end

-- Shows `tiles` for a dungeon party's `members`: a member's role is
-- filled (grey), the rest open.
local function showRoles(tiles, members)
    local taken = {}
    local index
    for index = 1, #(members or {}) do
        local role = members[index].role
        if role ~= nil then
            taken[role] = (taken[role] or 0) + 1
        end
    end
    local seen = {}
    for index = 1, #tiles do
        local role = tiles[index].role
        seen[role] = (seen[role] or 0) + 1
        tiles[index]:SetFilled(seen[role] <= (taken[role] or 0))
        tiles[index]:Show()
    end
end

local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

local function hideAll(list)
    local index
    for index = 1, #list do
        list[index]:Hide()
    end
end

function Page:buildEditor(card)
    local ui = self.ui
    local pad = Theme.SPACING.l
    local editor = ui:frame("Frame", card)
    editor:SetAllPoints(card)
    local owner = self

    editor.kindLabel = ui:SectionLabel(editor, "What's it for?")
    editor.kindLabel:SetPoint("TOPLEFT", editor, "TOPLEFT", pad, -pad)
    self.kindSelector = ui:Segmented(editor, LfgBoardPage.KINDS, LfgBoardPage.FIELD_WIDTH, function(id)
        owner.draft.kind = id
        owner:refreshEditor()
    end)
    self.kindSelector:SetPoint("TOPLEFT", editor.kindLabel, "BOTTOMLEFT", 0, -Theme.SPACING.xs)

    -- The fields for each kind sit in one box under the choice.
    local fields = ui:frame("Frame", editor)
    fields:SetPoint("TOPLEFT", self.kindSelector, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    fields:SetSize(LfgBoardPage.FIELD_WIDTH, LfgBoardPage.DUNGEON_ROWS * LfgBoardPage.DUNGEON_ROW_HEIGHT
        + Widgets.INPUT_HEIGHT + Theme.SPACING.xs)
    editor.fields = fields

    self.search = ui:SearchBox(fields, LfgBoardPage.FIELD_WIDTH, "Search dungeons", function(text)
        owner.draft.search = text
        owner:refreshDungeons()
    end)
    self.search:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, 0)
    self.dungeonRows = {}
    local index
    for index = 1, LfgBoardPage.DUNGEON_ROWS do
        local row = ui:frame("Button", fields)
        row:SetHeight(LfgBoardPage.DUNGEON_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", self.search, "BOTTOMLEFT", 0,
            -Theme.SPACING.xs - (index - 1) * LfgBoardPage.DUNGEON_ROW_HEIGHT)
        row:SetPoint("RIGHT", self.search, "RIGHT", 0, 0)
        ui:Round(row, Theme.RADIUS.small, "surface", false)
        row.label = ui:Text(row, "", "regular", "body", "text")
        row.label:SetPoint("LEFT", row, "LEFT", Theme.SPACING.s, 0)
        row.range = ui:Text(row, "", "regular", "small", "muted")
        row.range:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.s, 0)
        row:SetScript("OnClick", function(self)
            if self.dungeon ~= nil then
                owner.draft.dungeon = self.dungeon
                owner:refreshDungeons()
            end
        end)
        self.dungeonRows[index] = row
    end

    editor.questing = ui:Text(fields, "", "regular", "body", "text")
    editor.questing:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, 0)
    editor.raid = ui:Text(fields, LfgBoardPage.RAID_EXPLANATION, "regular", "body", "muted")
    editor.raid:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, 0)
    editor.raid:SetWidth(LfgBoardPage.FIELD_WIDTH)
    self.otherText = ui:TextInput(fields, LfgBoardPage.FIELD_WIDTH, addon.LfgListing.PURPOSE_LETTERS, function(text)
        owner.draft.text = text
    end)
    self.otherText:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, 0)

    -- The note, the error line and the buttons sit on the right.
    editor.noteLabel = ui:SectionLabel(editor, "Note")
    editor.noteLabel:SetPoint("TOPLEFT", editor, "TOP", 0, -pad)
    self.note = ui:TextInput(editor, LfgBoardPage.FIELD_WIDTH, addon.LfgListing.NOTE_LETTERS, function(text)
        owner.draft.note = text
    end)
    self.note:SetPoint("TOPLEFT", editor.noteLabel, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    self.errorText = ui:Text(editor, "", "regular", "small", "orange")
    self.errorText:SetPoint("TOPLEFT", self.note, "BOTTOMLEFT", 0, -Theme.SPACING.s)

    self.cancelButton = ui:Button(editor, "Cancel", "secondary", function()
        owner.editing = false
        owner:Refresh()
    end)
    self.cancelButton:SetWidth(80)
    self.cancelButton:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", -pad, pad)
    self.saveButton = ui:Button(editor, "Save", "primary", function()
        owner:Save()
    end)
    self.saveButton:SetWidth(80)
    self.saveButton:SetPoint("RIGHT", self.cancelButton, "LEFT", -Theme.SPACING.s, 0)
    self.editor = editor
end

-- The player's own card -------------------------------------------------------

-- Opens the inline editor, filled from the listing when there is one.
function Page:StartEditing()
    local listing = self.options.listing
    local purpose = listing:IsActive() and listing:Purpose() or nil
    self.draft = {
        kind = purpose and purpose.kind or "dungeon",
        dungeon = purpose and purpose.dungeon or nil,
        text = purpose and purpose.text or "",
        note = listing:IsActive() and listing:Note() or "",
        search = "",
    }
    self.editing = true
    self.search:SetValue("")
    self.otherText:SetValue(self.draft.text)
    self.note:SetValue(self.draft.note)
    self.errorText:SetText("")
    self:Refresh()
end

-- The draft as a purpose to save.
function Page:draftPurpose()
    local draft = self.draft
    if draft.kind == "dungeon" then
        return { kind = "dungeon", dungeon = draft.dungeon }
    elseif draft.kind == "questing" then
        return { kind = "questing", zone = self.options.zone() }
    elseif draft.kind == "other" then
        return { kind = "other", text = draft.text }
    end
    return { kind = draft.kind }
end

-- Saves the draft: the listing starts, or changes. A draft that can't be
-- saved says why and stays open.
function Page:Save()
    local saved, reason = self.options.onSave(self:draftPurpose(), self.draft.note)
    if not saved then
        self.errorText:SetText("Can't save: " .. tostring(reason) .. ".")
        return false
    end
    self.editing = false
    self:Refresh()
    return true
end

-- Which way the card shows: "solo", "view" or "edit".
function Page:Mode()
    if self.editing then
        return "edit"
    end
    return self.options.listing:IsActive() and "view" or "solo"
end

function Page:refreshCard()
    local mode = self:Mode()
    local heights = { solo = LfgBoardPage.SOLO_HEIGHT, view = LfgBoardPage.VIEW_HEIGHT,
        edit = LfgBoardPage.EDIT_HEIGHT }
    self.card:SetHeight(heights[mode])
    setShown(self.solo, mode == "solo")
    setShown(self.view, mode == "view")
    setShown(self.editor, mode == "edit")
    self.tabs:ClearAllPoints()
    self.tabs:SetPoint("TOPLEFT", self.card, "BOTTOMLEFT", 0, -Theme.SPACING.l)
    self.tabs:SetPoint("RIGHT", self.content, "RIGHT", 0, 0)
    if mode == "view" then
        self:refreshView()
    elseif mode == "edit" then
        self:refreshEditor()
    end
end

function Page:refreshView()
    local listing, view = self.options.listing, self.view
    local purpose = listing:Purpose()
    local members = self.options.members()
    local fields = listing:Announcement(members)
    view.purpose:SetText(addon.LfgListing.Label(fields.k, fields.p))
    view.details:SetText(join({ addon.LfgListing.KindLabel(fields.k), range(fields.lo, fields.hi),
        fields.s .. "/" .. fields.x }))
    view.note:SetText(listing:Note() or "")
    if purpose.kind == "dungeon" then
        showRoles(view.tiles, members)
    else
        hideAll(view.tiles)
    end
end

function Page:refreshEditor()
    local draft, editor = self.draft, self.editor
    self.kindSelector:Select(draft.kind)
    local dungeon = draft.kind == "dungeon"
    setShown(self.search, dungeon)
    if dungeon then
        self:refreshDungeons()
    else
        hideAll(self.dungeonRows)
    end
    local zone = self.options.zone()
    editor.questing:SetText(zone and ("Questing in " .. zone) or "Your zone isn't known yet.")
    setShown(editor.questing, draft.kind == "questing")
    setShown(editor.raid, draft.kind == "raid")
    setShown(self.otherText, draft.kind == "other")
end

-- The dungeon list: what the search finds, those that fit the player's
-- level first, then the rest under "Other levels".
function Page:refreshDungeons()
    local fitting, others = self.options.catalog():Search(self.draft.search, self.options.level())
    local entries = {}
    local index
    for index = 1, #fitting do
        table.insert(entries, fitting[index])
    end
    if #others > 0 then
        table.insert(entries, { header = "Other levels" })
        for index = 1, #others do
            table.insert(entries, others[index])
        end
    end
    self.dungeonEntries = entries
    local chosen = self.draft.dungeon
    for index = 1, #self.dungeonRows do
        local row, entry = self.dungeonRows[index], entries[index]
        if entry == nil then
            row.dungeon = nil
            row:Hide()
        elseif entry.header ~= nil then
            row.dungeon = nil
            row.label:SetText(Theme.Label(entry.header))
            row.label:SetTextColor(Theme.Color("label"))
            row.range:SetText("")
            row:SetFill("surface")
            row:Show()
        else
            row.dungeon = entry
            row.label:SetText(entry.name)
            row.label:SetTextColor(Theme.Color("text"))
            row.range:SetText(range(entry.minLevel, entry.maxLevel))
            row:SetFill(chosen ~= nil and chosen.id == entry.id and "green" or "surface")
            row:Show()
        end
    end
end

-- The tabs ----------------------------------------------------------------------

-- A small card for a guildmate's listing, made on first use: the purpose,
-- then the type, levels, leader and size in small text, with role tiles on
-- the right for a dungeon.
function Page:smallCard(index)
    local card = self.smallCards[index]
    if card ~= nil then
        return card
    end
    local ui = self.ui
    card = ui:Panel(self.area)
    card:SetHeight(LfgBoardPage.SMALL_CARD_HEIGHT)
    local row = math.floor((index - 1) / 2)
    local top = -row * (LfgBoardPage.SMALL_CARD_HEIGHT + Theme.SPACING.s)
    if index % 2 == 1 then
        card:SetPoint("TOPLEFT", self.area, "TOPLEFT", 0, top)
        card:SetPoint("RIGHT", self.area, "CENTER", -Theme.SPACING.xs, 0)
    else
        card:SetPoint("TOPLEFT", self.area, "TOP", Theme.SPACING.xs, top)
        card:SetPoint("RIGHT", self.area, "RIGHT", 0, 0)
    end
    card.purpose = ui:Text(card, "", "semibold", "body", "muted")
    card.purpose:SetPoint("TOPLEFT", card, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    card.details = ui:Text(card, "", "regular", "small", "label")
    card.details:SetPoint("TOPLEFT", card.purpose, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    card.tiles = self:roleTiles(card, 12)
    card.tiles[1]:SetPoint("RIGHT", card, "RIGHT", -Theme.SPACING.m - 4 * 16, 0)
    self.smallCards[index] = card
    return card
end

local function details(listing)
    local where = range(listing.minLevel, listing.maxLevel)
    local size = listing.kind == "raid" and (listing.size .. " players") or (listing.size .. "/" .. listing.maxSize)
    return join({ addon.LfgListing.KindLabel(listing.kind), where, listing.leader, size })
end

-- What tab `id` lists: for now every listing is on Other Parties.
function Page:tabListings(id, listings)
    if id == "other" then
        return listings
    end
    return {}
end

function Page:refreshTab()
    local listings = self.options.listings() or {}
    self.tabs:SetLabel("relevant", "Relevant Parties" .. DOT .. #self:tabListings("relevant", listings))
    self.tabs:SetLabel("other", "Other Parties" .. DOT .. #self:tabListings("other", listings))
    self.tabs:Select(self.tab)
    local shown = self.tab == "history" and {} or self:tabListings(self.tab, listings)
    self.shownListings = shown
    if #shown == 0 then
        self.emptyText:SetText(LfgBoardPage.EMPTY[self.tab])
        self.emptyText:Show()
    else
        self.emptyText:Hide()
    end
    -- The editor is tall: fewer cards fit under it.
    local limit = self:Mode() == "edit" and LfgBoardPage.EDIT_SMALL_CARDS or LfgBoardPage.SMALL_CARDS
    local index
    for index = 1, math.max(#self.smallCards, math.min(#shown, limit)) do
        local listing = index <= limit and shown[index] or nil
        if listing == nil then
            if self.smallCards[index] ~= nil then
                self.smallCards[index]:Hide()
            end
        else
            local card = self:smallCard(index)
            card.listing = listing
            card.purpose:SetText(addon.LfgListing.Label(listing.kind, listing.purpose))
            card.details:SetText(details(listing))
            if listing.kind == "dungeon" then
                showRoles(card.tiles, listing.members)
            else
                hideAll(card.tiles)
            end
            card:Show()
        end
    end
    local more = #shown - limit
    if more > 0 then
        local rows = math.ceil(limit / 2)
        self.moreText:ClearAllPoints()
        self.moreText:SetPoint("TOPLEFT", self.area, "TOPLEFT", 0,
            -rows * (LfgBoardPage.SMALL_CARD_HEIGHT + Theme.SPACING.s))
        self.moreText:SetText("and " .. more .. " more")
        self.moreText:Show()
    else
        self.moreText:Hide()
    end
end

-- Redraws the card and the tabs from what the options say now.
function Page:Refresh()
    self:refreshCard()
    self:refreshTab()
end
