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
--                     under "Your alts could join"
--   Nearby            a card listing the guildmates in the player's zone,
--                     their levels in a column left of their names
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
    -- The Nearby tab's card: its width, and the names it lists (more are
    -- counted).
    NEARBY_WIDTH = 320,
    NEARBY_ROWS = 40,
    NEARBY_ROW_HEIGHT = 18,
    -- The levels' column left of the names.
    LEVEL_WIDTH = 22,
    -- The role tiles on a large card's right: their width, and each row's
    -- height.
    TILE_BLOCK_WIDTH = 84,
    TILE_HEIGHT = 22,
    -- The leader's name on a small card's second line.
    SMALL_LEADER_WIDTH = 120,
    -- Other Parties' cards are faded to this.
    GREYED_ALPHA = 0.5,
    -- The tab list's width until the window lays it out.
    LIST_WIDTH = 688,
    SCROLL_STEP = 40,
    -- The most rows the dungeon (or questing zone) list shows, its "Other
    -- levels" line included.
    DUNGEON_ROWS = 7,
    DUNGEON_ROW_HEIGHT = 20,
    -- Roles in your party: one row per member.
    ROLE_ROWS = 5,
    ROLE_ROW_HEIGHT = 20,
    FIELD_WIDTH = 320,
    KINDS = {
        { id = "dungeon", label = "Dungeon" },
        { id = "questing", label = "Questing" },
        { id = "raid", label = "Raid" },
        { id = "other", label = "Other" },
    },
    EMPTY = {
        relevant = "No relevant groups for you right now.",
        nearby = "No guildmates nearby right now.",
        other = "No other groups right now.",
        history = "No parties in your history yet.",
    },
    -- Find guildmates: each row's height, and why the button's greyed out.
    FILL_ROW_HEIGHT = 28,
    FILL_UNLISTED = "List your party to find guildmates",
    FILL_FULL = "Your party has no room",
    FILL_EMPTY = "No guildmates online could fill a slot right now.",
    CHANGE_ZONE = "Change",
    CHOOSE_ZONE = "Choose",
    CANCEL_ZONE = "Cancel",
    SEARCH_PLACEHOLDERS = { dungeon = "Search all dungeons", questing = "Search all zones" },
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
--   zones         function() -> the ZoneCatalog Questing searches (the
--                 player's zone in it), or nil for the player's zone alone
--   groups        function() -> the board's listings sorted for the player
--                 (LfgBoard:Groups: relevant, alts, other)
--   nearby        function() -> { zone, people = { { name, whisper, level?,
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
--                 { key, name, classToken?, role, isPlayer? }
--   roleChoices   function(member) -> the roles `member` can be set to
--                 (their class's), or nil
--   canSetRole    function(member) -> whether the player may set it: the
--                 party's lister sets anyone's, a member only their own
--   onSetRole     function(member, role): sets a member's role in the party
--   myRole        function() -> the player's role in the party they're a
--                 member of, as { role, classToken }, or nil
--   onSave        function(purpose, note) -> true, or false and why not
--   onAskInGuild  function(line): types `line` into guild chat, unsent
--   fillCandidates function() -> the Find guildmates rows
--                 (LfgFillCandidates.List, each with classToken? too)
--   onInvite      function(row): invites a Find guildmates row's character
--   onLogOver     function(row): opens a whisper to an alt row's online
--                 character, pre-filled with row.message
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
        { id = "nearby", label = "Nearby" },
        { id = "other", label = "Other Parties" },
        { id = "history", label = "History" },
    }, function(id)
        owner:ShowTab(id)
    end)
    self:buildList()
    self:buildFill()
end

-- A Find guildmates button on `parent` (the solo card or the listing),
-- with why it's greyed out in the game's tooltip.
function Page:findButton(parent)
    local owner, environment = self, self.ui.environment
    local button = self.ui:Button(parent, "Find guildmates", "secondary", function()
        owner:OpenFill()
    end)
    button:SetWidth(130)
    button:HookScript("OnEnter", function(self)
        local tooltip = environment and environment.GameTooltip
        if not self.active and self.reason ~= nil and type(tooltip) == "table" then
            tooltip:SetOwner(self, "ANCHOR_RIGHT")
            tooltip:SetText(self.reason, 1, 1, 1, 1, true)
            tooltip:Show()
        end
    end)
    button:HookScript("OnLeave", function()
        local tooltip = environment and environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:Hide()
        end
    end)
    return button
end

-- Greys `button` out with `reason`, or enables it (no reason).
local function offerFind(button, reason)
    button.reason = reason
    button:SetActive(reason == nil)
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
    -- A leader whose party isn't listed sees it greyed out.
    self.soloFindButton = self:findButton(solo)
    self.soloFindButton:SetPoint("RIGHT", self.startButton, "LEFT", -Theme.SPACING.s, 0)
    self.soloFindButton:Hide()
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
    self.listingFindButton = self:findButton(view)
    self.listingFindButton:SetPoint("RIGHT", self.askGuildButton, "LEFT", -Theme.SPACING.s, 0)
    -- In someone else's dungeon party: the player's own role in it.
    self.myRoleButton = ui:Button(view, "My role", "secondary", function(button)
        local mine = owner.options.myRole and owner.options.myRole() or nil
        if mine ~= nil then
            owner:pickRole(button, { isPlayer = true, key = "player", name = "My role", role = mine.role,
                classToken = mine.classToken })
        end
    end)
    self.myRoleButton:SetWidth(130)
    self.myRoleButton:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -pad, pad)
    self.myRoleButton:Hide()
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
        if owner.draft.kind ~= id then
            -- Each list starts unsearched.
            owner.draft.search = ""
            owner.draft.offset = 0
            owner.search:SetValue("")
        end
        owner.draft.kind = id
        -- Questing starts on the chosen zone, the list closed.
        owner.draft.pickingZone = false
        owner:refreshEditor()
    end)
    self.kindSelector:SetPoint("TOPLEFT", editor.kindLabel, "BOTTOMLEFT", 0, -Theme.SPACING.xs)

    -- The fields for each kind sit in one box under the choice.
    local fields = ui:frame("Frame", editor)
    fields:SetPoint("TOPLEFT", self.kindSelector, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    fields:SetSize(LfgBoardPage.FIELD_WIDTH, LfgBoardPage.DUNGEON_ROWS * LfgBoardPage.DUNGEON_ROW_HEIGHT
        + Widgets.INPUT_HEIGHT + Theme.SPACING.xs)
    editor.fields = fields

    -- Dungeon and Questing share the search and the list: dungeons, or
    -- the zones a questing listing can be in.
    self.search = ui:SearchBox(fields, LfgBoardPage.FIELD_WIDTH, LfgBoardPage.SEARCH_PLACEHOLDERS.dungeon, function(text)
        owner.draft.search = text
        owner.draft.offset = 0
        owner:refreshDungeons()
    end)
    -- The mouse wheel scrolls the list past its first rows.
    fields:EnableMouseWheel(true)
    fields:SetScript("OnMouseWheel", function(_, delta)
        if owner.draft ~= nil and owner:listed() then
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
            if type(self.dungeon) == "table" then
                owner.draft.dungeon = self.dungeon
                owner:refreshDungeons()
            elseif type(self.zone) == "table" then
                -- Picking a zone closes the list on it.
                owner.draft.zone = self.zone
                owner.draft.pickingZone = false
                owner:refreshEditor()
            end
        end)
        self.dungeonRows[index] = row
    end

    -- Questing: the chosen zone (the current one to start), with Change to
    -- open the zone list.
    editor.questing = ui:Text(fields, "", "regular", "body", "text")
    editor.questing:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, -Theme.SPACING.xs)
    self.changeZoneButton = ui:Button(fields, LfgBoardPage.CHANGE_ZONE, "secondary", function()
        owner.draft.pickingZone = true
        owner.draft.search = ""
        owner.draft.offset = 0
        owner.search:SetValue("")
        owner:refreshEditor()
    end)
    self.changeZoneButton:SetWidth(80)
    self.changeZoneButton:SetPoint("TOPRIGHT", fields, "TOPRIGHT", 0, 0)
    self.changeZoneButton:Hide()
    -- Beside the zone search: closes the list, the zone as it was.
    self.cancelZoneButton = ui:Button(fields, LfgBoardPage.CANCEL_ZONE, "secondary", function()
        owner.draft.pickingZone = false
        owner:refreshEditor()
    end)
    self.cancelZoneButton:SetWidth(80)
    self.cancelZoneButton:SetPoint("LEFT", self.search, "RIGHT", Theme.SPACING.s, 0)
    self.cancelZoneButton:Hide()
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

    -- Roles in your party (dungeons): each member's role icon left of their
    -- name in class color. Clicking a name picks their role from those
    -- their class plays: the lister sets anyone's, a member their own.
    -- That wins over the game's party menu.
    editor.rolesLabel = ui:SectionLabel(editor, "Roles in your party")
    editor.rolesLabel:SetPoint("TOPLEFT", self.note, "BOTTOMLEFT", 0, -28)
    self.roleRows = {}
    local row
    for row = 1, LfgBoardPage.ROLE_ROWS do
        local line = self:nameButton(editor, LfgBoardPage.ROLE_ROW_HEIGHT, function(clicked)
            owner:pickRole(clicked, clicked.member)
        end)
        line:SetWidth(LfgBoardPage.FIELD_WIDTH)
        line:SetPoint("TOPLEFT", editor.rolesLabel, "BOTTOMLEFT", 0,
            -Theme.SPACING.xs - (row - 1) * LfgBoardPage.ROLE_ROW_HEIGHT)
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
        zone = self:startingZone(purpose),
        text = purpose and purpose.text or "",
        note = listing:IsActive() and listing:Note() or "",
        search = "",
        offset = 0,
    }
    self.editing = true
    self.search:SetValue("")
    self.otherText:SetValue(self.draft.text)
    self.note:SetValue(self.draft.note)
    self.errorText:SetText("")
    self:Refresh()
end

-- The zones Questing offers: the ZoneCatalog, else the player's zone alone.
function Page:zones()
    local zones = self.options.zones and self.options.zones() or nil
    if zones == nil then
        zones = addon.ZoneCatalog.Create({}, { name = self.options.zone() })
    end
    return zones
end

-- The zone a questing draft starts with: the listing's when it's questing,
-- else the player's current zone. Nil when neither is known.
function Page:startingZone(purpose)
    local zones = self:zones()
    if purpose ~= nil and purpose.kind == "questing" then
        return zones:Named(purpose.zone) or { id = purpose.zone, name = purpose.zone }
    end
    local current = self.options.zone()
    return current and zones:Named(current) or nil
end

-- Whether the draft shows the list: Dungeon, and Questing while its zone
-- is being changed.
function Page:listed()
    return self.draft.kind == "dungeon" or (self.draft.kind == "questing" and self.draft.pickingZone == true)
end

-- The draft as a purpose to save. Questing carries the chosen zone's game
-- range (`game`), when it has one, for the listing's levels.
function Page:draftPurpose()
    local draft = self.draft
    if draft.kind == "dungeon" then
        return { kind = "dungeon", dungeon = draft.dungeon }
    elseif draft.kind == "questing" then
        local zone = draft.zone
        return { kind = "questing", zone = zone and zone.name or nil,
            game = zone and zone.minLevel and { minLevel = zone.minLevel, maxLevel = zone.maxLevel } or nil }
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
        setShown(self.soloFindButton, party.inParty and party.isLeader and self.options.fillCandidates ~= nil)
        offerFind(self.soloFindButton, LfgBoardPage.FILL_UNLISTED)
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
    self.myRoleButton:Hide()
    self.askGuildButton:SetActive(addon.LfgListing.GuildLine(fields) ~= nil)
    setShown(self.listingFindButton, self.options.fillCandidates ~= nil)
    offerFind(self.listingFindButton, fields.s >= fields.x and LfgBoardPage.FILL_FULL or nil)
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
    self.listingFindButton:Hide()
    -- A dungeon member picks their own role here.
    local mine = listing.kind == "dungeon" and self.options.myRole and self.options.myRole() or nil
    if mine ~= nil then
        self.myRoleButton:SetLabel("My role: " .. (Widgets.ROLE_LABELS[mine.role] or "pick"))
        self.myRoleButton:Show()
    else
        self.myRoleButton:Hide()
    end
end

-- Roles in your party: each member's role icon by their name.
-- Questing shows the party too, by name only: its roles don't matter.
function Page:refreshRoles()
    local dungeon = self.draft.kind == "dungeon"
    local shown = dungeon or self.draft.kind == "questing"
    local members = shown and (self.options.partyRoles and self.options.partyRoles()) or {}
    setShown(self.editor.rolesLabel, #members > 0)
    self.editor.rolesLabel:SetText(Theme.Label(dungeon and "Roles in your party" or "Your party"))
    local index
    for index = 1, #self.roleRows do
        local line, member = self.roleRows[index], members[index]
        if member == nil then
            line.key = false
            line.member = false
            line:Hide()
        else
            line.key = member.key
            -- Only a dungeon's names open the role menu.
            line.member = dungeon and member or false
            line.memberName = member.name
            self:showName(line, { text = colored(member.name, self.options.classColor
                and self.options.classColor(member.classToken)), role = dungeon and member.role or nil })
        end
    end
end

-- Opens the role menu on name `anchor` for party member `member`: the roles
-- their class plays, when the player may set theirs.
function Page:pickRole(anchor, member)
    local options, owner = self.options, self
    if not member or options.canSetRole == nil or not options.canSetRole(member) then
        return
    end
    local roles = options.roleChoices and options.roleChoices(member) or nil
    if roles == nil or roles[1] == nil then
        return
    end
    local items = {}
    local index
    for index = 1, #roles do
        local role = roles[index]
        items[index] = { label = (Widgets.ROLE_LABELS[role] or role) .. (role == member.role and " (current)" or ""),
            onClick = function()
                if options.onSetRole ~= nil then
                    options.onSetRole(member, role)
                end
                owner:Refresh()
            end }
    end
    self.roleMenu = self.roleMenu or self.ui:ContextMenu(self.content)
    self.roleMenuFor = nil
    self.roleMenu:Open(anchor, items, member.name)
end

function Page:refreshEditor()
    local draft, editor = self.draft, self.editor
    self.kindSelector:Select(draft.kind)
    -- Questing shows its zone, with Change opening the list; with no zone
    -- known at all it says so.
    local questing = draft.kind == "questing"
    local unknown = questing and #self:zones().zones == 0
    local listed = draft.kind == "dungeon" or (questing and draft.pickingZone == true and not unknown)
    setShown(self.search, listed)
    if listed then
        self.search.placeholder:SetText(LfgBoardPage.SEARCH_PLACEHOLDERS[draft.kind])
        self:refreshDungeons()
    else
        hideAll(self.dungeonRows)
    end
    local zone = draft.zone
    editor.questing:SetText(unknown and "Your zone isn't known yet."
        or zone ~= nil and ("Questing in " .. zone.name .. (zone.minLevel and (" (" .. range(zone.minLevel,
            zone.maxLevel) .. ")") or "")) or "Choose a zone.")
    setShown(editor.questing, questing and not listed)
    setShown(self.changeZoneButton, questing and not listed and not unknown)
    setShown(self.cancelZoneButton, questing and listed)
    self.changeZoneButton:SetLabel(zone ~= nil and LfgBoardPage.CHANGE_ZONE or LfgBoardPage.CHOOSE_ZONE)
    setShown(editor.raid, draft.kind == "raid")
    setShown(self.otherText, draft.kind == "other")
    self:refreshRoles()
end

-- The dungeon list, or Questing's zone list: what the search finds, those
-- that fit the player's level first, then the rest under "Other levels".
function Page:refreshDungeons()
    local questing = self.draft.kind == "questing"
    local catalog = questing and self:zones() or self.options.catalog()
    local fitting, others = catalog:Search(self.draft.search, self.options.level())
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
    local chosen = questing and self.draft.zone or self.draft.dungeon
    for index = 1, #self.dungeonRows do
        local row, entry = self.dungeonRows[index], entries[index + offset]
        row.dungeon, row.zone = false, false
        if entry == nil then
            row:Hide()
        elseif entry.header ~= nil then
            row.label:SetText(Theme.Label(entry.header))
            row.label:SetTextColor(Theme.Color("label"))
            row.range:SetText("")
            row:SetFill("surface")
            row:Show()
        else
            if questing then
                row.zone = entry
            else
                row.dungeon = entry
            end
            row.label:SetText(entry.name)
            row.label:SetTextColor(Theme.Color("text"))
            row.range:SetText(range(entry.minLevel, entry.maxLevel) or "")
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
    local area, list = ui:ScrollList(content, LfgBoardPage.SCROLL_STEP, LfgBoardPage.LIST_WIDTH)
    area:SetPoint("TOPLEFT", self.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    area:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    self.area, self.list = area, list
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

-- Shows the Nearby card for `nearby` ({ zone, people }) at the list's top.
-- Returns its height.
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
                whisper = person.whisper, level = person.level or "",
                top = addon.GroupFriends.IsStarred(options.friendTier(person.whisper or person.name)) })
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
    card:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, 0)
    card:Show()
    return height
end

-- Places `frame` at height `top` of the list: across the whole width, or in
-- the left or right `column` of two.
function Page:place(frame, top, column)
    local list = self.list
    frame:ClearAllPoints()
    if column == "right" then
        frame:SetPoint("TOPLEFT", list, "TOP", Theme.SPACING.xs, -top)
        frame:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    elseif column == "left" then
        frame:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top)
        frame:SetPoint("RIGHT", list, "CENTER", -Theme.SPACING.xs, 0)
    else
        frame:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top)
    end
end

-- A name that opens the name menu when clicked (or calls `onClick(line)`
-- instead), `height` tall, with room for a level column and a role icon on
-- its left, and a crown (the leader) and star (a Top 5 group friend or a
-- Friend) after it. Shown with showName; placed by its owner.
function Page:nameButton(parent, height, onClick)
    local ui, owner = self.ui, self
    local line = ui:frame("Button", parent)
    line:SetHeight(height)
    line.level = ui:Text(line, "", "regular", "small", "muted")
    line.level:SetWidth(LfgBoardPage.LEVEL_WIDTH)
    line.level:SetJustifyH("RIGHT")
    line.level:SetPoint("LEFT", line, "LEFT", 0, 0)
    line.roleIcon = line:CreateTexture(nil, "ARTWORK")
    line.roleIcon:SetSize(12, 12)
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
        if onClick ~= nil then
            onClick(self)
        else
            owner:nameMenu(self)
        end
    end)
    return line
end

-- Shows name button `line` for `fields`: text (the name, maybe in class
-- color), whisper (whom Whisper whispers), level (shown in the levels'
-- column when given, "" for an unknown one), role (its icon, in the role's
-- color), leader (the crown) and top (the star).
function Page:showName(line, fields)
    local role = fields.role
    line.role = role
    local left = 0
    if fields.level ~= nil then
        line.level:SetText(tostring(fields.level))
        line.level:Show()
        left = LfgBoardPage.LEVEL_WIDTH + Theme.SPACING.s
    else
        line.level:Hide()
    end
    line.roleIcon:ClearAllPoints()
    line.roleIcon:SetPoint("LEFT", line, "LEFT", left, 0)
    line.name:ClearAllPoints()
    if role ~= nil and Widgets.ROLE_ICONS[role] ~= nil then
        line.roleIcon:SetTexture(Theme.TEXTURES[Widgets.ROLE_ICONS[role]])
        line.roleIcon:SetVertexColor(Theme.Color(role))
        line.roleIcon:Show()
        line.name:SetPoint("LEFT", line.roleIcon, "RIGHT", 4, 0)
    else
        line.roleIcon:Hide()
        line.name:SetPoint("LEFT", line, "LEFT", left, 0)
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

-- Opens the name menu under `anchor` with its name as the title, over a
-- line, then `items`. A second click on the same name closes it.
function Page:openNameMenu(anchor, items)
    self.namesMenu = self.namesMenu or self.ui:ContextMenu(self.content)
    local menu = self.namesMenu
    if menu:IsOpen() and self.nameMenuFor ~= nil and self.nameMenuFor.anchor == anchor then
        menu:Close()
        self.nameMenuFor = nil
        return
    end
    self.nameMenuFor = { anchor = anchor, title = anchor.title, whisper = anchor.whisper }
    menu:Open(anchor, items, anchor.title)
end

-- The menu a name opens: the name, then Whisper.
function Page:nameMenu(anchor)
    local owner, whisper = self, anchor.whisper
    self:openNameMenu(anchor, {
        { label = "Whisper", onClick = function()
            owner.nameMenuFor = nil
            if whisper then
                owner.options.onWhisper(whisper)
            end
        end },
    })
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

-- Role tiles laid out as on a large card, with their icons: two on top
-- (Tank and Healer), three smaller below filling the same width. `role` is
-- nil for a party's real roles, or "any" for person tiles.
function Page:tileBlock(parent, role)
    local width, height, gap = LfgBoardPage.TILE_BLOCK_WIDTH, LfgBoardPage.TILE_HEIGHT, 4
    local top = (width - gap) / 2
    local bottom = (width - 2 * gap) / 3
    local roles = { role or "tank", role or "healer", role or "dps", role or "dps", role or "dps" }
    local tiles = {}
    local index
    for index = 1, 5 do
        tiles[index] = self.ui:RoleTile(parent, roles[index], index <= 2 and top or bottom, height)
        tiles[index]:ShowIcon()
    end
    tiles[2]:SetPoint("LEFT", tiles[1], "RIGHT", gap, 0)
    tiles[3]:SetPoint("TOPLEFT", tiles[1], "BOTTOMLEFT", 0, -gap)
    tiles[4]:SetPoint("LEFT", tiles[3], "RIGHT", gap, 0)
    tiles[5]:SetPoint("LEFT", tiles[4], "RIGHT", gap, 0)
    return tiles
end

-- A large card, made on first use: the purpose with its icon, then its
-- type, levels and size; the members on the left, each with their role's
-- icon (a dungeon's), the leader crowned and top group friends starred,
-- every name opening the name menu; the role tiles on the right (open in
-- color, filled grey); the note; and Ask to join and Whisper <leader>
-- side by side.
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
        line:SetPoint("RIGHT", card, "RIGHT", -pad - LfgBoardPage.TILE_BLOCK_WIDTH - Theme.SPACING.s, 0)
        card.members[row] = line
    end
    card.more = ui:Text(card, "", "regular", "small", "label")
    card.more:SetPoint("TOPLEFT", card, "TOPLEFT", pad,
        -54 - LfgBoardPage.CARD_MEMBERS * LfgBoardPage.MEMBER_HEIGHT)
    card.roleTiles = self:tileBlock(card, nil)
    card.roleTiles[1]:SetPoint("TOPLEFT", card, "TOPRIGHT", -pad - LfgBoardPage.TILE_BLOCK_WIDTH, -54)
    card.anyTiles = self:tileBlock(card, "any")
    card.anyTiles[1]:SetPoint("TOPLEFT", card.roleTiles[1], "TOPLEFT", 0, 0)
    card.raidTile = ui:RoleTile(card, "any", LfgBoardPage.TILE_BLOCK_WIDTH, LfgBoardPage.TILE_HEIGHT)
    card.raidTile:SetPoint("TOPLEFT", card.roleTiles[1], "TOPLEFT", 0, 0)
    card.count = ui:Text(card, "", "regular", "small", "muted")
    card.count:SetPoint("TOP", card.raidTile, "BOTTOM", 0, -4)
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
        sizeText(listing), listing.contact and ("contact " .. listing.leader) or nil }))
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
                top = addon.GroupFriends.IsStarred(options.friendTier(member.name)),
            })
        end
    end
    local more = #listing.members - #card.members
    card.more:SetText(more > 0 and ("and " .. more .. " more") or "")
    showTiles(card, listing)
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
    -- The leader after the details, in class color, opening the name menu.
    card.leader = self:nameButton(card, LfgBoardPage.MEMBER_HEIGHT)
    card.leader:SetWidth(LfgBoardPage.SMALL_LEADER_WIDTH)
    card.leader:SetPoint("LEFT", card.details, "RIGHT", 0, 0)
    Theme.Font(card.leader.name, "regular", "small", "text")
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

-- Shows a small card for `listing`; `greyed` fades it out (Other
-- Parties). Its second line is the type and levels, then the leader.
function Page:showSmall(card, listing, greyed)
    card.listing = listing
    card.purpose:SetText(addon.LfgListing.Label(listing.kind, listing.purpose))
    local details = join({ addon.LfgListing.KindLabel(listing.kind), range(listing.minLevel, listing.maxLevel) })
    card.details:SetText(details ~= "" and (details .. DOT) or "")
    -- A party led from outside the guild is named by its contact, whose
    -- class the listing doesn't carry.
    local leader = listing.members ~= nil and listing.members[1] or nil
    local color = not listing.contact and leader ~= nil and self.options.classColor(leader.classToken) or nil
    self:showName(card.leader, { text = colored(listing.leader, color), whisper = listing.sender })
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
        self:showSmall(card, entries[index].listing, greyed)
    end
    local rows = math.ceil(#entries / 2)
    return top + rows * (LfgBoardPage.SMALL_CARD_HEIGHT + Theme.SPACING.s)
end

function Page:refreshTab()
    local groups = self.options.groups() or { relevant = {}, alts = {}, other = {} }
    self.groups = groups
    local nearby = self.options.nearby()
    local people = nearby ~= nil and nearby.people or {}
    self.tabs:SetLabel("relevant", "Relevant Parties" .. DOT .. #groups.relevant)
    self.tabs:SetLabel("nearby", "Nearby" .. DOT .. #people)
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
    elseif self.tab == "nearby" then
        if #people == 0 then
            empty(LfgBoardPage.EMPTY.nearby)
        else
            top = self:showNearby(nearby)
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
    self.list:SetHeight(math.max(top, 1))
    -- The name menu goes once its name is hidden (or its card is) or shows
    -- someone else.
    local named = self.nameMenuFor
    if named ~= nil and self.namesMenu ~= nil and self.namesMenu:IsOpen() then
        local anchor = named.anchor
        local shown = type(anchor.IsVisible) ~= "function" or anchor:IsVisible()
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
                    whisper = entry.whisper, top = addon.GroupFriends.IsStarred(entry.tier) })
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

-- Redraws the card and the tabs from what the options say now. Find
-- guildmates, while open, stays as it was built.
function Page:Refresh()
    self:refreshCard()
    self:refreshTab()
    setShown(self.tabs, not self.filling)
    setShown(self.area, not self.filling)
    setShown(self.fill, self.filling == true)
    -- The role menu goes once its card is hidden or shows another listing.
    local asked = self.roleMenuFor
    if asked ~= nil and self.roleMenu ~= nil and self.roleMenu:IsOpen() then
        local now = asked.card and asked.card.listing
        local shown = asked.card == nil or type(asked.card.IsVisible) ~= "function" or asked.card:IsVisible()
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

-- Find guildmates ---------------------------------------------------------------

-- The Find guildmates panel, in the board list's place while it's open: a
-- header with the listing's label and range, Back, and a row per guildmate
-- who could fill a slot, with Invite and Whisper.
function Page:buildFill()
    local ui, content, owner = self.ui, self.content, self
    local fill = ui:frame("Frame", content)
    fill:SetPoint("TOPLEFT", self.card, "BOTTOMLEFT", 0, -Theme.SPACING.l)
    fill:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    fill.label = ui:SectionLabel(fill, "Find guildmates")
    fill.label:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
    fill.title = ui:Text(fill, "", "semibold", "heading", "text")
    fill.title:SetPoint("TOPLEFT", fill.label, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    self.backButton = ui:Button(fill, "Back", "secondary", function()
        owner:CloseFill()
    end)
    self.backButton:SetWidth(70)
    self.backButton:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
    local area, list = ui:ScrollList(fill, LfgBoardPage.SCROLL_STEP, LfgBoardPage.LIST_WIDTH)
    area:SetPoint("TOPLEFT", fill.title, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    area:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
    fill.area, fill.list = area, list
    fill.empty = ui:Text(list, LfgBoardPage.FILL_EMPTY, "regular", "body", "muted")
    fill.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    fill.rows = {}
    fill:Hide()
    self.fill = fill
end

-- Find guildmates row `index`, made the first time it's needed.
function Page:fillRow(index)
    local fill, ui, owner = self.fill, self.ui, self
    local row = fill.rows[index]
    if row ~= nil then
        return row
    end
    row = ui:frame("Frame", fill.list)
    row:SetHeight(LfgBoardPage.FILL_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", fill.list, "TOPLEFT", 0, -(index - 1) * LfgBoardPage.FILL_ROW_HEIGHT)
    row:SetPoint("RIGHT", fill.list, "RIGHT", 0, 0)
    row.name = ui:Text(row, "", "semibold", "body", "text")
    row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
    -- A starred friend's star, after the name.
    row.star = row:CreateTexture(nil, "ARTWORK")
    row.star:SetTexture(Theme.TEXTURES.star)
    row.star:SetVertexColor(Theme.Color("gold"))
    row.star:SetSize(10, 10)
    row.star:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
    row.details = ui:Text(row, "", "regular", "small", "muted")
    row.details:SetPoint("LEFT", row.star, "RIGHT", Theme.SPACING.s - 4, 0)
    -- An alt's Whisper asks its player, on the character online now, to
    -- log over.
    row.whisper = ui:Button(row, "Whisper", "secondary", function()
        local candidate = row.candidate
        if candidate.kind == addon.LfgFillCandidates.ALT then
            if owner.options.onLogOver ~= nil then
                owner.options.onLogOver(candidate)
            end
        elseif owner.options.onWhisper ~= nil then
            owner.options.onWhisper(candidate.whisper)
        end
    end)
    row.whisper:SetWidth(80)
    row.whisper:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.invite = ui:Button(row, "Invite", "primary", function()
        if owner.options.onInvite ~= nil then
            owner.options.onInvite(row.candidate)
        end
    end)
    row.invite:SetWidth(70)
    row.invite:SetPoint("RIGHT", row.whisper, "LEFT", -Theme.SPACING.s, 0)
    fill.rows[index] = row
    return row
end

-- Opens Find guildmates for the player's listing, built from who's online
-- now; it isn't refreshed while open.
function Page:OpenFill()
    local options, fill = self.options, self.fill
    local fields = options.listing:IsActive() and options.listing:Announcement(options.members()) or nil
    if fields == nil or options.fillCandidates == nil then
        return false
    end
    fill.title:SetText(join({ addon.LfgListing.Label(fields.k, fields.p), range(fields.lo, fields.hi) }))
    local candidates = options.fillCandidates() or {}
    self.fillCandidates = candidates
    hideAll(fill.rows)
    local index
    for index = 1, #candidates do
        local candidate, row = candidates[index], self:fillRow(index)
        row.candidate = candidate
        local color = options.classColor and options.classColor(candidate.classToken or candidate.class)
        if candidate.kind == addon.LfgFillCandidates.ALT then
            -- "Bobalt (22 Priest) · alt of Bob, online as Bobmain": Whisper
            -- only.
            local about = tostring(candidate.level or "?") .. (candidate.className and (" " .. candidate.className) or "")
            row.name:SetText(colored(candidate.name, color) .. " (" .. about .. ")")
            row.details:SetText(string.gsub(DOT, "^ ", "") .. join({ "alt of " .. tostring(candidate.label) ..
                ", online as " .. tostring(candidate.onlineName), candidate.inGroup and "In a group" or nil }))
            row.invite:Hide()
        else
            row.name:SetText(colored(candidate.name, color))
            row.details:SetText(join({ candidate.level and ("Level " .. candidate.level) or nil,
                candidate.label ~= candidate.name and candidate.label or nil, candidate.inGroup and "In a group" or nil }))
            row.invite:Show()
        end
        setShown(row.star, candidate.starred == true)
        row:Show()
    end
    setShown(fill.empty, #candidates == 0)
    fill.list:SetHeight(math.max(1, #candidates * LfgBoardPage.FILL_ROW_HEIGHT))
    fill.area:SetVerticalScroll(0)
    self.filling = true
    self:Refresh()
    return true
end

-- Back: the board list again.
function Page:CloseFill()
    self.filling = false
    self:Refresh()
end
