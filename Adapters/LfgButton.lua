local _, addon = ...

-- The LFG button: a small rounded-square tile with a thin green frame and
-- the tree icon, free on the screen and separate from the minimap icon.
-- It's dragged anywhere, with its place saved per character, and stays put
-- in instances. Right-click gives Open Guild LFG Board and Hide LFG button.
-- Whether it shows is the caller's (a per-character setting); hidden means
-- "not participating right now", and it never comes back by itself.
--
-- A gold count in its lower corner says how many listed groups the
-- character could join, and a glow says something's new (see
-- LfgDrawerModel, whose view Update draws). Left-click slides the drawer
-- out to its left: the newest group for the player with Start a group, or
-- their party. Its X closes only the drawer, and a click anywhere else in
-- it that isn't a button opens the Guild LFG Board.
--
-- Made the first time it shows. Like the other adapters, a frame call that
-- fails just leaves it out.
local Theme = addon.Theme

local LfgButton = {
    SIZE = 40,
    ICON_INSET = 7,
    -- Where it starts before it's ever moved: near the minimap.
    DEFAULT_POINT = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -230, y = -30 },
    DRAWER_WIDTH = 230,
    DRAWER_GAP = 6,
    -- How far the drawer slides in from.
    SLIDE = 24,
    DRAWER_HEIGHTS = { newest = 156, none = 96, party = 146, ask = 178, gate = 146, slot = 164 },
    -- The party's role tiles, as on the Your listing card.
    TILE_SIZE = 22,
    NONE_TEXT = "No groups for you right now",
    ASK_GUILD_TEXT = "Ask in guild",
    ASK_TEXT = "You're leading a party. List it on the Guild LFG Board?",
    GATE_TEXT = "Your party has players from outside the guild. List it on the Guild LFG Board?",
    SLOT_TEXT = "Someone left \226\128\148 fill the empty slot?",
    -- Show Nearby: the names it lists (more are counted), each row's
    -- height, and the levels' column.
    NEARBY_ROWS = 25,
    NEARBY_ROW_HEIGHT = 18,
    LEVEL_WIDTH = 22,
    NEARBY_NONE_TEXT = "No guildmates nearby right now.",
    -- An Ask to join request under the drawer.
    TOAST_HEIGHT = 74,
}
addon.LfgButton = LfgButton

local DOT = " \194\183 "

local Button = {}
Button.__index = Button

-- Font string `text` wraps within `width` at spaces, never inside a word.
local function wrapAtWords(text, width)
    text:SetWidth(width)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    if type(text.SetNonSpaceWrap) == "function" then
        text:SetNonSpaceWrap(false)
    end
end

-- How much taller font string `text` is than `lines` lines of it, as the
-- client lays it out: 0 where the client can't say.
local function extraHeight(text, lines)
    if type(text.GetStringHeight) ~= "function" or type(text.GetNumLines) ~= "function" then
        return 0
    end
    local height, count = text:GetStringHeight(), text:GetNumLines()
    height, count = tonumber(height), tonumber(count)
    if height == nil or count == nil or count <= lines or height <= 0 then
        return 0
    end
    return height * (count - lines) / count
end

-- options:
--   frameName       the button's global name
--   shown           function() -> whether it shows on this character
--   onOpenBoard     function(): the menu's Open Guild LFG Board, and a
--                   click in the drawer
--   onHide          function(): the menu's Hide LFG button
--   onDrawerOpened  function(): the drawer opened, so what's new is seen
--   onStartGroup    function(): the drawer's Start a group
--   onListParty     function(): the leader chose to list their party, or
--                   the player said yes to listing one with outsiders
--   onNotLooking    function(): the leader said Not looking (or no to
--                   listing a party with outsiders), or closed the drawer
--                   on the question
--   onSnooze        function(): "don't ask for 30 minutes"
--   onFillSlot      function(yes): the answer to "Someone left — fill the
--                   empty slot?"
--   nearby          function() -> { zone, people = { { name, whisper,
--                   level?, classToken? } } } of guildmates in the player's
--                   zone, or nil; the menu's Show Nearby lists them
--   askRoles        function(listing) -> the open roles the current
--                   character can ask to join a dungeon listing as
--   onAsk           function(listing, role?): Ask to join
--   onWhisper       function(name): whispers someone
--   onEditListing   function(): the drawer's Edit on the player's own
--                   listing (the party's `own`)
--   onEndListing    function(): its End listing
--   onFindGuildmates function(): the drawer's Find guildmates, shown for
--                   the party's `find` ({ reason? }: greyed out with the
--                   reason when there is one)
--   onAskInGuild    function(line): types `line` into guild chat, unsent;
--                   the drawer's Ask in guild for the player's listed
--                   party with open slots (the party's `guildLine`)
--   onInvite        function(request): the leader invited an asker
--   onDecline       function(request): the leader declined one
--   classColor      function(classToken) -> "ffrrggbb", or nil
--   dungeonIcon     function(name) -> the game's icon for a dungeon, or nil
--   loadPosition    function() -> saved { point, relativePoint, x, y } or nil
--   savePosition    function(position)
function LfgButton.Create(client, options)
    return setmetatable({
        client = client,
        environment = client.environment,
        options = options,
    }, Button)
end

function Button:build()
    local environment = self.environment
    local ui = addon.Widgets.Create(environment)
    self.ui = ui
    local button = environment.CreateFrame("Button", self.options.frameName, environment.UIParent)
    button:SetSize(LfgButton.SIZE, LfgButton.SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetClampedToScreen(true)
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    ui:Round(button, Theme.RADIUS.button, "surface", "green")
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture(Theme.TEXTURES.tree)
    button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", LfgButton.ICON_INSET, -LfgButton.ICON_INSET)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -LfgButton.ICON_INSET, LfgButton.ICON_INSET)
    self.glow = ui:Glow(button, 12)
    self.count = ui:CountBadge(button)
    self.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
    self.button = button
    self.menu = ui:ContextMenu(environment.UIParent)
    self:buildDrawer()
    self:place()

    local owner = self
    button:SetScript("OnEnter", function(self)
        self:SetFill("raised")
    end)
    button:SetScript("OnLeave", function(self)
        self:SetFill("surface")
    end)
    button:SetScript("OnDragStart", function(self)
        owner.menu:Close()
        self:StartMoving()
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        owner:savePosition()
    end)
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            owner:OpenMenu()
        else
            owner.menu:Close()
            owner:ToggleDrawer()
        end
    end)
    button:Hide()
    if self.view ~= nil then
        self:Update(self.view)
    end
end

-- The drawer -----------------------------------------------------------------------

function Button:buildDrawer()
    local ui, owner = self.ui, self
    local drawer = ui:Panel(self.environment.UIParent, { fill = "background" })
    drawer:SetFrameStrata("MEDIUM")
    drawer:SetWidth(LfgButton.DRAWER_WIDTH)
    drawer:SetClampedToScreen(true)
    drawer:SetPoint("TOPRIGHT", self.button, "TOPLEFT", -LfgButton.DRAWER_GAP, 0)
    drawer:EnableMouse(true)
    -- A click on the drawer itself, not one of its buttons, opens the board.
    drawer:SetScript("OnMouseUp", function()
        owner.options.onOpenBoard()
    end)
    local pad = Theme.SPACING.m
    drawer.heading = ui:SectionLabel(drawer, "New for you")
    drawer.heading:SetPoint("TOPLEFT", drawer, "TOPLEFT", pad, -pad)
    self.drawerClose = ui:IconButton(drawer, Theme.TEXTURES.close, 20, function()
        owner:CloseDrawer()
    end)
    self.drawerClose:SetPoint("TOPRIGHT", drawer, "TOPRIGHT", -Theme.SPACING.xs, -Theme.SPACING.xs)

    -- New for you: the newest relevant group.
    drawer.icon = drawer:CreateTexture(nil, "ARTWORK")
    drawer.icon:SetSize(40, 40)
    drawer.icon:SetPoint("TOPLEFT", drawer.heading, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    drawer.purpose = ui:Text(drawer, "", "semibold", "title", "text")
    drawer.purpose:SetPoint("TOPLEFT", drawer.icon, "TOPRIGHT", Theme.SPACING.s, -2)
    wrapAtWords(drawer.purpose, LfgButton.DRAWER_WIDTH - 2 * pad - 48)
    drawer.details = ui:Text(drawer, "", "regular", "small", "muted")
    drawer.details:SetPoint("TOPLEFT", drawer.purpose, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    wrapAtWords(drawer.details, LfgButton.DRAWER_WIDTH - 2 * pad - 48)
    -- Ask to join, or Whisper when the leader takes no asks.
    self.askButton = ui:Button(drawer, "Ask to join", "primary", function(button)
        owner:askOrWhisper(button, button.listing)
    end)
    self.askButton:SetPoint("TOPLEFT", drawer.icon, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    self.askButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    drawer.empty = ui:Text(drawer, LfgButton.NONE_TEXT, "regular", "body", "muted")
    drawer.empty:SetPoint("TOPLEFT", drawer.heading, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    self.startButton = ui:Button(drawer, "Start a group", "secondary", function()
        owner:CloseDrawer()
        owner.options.onStartGroup()
    end)
    self.startButton:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, pad)
    self.startButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)

    -- Asking the leader: list the party (on the board's card), Not looking,
    -- or don't ask for a while.
    drawer.question = ui:Text(drawer, LfgButton.ASK_TEXT, "regular", "body", "text")
    drawer.question:SetPoint("TOPLEFT", drawer.heading, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    wrapAtWords(drawer.question, LfgButton.DRAWER_WIDTH - 2 * pad)
    -- The same Yes and No answer "fill the empty slot?".
    self.listButton = ui:Button(drawer, "Choose what it's for", "primary", function()
        local kind = drawer.kind
        owner:CloseDrawer(true)
        if kind == addon.LfgDrawerModel.SLOT then
            owner.options.onFillSlot(true)
        else
            owner.options.onListParty()
        end
    end)
    self.listButton:SetPoint("TOPLEFT", drawer.question, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    self.listButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    self.notLookingButton = ui:Button(drawer, "Not looking", "secondary", function()
        local kind = drawer.kind
        owner:CloseDrawer(true)
        if kind == addon.LfgDrawerModel.SLOT then
            owner.options.onFillSlot(false)
        else
            owner.options.onNotLooking()
        end
    end)
    self.notLookingButton:SetPoint("TOPLEFT", self.listButton, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    self.notLookingButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    self.snoozeButton = ui:Button(drawer, "Don't ask for 30 minutes", "secondary", function()
        owner:CloseDrawer(true)
        owner.options.onSnooze()
    end)
    self.snoozeButton:SetPoint("TOPLEFT", self.notLookingButton, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    self.snoozeButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    -- Someone left: what the open slot would be posted as.
    drawer.slotDetails = ui:Text(drawer, "", "regular", "small", "muted")
    drawer.slotDetails:SetPoint("TOPLEFT", drawer.question, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    drawer.slotDetails:SetWidth(LfgButton.DRAWER_WIDTH - 2 * pad)

    -- Your party: its purpose, size and needs, note, and its slots as the
    -- Your listing card shows them (role tiles with icons, open ones in
    -- color, filled ones grey).
    drawer.party = ui:Text(drawer, "", "semibold", "title", "text")
    drawer.party:SetPoint("TOPLEFT", drawer.heading, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    wrapAtWords(drawer.party, LfgButton.DRAWER_WIDTH - 2 * pad)
    drawer.partyDetails = ui:Text(drawer, "", "regular", "small", "muted")
    drawer.partyDetails:SetPoint("TOPLEFT", drawer.party, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    wrapAtWords(drawer.partyDetails, LfgButton.DRAWER_WIDTH - 2 * pad)
    drawer.note = ui:Text(drawer, "", "italic", "small", "muted")
    drawer.note:SetPoint("TOPLEFT", drawer.partyDetails, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    wrapAtWords(drawer.note, LfgButton.DRAWER_WIDTH - 2 * pad)
    drawer.roleTiles = ui:RoleRow(drawer, LfgButton.TILE_SIZE)
    drawer.roleTiles[1]:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, pad)
    drawer.anyTiles = {}
    local index
    for index = 1, 5 do
        drawer.anyTiles[index] = ui:RoleTile(drawer, "any", LfgButton.TILE_SIZE, LfgButton.TILE_SIZE)
        drawer.anyTiles[index]:SetPoint("LEFT", drawer.roleTiles[index], "LEFT", 0, 0)
    end
    drawer.raidTile = ui:RoleTile(drawer, "any", LfgButton.TILE_SIZE, LfgButton.TILE_SIZE)
    drawer.raidTile:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, pad)
    -- Ask in guild, over the tiles, while the listed party has open slots:
    -- types the line (with the note) into guild chat for the player to send.
    self.askGuildButton = ui:Button(drawer, LfgButton.ASK_GUILD_TEXT, "secondary", function(button)
        if button.line ~= nil and owner.options.onAskInGuild ~= nil then
            owner:CloseDrawer()
            owner.options.onAskInGuild(button.line)
        end
    end)
    self.askGuildButton:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, pad + LfgButton.TILE_SIZE + Theme.SPACING.s)
    self.askGuildButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    self.askGuildButton:Hide()
    -- Edit and Stop looking (the board's word for it, with its tooltip),
    -- side by side, on the player's own listing.
    local half = (LfgButton.DRAWER_WIDTH - 2 * pad - Theme.SPACING.xs) / 2
    self.editListingButton = ui:Button(drawer, "Edit", "secondary", function()
        owner:CloseDrawer()
        if owner.options.onEditListing ~= nil then
            owner.options.onEditListing()
        end
    end)
    self.editListingButton:SetWidth(half)
    self.endListingButton = ui:Button(drawer, "Stop looking", "secondary", function()
        owner:CloseDrawer()
        if owner.options.onEndListing ~= nil then
            owner.options.onEndListing()
        end
    end)
    ui:Hint(self.endListingButton, "Your party stays together but shows as Playing.")
    self.endListingButton:SetWidth(half)
    self.endListingButton:SetPoint("LEFT", self.editListingButton, "RIGHT", Theme.SPACING.xs, 0)
    self.editListingButton:Hide()
    self.endListingButton:Hide()
    -- Find guildmates, over Edit and End listing, as the board's party card
    -- has it; greyed out with why, in the tooltip, when it can't be used.
    self.findButton = ui:Button(drawer, "Find guildmates", "secondary", function()
        owner:CloseDrawer()
        if owner.options.onFindGuildmates ~= nil then
            owner.options.onFindGuildmates()
        end
    end)
    self.findButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    local environment = self.environment
    self.findButton:HookScript("OnEnter", function(button)
        local tooltip = environment and environment.GameTooltip
        if not button.active and button.reason ~= nil and type(tooltip) == "table" then
            tooltip:SetOwner(button, "ANCHOR_RIGHT")
            tooltip:SetText(button.reason, 1, 1, 1, 1, true)
            tooltip:Show()
        end
    end)
    self.findButton:HookScript("OnLeave", function()
        local tooltip = environment and environment.GameTooltip
        if type(tooltip) == "table" then
            tooltip:Hide()
        end
    end)
    self.findButton:Hide()

    -- Show Nearby (the button's menu): the guildmates in the player's zone,
    -- as the board's Nearby tab lists them, each name opening a menu to
    -- whisper them. Its rows are made as they're needed.
    drawer.nearby = ui:frame("Frame", drawer)
    drawer.nearby:SetPoint("TOPLEFT", drawer.heading, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    drawer.nearby:SetPoint("BOTTOMRIGHT", drawer, "BOTTOMRIGHT", -pad, pad)
    drawer.nearby.rows = {}
    drawer.nearby.empty = ui:Text(drawer.nearby, LfgButton.NEARBY_NONE_TEXT, "regular", "body", "muted")
    drawer.nearby.empty:SetPoint("TOPLEFT", drawer.nearby, "TOPLEFT", 0, 0)
    drawer.nearby.more = ui:Text(drawer.nearby, "", "regular", "small", "label")
    drawer.nearby:Hide()
    self.nameMenu = ui:ContextMenu(self.environment.UIParent)

    -- It slides in from the button's side where the client can animate.
    if type(drawer.CreateAnimationGroup) == "function" then
        local ok, group = pcall(drawer.CreateAnimationGroup, drawer)
        if ok and type(group) == "table" and type(group.CreateAnimation) == "function" then
            local slide = group:CreateAnimation("Translation")
            if type(slide) == "table" then
                slide:SetOffset(-LfgButton.SLIDE, 0)
                slide:SetDuration(0.15)
                self.drawerSlide = group
            end
        end
    end
    drawer:Hide()
    self.drawer = drawer
    self.toasts = {}
end

-- One Ask to join request under the drawer, made on first use: who, their
-- role and level, and Invite and Decline.
function Button:toast(index)
    local toast = self.toasts[index]
    if toast ~= nil then
        return toast
    end
    local ui, owner, pad = self.ui, self, Theme.SPACING.m
    toast = ui:Panel(self.environment.UIParent, { fill = "background", border = "gold" })
    toast:SetFrameStrata("MEDIUM")
    toast:SetSize(LfgButton.DRAWER_WIDTH, LfgButton.TOAST_HEIGHT)
    toast:EnableMouse(true)
    if index == 1 then
        toast:SetPoint("TOPRIGHT", self.drawer, "BOTTOMRIGHT", 0, -LfgButton.DRAWER_GAP)
    else
        toast:SetPoint("TOPRIGHT", self.toasts[index - 1], "BOTTOMRIGHT", 0, -LfgButton.DRAWER_GAP)
    end
    toast.name = ui:Text(toast, "", "semibold", "body", "text")
    toast.name:SetPoint("TOPLEFT", toast, "TOPLEFT", pad, -pad)
    toast.details = ui:Text(toast, "", "regular", "small", "muted")
    toast.details:SetPoint("TOPLEFT", toast.name, "BOTTOMLEFT", 0, -2)
    local half = (LfgButton.DRAWER_WIDTH - 2 * pad - Theme.SPACING.s) / 2
    toast.invite = ui:Button(toast, "Invite", "primary", function()
        owner.options.onInvite(toast.request)
    end)
    toast.invite:SetWidth(half)
    toast.invite:SetPoint("BOTTOMLEFT", toast, "BOTTOMLEFT", pad, pad)
    toast.decline = ui:Button(toast, "Decline", "secondary", function()
        owner.options.onDecline(toast.request)
    end)
    toast.decline:SetWidth(half)
    toast.decline:SetPoint("BOTTOMRIGHT", toast, "BOTTOMRIGHT", -pad, pad)
    toast:Hide()
    self.toasts[index] = toast
    return toast
end

-- "Healer, 24" for a request with a role; "Level 24, wants to join"
-- without one.
local function requestDetails(request)
    if request.role ~= nil then
        return (addon.Widgets.ROLE_LABELS[request.role] or request.role) .. ", " .. tostring(request.level)
    end
    return "Level " .. tostring(request.level) .. ", wants to join"
end

-- The requests stacked under the open drawer.
function Button:refreshToasts()
    local requests = self.view and self.view.requests or {}
    local open = self:DrawerOpen()
    local index
    for index = 1, math.max(#requests, #self.toasts) do
        local request = requests[index]
        if request ~= nil and open then
            local toast = self:toast(index)
            toast.request = request
            local color = self.options.classColor and self.options.classColor(request.classToken) or nil
            toast.name:SetText(type(color) == "string" and ("|c" .. color .. request.name .. "|r") or request.name)
            toast.details:SetText(requestDetails(request))
            toast:Show()
        elseif self.toasts[index] ~= nil then
            self.toasts[index].request = false
            self.toasts[index]:Hide()
        end
    end
end

-- Ask to join `listing`: a dungeon's asks pick one open role the current
-- character can play (from a menu when there's a choice). A leader who
-- takes no asks is whispered instead.
function Button:askOrWhisper(anchor, listing)
    if type(listing) ~= "table" then
        return
    end
    if not listing.acceptsAsk then
        self.options.onWhisper(listing.sender)
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
        local items = {}
        local index
        for index = 1, #roles do
            local role = roles[index]
            items[index] = { label = "Ask as " .. (addon.Widgets.ROLE_LABELS[role] or role), onClick = function()
                self.options.onAsk(listing, role)
            end }
        end
        self.menu:Open(anchor, items)
    end
end

local function setShown(frame, shown)
    if shown then
        frame:Show()
    else
        frame:Hide()
    end
end

-- "Healer, DPS" for a dungeon's open roles, or the players still wanted.
local function needs(listing)
    if listing.kind == "dungeon" then
        local names = {}
        local index
        for index = 1, #(listing.openRoles or {}) do
            names[index] = addon.Widgets.ROLE_LABELS[listing.openRoles[index]] or listing.openRoles[index]
        end
        return #names > 0 and ("needs " .. table.concat(names, ", ")) or nil
    end
    if listing.kind == "raid" then
        return nil
    end
    local wanted = (listing.maxSize or 0) - (listing.size or 0)
    return wanted > 0 and ("needs " .. wanted) or nil
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

local function sizeText(listing)
    if listing.kind == "raid" then
        return listing.size .. " players"
    end
    return listing.size .. "/" .. listing.maxSize
end

-- Redraws the drawer from the last view.
function Button:refreshDrawer()
    local drawer, view = self.drawer, self.view
    if drawer == nil or view == nil then
        return
    end
    if self.nearbyMode then
        self:refreshNearby()
        self:refreshToasts()
        return
    end
    drawer.nearby:Hide()
    local top = view.top or { kind = addon.LfgDrawerModel.NONE }
    local kind = top.kind
    drawer.kind = kind
    local slot = kind == addon.LfgDrawerModel.SLOT
    local gate = kind == addon.LfgDrawerModel.GATE or slot
    local asking = kind == addon.LfgDrawerModel.ASK or gate
    local headings = { [addon.LfgDrawerModel.PARTY] = top.party ~= nil and top.party.solo and "Open to the guild"
        or "Your party", [addon.LfgDrawerModel.ASK] = "Open to the guild?",
        [addon.LfgDrawerModel.GATE] = "Open to the guild?", [addon.LfgDrawerModel.SLOT] = "Your party" }
    drawer.heading:SetText(Theme.Label(headings[kind] or "New for you"))
    -- Asking whether to list a party with outsiders, or to fill an empty
    -- slot, is a plain yes or no.
    drawer.question:SetText(slot and LfgButton.SLOT_TEXT or kind == addon.LfgDrawerModel.GATE and LfgButton.GATE_TEXT
        or LfgButton.ASK_TEXT)
    self.listButton:SetLabel(gate and "Yes" or "Choose what it's for")
    self.notLookingButton:SetLabel(gate and "No" or "Not looking")
    setShown(drawer.question, asking)
    setShown(drawer.slotDetails, slot)
    self.listButton:ClearAllPoints()
    self.listButton:SetPoint("TOPLEFT", slot and drawer.slotDetails or drawer.question, "BOTTOMLEFT", 0,
        -Theme.SPACING.s)
    self.listButton:SetPoint("RIGHT", drawer, "RIGHT", -Theme.SPACING.m, 0)
    setShown(self.listButton, asking)
    setShown(self.notLookingButton, asking)
    setShown(self.snoozeButton, asking and not gate)
    if slot then
        -- Posted as: the purpose and the open role, where they're known.
        local info = top.party or {}
        local role = info.slotRole and ("needs " .. (addon.Widgets.ROLE_LABELS[info.slotRole] or info.slotRole))
        drawer.slotDetails:SetText(join({ info.label or "Playing", role }))
    end
    local newest, party = kind == addon.LfgDrawerModel.NEWEST, kind == addon.LfgDrawerModel.PARTY
    setShown(drawer.icon, newest)
    setShown(drawer.purpose, newest)
    setShown(drawer.details, newest)
    setShown(self.askButton, newest)
    setShown(drawer.empty, kind == addon.LfgDrawerModel.NONE)
    setShown(self.startButton, not party and not asking)
    setShown(drawer.party, party)
    setShown(drawer.partyDetails, party)
    setShown(drawer.note, party)
    local guildLine = party and top.party ~= nil and top.party.guildLine or nil
    self.askGuildButton.line = guildLine
    local asksGuild = guildLine ~= nil and self.options.onAskInGuild ~= nil
    setShown(self.askGuildButton, asksGuild)
    -- Placed, and its words set, each time it shows: placed only once, at
    -- build, it showed with no text in game.
    local pad = Theme.SPACING.m
    if asksGuild then
        self.askGuildButton:ClearAllPoints()
        self.askGuildButton:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, pad + LfgButton.TILE_SIZE + Theme.SPACING.s)
        self.askGuildButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
        self.askGuildButton:SetLabel(LfgButton.ASK_GUILD_TEXT)
    end
    -- Edit and End listing go over Ask in guild, or over the tiles.
    local own = party and top.party ~= nil and top.party.own == true
    setShown(self.editListingButton, own)
    setShown(self.endListingButton, own)
    local above = pad + LfgButton.TILE_SIZE + Theme.SPACING.s
    if asksGuild then
        above = above + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.xs
    end
    self.editListingButton:ClearAllPoints()
    self.editListingButton:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, above)
    local find = party and top.party ~= nil and top.party.find or nil
    local finds = find ~= nil and self.options.onFindGuildmates ~= nil
    setShown(self.findButton, finds)
    if finds then
        self.findButton.reason = find.reason
        self.findButton:SetActive(find.reason == nil)
        if own then
            above = above + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.xs
        end
        self.findButton:ClearAllPoints()
        self.findButton:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, above)
        self.findButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    end
    local index
    for index = 1, 5 do
        drawer.roleTiles[index]:Hide()
        drawer.anyTiles[index]:Hide()
    end
    drawer.raidTile:Hide()
    if newest then
        local listing = top.listing
        local icon = listing.kind == "dungeon"
            and (self.options.dungeonIcon and self.options.dungeonIcon(listing.purpose) or Theme.TEXTURES.dungeon)
            or Theme.TEXTURES.tree
        drawer.icon:SetTexture(icon)
        drawer.iconTexture = icon
        drawer.purpose:SetText(addon.LfgListing.Label(listing.kind, listing.purpose))
        drawer.details:SetText(join({ listing.leader, sizeText(listing), needs(listing) }))
        self.askButton.listing = listing
        if listing.acceptsAsk then
            local label, active = addon.LfgBoard.AskButton(top.request)
            self.askButton:SetLabel(label)
            self.askButton:SetActive(active)
        else
            self.askButton:SetLabel("Whisper " .. listing.leader)
            self.askButton:SetActive(true)
        end
    elseif party then
        local info = top.party
        drawer.party:SetText(info.label or "Playing")
        drawer.partyDetails:SetText(join({ sizeText(info), needs(info) }))
        drawer.note:SetText(info.note or "")
        if info.kind == "dungeon" then
            -- Without the roster (a party listed by someone else), only
            -- the roles it asks for are open.
            addon.Widgets.ShowRoles(drawer.roleTiles, info.members or {}, info.openRoles)
        elseif info.kind == "raid" then
            drawer.raidTile:SetFilled((info.size or 0) >= (info.maxSize or 0))
            drawer.raidTile:Show()
        else
            for index = 1, 5 do
                drawer.anyTiles[index]:SetFilled(index <= (info.size or 0))
                drawer.anyTiles[index]:Show()
            end
        end
    end
    -- Text wrapped onto more lines than the drawer's height allows for
    -- (a long zone or dungeon name, a long note) makes it taller, and what
    -- sits under it moves down.
    local extra = 0
    if newest then
        extra = extraHeight(drawer.purpose, 1) + extraHeight(drawer.details, 1)
        self.askButton:ClearAllPoints()
        self.askButton:SetPoint("TOPLEFT", drawer.icon, "BOTTOMLEFT", 0, -Theme.SPACING.s - extra)
        self.askButton:SetPoint("RIGHT", drawer, "RIGHT", -Theme.SPACING.m, 0)
    elseif party then
        extra = extraHeight(drawer.party, 1) + extraHeight(drawer.partyDetails, 1) + extraHeight(drawer.note, 1)
    end
    if party and asksGuild then
        extra = extra + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.s
    end
    if own then
        extra = extra + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.xs
    end
    if finds then
        extra = extra + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.xs
    end
    local height = (LfgButton.DRAWER_HEIGHTS[kind] or LfgButton.DRAWER_HEIGHTS.none) + extra
    if party then
        -- Where the game can measure it, the party's text decides: its
        -- buttons and tiles sit just under its last line, with no gap.
        local measured = self:partyHeight(asksGuild, own, finds)
        height = measured or height
    end
    drawer:SetHeight(height)
    self:refreshToasts()
end

-- The party section's height from the game's measure of its text: the
-- drawer's top to the last line shown (the note, else the details), then
-- the buttons over the tiles. Nil where the client can't measure it.
function Button:partyHeight(asksGuild, own, finds)
    local drawer = self.drawer
    local last = drawer.note
    local note = type(last.GetText) == "function" and last:GetText() or nil
    if type(note) ~= "string" or note == "" then
        last = drawer.partyDetails
    end
    local top = type(drawer.GetTop) == "function" and drawer:GetTop() or nil
    local bottom = type(last.GetBottom) == "function" and last:GetBottom() or nil
    if type(top) ~= "number" or type(bottom) ~= "number" or top <= bottom then
        return nil
    end
    local pad, button = Theme.SPACING.m, addon.Widgets.BUTTON_HEIGHT
    -- From the drawer's bottom: the tiles, then each button shown.
    local stack = pad + LfgButton.TILE_SIZE
    if asksGuild or own or finds then
        stack = stack + Theme.SPACING.s
    end
    local rows = (asksGuild and 1 or 0) + (own and 1 or 0) + (finds and 1 or 0)
    if rows > 0 then
        stack = stack + rows * button + (rows - 1) * Theme.SPACING.xs
    end
    return (top - bottom) + Theme.SPACING.m + stack
end

-- Show Nearby: the drawer lists the guildmates in the player's zone in
-- place of its usual contents, until it's closed.
function Button:ShowNearby()
    if self.drawer == nil then
        return
    end
    self.nearbyMode = true
    if self:DrawerOpen() then
        self:refreshDrawer()
    else
        self:OpenDrawer()
    end
end

-- The drawer's Nearby list: "Nearby in <zone>", then a guildmate per line,
-- their level in a column left of their name in class color; a click on a
-- name opens a menu to whisper them.
function Button:refreshNearby()
    local drawer, options, ui, owner = self.drawer, self.options, self.ui, self
    drawer.kind = "nearby"
    local hidden = { drawer.icon, drawer.purpose, drawer.details, drawer.empty, drawer.question, drawer.slotDetails,
        drawer.party, drawer.partyDetails, drawer.note, drawer.raidTile, self.askButton, self.startButton,
        self.listButton, self.notLookingButton, self.snoozeButton, self.askGuildButton, self.editListingButton,
        self.endListingButton, self.findButton }
    local index
    for index = 1, #hidden do
        hidden[index]:Hide()
    end
    for index = 1, 5 do
        drawer.roleTiles[index]:Hide()
        drawer.anyTiles[index]:Hide()
    end
    local nearby = options.nearby and options.nearby() or nil
    local people = nearby ~= nil and nearby.people or {}
    drawer.heading:SetText(Theme.Label(nearby ~= nil and ("Nearby in " .. nearby.zone) or "Nearby"))
    local list = drawer.nearby
    setShown(list.empty, #people == 0)
    local shown = math.min(#people, LfgButton.NEARBY_ROWS)
    for index = 1, math.max(shown, #list.rows) do
        local row = list.rows[index]
        if index <= shown then
            if row == nil then
                row = ui:frame("Button", list)
                row:SetHeight(LfgButton.NEARBY_ROW_HEIGHT)
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(index - 1) * LfgButton.NEARBY_ROW_HEIGHT)
                row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
                row.level = ui:Text(row, "", "regular", "small", "muted")
                row.level:SetWidth(LfgButton.LEVEL_WIDTH)
                row.level:SetJustifyH("RIGHT")
                row.level:SetPoint("LEFT", row, "LEFT", 0, 0)
                row.name = ui:Text(row, "", "regular", "body", "text")
                row.name:SetPoint("LEFT", row, "LEFT", LfgButton.LEVEL_WIDTH + Theme.SPACING.s, 0)
                row.index = index
                row:SetScript("OnClick", function(self)
                    local whisper = self.whisper
                    owner.nameMenuFor = { row = self, whisper = whisper }
                    owner.nameMenu:Open(self, {
                        { label = "Whisper", onClick = function()
                            if whisper then
                                options.onWhisper(whisper)
                            end
                        end },
                    }, self.title)
                end)
                list.rows[index] = row
            end
            local person = people[index]
            local color = options.classColor and options.classColor(person.classToken) or nil
            row.title = type(color) == "string" and ("|c" .. color .. person.name .. "|r") or person.name
            row.whisper = person.whisper or person.name
            row.level:SetText(person.level ~= nil and tostring(person.level) or "")
            row.name:SetText(row.title)
            row:Show()
        elseif row ~= nil then
            row:Hide()
        end
    end
    -- A name's menu goes once its row is hidden or shows someone else.
    local named = self.nameMenuFor
    if named ~= nil and self.nameMenu:IsOpen()
        and (named.row.index > shown or named.row.whisper ~= named.whisper)
    then
        self.nameMenu:Close()
        self.nameMenuFor = nil
    end
    local more = #people - shown
    list.more:ClearAllPoints()
    list.more:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -shown * LfgButton.NEARBY_ROW_HEIGHT)
    list.more:SetText(more > 0 and ("and " .. more .. " more") or "")
    list:Show()
    local pad = Theme.SPACING.m
    local rows = math.max(shown, 1) * LfgButton.NEARBY_ROW_HEIGHT + (more > 0 and 16 or 0)
    drawer:SetHeight(pad + 14 + Theme.SPACING.s + rows + pad)
end

-- The drawer opens to the button's left, or to its right when the button
-- sits too near the screen's left edge for it.
function Button:anchorDrawer()
    local left = type(self.button.GetLeft) == "function" and self.button:GetLeft() or nil
    local right = type(left) == "number" and left < LfgButton.DRAWER_WIDTH + LfgButton.DRAWER_GAP
    self.drawer:ClearAllPoints()
    if right then
        self.drawer:SetPoint("TOPLEFT", self.button, "TOPRIGHT", LfgButton.DRAWER_GAP, 0)
    else
        self.drawer:SetPoint("TOPRIGHT", self.button, "TOPLEFT", -LfgButton.DRAWER_GAP, 0)
    end
end

-- Opens the drawer, or closes it when open.
function Button:ToggleDrawer()
    if self:DrawerOpen() then
        self:CloseDrawer()
    else
        self:OpenDrawer()
    end
end

function Button:OpenDrawer()
    if self.drawer == nil then
        return
    end
    self.drawerOpen = true
    self:anchorDrawer()
    self:refreshDrawer()
    self.drawer:Show()
    if self.drawerSlide ~= nil then
        self.drawerSlide:Stop()
        self.drawerSlide:Play()
    end
    if self.options.onDrawerOpened ~= nil then
        self.options.onDrawerOpened()
    end
end

-- Closes the drawer. Closing it on the leader's question without an answer
-- (`answered` false) is Not looking.
function Button:CloseDrawer(answered)
    local wasAsking = self:DrawerOpen() and self.drawer ~= nil
        and (self.drawer.kind == addon.LfgDrawerModel.ASK or self.drawer.kind == addon.LfgDrawerModel.GATE)
    self.drawerOpen = false
    -- Show Nearby lasts until the drawer closes.
    self.nearbyMode = false
    if self.nameMenu ~= nil then
        self.nameMenu:Close()
    end
    if self.drawer ~= nil then
        self.drawer:Hide()
        self:refreshToasts()
    end
    if wasAsking and not answered and self.options.onNotLooking ~= nil then
        self.options.onNotLooking()
    end
end

function Button:DrawerOpen()
    return self.drawerOpen == true
end

-- Shows `view` (LfgDrawerModel:Update's): the count, the glow, one pulse
-- per fresh listing, and the drawer's contents.
function Button:Update(view)
    self.view = view
    if self.button == nil then
        return
    end
    self.count:SetCount(view.count)
    self.glow:SetGlow(view.glow)
    if view.glow == "gold" then
        local index
        for index = 1, #(view.fresh or {}) do
            self.glow:Pulse()
        end
    end
    self:refreshDrawer()
end

-- The rest --------------------------------------------------------------------------

function Button:place()
    local button = self.button
    local parent = self.environment.UIParent
    local saved = self.options.loadPosition and self.options.loadPosition() or nil
    button:ClearAllPoints()
    if type(saved) == "table" and pcall(button.SetPoint, button, saved.point, parent, saved.relativePoint, saved.x,
        saved.y)
    then
        return
    end
    local default = LfgButton.DEFAULT_POINT
    button:ClearAllPoints()
    button:SetPoint(default.point, parent, default.relativePoint, default.x, default.y)
end

function Button:savePosition()
    if self.options.savePosition == nil then
        return
    end
    local point, _, relativePoint, x, y = self.button:GetPoint(1)
    if type(point) == "string" and type(x) == "number" and type(y) == "number" then
        self.options.savePosition({ point = point, relativePoint = relativePoint or point, x = x, y = y })
    end
end

-- The right-click menu, under the button.
function Button:OpenMenu()
    local options, owner = self.options, self
    self.menu:Open(self.button, {
        { label = "Open Guild LFG Board", onClick = function()
            options.onOpenBoard()
        end },
        { label = "Show Nearby", onClick = function()
            owner:ShowNearby()
        end },
        { label = "Hide LFG button", onClick = function()
            options.onHide()
        end },
    })
end

-- Shows or hides the button as the setting says, making it the first time
-- it shows. True when it's showing.
function Button:Refresh()
    local shown = self.options.shown() == true
    if not shown then
        if self.button ~= nil then
            self.menu:Close()
            self:CloseDrawer()
            self.button:Hide()
        end
        self.showing = false
        return false
    end
    if self.button == nil and not pcall(self.build, self) then
        self.button = nil
        self.showing = false
        return false
    end
    self.button:Show()
    self.showing = true
    return true
end

-- Whether the button is on screen.
function Button:IsShowing()
    return self.showing == true
end
