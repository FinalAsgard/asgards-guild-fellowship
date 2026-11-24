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
    DRAWER_HEIGHTS = { newest = 156, none = 96, party = 132, ask = 178, gate = 146 },
    NONE_TEXT = "No groups for you right now",
    ASK_TEXT = "You're leading a party. List it on the Guild LFG Board?",
    GATE_TEXT = "Your party has players from outside the guild. List it on the Guild LFG Board?",
    -- An Ask to join request under the drawer.
    TOAST_HEIGHT = 74,
}
addon.LfgButton = LfgButton

local DOT = " \194\183 "

local Button = {}
Button.__index = Button

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
--   askRoles        function(listing) -> the open roles the current
--                   character can ask to join a dungeon listing as
--   onAsk           function(listing, role?): Ask to join
--   onWhisper       function(name): whispers a leader
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
    drawer.purpose:SetWidth(LfgButton.DRAWER_WIDTH - 2 * pad - 48)
    drawer.details = ui:Text(drawer, "", "regular", "small", "muted")
    drawer.details:SetPoint("TOPLEFT", drawer.purpose, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    drawer.details:SetWidth(LfgButton.DRAWER_WIDTH - 2 * pad - 48)
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
    drawer.question:SetWidth(LfgButton.DRAWER_WIDTH - 2 * pad)
    drawer.question:SetJustifyH("LEFT")
    self.listButton = ui:Button(drawer, "Choose what it's for", "primary", function()
        owner:CloseDrawer(true)
        owner.options.onListParty()
    end)
    self.listButton:SetPoint("TOPLEFT", drawer.question, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    self.listButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    self.notLookingButton = ui:Button(drawer, "Not looking", "secondary", function()
        owner:CloseDrawer(true)
        owner.options.onNotLooking()
    end)
    self.notLookingButton:SetPoint("TOPLEFT", self.listButton, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    self.notLookingButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)
    self.snoozeButton = ui:Button(drawer, "Don't ask for 30 minutes", "secondary", function()
        owner:CloseDrawer(true)
        owner.options.onSnooze()
    end)
    self.snoozeButton:SetPoint("TOPLEFT", self.notLookingButton, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    self.snoozeButton:SetPoint("RIGHT", drawer, "RIGHT", -pad, 0)

    -- Your party: its purpose, size and needs, note, and filled slots.
    drawer.party = ui:Text(drawer, "", "semibold", "title", "text")
    drawer.party:SetPoint("TOPLEFT", drawer.heading, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    drawer.partyDetails = ui:Text(drawer, "", "regular", "small", "muted")
    drawer.partyDetails:SetPoint("TOPLEFT", drawer.party, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    drawer.note = ui:Text(drawer, "", "italic", "small", "muted")
    drawer.note:SetPoint("TOPLEFT", drawer.partyDetails, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    drawer.note:SetWidth(LfgButton.DRAWER_WIDTH - 2 * pad)
    drawer.slots = {}
    local slotWidth = (LfgButton.DRAWER_WIDTH - 2 * pad - 4 * 4) / 5
    local index
    for index = 1, 5 do
        local slot = ui:Panel(drawer, { radius = Theme.RADIUS.small, fill = "raised", border = false })
        slot:SetSize(slotWidth, 8)
        if index == 1 then
            slot:SetPoint("BOTTOMLEFT", drawer, "BOTTOMLEFT", pad, pad)
        else
            slot:SetPoint("LEFT", drawer.slots[index - 1], "RIGHT", 4, 0)
        end
        drawer.slots[index] = slot
    end

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
    local top = view.top or { kind = addon.LfgDrawerModel.NONE }
    local kind = top.kind
    drawer.kind = kind
    drawer:SetHeight(LfgButton.DRAWER_HEIGHTS[kind] or LfgButton.DRAWER_HEIGHTS.none)
    local gate = kind == addon.LfgDrawerModel.GATE
    local asking = kind == addon.LfgDrawerModel.ASK or gate
    local headings = { [addon.LfgDrawerModel.PARTY] = "Your party", [addon.LfgDrawerModel.ASK] = "List your party?",
        [addon.LfgDrawerModel.GATE] = "List your party?" }
    drawer.heading:SetText(Theme.Label(headings[kind] or "New for you"))
    -- Asking whether to list a party with outsiders is a plain yes or no.
    drawer.question:SetText(gate and LfgButton.GATE_TEXT or LfgButton.ASK_TEXT)
    self.listButton:SetLabel(gate and "Yes" or "Choose what it's for")
    self.notLookingButton:SetLabel(gate and "No" or "Not looking")
    setShown(drawer.question, asking)
    setShown(self.listButton, asking)
    setShown(self.notLookingButton, asking)
    setShown(self.snoozeButton, asking and not gate)
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
    local index
    for index = 1, #drawer.slots do
        setShown(drawer.slots[index], party)
    end
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
        drawer.party:SetText(info.label or "Not listed")
        drawer.partyDetails:SetText(join({ sizeText(info), needs(info) }))
        drawer.note:SetText(info.note or "")
        for index = 1, #drawer.slots do
            local filled = index <= math.min(info.size or 0, 5)
            drawer.slots[index].filled = filled
            drawer.slots[index]:SetFill(filled and "green" or "raised")
        end
    end
    self:refreshToasts()
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
    local options = self.options
    self.menu:Open(self.button, {
        { label = "Open Guild LFG Board", onClick = function()
            options.onOpenBoard()
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
