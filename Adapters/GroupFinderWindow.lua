local _, addon = ...

-- The Group Finder's own window, separate from the master frame, built with
-- the Details! Framework's simple panel (draggable, with a close button, and
-- Escape closes it). It remembers where it was dropped, across reloads and
-- on every character.
--
-- With no group going, it shows the dungeon picker: the dungeons that fit
-- the character's level first, and the rest behind "Show all". Picking one
-- starts the group and shows its slots (1 tank, 1 healer, 3 DPS) filled
-- from the party, with Tank/Healer/DPS buttons for each party member the
-- game hasn't assigned a role, "Group complete" once all five are filled,
-- and Change dungeon and End group buttons. Closing the window keeps the
-- group. While any role is open, Ask in guild offers a ready-made line for
-- guild chat, and posts it only once the organizer confirms.
--
-- Along the bottom, always: the guildmates whose add-on replied to the
-- last ask, available or not, and a Do Not Disturb check box.
--
-- Beside the slots, for each role still open, the online guildmates who
-- could fill it (GroupCandidates). The dungeon picker shows, for each
-- dungeon, how many online guildmates could fill tank, healer and DPS.
-- Add-on users get a Request button (Cancel while their request is
-- pending), and their request's state beside their name. An accepted
-- invitee's slot reads "Waiting for <character> to log in" until that
-- character is online, then shows an Invite button; nothing is invited
-- without that click.
--
-- Like the other adapters, it reaches the game only through the client's
-- environment (CreateFrame, UIParent) and the framework, so specs can draw
-- it with fake frames.
local GroupFinderWindow = {
    WIDTH = 760,
    -- The picker and the slots take the left; suggestions the right.
    LEFT_WIDTH = 380,
    SUGGESTION_HEIGHT = 18,
    REQUEST_WIDTH = 64,
    HEIGHT = 470,
    PADDING = 12,
    ROW_HEIGHT = 20,
    PARTY_ROW_HEIGHT = 24,
    -- Where the dungeon list and the slots start, below the title bar and
    -- the dungeon's heading.
    LIST_TOP = 86,
    -- Room along the bottom for the replies and Do Not Disturb.
    FOOTER_HEIGHT = 64,
    CHECK_SIZE = 24,
    BUTTON_HEIGHT = 20,
    ROLE_BUTTON_WIDTH = 56,
    STRATA = "HIGH",
}
addon.GroupFinderWindow = GroupFinderWindow

local Window = {}
Window.__index = Window

-- "The Deadmines (17–26)".
function GroupFinderWindow.Label(dungeon)
    return dungeon.name .. " (" .. dungeon.minLevel .. "–" .. dungeon.maxLevel .. ")"
end

-- "Hammer (42, not in guild)".
function GroupFinderWindow.MemberLabel(member)
    local details = {}
    if member.level ~= nil then
        table.insert(details, tostring(member.level))
    end
    if not member.inGuild then
        table.insert(details, "not in guild")
    end
    if #details == 0 then
        return member.name
    end
    return member.name .. " (" .. table.concat(details, ", ") .. ")"
end

-- options:
--   dungeons()          the DungeonCatalog to pick from, read on every open
--   playerLevel()       the character's level, or nil
--   session             the GroupSession
--   roles               the client's RoleCatalog
--   syncParty()         hands the current party to the session
--   replies()           the guildmates who replied to the last ask, each
--                       { sender, available } (GroupAvailability)
--   dnd                 { get() -> boolean, set(boolean) }: Do Not Disturb
--   candidates()        a GroupCandidates for the guild as it is now, or nil
--   postToGuild(text)   posts a line to guild chat
--   request(entry)      asks a suggested player (a GroupCandidates entry)
--                       to join
--   cancelRequest(id)   withdraws a pending request
--   isOnline(key)       whether a guild character is online now
--   invite(key)         sends the game's party invite to that character
--   loadAnchor()        the saved position ({ point, x, y }), or nil
--   saveAnchor(anchor)  saves a new one
-- Returns nil and the reason when the framework is missing or can't build
-- the window.
function GroupFinderWindow.Create(client, options)
    local framework = client:GetGlobal("DetailsFramework")
    if type(framework) ~= "table" or type(framework.CreateSimplePanel) ~= "function" then
        return nil, "the Details! Framework isn't loaded"
    end
    local window = setmetatable({
        environment = client.environment,
        framework = framework,
        dungeons = options.dungeons,
        playerLevel = options.playerLevel,
        session = options.session,
        roles = options.roles,
        syncParty = options.syncParty or function() end,
        replies = options.replies or function()
            return {}
        end,
        dnd = options.dnd,
        candidates = options.candidates or function()
            return nil
        end,
        suggestionLines = {},
        postToGuild = options.postToGuild or function() end,
        request = options.request or function() end,
        cancelRequest = options.cancelRequest or function() end,
        isOnline = options.isOnline or function()
            return false
        end,
        invite = options.invite or function() end,
        suggestionButtons = {},
        loadAnchor = options.loadAnchor or function() return nil end,
        saveAnchor = options.saveAnchor or function() end,
        showAll = false,
        choosing = false,
        rows = {},
        slotRows = {},
        partyRows = {},
    }, Window)
    local ok, reason = pcall(window.build, window)
    if not ok then
        return nil, tostring(reason)
    end
    return window
end

-- Puts the window where it was last dropped, else in the middle of the
-- screen.
function Window:place()
    local panel, parent = self.panel, self.environment.UIParent
    local ok, saved = pcall(self.loadAnchor)
    panel:ClearAllPoints()
    if ok and type(saved) == "table"
        and pcall(panel.SetPoint, panel, saved.point, parent, saved.point, saved.x, saved.y)
    then
        return
    end
    panel:ClearAllPoints()
    panel:SetPoint("CENTER", parent, "CENTER", 0, 0)
end

-- Saves where the window was dropped, as its top-left corner's offset from
-- the screen's top-left.
function Window:saveCurrent()
    pcall(function()
        local parent = self.environment.UIParent
        local left, top = self.panel:GetLeft(), self.panel:GetTop()
        local parentTop = parent:GetTop()
        if type(left) ~= "number" or type(top) ~= "number" or type(parentTop) ~= "number" then
            return
        end
        local position = { point = "TOPLEFT", x = left, y = top - parentTop }
        self.panel:ClearAllPoints()
        self.panel:SetPoint(position.point, parent, position.point, position.x, position.y)
        self.saveAnchor(position)
    end)
end

function Window:button(parent, text, width, onClick)
    local made = self.environment.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    made:SetWidth(width)
    made:SetHeight(GroupFinderWindow.BUTTON_HEIGHT)
    made:SetText(text)
    made:SetScript("OnClick", onClick)
    return made
end

-- A frame down the panel's left, holding one view.
function Window:view()
    local frame = self.environment.CreateFrame("Frame", nil, self.panel)
    frame:SetPoint("TOPLEFT", self.panel, "TOPLEFT", 0, 0)
    frame:SetPoint("BOTTOMLEFT", self.panel, "BOTTOMLEFT", 0, 0)
    frame:SetWidth(GroupFinderWindow.LEFT_WIDTH)
    return frame
end

-- The suggestions column, right of the slots.
function Window:buildSuggestions()
    local createFrame = self.environment.CreateFrame
    local padding = GroupFinderWindow.PADDING
    local column = createFrame("Frame", nil, self.panel)
    column:SetPoint("TOPLEFT", self.panel, "TOPLEFT", GroupFinderWindow.LEFT_WIDTH, -60)
    column:SetPoint("BOTTOMRIGHT", self.panel, "BOTTOMRIGHT", -padding, padding + GroupFinderWindow.FOOTER_HEIGHT)
    self.suggestions = column
    local heading = column:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", column, "TOPLEFT", 0, 0)
    heading:SetText("Guildmates who could join")
    local scroll = createFrame("ScrollFrame", nil, column, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", column, "TOPLEFT", 0, -GroupFinderWindow.LIST_TOP + 60)
    scroll:SetPoint("BOTTOMRIGHT", column, "BOTTOMRIGHT", -22, 0)
    local list = createFrame("Frame", nil, scroll)
    list:SetWidth(GroupFinderWindow.WIDTH - GroupFinderWindow.LEFT_WIDTH - padding - 22)
    list:SetHeight(GroupFinderWindow.SUGGESTION_HEIGHT)
    scroll:SetScrollChild(list)
    self.suggestionList = list
end

-- The suggestions column's line `index`, made on first use.
function Window:suggestionLine(index)
    if self.suggestionLines[index] ~= nil then
        return self.suggestionLines[index]
    end
    local line = self.suggestionList:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line:SetPoint("TOPLEFT", self.suggestionList, "TOPLEFT", 0, -(index - 1) * GroupFinderWindow.SUGGESTION_HEIGHT)
    line:SetPoint("RIGHT", self.suggestionList, "RIGHT", -GroupFinderWindow.REQUEST_WIDTH - 4, 0)
    line:SetJustifyH("LEFT")
    if type(line.SetWordWrap) == "function" then
        line:SetWordWrap(false)
    end
    self.suggestionLines[index] = line
    local button = self:button(self.suggestionList, "Request", GroupFinderWindow.REQUEST_WIDTH, function()
        local item = self.suggestionButtons[index].item
        if item == nil then
            return
        end
        local request = self.session:RequestFor(item.player.id)
        if request ~= nil and request.state == addon.GroupSession.PENDING then
            pcall(self.cancelRequest, request.id)
        else
            pcall(self.request, item.player)
        end
        self:Refresh()
    end)
    button:SetHeight(GroupFinderWindow.SUGGESTION_HEIGHT)
    button:SetPoint("TOPRIGHT", self.suggestionList, "TOPRIGHT", 0, -(index - 1) * GroupFinderWindow.SUGGESTION_HEIGHT)
    self.suggestionButtons[index] = { button = button }
    return line
end

-- The lines the suggestions column shows: each open role's heading, then
-- its guildmates, or a line saying nobody fits. Each is { text, player }
-- (player only on a guildmate's line). `requestOf(playerId)`, when given,
-- adds the state of the player's newest request.
function GroupFinderWindow.SuggestionItems(lists, requestOf)
    local items = {}
    if #lists == 0 then
        return { { text = "Every role is filled." } }
    end
    local index
    for index = 1, #lists do
        table.insert(items, { text = "|cffffd100" .. addon.RoleCatalog.LABELS[lists[index].role] .. "|r" })
        local players = lists[index].players
        if #players == 0 then
            table.insert(items, { text = "  |cff9d9d9dNo one online fits.|r" })
        end
        local playerIndex
        for playerIndex = 1, #players do
            local player = players[playerIndex]
            local text = "  " .. addon.GroupCandidates.Describe(player)
            local request = requestOf and requestOf(player.id)
            if request ~= nil then
                text = text .. " |cff9d9d9d[" .. (GroupFinderWindow.STATE_LABELS[request.state] or request.state) .. "]|r"
            end
            table.insert(items, { text = text, player = player })
        end
    end
    return items
end

function GroupFinderWindow.SuggestionTexts(lists)
    local items = GroupFinderWindow.SuggestionItems(lists)
    local texts = {}
    local index
    for index = 1, #items do
        texts[index] = items[index].text
    end
    return texts
end

function Window:drawSuggestions(candidates, dungeon)
    local items = {}
    if candidates ~= nil and dungeon ~= nil then
        items = GroupFinderWindow.SuggestionItems(candidates:Suggestions(dungeon, self.session:OpenRoles()),
            function(playerId)
                return self.session:RequestFor(playerId)
            end)
    end
    local index
    for index = 1, #items do
        local line = self:suggestionLine(index)
        line:SetText(items[index].text)
        line:Show()
        local slot = self.suggestionButtons[index]
        local player = items[index].player
        slot.item = items[index]
        local request = player and self.session:RequestFor(player.id)
        if player == nil or not player.addon or (request ~= nil and request.state == addon.GroupSession.ACCEPTED) then
            slot.button:Hide()
        else
            local pending = request ~= nil and request.state == addon.GroupSession.PENDING
            slot.button:SetText(pending and "Cancel" or "Request")
            slot.button:Show()
        end
    end
    for index = #items + 1, #self.suggestionLines do
        self.suggestionLines[index]:Hide()
        self.suggestionButtons[index].item = nil
        self.suggestionButtons[index].button:Hide()
    end
    self.suggestionList:SetHeight(math.max(#items, 1) * GroupFinderWindow.SUGGESTION_HEIGHT)
end

-- How each request state reads beside a guildmate.
GroupFinderWindow.STATE_LABELS = {
    ["joined-elsewhere"] = "joined another group",
}

-- "T 2 · H 0 · D 5": how many online guildmates could fill each role.
function GroupFinderWindow.CountsText(counts)
    return "T " .. counts.tank .. " · H " .. counts.healer .. " · D " .. counts.dps
end

function Window:buildPicker()
    local createFrame = self.environment.CreateFrame
    local padding = GroupFinderWindow.PADDING
    local picker = self:view()
    self.picker = picker

    self.hintText = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.hintText:SetPoint("TOPLEFT", picker, "TOPLEFT", padding, -60)
    self.hintText:SetJustifyH("LEFT")

    local showAll = createFrame("CheckButton", nil, picker, "UICheckButtonTemplate")
    showAll:SetWidth(GroupFinderWindow.CHECK_SIZE)
    showAll:SetHeight(GroupFinderWindow.CHECK_SIZE)
    showAll:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -70, -54)
    showAll:SetScript("OnClick", function(button)
        self.showAll = button:GetChecked() == true
        self:Refresh()
    end)
    local showAllLabel = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showAllLabel:SetPoint("LEFT", showAll, "RIGHT", 2, 0)
    showAllLabel:SetText("Show all")
    self.showAllButton = showAll

    local scroll = createFrame("ScrollFrame", nil, picker, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", picker, "TOPLEFT", padding, -GroupFinderWindow.LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -padding - 22, padding + GroupFinderWindow.FOOTER_HEIGHT)
    local list = createFrame("Frame", nil, scroll)
    list:SetWidth(GroupFinderWindow.WIDTH - 2 * padding - 22)
    list:SetHeight(GroupFinderWindow.ROW_HEIGHT)
    scroll:SetScrollChild(list)
    self.list = list
end

function Window:buildGroup()
    local padding = GroupFinderWindow.PADDING
    local group = self:view()
    self.group = group

    self.endButton = self:button(group, "End group", 90, function()
        local pending = self.session:PendingRequests()
        local index
        for index = 1, #pending do
            pcall(self.cancelRequest, pending[index].id)
        end
        self.session:End()
        self.choosing = false
        self.asking = nil
        self:Refresh()
    end)
    self.endButton:SetPoint("TOPRIGHT", group, "TOPRIGHT", -padding, -54)
    self.changeButton = self:button(group, "Change dungeon", 120, function()
        self.choosing = true
        self:Refresh()
    end)
    self.changeButton:SetPoint("RIGHT", self.endButton, "LEFT", -4, 0)
    self.askButton = self:button(group, "Ask in guild", 100, function()
        self.asking = self.session:AskLine(self:Picked())
        self:Refresh()
    end)
    self.askButton:SetPoint("RIGHT", self.changeButton, "LEFT", -4, 0)

    local index
    for index = 1, #addon.GroupSession.LAYOUT do
        local top = -GroupFinderWindow.LIST_TOP - (index - 1) * GroupFinderWindow.ROW_HEIGHT
        local role = group:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        role:SetPoint("TOPLEFT", group, "TOPLEFT", padding, top)
        role:SetText(addon.RoleCatalog.LABELS[addon.GroupSession.LAYOUT[index].role] .. ":")
        local text = group:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOPLEFT", group, "TOPLEFT", padding + 70, top)
        text:SetPoint("RIGHT", group, "RIGHT", -padding - 64, 0)
        text:SetJustifyH("LEFT")
        local row = { role = role, text = text }
        row.invite = self:button(group, "Invite", 60, function()
            if row.inviteKey ~= nil then
                pcall(self.invite, row.inviteKey)
            end
        end)
        row.invite:SetHeight(GroupFinderWindow.ROW_HEIGHT - 2)
        row.invite:SetPoint("TOPRIGHT", group, "TOPRIGHT", -padding, top + 1)
        self.slotRows[index] = row
    end

    local below = -GroupFinderWindow.LIST_TOP - #addon.GroupSession.LAYOUT * GroupFinderWindow.ROW_HEIGHT
    self.completeText = group:CreateFontString(nil, "OVERLAY", "GameFontGreen")
    self.completeText:SetPoint("TOPLEFT", group, "TOPLEFT", padding, below - 6)
    self.completeText:SetText("Group complete")

    -- Ask in guild's confirmation, where Group complete would be (the two
    -- never show together).
    local confirm = self.environment.CreateFrame("Frame", nil, group)
    confirm:SetPoint("TOPLEFT", group, "TOPLEFT", padding, below - 2)
    confirm:SetPoint("RIGHT", group, "RIGHT", -padding, 0)
    confirm:SetHeight(28)
    self.confirmCancel = self:button(confirm, "Cancel", 64, function()
        self.asking = nil
        self:Refresh()
    end)
    self.confirmCancel:SetPoint("RIGHT", confirm, "RIGHT", 0, 0)
    self.confirmPost = self:button(confirm, "Post", 52, function()
        local line = self.asking
        self.asking = nil
        if line ~= nil then
            pcall(self.postToGuild, line)
        end
        self:Refresh()
    end)
    self.confirmPost:SetPoint("RIGHT", self.confirmCancel, "LEFT", -4, 0)
    self.confirmText = confirm:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.confirmText:SetPoint("LEFT", confirm, "LEFT", 0, 0)
    self.confirmText:SetPoint("RIGHT", self.confirmPost, "LEFT", -6, 0)
    self.confirmText:SetJustifyH("LEFT")
    self.confirm = confirm

    self.partyHeading = group:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.partyHeading:SetPoint("TOPLEFT", group, "TOPLEFT", padding, below - 32)
    self.partyHeading:SetText("Party roles")
    self.partyTop = below - 52
end

-- "Hammer, Wrench (unavailable)": a name as the game gave it, without the
-- realm.
function GroupFinderWindow.RepliesLine(replies)
    if #replies == 0 then
        return "No other add-on users have replied yet."
    end
    local names = {}
    local index
    for index = 1, #replies do
        local name = string.match(replies[index].sender, "^([^%-]+)") or replies[index].sender
        if not replies[index].available then
            name = name .. " (unavailable)"
        end
        names[index] = name
    end
    return "Add-on users online: " .. table.concat(names, ", ")
end

function Window:buildFooter()
    local padding = GroupFinderWindow.PADDING
    local panel = self.panel
    local dnd = self.environment.CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    dnd:SetWidth(GroupFinderWindow.CHECK_SIZE)
    dnd:SetHeight(GroupFinderWindow.CHECK_SIZE)
    dnd:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", padding, padding)
    dnd:SetScript("OnClick", function(button)
        if self.dnd ~= nil then
            pcall(self.dnd.set, button:GetChecked() == true)
        end
        self:Refresh()
    end)
    local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", dnd, "RIGHT", 2, 0)
    label:SetText("Do Not Disturb (no group requests, on every character)")
    self.dndButton = dnd

    self.repliesText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.repliesText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", padding, padding + GroupFinderWindow.CHECK_SIZE + 4)
    self.repliesText:SetPoint("RIGHT", panel, "RIGHT", -padding, 0)
    self.repliesText:SetJustifyH("LEFT")
end

function Window:drawFooter()
    local ok, replies = pcall(self.replies)
    self.repliesText:SetText(GroupFinderWindow.RepliesLine(ok and type(replies) == "table" and replies or {}))
    if self.dnd ~= nil then
        local got, enabled = pcall(self.dnd.get)
        self.dndButton:SetChecked(got and enabled == true)
    end
end

function Window:build()
    local panel = self.framework:CreateSimplePanel(self.environment.UIParent,
        GroupFinderWindow.WIDTH, GroupFinderWindow.HEIGHT, "Group Finder",
        addon.Identity.addonName .. "GroupFinder")
    self.panel = panel
    panel:SetFrameStrata(GroupFinderWindow.STRATA)
    panel:SetClampedToScreen(true)
    self:place()
    -- The panel moves itself while the mouse is held; letting go saves.
    panel:HookScript("OnMouseUp", function()
        self:saveCurrent()
    end)

    self.dungeonText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    self.dungeonText:SetPoint("TOPLEFT", panel, "TOPLEFT", GroupFinderWindow.PADDING, -34)
    self.dungeonText:SetPoint("RIGHT", panel, "RIGHT", -GroupFinderWindow.PADDING, 0)
    self.dungeonText:SetJustifyH("LEFT")

    self:buildPicker()
    self:buildGroup()
    self:buildSuggestions()
    self:buildFooter()
    panel:Hide()
end

-- The dungeon list's row `index`, made on first use: a button showing one
-- dungeon that picks it when clicked.
function Window:row(index)
    if self.rows[index] ~= nil then
        return self.rows[index]
    end
    local button = self.environment.CreateFrame("Button", nil, self.list)
    button:SetHeight(GroupFinderWindow.ROW_HEIGHT)
    button:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, -(index - 1) * GroupFinderWindow.ROW_HEIGHT)
    button:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
    button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", button, "LEFT", 4, 0)
    label:SetJustifyH("LEFT")
    local row = { button = button, label = label }
    button:SetScript("OnClick", function()
        if row.dungeonId ~= nil then
            self:Pick(row.dungeonId)
        end
    end)
    self.rows[index] = row
    return row
end

-- The party list's row `index`, made on first use: a member's name and a
-- button for each role.
function Window:partyRow(index)
    if self.partyRows[index] ~= nil then
        return self.partyRows[index]
    end
    local padding = GroupFinderWindow.PADDING
    local frame = self.environment.CreateFrame("Frame", nil, self.group)
    frame:SetHeight(GroupFinderWindow.PARTY_ROW_HEIGHT)
    frame:SetPoint("TOPLEFT", self.group, "TOPLEFT", padding,
        self.partyTop - (index - 1) * GroupFinderWindow.PARTY_ROW_HEIGHT)
    frame:SetPoint("RIGHT", self.group, "RIGHT", -padding, 0)
    local row = { frame = frame, buttons = {} }
    local previous
    local roleIndex
    for roleIndex = #addon.RoleCatalog.ROLES, 1, -1 do
        local role = addon.RoleCatalog.ROLES[roleIndex]
        local button = self:button(frame, addon.RoleCatalog.LABELS[role], GroupFinderWindow.ROLE_BUTTON_WIDTH,
            function()
                if row.key ~= nil then
                    self.session:Assign(row.key, role)
                    pcall(self.syncParty)
                    self:Refresh()
                end
            end)
        if previous == nil then
            button:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
        else
            button:SetPoint("RIGHT", previous, "LEFT", -2, 0)
        end
        previous = button
        row.buttons[role] = button
    end
    row.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", frame, "LEFT", 0, 0)
    row.text:SetPoint("RIGHT", previous, "LEFT", -6, 0)
    row.text:SetJustifyH("LEFT")
    self.partyRows[index] = row
    return row
end

function Window:drawPicker()
    local level = self.level
    local fitting, others = self.catalog:Split(level)
    local shown = {}
    local index
    for index = 1, #fitting do
        table.insert(shown, fitting[index])
    end
    -- Without a level, nothing fits, so every dungeon is listed.
    if self.showAll or level == nil then
        for index = 1, #others do
            table.insert(shown, others[index])
        end
    end
    if level == nil then
        self.hintText:SetText("Every dungeon:")
    elseif #fitting == 0 and not self.showAll then
        self.hintText:SetText("No dungeons fit level " .. level .. ". Tick Show all to see them all.")
    else
        self.hintText:SetText("Dungeons for level " .. level .. " first:")
    end

    for index = 1, #shown do
        local row = self:row(index)
        row.dungeonId = shown[index].id
        local label = GroupFinderWindow.Label(shown[index])
        if self.candidatesNow ~= nil then
            label = label .. "  |cff9d9d9d" .. GroupFinderWindow.CountsText(self.candidatesNow:Counts(shown[index])) .. "|r"
        end
        row.label:SetText(label)
        row.button:Show()
    end
    for index = #shown + 1, #self.rows do
        self.rows[index].dungeonId = nil
        self.rows[index].button:Hide()
    end
    self.list:SetHeight(math.max(#shown, 1) * GroupFinderWindow.ROW_HEIGHT)
end

function Window:drawGroup()
    local slots = self.session:Slots()
    local index
    for index = 1, #self.slotRows do
        local slot = slots[index]
        local row = self.slotRows[index]
        local state = self.session:InviteState(slot, self.isOnline)
        row.inviteKey = nil
        if state == "waiting" then
            row.text:SetText("Waiting for " .. slot.member.name .. " to log in")
        elseif slot ~= nil and slot.member ~= nil then
            row.text:SetText(GroupFinderWindow.MemberLabel(slot.member))
        else
            row.text:SetText("open")
        end
        if state == "ready" then
            row.inviteKey = slot.member.key
            row.invite:Show()
        else
            row.invite:Hide()
        end
    end
    if self.session:IsComplete() then
        self.completeText:Show()
        self.askButton:Hide()
        self.asking = nil
    else
        self.completeText:Hide()
        self.askButton:Show()
    end
    if self.asking ~= nil then
        self.confirmText:SetText("Post to guild chat? \"" .. self.asking .. "\"")
        self.confirm:Show()
    else
        self.confirm:Hide()
    end

    -- Members the game assigned a role need no buttons.
    local members = self.session:Members()
    local count = 0
    for index = 1, #members do
        local member = members[index]
        if member.assignedRole == nil then
            count = count + 1
            local row = self:partyRow(count)
            row.key = member.key
            row.text:SetText(GroupFinderWindow.MemberLabel(member))
            local role, button
            for role, button in pairs(row.buttons) do
                if self.roles:Can(member.classToken, role) then
                    button:Show()
                else
                    button:Hide()
                end
            end
            row.frame:Show()
        end
    end
    for index = count + 1, #self.partyRows do
        self.partyRows[index].key = nil
        self.partyRows[index].frame:Hide()
    end
    if count > 0 then
        self.partyHeading:Show()
    else
        self.partyHeading:Hide()
    end
end

-- Redraws the window from the session, the catalog and the level.
function Window:draw()
    local picked = self:Picked()
    if picked ~= nil then
        self.dungeonText:SetText("Dungeon: " .. GroupFinderWindow.Label(picked))
    elseif self.session:IsActive() then
        self.dungeonText:SetText("Dungeon: unknown")
    else
        self.dungeonText:SetText("Pick a dungeon")
    end
    local ok, candidates = pcall(self.candidates)
    self.candidatesNow = ok and candidates or nil
    if self.session:IsActive() and not self.choosing then
        self.picker:Hide()
        self:drawGroup()
        self.group:Show()
        self:drawSuggestions(self.candidatesNow, picked)
        self.suggestions:Show()
    else
        self.group:Hide()
        self.suggestions:Hide()
        self:drawPicker()
        self.picker:Show()
    end
    self:drawFooter()
end

-- Redraws the window, when it has been opened.
function Window:Refresh()
    if self.catalog ~= nil then
        pcall(self.draw, self)
    end
end

-- Picks the dungeon with `id`: starts the group, or changes its dungeon
-- keeping its slots.
function Window:Pick(id)
    if self.catalog == nil or self.catalog:Get(id) == nil then
        return false
    end
    if self.session:IsActive() then
        self.session:SetDungeon(id)
    else
        self.session:Start(id)
        self.syncParty()
    end
    self.choosing = false
    self:Refresh()
    return true
end

-- The group's dungeon, or nil.
function Window:Picked()
    return self.catalog ~= nil and self.catalog:Get(self.session:Dungeon()) or nil
end

function Window:IsShown()
    local ok, shown = pcall(self.panel.IsShown, self.panel)
    return ok and shown == true
end

-- Opens the window with the current dungeons, level and party, or closes
-- it. Returns whether it's now open.
function Window:Toggle()
    if self:IsShown() then
        self.panel:Hide()
        return false
    end
    self.catalog = self.dungeons()
    self.level = self.playerLevel()
    self.showAllButton:SetChecked(self.showAll)
    self.syncParty()
    self:Refresh()
    self.panel:Show()
    return true
end
