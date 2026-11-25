local _, addon = ...

-- The Guild LFG Board page in the AGF window. At the top is the card for
-- the player's own party: "You're not in a party" with Start a group when
-- they aren't listed, their listing in view mode (Edit, Ask in guild, Not
-- looking) when
-- they are, and an inline editor (What's it for?, the kind's fields, Roles
-- in your party, the note, Save and Cancel) while editing. In someone
-- else's party it shows that party's listing, read-only; only the leader
-- lists a party. Below it are the tabs:
--   Relevant Parties  large gold-bordered cards for groups the current
--                     character could join, two per row, then small cards
--                     under "Your alts could join", with a Nearby card on
--                     the right listing guildmates in the player's zone
--   Other Parties     small greyed cards for the rest
--   History           the player's own recent parties (LfgHistoryView),
--                     newest first, 20 at a time with Show more
-- An empty tab shows one line.
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
    LARGE_CARD_HEIGHT = 196,
    -- The members a large card lists; more are counted.
    CARD_MEMBERS = 5,
    -- The guildmates a History party lists; more are counted.
    HISTORY_MEMBERS = 8,
    HISTORY_MEMBER_HEIGHT = 20,
    MEMBER_HEIGHT = 14,
    -- The Nearby card on the right of Relevant Parties: its width, and the
    -- names it lists (more are counted).
    NEARBY_WIDTH = 160,
    NEARBY_ROWS = 20,
    NEARBY_ROW_HEIGHT = 18,
    -- Other Parties' cards are faded to this.
    GREYED_ALPHA = 0.5,
    -- The tab list's width until the window lays it out.
    LIST_WIDTH = 688,
    SCROLL_STEP = 40,
    -- The most rows the dungeon list shows, its "Other levels" line
    -- included.
    DUNGEON_ROWS = 7,
    DUNGEON_ROW_HEIGHT = 20,
    -- Roles in your party: one row per member.
    ROLE_ROWS = 5,
    ROLE_ROW_HEIGHT = 24,
    ROLE_BUTTON_WIDTH = 56,
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
--   groups        function() -> the board's listings sorted for the player
--                 (LfgBoard:Groups: relevant, alts, other)
--   nearby        function() -> { zone, people = { { name, whisper,
--                 classToken? } } } of guildmates in the player's zone, or
--                 nil
--   classColor    function(classToken) -> "ffrrggbb" or nil
--   friendTier    function(name) -> the guildmate's GroupFriends tier, or nil
-- Every name shown (a card's members, Nearby, History) opens a menu: the
-- name, then Whisper.
--   history       function() -> the player's GroupHistory entries
--   historyMember function(key) -> a guildmate's { name, whisper,
--                 classToken? }, or nil
--   keyTier       function(key) -> a guildmate's GroupFriends tier, or nil
--   formatDate    function(at) -> the date it shows for a party
--   dungeonIcon   function(name) -> the game's icon for the dungeon, or nil
--   onWhisper     function(name): whispers someone
--   requestOf     function(id) -> the player's request to join leader
--                 `id`'s listing (LfgBoard:Request), or nil
--   askRoles      function(listing) -> the open roles the current
--                 character can ask to join a dungeon listing as
--   onAsk         function(listing, role?): Ask to join, as the current
--                 character
--   party         function() -> { inParty, isLeader, listing? (the party's
--                 listing on the board, when someone else leads it) }
--   partyRoles    function() -> the members for Roles in your party, each
--                 { key, name, role, assigned (by the game), canPlay =
--                 { tank, healer, dps } }
--   onSave        function(purpose, note, roles) -> true, or false and why
--                 not; `roles` are the members' roles the leader chose, by
--                 key, applied only when it saves
--   onAskInGuild  function(line): types `line` into guild chat, unsent
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

-- `parts` joined with dots, leaving out the empty ones. Its holes (nil
-- parts) make #parts unreliable, so it runs to the highest index.
local function join(parts)
    local last = 0
    local key
    for key in pairs(parts) do
        if type(key) == "number" and key > last then
            last = key
        end
    end
    local kept = {}
    local index
    for index = 1, last do
        if parts[index] ~= nil and parts[index] ~= "" then
            table.insert(kept, parts[index])
        end
    end
    return table.concat(kept, DOT)
end

-- `name` in its class color, where `color` ("ffrrggbb") is known.
local function colored(name, color)
    if type(color) ~= "string" then
        return name
    end
    return "|c" .. color .. name .. "|r"
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
        owner:ShowTab(id)
    end)
    self:buildList()
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
    -- Types a line into guild chat for guildmates without the add-on; the
    -- player sends it, or doesn't.
    self.askGuildButton = ui:Button(view, "Ask in guild", "secondary", function()
        local line = addon.LfgListing.GuildLine(owner.options.listing:Announcement(owner.options.members()))
        if line ~= nil and owner.options.onAskInGuild ~= nil then
            owner.options.onAskInGuild(line)
        end
    end)
    self.askGuildButton:SetWidth(100)
    self.askGuildButton:SetPoint("RIGHT", self.editButton, "LEFT", -Theme.SPACING.s, 0)
    view.tiles = self:roleTiles(view, 22)
    view.tiles[1]:SetPoint("TOPRIGHT", view, "TOPRIGHT", -pad - 4 * 26, -pad)
    self.view = view
end

-- A party's five role tiles in a row: Tank, Healer and three DPS.
function Page:roleTiles(parent, size)
    return self.ui:RoleRow(parent, size)
end

local showRoles = Widgets.ShowRoles

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
        owner.draft.offset = 0
        owner:refreshDungeons()
    end)
    -- The mouse wheel scrolls the dungeon list past its first rows.
    fields:EnableMouseWheel(true)
    fields:SetScript("OnMouseWheel", function(_, delta)
        if owner.draft ~= nil and owner.draft.kind == "dungeon" then
            owner.draft.offset = (owner.draft.offset or 0) - delta
            owner:refreshDungeons()
        end
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

    -- Roles in your party (dungeons): Tank, Healer or DPS for each member,
    -- the roles their class can't play greyed out. A role the game assigned
    -- can't be changed here.
    editor.rolesLabel = ui:SectionLabel(editor, "Roles in your party")
    editor.rolesLabel:SetPoint("TOPLEFT", self.note, "BOTTOMLEFT", 0, -28)
    self.roleRows = {}
    local row
    for row = 1, LfgBoardPage.ROLE_ROWS do
        local line = ui:frame("Frame", editor)
        line:SetSize(LfgBoardPage.FIELD_WIDTH, LfgBoardPage.ROLE_ROW_HEIGHT)
        line:SetPoint("TOPLEFT", editor.rolesLabel, "BOTTOMLEFT", 0,
            -Theme.SPACING.xs - (row - 1) * LfgBoardPage.ROLE_ROW_HEIGHT)
        line.name = ui:Text(line, "", "regular", "body", "text")
        line.name:SetPoint("LEFT", line, "LEFT", 0, 0)
        line.buttons = {}
        local roles = { "tank", "healer", "dps" }
        local position
        for position = 1, #roles do
            local choice = ui:frame("Button", line)
            choice:SetSize(LfgBoardPage.ROLE_BUTTON_WIDTH, LfgBoardPage.ROLE_ROW_HEIGHT - 4)
            choice:SetPoint("RIGHT", line, "RIGHT",
                -(#roles - position) * (LfgBoardPage.ROLE_BUTTON_WIDTH + Theme.SPACING.xs), 0)
            ui:Round(choice, Theme.RADIUS.small, "raised", "border")
            choice.role = roles[position]
            choice.label = ui:Text(choice, Widgets.ROLE_LABELS[roles[position]], "semibold", "small", "text")
            choice.label:SetPoint("CENTER", choice, "CENTER", 0, 0)
            -- Kept in the draft until Save; Cancel drops it.
            choice:SetScript("OnClick", function(self)
                if self.enabled and line.key then
                    owner.draft.roles[line.key] = self.role
                    owner:refreshRoles()
                end
            end)
            line.buttons[position] = choice
        end
        self.roleRows[row] = line
    end

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
        offset = 0,
        -- Members' roles chosen in the editor, by key.
        roles = {},
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
    local saved, reason = self.options.onSave(self:draftPurpose(), self.draft.note, self.draft.roles)
    if not saved then
        self.errorText:SetText("Can't save: " .. tostring(reason) .. ".")
        return false
    end
    self.editing = false
    self:Refresh()
    return true
end

-- The player's party as the options say, or a solo player's.
function Page:party()
    local party = self.options.party and self.options.party() or nil
    return party or { inParty = false, isLeader = true, members = {} }
end

-- Which way the card shows: "solo" (nothing listed), "view" (the player's
-- listing, editable), "member" (the party's listing, read-only, in someone
-- else's party) or "edit".
function Page:Mode()
    if self.editing then
        return "edit"
    end
    if self.options.listing:IsActive() then
        return "view"
    end
    local party = self:party()
    if party.inParty and not party.isLeader and party.listing ~= nil then
        return "member"
    end
    return "solo"
end

function Page:refreshCard()
    local mode = self:Mode()
    local heights = { solo = LfgBoardPage.SOLO_HEIGHT, view = LfgBoardPage.VIEW_HEIGHT,
        member = LfgBoardPage.VIEW_HEIGHT, edit = LfgBoardPage.EDIT_HEIGHT }
    self.card:SetHeight(heights[mode])
    setShown(self.solo, mode == "solo")
    setShown(self.view, mode == "view" or mode == "member")
    setShown(self.editor, mode == "edit")
    self.tabs:ClearAllPoints()
    self.tabs:SetPoint("TOPLEFT", self.card, "BOTTOMLEFT", 0, -Theme.SPACING.l)
    self.tabs:SetPoint("RIGHT", self.content, "RIGHT", 0, 0)
    if mode == "solo" then
        -- In a party it isn't listed; only its leader can list it.
        local party = self:party()
        self.solo.text:SetText(party.inParty and "Your party isn't listed" or "You're not in a party")
        self.startButton:SetLabel(party.inParty and "List your party" or "Start a group")
        setShown(self.startButton, not party.inParty or party.isLeader)
    elseif mode == "view" then
        self:refreshView()
    elseif mode == "member" then
        self:refreshMemberView()
    elseif mode == "edit" then
        self:refreshEditor()
    end
end

function Page:refreshView()
    local listing, view = self.options.listing, self.view
    local purpose = listing:Purpose()
    local members = self.options.members()
    local fields = listing:Announcement(members)
    view.label:SetText(Theme.Label("Your listing"))
    view.purpose:SetText(addon.LfgListing.Label(fields.k, fields.p))
    view.details:SetText(join({ addon.LfgListing.KindLabel(fields.k), range(fields.lo, fields.hi),
        fields.k == "raid" and (fields.s .. " players") or (fields.s .. "/" .. fields.x) }))
    view.note:SetText(listing:Note() or "")
    if purpose.kind == "dungeon" then
        -- As the guild sees it: the roster announced (the party as it was,
        -- until an open slot's posted) and the roles asked for.
        local announced = {}
        local index
        for index = 1, #fields.mb do
            announced[index] = { role = fields.mb[index].r }
        end
        showRoles(view.tiles, announced, fields.r)
    else
        hideAll(view.tiles)
    end
    self.editButton:Show()
    self.notLookingButton:Show()
    self.askGuildButton:Show()
    self.askGuildButton:SetActive(addon.LfgListing.GuildLine(fields) ~= nil)
end

-- In someone else's party: its listing as the guild sees it, read-only.
function Page:refreshMemberView()
    local listing, view = self:party().listing, self.view
    view.label:SetText(Theme.Label("Your party's listing"))
    view.purpose:SetText(addon.LfgListing.Label(listing.kind, listing.purpose))
    view.details:SetText(join({ addon.LfgListing.KindLabel(listing.kind), range(listing.minLevel, listing.maxLevel),
        listing.kind == "raid" and (listing.size .. " players") or (listing.size .. "/" .. listing.maxSize),
        (listing.contact and "contact " or "led by ") .. listing.leader }))
    view.note:SetText(listing.note or "")
    if listing.kind == "dungeon" then
        showRoles(view.tiles, listing.members, listing.openRoles)
    else
        hideAll(view.tiles)
    end
    self.editButton:Hide()
    self.notLookingButton:Hide()
    self.askGuildButton:Hide()
end

-- Roles in your party: each member's role, and the ones they could play.
function Page:refreshRoles()
    local members = self.draft.kind == "dungeon" and (self.options.partyRoles and self.options.partyRoles()) or {}
    setShown(self.editor.rolesLabel, #members > 0)
    local index
    for index = 1, #self.roleRows do
        local line, member = self.roleRows[index], members[index]
        if member == nil then
            line.key = false
            line:Hide()
        else
            line.key = member.key
            line.name:SetText(member.name)
            local position
            for position = 1, #line.buttons do
                local choice = line.buttons[position]
                local playable = member.canPlay[choice.role] == true
                choice.enabled = playable and not member.assigned
                local role = member.role
                if not member.assigned and self.draft.roles[member.key] ~= nil then
                    role = self.draft.roles[member.key]
                end
                choice.selected = role == choice.role
                choice:SetFill(choice.selected and "green" or "raised")
                choice.label:SetTextColor(Theme.Color(playable and "text" or "disabled"))
            end
            line:Show()
        end
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
    self:refreshRoles()
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
    -- Scrolled by the wheel, never past the last full view.
    local offset = math.max(0, math.min(self.draft.offset or 0, #entries - #self.dungeonRows))
    self.draft.offset = offset
    local chosen = self.draft.dungeon
    for index = 1, #self.dungeonRows do
        local row, entry = self.dungeonRows[index], entries[index + offset]
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

-- The tabs' contents scroll: what's shown is laid out top to bottom on one
-- list frame inside a scroll frame, scrolled with the mouse wheel.
function Page:buildList()
    local ui, content = self.ui, self.content
    local area = ui:frame("ScrollFrame", content)
    area:SetPoint("TOPLEFT", self.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    area:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    local list = ui:frame("Frame", area)
    list:SetSize(LfgBoardPage.LIST_WIDTH, 1)
    area:SetScrollChild(list)
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(self, delta)
        local most = self:GetVerticalScrollRange() or 0
        local scroll = (self:GetVerticalScroll() or 0) - delta * LfgBoardPage.SCROLL_STEP
        self:SetVerticalScroll(math.max(0, math.min(most, scroll)))
    end)
    area:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            list:SetWidth(width)
        end
    end)
    self.area, self.list = area, list
    -- Where the cards go: the list's width, less the Nearby card's when it
    -- shows.
    self.cards = ui:frame("Frame", list)
    self.emptyText = ui:Text(list, "", "regular", "body", "muted")
    self.altsLabel = ui:SectionLabel(list, "Your alts could join")
    self:buildNearby()
    self.largeCards, self.smallCards = {}, {}
    self.historyRows = {}
    self.historyView = addon.LfgHistoryView.Create()
    local owner = self
    self.moreButton = ui:Button(list, "Show more", "secondary", function()
        owner.historyView:More()
        owner:refreshTab()
    end)
    self.moreButton:SetWidth(120)
    self.moreButton:Hide()
end

-- The Nearby card: "Nearby in <zone>", then the guildmates there one per
-- line, in class color, each name opening the name menu.
function Page:buildNearby()
    local ui, pad = self.ui, Theme.SPACING.m
    local card = ui:Panel(self.list)
    card:SetWidth(LfgBoardPage.NEARBY_WIDTH)
    card.title = ui:SectionLabel(card, "")
    card.title:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
    card.title:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
    card.title:SetJustifyH("LEFT")
    card.title:SetWordWrap(false)
    card.rows = {}
    card.more = ui:Text(card, "", "regular", "small", "label")
    card:Hide()
    self.nearbyCard = card
end

-- Shows the Nearby card for `nearby` ({ zone, people }) at the list's top
-- right. Returns its height.
function Page:showNearby(nearby)
    local card, pad = self.nearbyCard, Theme.SPACING.m
    local options = self.options
    card.title:SetText(Theme.Label("Nearby in " .. nearby.zone))
    local top = pad + 16 + Theme.SPACING.xs
    local shown = math.min(#nearby.people, LfgBoardPage.NEARBY_ROWS)
    local index
    for index = 1, math.max(shown, #card.rows) do
        local row = card.rows[index]
        if index <= shown then
            if row == nil then
                row = self:nameButton(card, LfgBoardPage.NEARBY_ROW_HEIGHT)
                row:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -top - (index - 1) * LfgBoardPage.NEARBY_ROW_HEIGHT)
                row:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
                card.rows[index] = row
            end
            local person = nearby.people[index]
            self:showName(row, { text = colored(person.name, options.classColor(person.classToken)),
                whisper = person.whisper })
        else
            row:Hide()
        end
    end
    local more = #nearby.people - shown
    card.more:ClearAllPoints()
    card.more:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -top - shown * LfgBoardPage.NEARBY_ROW_HEIGHT)
    card.more:SetText(more > 0 and ("and " .. more .. " more") or "")
    local height = top + shown * LfgBoardPage.NEARBY_ROW_HEIGHT + (more > 0 and 16 or 0) + pad
    card:SetHeight(height)
    card:ClearAllPoints()
    card:SetPoint("TOPRIGHT", self.list, "TOPRIGHT", 0, 0)
    card:Show()
    return height
end

-- Lets the cards use the list's whole width, or leaves `inset` on the
-- right (for the Nearby card).
function Page:inset(inset)
    self.cards:ClearAllPoints()
    self.cards:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, 0)
    self.cards:SetPoint("BOTTOMRIGHT", self.list, "BOTTOMRIGHT", -(inset or 0), 0)
end

-- Places `frame` at height `top` of the cards' area: across its whole
-- width, or in the left or right `column` of two.
function Page:place(frame, top, column)
    local area = self.cards
    frame:ClearAllPoints()
    if column == "right" then
        frame:SetPoint("TOPLEFT", area, "TOP", Theme.SPACING.xs, -top)
        frame:SetPoint("RIGHT", area, "RIGHT", 0, 0)
    elseif column == "left" then
        frame:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -top)
        frame:SetPoint("RIGHT", area, "CENTER", -Theme.SPACING.xs, 0)
    else
        frame:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -top)
    end
end

-- A name that opens the name menu when clicked, `height` tall, with room
-- for a role icon on its left and a crown (the leader) and star (a top
-- group friend) after it. Shown with showName; placed by its owner.
function Page:nameButton(parent, height)
    local ui, owner = self.ui, self
    local line = ui:frame("Button", parent)
    line:SetHeight(height)
    line.roleIcon = line:CreateTexture(nil, "ARTWORK")
    line.roleIcon:SetSize(12, 12)
    line.roleIcon:SetPoint("LEFT", line, "LEFT", 0, 0)
    line.name = ui:Text(line, "", "regular", "body", "text")
    line.crown = line:CreateTexture(nil, "ARTWORK")
    line.crown:SetTexture(Theme.TEXTURES.crown)
    line.crown:SetVertexColor(Theme.Color("gold"))
    line.crown:SetSize(10, 10)
    line.crown:SetPoint("LEFT", line.name, "RIGHT", 4, 0)
    line.star = line:CreateTexture(nil, "ARTWORK")
    line.star:SetTexture(Theme.TEXTURES.star)
    line.star:SetVertexColor(Theme.Color("gold"))
    line.star:SetSize(10, 10)
    line:SetScript("OnClick", function(self)
        owner:nameMenu(self)
    end)
    return line
end

-- Shows name button `line` for `fields`: text (the name, maybe in class
-- color), whisper (whom Whisper whispers), role (its icon, in the role's
-- color), leader (the crown) and top (the star).
function Page:showName(line, fields)
    local role = fields.role
    line.role = role
    line.name:ClearAllPoints()
    if role ~= nil and Widgets.ROLE_ICONS[role] ~= nil then
        line.roleIcon:SetTexture(Theme.TEXTURES[Widgets.ROLE_ICONS[role]])
        line.roleIcon:SetVertexColor(Theme.Color(role))
        line.roleIcon:Show()
        line.name:SetPoint("LEFT", line.roleIcon, "RIGHT", 4, 0)
    else
        line.roleIcon:Hide()
        line.name:SetPoint("LEFT", line, "LEFT", 0, 0)
    end
    line.name:SetText(fields.text)
    line.title = fields.text
    line.whisper = fields.whisper or false
    setShown(line.crown, fields.leader == true)
    line.star:ClearAllPoints()
    line.star:SetPoint("LEFT", fields.leader and line.crown or line.name, "RIGHT", 4, 0)
    line.topFriend = fields.top == true
    setShown(line.star, line.topFriend)
    line:Show()
end

-- The menu a name opens, under it: the name over a line, then Whisper. A
-- second click on the same name closes it.
function Page:nameMenu(anchor)
    self.namesMenu = self.namesMenu or self.ui:ContextMenu(self.content)
    local menu = self.namesMenu
    if menu:IsOpen() and self.nameMenuFor ~= nil and self.nameMenuFor.anchor == anchor then
        menu:Close()
        self.nameMenuFor = nil
        return
    end
    local owner, whisper = self, anchor.whisper
    self.nameMenuFor = { anchor = anchor, title = anchor.title, whisper = whisper }
    menu:Open(anchor, {
        { label = "Whisper", onClick = function()
            owner.nameMenuFor = nil
            if whisper then
                owner.options.onWhisper(whisper)
            end
        end },
    }, anchor.title)
end

-- Shows `tiles` (5 person tiles) with the first `size` filled.
local function showSize(tiles, size)
    local index
    for index = 1, #tiles do
        tiles[index]:SetFilled(index <= (size or 0))
        tiles[index]:Show()
    end
end

-- Shows the tiles that fit `listing`'s kind from `card`'s role and person
-- tiles, and the player count for a raid.
local function showTiles(card, listing)
    hideAll(card.roleTiles)
    hideAll(card.anyTiles)
    card.raidTile:Hide()
    card.count:SetText("")
    if listing.kind == "dungeon" then
        -- Open tiles are the roles asked for, the same ones Ask to join
        -- offers.
        showRoles(card.roleTiles, listing.members, listing.openRoles)
    elseif listing.kind == "raid" then
        card.raidTile:SetFilled(not addon.LfgRelevance.HasRoom(listing))
        card.raidTile:Show()
        card.count:SetText(listing.size .. " players")
    else
        showSize(card.anyTiles, listing.size)
    end
end

local function sizeText(listing)
    if listing.kind == "raid" then
        return listing.size .. " players"
    end
    return listing.size .. "/" .. listing.maxSize
end

-- What a dungeon listing still needs, as its open roles ("needs Healer,
-- DPS"); nil for other kinds, or when it needs nobody.
local function needsText(listing)
    if listing.kind ~= "dungeon" then
        return nil
    end
    local names = {}
    local index
    for index = 1, #(listing.openRoles or {}) do
        names[index] = Widgets.ROLE_LABELS[listing.openRoles[index]] or listing.openRoles[index]
    end
    return #names > 0 and ("needs " .. table.concat(names, ", ")) or nil
end

-- A large card, made on first use: the purpose with its icon, then its
-- type, levels, size and what it needs; the members, each with their
-- role's icon (a dungeon's), the leader crowned and top group friends
-- starred, every name opening the name menu; the note; and Ask to join and
-- Whisper <leader> side by side.
function Page:largeCard(index)
    local card = self.largeCards[index]
    if card ~= nil then
        return card
    end
    local ui, pad = self.ui, Theme.SPACING.m
    card = ui:Panel(self.list, { border = "gold" })
    card:SetHeight(LfgBoardPage.LARGE_CARD_HEIGHT)
    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(32, 32)
    card.icon:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
    card.purpose = ui:Text(card, "", "semibold", "title", "text")
    card.details = ui:Text(card, "", "regular", "small", "muted")
    card.details:SetPoint("TOPLEFT", card.purpose, "BOTTOMLEFT", 0, -2)
    local owner = self
    card.members = {}
    local row
    for row = 1, LfgBoardPage.CARD_MEMBERS do
        local line = self:nameButton(card, LfgBoardPage.MEMBER_HEIGHT)
        line:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -54 - (row - 1) * LfgBoardPage.MEMBER_HEIGHT)
        line:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
        card.members[row] = line
    end
    card.more = ui:Text(card, "", "regular", "small", "label")
    card.more:SetPoint("TOPLEFT", card, "TOPLEFT", pad,
        -54 - LfgBoardPage.CARD_MEMBERS * LfgBoardPage.MEMBER_HEIGHT)
    card.note = ui:Text(card, "", "italic", "small", "muted")
    card.note:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", pad, pad + Widgets.BUTTON_HEIGHT + Theme.SPACING.s)
    -- Ask to join and Whisper <leader> share the bottom; a leader who
    -- takes no asks (not in the guild, or their LFG button hidden) has
    -- Whisper alone.
    card.ask = ui:Button(card, "Ask to join", "primary", function(button)
        owner:ask(button, card.listing, card)
    end)
    card.ask:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", pad, pad)
    card.ask:SetPoint("BOTTOMRIGHT", card, "BOTTOM", -Theme.SPACING.xs, pad)
    card.whisper = ui:Button(card, "Whisper", "secondary", function(button)
        owner.options.onWhisper(button.target)
    end)
    self.largeCards[index] = card
    return card
end

function Page:showLarge(card, listing)
    local options, pad = self.options, Theme.SPACING.m
    local icon = listing.kind == "dungeon" and (options.dungeonIcon(listing.purpose) or Theme.TEXTURES.dungeon)
        or nil
    card.purpose:ClearAllPoints()
    card.iconTexture = icon or false
    if icon ~= nil then
        card.icon:SetTexture(icon)
        card.icon:Show()
        card.purpose:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", Theme.SPACING.s, 0)
    else
        card.icon:Hide()
        card.purpose:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
    end
    card.listing = listing
    card.purpose:SetText(addon.LfgListing.Label(listing.kind, listing.purpose))
    -- A party led from outside the guild names its contact.
    card.details:SetText(join({ addon.LfgListing.KindLabel(listing.kind), range(listing.minLevel, listing.maxLevel),
        sizeText(listing), needsText(listing), listing.contact and ("contact " .. listing.leader) or nil }))
    local row
    for row = 1, #card.members do
        local line, member = card.members[row], listing.members[row]
        if member == nil then
            line:Hide()
        else
            local leader = row == 1
            self:showName(line, {
                text = colored(member.name, options.classColor(member.classToken)),
                -- The leader by the name they listed from, unless they're
                -- outside the guild and the contact speaks for the party.
                whisper = leader and not listing.contact and listing.sender or member.name,
                role = listing.kind == "dungeon" and member.role or nil,
                leader = leader,
                top = options.friendTier(member.name) == addon.GroupFriends.TOP,
            })
        end
    end
    local more = #listing.members - #card.members
    card.more:SetText(more > 0 and ("and " .. more .. " more") or "")
    card.note:SetText(listing.note or "")
    card.whisper.target = listing.sender
    card.whisper:SetLabel("Whisper " .. listing.leader)
    card.whisper:ClearAllPoints()
    if listing.acceptsAsk then
        local label, active = addon.LfgBoard.AskButton(self.options.requestOf and self.options.requestOf(listing.id))
        card.ask:SetLabel(label)
        card.ask:SetActive(active)
        card.ask:Show()
        card.whisper:SetPoint("BOTTOMLEFT", card, "BOTTOM", Theme.SPACING.xs, pad)
    else
        card.ask:Hide()
        card.whisper:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", pad, pad)
    end
    card.whisper:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -pad, pad)
    card:Show()
end

-- A small card, made on first use: the purpose, then the type, levels,
-- leader and size (or which alt fits) in small text, with one row of small
-- tiles on the right.
function Page:smallCard(index)
    local card = self.smallCards[index]
    if card ~= nil then
        return card
    end
    local ui = self.ui
    card = ui:Panel(self.list)
    card:SetHeight(LfgBoardPage.SMALL_CARD_HEIGHT)
    card.purpose = ui:Text(card, "", "semibold", "body", "text")
    card.purpose:SetPoint("TOPLEFT", card, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
    card.details = ui:Text(card, "", "regular", "small", "label")
    card.details:SetPoint("TOPLEFT", card.purpose, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    card.roleTiles = self:roleTiles(card, 12)
    card.roleTiles[1]:SetPoint("RIGHT", card, "RIGHT", -Theme.SPACING.m - 4 * 16, 0)
    card.anyTiles = {}
    local index_
    for index_ = 1, 5 do
        card.anyTiles[index_] = ui:RoleTile(card, "any", 12, 12)
        card.anyTiles[index_]:SetPoint("LEFT", card.roleTiles[index_], "LEFT", 0, 0)
    end
    card.raidTile = ui:RoleTile(card, "any", 12, 12)
    card.raidTile:SetPoint("RIGHT", card, "RIGHT", -Theme.SPACING.m, 0)
    card.count = ui:Text(card, "", "regular", "small", "label")
    card.count:SetPoint("RIGHT", card.raidTile, "LEFT", -Theme.SPACING.xs, 0)
    self.smallCards[index] = card
    return card
end

-- Shows a small card for `listing`; `alt` names the alt that fits, and
-- `greyed` fades it out (Other Parties).
function Page:showSmall(card, listing, alt, greyed)
    card.listing = listing
    card.purpose:SetText(addon.LfgListing.Label(listing.kind, listing.purpose))
    local fits = alt and (alt.level and (alt.name .. " (" .. alt.level .. ")") or alt.name) or nil
    card.details:SetText(join({ addon.LfgListing.KindLabel(listing.kind), range(listing.minLevel, listing.maxLevel),
        listing.leader, fits or sizeText(listing) }))
    showTiles(card, listing)
    card.greyed = greyed == true
    card.purpose:SetTextColor(Theme.Color(card.greyed and "muted" or "text"))
    card:SetAlpha(card.greyed and LfgBoardPage.GREYED_ALPHA or 1)
    card:Show()
end

-- Lays out small cards for `entries` (each { listing, alt? }) two per row
-- from height `top`. Returns the height under them.
function Page:smallRows(entries, top, greyed, used)
    local index
    for index = 1, #entries do
        used.small = used.small + 1
        local card = self:smallCard(used.small)
        local row = math.floor((index - 1) / 2)
        self:place(card, top + row * (LfgBoardPage.SMALL_CARD_HEIGHT + Theme.SPACING.s),
            index % 2 == 1 and "left" or "right")
        self:showSmall(card, entries[index].listing, entries[index].alt, greyed)
    end
    local rows = math.ceil(#entries / 2)
    return top + rows * (LfgBoardPage.SMALL_CARD_HEIGHT + Theme.SPACING.s)
end

function Page:refreshTab()
    local groups = self.options.groups() or { relevant = {}, alts = {}, other = {} }
    self.groups = groups
    self.tabs:SetLabel("relevant", "Relevant Parties" .. DOT .. #groups.relevant)
    self.tabs:SetLabel("other", "Other Parties" .. DOT .. #groups.other)
    self.tabs:Select(self.tab)
    hideAll(self.largeCards)
    hideAll(self.smallCards)
    hideAll(self.historyRows)
    self.moreButton:Hide()
    self.altsLabel:Hide()
    self.nearbyCard:Hide()
    self.emptyText:Hide()
    local used = { small = 0 }
    local top = 0
    -- Relevant Parties has the Nearby card on its right, when anyone's
    -- nearby; the cards take the rest.
    local nearby = self.tab == "relevant" and self.options.nearby() or nil
    if nearby ~= nil and #(nearby.people or {}) == 0 then
        nearby = nil
    end
    local nearbyHeight = 0
    if nearby ~= nil then
        nearbyHeight = self:showNearby(nearby)
        self:inset(LfgBoardPage.NEARBY_WIDTH + Theme.SPACING.s)
    else
        self:inset(0)
    end
    local function empty(text)
        self.emptyText:SetText(text)
        self:place(self.emptyText, top)
        self.emptyText:Show()
        top = top + 24
    end
    if self.tab == "relevant" then
        local index
        for index = 1, #groups.relevant do
            local card = self:largeCard(index)
            local row = math.floor((index - 1) / 2)
            self:place(card, top + row * (LfgBoardPage.LARGE_CARD_HEIGHT + Theme.SPACING.s),
                index % 2 == 1 and "left" or "right")
            self:showLarge(card, groups.relevant[index])
        end
        top = top + math.ceil(#groups.relevant / 2) * (LfgBoardPage.LARGE_CARD_HEIGHT + Theme.SPACING.s)
        if #groups.relevant == 0 and #groups.alts == 0 then
            empty(LfgBoardPage.EMPTY.relevant)
        end
        if #groups.alts > 0 then
            self:place(self.altsLabel, top + Theme.SPACING.xs)
            self.altsLabel:Show()
            top = self:smallRows(groups.alts, top + 24, false, used)
        end
    elseif self.tab == "other" then
        if #groups.other == 0 then
            empty(LfgBoardPage.EMPTY.other)
        end
        local entries = {}
        local index
        for index = 1, #groups.other do
            entries[index] = { listing = groups.other[index] }
        end
        top = self:smallRows(entries, top, true, used)
    else
        top = self:historyList(top, empty)
    end
    self.list:SetHeight(math.max(top, nearbyHeight, 1))
    -- The name menu goes once its name is hidden or shows someone else.
    local named = self.nameMenuFor
    if named ~= nil and self.namesMenu ~= nil and self.namesMenu:IsOpen() then
        local anchor = named.anchor
        local shown = type(anchor.IsShown) ~= "function" or anchor:IsShown()
        if not shown or anchor.title ~= named.title or anchor.whisper ~= named.whisper then
            self.namesMenu:Close()
            self.nameMenuFor = nil
        end
    end
end

-- One History party, made on first use: its date and dungeon or zone,
-- then its guildmates (top group friends starred), each name opening the
-- name menu.
function Page:historyRow(index)
    local row = self.historyRows[index]
    if row ~= nil then
        return row
    end
    local ui, pad = self.ui, Theme.SPACING.m
    row = ui:Panel(self.list)
    row.title = ui:Text(row, "", "semibold", "body", "text")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", pad, -Theme.SPACING.s)
    row.members = {}
    local line
    for line = 1, LfgBoardPage.HISTORY_MEMBERS do
        local member = self:nameButton(row, LfgBoardPage.HISTORY_MEMBER_HEIGHT)
        member:SetWidth(260)
        member:SetPoint("TOPLEFT", row, "TOPLEFT", pad,
            -28 - (line - 1) * LfgBoardPage.HISTORY_MEMBER_HEIGHT)
        row.members[line] = member
    end
    row.more = ui:Text(row, "", "regular", "small", "label")
    self.historyRows[index] = row
    return row
end

-- Lays out the History tab's parties from height `top` (or its one empty
-- line), with Show more when older ones are left. Returns the height
-- under them.
function Page:historyList(top, empty)
    local options = self.options
    local page = self.historyView:Page(options.history and options.history() or {}, options.historyMember,
        options.keyTier)
    if page.parties[1] == nil then
        empty(LfgBoardPage.EMPTY.history)
        return top + 24
    end
    local index
    for index = 1, #page.parties do
        local party = page.parties[index]
        local row = self:historyRow(index)
        row.party = party
        local date = options.formatDate and options.formatDate(party.at) or nil
        row.title:SetText(join({ date, party.place }))
        local line
        for line = 1, #row.members do
            local member, entry = row.members[line], party.members[line]
            if entry == nil then
                member:Hide()
            else
                self:showName(member, { text = colored(entry.name, options.classColor(entry.classToken)),
                    whisper = entry.whisper, top = entry.tier == addon.GroupFriends.TOP })
            end
        end
        local shown = math.min(#party.members, #row.members)
        local more = #party.members - shown
        row.more:ClearAllPoints()
        row.more:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m,
            -28 - shown * LfgBoardPage.HISTORY_MEMBER_HEIGHT)
        row.more:SetText(more > 0 and ("and " .. more .. " more") or "")
        local height = 28 + shown * LfgBoardPage.HISTORY_MEMBER_HEIGHT + (more > 0 and 16 or 0) + Theme.SPACING.s
        row:SetHeight(height)
        self:place(row, top)
        row:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
        row:Show()
        top = top + height + Theme.SPACING.s
    end
    if page.more then
        self:place(self.moreButton, top)
        self.moreButton:Show()
        top = top + Widgets.BUTTON_HEIGHT + Theme.SPACING.s
    end
    return top
end

-- Shows tab `id` ("relevant", "other" or "history") from the top.
function Page:ShowTab(id)
    if id == "history" and self.tab ~= "history" then
        self.historyView:Reset()
    end
    self.tab = id
    self.area:SetVerticalScroll(0)
    self:refreshTab()
end

-- Redraws the card and the tabs from what the options say now.
function Page:Refresh()
    self:refreshCard()
    self:refreshTab()
    -- The role menu goes once its card is hidden or shows another listing.
    local asked = self.roleMenuFor
    if asked ~= nil and self.roleMenu ~= nil and self.roleMenu:IsOpen() then
        local now = asked.card and asked.card.listing
        local shown = asked.card == nil or type(asked.card.IsShown) ~= "function" or asked.card:IsShown()
        if not shown or now == nil or now.id ~= asked.id or now.listedAt ~= asked.listedAt then
            self.roleMenu:Close()
            self.roleMenuFor = nil
        end
    end
end

-- Leader `id`'s listing on the board now, or nil.
function Page:listingNow(id)
    local groups = self.options.groups() or {}
    local lists = { groups.relevant or {}, groups.other or {} }
    local index, position
    for index = 1, #lists do
        for position = 1, #lists[index] do
            if lists[index][position].id == id then
                return lists[index][position]
            end
        end
    end
    for index = 1, #(groups.alts or {}) do
        if groups.alts[index].listing.id == id then
            return groups.alts[index].listing
        end
    end
    return nil
end

-- Ask to join `listing` (shown on `card`) as the current character: a
-- dungeon's ask picks one open role the character can play, from a menu
-- when there's a choice; other kinds carry no role.
function Page:ask(anchor, listing, card)
    if type(listing) ~= "table" or not listing.acceptsAsk then
        return
    end
    if listing.kind ~= "dungeon" then
        self.options.onAsk(listing, nil)
        return
    end
    local roles = self.options.askRoles(listing)
    if #roles == 1 then
        self.options.onAsk(listing, roles[1])
    elseif #roles > 1 then
        self.roleMenu = self.roleMenu or self.ui:ContextMenu(self.content)
        self.roleMenuFor = { card = card, id = listing.id, listedAt = listing.listedAt }
        local owner = self
        local items = {}
        local index
        for index = 1, #roles do
            local role = roles[index]
            items[index] = { label = "Ask as " .. (Widgets.ROLE_LABELS[role] or role), onClick = function()
                owner.roleMenuFor = nil
                -- Only while that listing still takes asks with the role
                -- open.
                local now = owner:listingNow(listing.id)
                if now == nil or now.listedAt ~= listing.listedAt or not now.acceptsAsk then
                    return
                end
                local still = owner.options.askRoles(now)
                local position
                for position = 1, #still do
                    if still[position] == role then
                        owner.options.onAsk(now, role)
                        return
                    end
                end
            end }
        end
        self.roleMenu:Open(anchor, items)
    end
end
