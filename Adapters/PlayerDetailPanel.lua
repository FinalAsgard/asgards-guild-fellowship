local _, addon = ...

-- The player detail panel for the new window: one player's header and
-- tiles, drawn from PlayerDetailViewModel. The header has the big name, a
-- gold Friend or Most grouped badge, the main's name in class color with
-- their level, class and rank, and where they are (wrapping to a second
-- line when it's long), with a star button at the top right, then Whisper
-- and Invite on a row of their own. Four tiles sit under it: Discord,
-- Grouped, Last grouped and Joined guild.
--
-- It takes the view and callbacks only, with no Friends-specific code, so
-- the roster can embed it as-is when it moves to the new window.
--
-- The Rank tab, shown only when the view has a checklist (an officer on
-- anyone, a member on their own player), has the player's status, the
-- rank promoted to, the characters to promote, and every requirement with
-- its detail. An officer ticks checks there (one that needs a note asks
-- for it), right-clicks a failed automated one to override it, and snoozes
-- a Due player; a member's own is read-only.
local Theme = addon.Theme
local DOT = " · "

local PlayerDetailPanel = {
    STAR_SIZE = 28,
    BADGE_STAR_SIZE = 12,
    BUTTON_WIDTH = 84,
    TILE_HEIGHT = 52,
    TILE_COUNT = 4,
    FRIEND = "Friend",
    MOST_GROUPED = "Most grouped",
    SCROLL_STEP = 48,
    -- The Theme's gold, for this player's own characters in a party.
    THEIRS_COLOR = "ffd9b038",
    LINE_HEIGHT = 18,
    PARTY_MEMBER_HEIGHT = 16,
    -- The ⋯ actions button, and the Bio tab's Edit buttons.
    ACTIONS = "•••",
    ACTIONS_WIDTH = 32,
    EDIT = "Edit",
    EDIT_WIDTH = 44,
    TABS = {
        { id = "characters", label = "Characters" },
        { id = "bio", label = "Bio" },
        { id = "grouped", label = "Grouped" },
        { id = "log", label = "Log" },
        { id = "rank", label = "Rank" },
    },
    RANK_ROW_HEIGHT = 38,
    -- A requirement's detail color, by its state.
    RANK_COLORS = { met = "green", missing = "red", overridden = "gold", ticked = "muted", unticked = "muted" },
    READ_ONLY = "Only officers can change this checklist.",
    NO_REQUIREMENTS = "This rank has no requirements to show.",
    OVERRIDE = "Override as met...",
    REMOVE_OVERRIDE = "Remove override",
    -- The most a note or reason holds (PromotionChecks' limit).
    NOTE_LETTERS = 100,
    SNOOZE = "Snooze",
}
addon.PlayerDetailPanel = PlayerDetailPanel

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

-- The badge's words: "Friend" or "Most grouped · #2", or nil.
function PlayerDetailPanel.BadgeText(badge)
    if type(badge) ~= "table" then
        return nil
    end
    if badge.kind == addon.PlayerDetailViewModel.FRIEND then
        return PlayerDetailPanel.FRIEND
    end
    if badge.kind == addon.PlayerDetailViewModel.TOP then
        return PlayerDetailPanel.MOST_GROUPED .. DOT .. "#" .. tostring(badge.rank)
    end
    return nil
end

-- The sub line: the main's name in class color (when the big name is an
-- alias), the level, class and rank, and where they are.
local function subLine(header)
    local parts = {}
    if header.alias ~= nil and header.mainName ~= nil then
        table.insert(parts, colored(header.mainName, header.color))
    end
    if header.facts ~= nil and header.facts ~= "" then
        table.insert(parts, header.alias == nil and colored(header.facts, header.color) or header.facts)
    end
    if header.status ~= nil and header.status ~= "" then
        table.insert(parts, header.status)
    end
    return table.concat(parts, DOT)
end

-- The Rank tab's onRankTick and onRankSnooze for a page whose `options`
-- has onRankTick(key, item, ticked, note) and onSnooze(key) (each true, or
-- false and why not) and onError(text); `refresh()` shows the panel again
-- after each.
function PlayerDetailPanel.RankCallbacks(options, refresh)
    local function report(ok, why, what)
        if ok == false and options.onError ~= nil then
            options.onError(what .. " wasn't changed: " .. tostring(why) .. ".")
        end
        refresh()
    end
    return function(view, item, ticked, note)
        if options.onRankTick ~= nil and view.rank ~= nil then
            local ok, why = options.onRankTick(view.rank.key, item, ticked, note)
            report(ok, why, (view.header.name or "") .. "'s checklist")
        end
    end, function(view)
        if options.onSnooze ~= nil and view.rank ~= nil then
            local ok, why = options.onSnooze(view.rank.key)
            report(ok, why, (view.header.name or "") .. "'s snooze")
        end
    end
end

-- Draws the panel on `parent` with widget factory `ui`. callbacks (each
-- given the target or player id, then the view):
--   onWhisper       function(target, view)
--   onInvite        function(target, view)
--   onToggleFriend  function(view): the star button
--   onMoreGrouped   function(view): Show more on the Grouped tab; the
--                   owner shows the view again with another page
--   formatDate      function(at) -> text, for the Grouped tab's dates
--   onCharacterMenu function(card, character, view): a right click on a
--                   Characters tab card (optional; without it, no menu)
--   onActions       function(button, view): the ⋯ button left of the star
--                   (optional; without it, there's no button). The owner's
--                   menu holds Whisper and Invite, so the panel then has
--                   no buttons for them.
--   onEditProfile   function(field, view): Edit by the Bio tab's Location
--                   or Bio heading ("location" or "bio"), shown while
--                   view.canEdit is true
--   onRankTick      function(view, item, ticked, note): the Rank tab ticks
--                   or unticks requirement `item` (an override for an
--                   automated one), with `note`; the owner saves it and
--                   shows the view again
--   onRankSnooze    function(view): the Rank tab's Snooze, likewise
-- ShowPlayer(view) fills and shows it; ShowEmpty(text) shows only `text`.
function PlayerDetailPanel.Create(ui, parent, callbacks)
    callbacks = callbacks or {}
    local pad = Theme.SPACING.l
    local panel = ui:frame("Frame", parent)
    panel:SetAllPoints(parent)
    -- What's shown, kept off the frame.
    local state = {}

    panel.name = ui:Text(panel, "", "semibold", "heading", "text")
    panel.name:SetPoint("TOPLEFT", panel, "TOPLEFT", pad, -pad)
    panel.name:SetJustifyH("LEFT")
    panel.name:SetWordWrap(false)
    panel.badgeStar = panel:CreateTexture(nil, "ARTWORK")
    panel.badgeStar:SetTexture(Theme.TEXTURES.star)
    panel.badgeStar:SetVertexColor(Theme.Color("gold"))
    panel.badgeStar:SetSize(PlayerDetailPanel.BADGE_STAR_SIZE, PlayerDetailPanel.BADGE_STAR_SIZE)
    panel.badgeStar:SetPoint("LEFT", panel.name, "RIGHT", Theme.SPACING.s, 0)
    panel.badge = ui:Text(panel, "", "semibold", "small", "gold")
    panel.badge:SetPoint("LEFT", panel.badgeStar, "RIGHT", Theme.SPACING.xs, 0)
    panel.sub = ui:Text(panel, "", "regular", "body", "muted")
    panel.sub:SetPoint("TOPLEFT", panel.name, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
    panel.sub:SetPoint("RIGHT", panel, "RIGHT", -pad, 0)
    panel.sub:SetJustifyH("LEFT")
    panel.sub:SetWordWrap(true)
    if type(panel.sub.SetMaxLines) == "function" then
        panel.sub:SetMaxLines(2)
    end

    -- Whisper and Invite on their own row under it.
    panel.invite = ui:Button(panel, "Invite", "secondary", function()
        local view = state.view
        if view ~= nil and view.header.target ~= nil and callbacks.onInvite ~= nil then
            callbacks.onInvite(view.header.target, view)
        end
    end)
    panel.invite:SetWidth(PlayerDetailPanel.BUTTON_WIDTH)
    panel.whisper = ui:Button(panel, "Whisper", "secondary", function()
        local view = state.view
        if view ~= nil and view.header.target ~= nil and callbacks.onWhisper ~= nil then
            callbacks.onWhisper(view.header.target, view)
        end
    end)
    panel.whisper:SetWidth(PlayerDetailPanel.BUTTON_WIDTH)
    panel.whisper:SetPoint("TOPLEFT", panel.sub, "BOTTOMLEFT", 0, -Theme.SPACING.s)
    panel.invite:SetPoint("LEFT", panel.whisper, "RIGHT", Theme.SPACING.s, 0)
    panel.star = ui:IconButton(panel, Theme.TEXTURES.star, PlayerDetailPanel.STAR_SIZE, function()
        local view = state.view
        if view ~= nil and view.header.canToggle and callbacks.onToggleFriend ~= nil then
            callbacks.onToggleFriend(view)
        end
    end)
    panel.star:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -pad, -pad)
    if callbacks.onActions ~= nil then
        panel.actions = ui:TextButton(panel, PlayerDetailPanel.ACTIONS, PlayerDetailPanel.ACTIONS_WIDTH, function(button)
            if state.view ~= nil then
                callbacks.onActions(button, state.view)
            end
        end)
        panel.actions:SetPoint("RIGHT", panel.star, "LEFT", -Theme.SPACING.xs, 0)
    end
    -- Gold for a Friend, grey to add one, dim when every slot is taken.
    local function tintStar(hovered)
        local header = state.view and state.view.header or {}
        local color = "muted"
        if header.isFriend then
            color = "gold"
        elseif not header.canToggle then
            color = "disabled"
        elseif hovered then
            color = "text"
        end
        panel.star.icon:SetVertexColor(Theme.Color(color))
    end
    panel.star:HookScript("OnEnter", function()
        tintStar(true)
    end)
    panel.star:HookScript("OnLeave", function()
        tintStar(false)
    end)

    -- The tiles, side by side under Whisper and Invite.
    panel.tiles = {}
    local index
    for index = 1, PlayerDetailPanel.TILE_COUNT do
        local box = ui:Panel(panel, { radius = Theme.RADIUS.button, fill = "raised", border = false })
        box:SetHeight(PlayerDetailPanel.TILE_HEIGHT)
        box.label = ui:Text(box, "", "semibold", "small", "label")
        box.label:SetPoint("TOPLEFT", box, "TOPLEFT", Theme.SPACING.s, -Theme.SPACING.s)
        box.value = ui:Text(box, "", "semibold", "body", "text")
        box.value:SetPoint("TOPLEFT", box.label, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
        box.value:SetPoint("RIGHT", box, "RIGHT", -Theme.SPACING.s, 0)
        box.value:SetJustifyH("LEFT")
        box.value:SetWordWrap(false)
        panel.tiles[index] = box
    end
    -- The tiles sit under Whisper and Invite, or under the sub line when
    -- the ⋯ menu has them instead.
    local tilesUnder = callbacks.onActions ~= nil and panel.sub or panel.whisper
    if callbacks.onActions ~= nil then
        panel.whisper:Hide()
        panel.invite:Hide()
    end
    -- Each tile takes a quarter of the width.
    local function layoutTiles(width)
        local gap = Theme.SPACING.s
        local tileWidth = math.max(1, (width - 2 * pad - (PlayerDetailPanel.TILE_COUNT - 1) * gap)
            / PlayerDetailPanel.TILE_COUNT)
        local tileIndex
        for tileIndex = 1, #panel.tiles do
            local box = panel.tiles[tileIndex]
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", tilesUnder, "BOTTOMLEFT", (tileIndex - 1) * (tileWidth + gap), -Theme.SPACING.m)
            box:SetWidth(tileWidth)
        end
    end
    layoutTiles(parent:GetWidth() or 0)
    panel:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            layoutTiles(width)
        end
    end)

    -- The tabs over a scrolling body.
    panel.tab = PlayerDetailPanel.TABS[1].id
    panel.tabs = ui:Tabs(panel, PlayerDetailPanel.TABS, function(id)
        panel:ShowTab(id)
    end)
    panel.tabs:SetPoint("TOPLEFT", panel.tiles[1], "BOTTOMLEFT", 0, -Theme.SPACING.m)
    panel.tabs:SetPoint("RIGHT", panel, "RIGHT", -pad, 0)
    local area = ui:frame("ScrollFrame", panel)
    area:SetPoint("TOPLEFT", panel.tabs, "BOTTOMLEFT", 0, -Theme.SPACING.m)
    area:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -pad, pad)
    local list = ui:frame("Frame", area)
    list:SetSize(400, 1)
    area:SetScrollChild(list)
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(self, delta)
        local most = self:GetVerticalScrollRange() or 0
        local scroll = (self:GetVerticalScroll() or 0) - delta * PlayerDetailPanel.SCROLL_STEP
        self:SetVerticalScroll(math.max(0, math.min(most, scroll)))
    end)
    area:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            list:SetWidth(width)
        end
    end)
    panel.area, panel.list = area, list
    panel.characterCards, panel.lines, panel.parties, panel.edits = {}, {}, {}, {}
    panel.more = ui:Button(list, "Show more", "secondary", function()
        if state.view ~= nil and callbacks.onMoreGrouped ~= nil then
            callbacks.onMoreGrouped(state.view)
        end
    end)
    panel.more:SetWidth(120)
    panel.more:Hide()
    panel.rankRows = {}
    panel.snooze = ui:Button(list, PlayerDetailPanel.SNOOZE, "secondary", function()
        if state.view ~= nil and callbacks.onRankSnooze ~= nil then
            callbacks.onRankSnooze(state.view)
        end
    end)
    panel.snooze:SetWidth(80)
    panel.snooze:Hide()
    panel.menu = ui:ContextMenu(panel)
    panel.prompt = ui:TextPrompt(panel)

    -- Places `frame` at height `top` of the list, across it.
    local function place(frame, top, height)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top)
        frame:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        if height ~= nil then
            frame:SetHeight(height)
        end
        frame:Show()
    end
    -- Line `index` of the Bio and Log tabs, made on first use.
    local function line(index)
        local text = panel.lines[index]
        if text == nil then
            text = ui:Text(list, "", "regular", "body", "text")
            text:SetJustifyH("LEFT")
            text:SetWordWrap(false)
            panel.lines[index] = text
        end
        return text
    end
    local function characterCard(index)
        local card = panel.characterCards[index]
        if card == nil then
            local onRightClick
            if callbacks.onCharacterMenu ~= nil then
                onRightClick = function(clicked)
                    if state.view ~= nil and clicked.fields ~= nil then
                        callbacks.onCharacterMenu(clicked, clicked.fields, state.view)
                    end
                end
            end
            card = addon.PlayerCards.Character(ui, list, onRightClick)
            panel.characterCards[index] = card
        end
        return card
    end
    -- The Edit button for Bio heading `index`, made on first use.
    local function editButton(index)
        local button = panel.edits[index]
        if button == nil then
            button = ui:TextButton(list, PlayerDetailPanel.EDIT, PlayerDetailPanel.EDIT_WIDTH, function(self)
                if state.view ~= nil and callbacks.onEditProfile ~= nil then
                    callbacks.onEditProfile(self.field, state.view)
                end
            end)
            panel.edits[index] = button
        end
        return button
    end
    -- A Grouped party: its date and dungeon or "Party", then its members.
    local function partyRow(index)
        local row = panel.parties[index]
        if row == nil then
            row = ui:Panel(list)
            row.title = ui:Text(row, "", "semibold", "body", "text")
            row.title:SetPoint("TOPLEFT", row, "TOPLEFT", Theme.SPACING.m, -Theme.SPACING.s)
            row.members = ui:Text(row, "", "regular", "body", "muted")
            row.members:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
            row.members:SetPoint("RIGHT", row, "RIGHT", -Theme.SPACING.m, 0)
            row.members:SetJustifyH("LEFT")
            row.members:SetWordWrap(true)
            panel.parties[index] = row
        end
        return row
    end
    local function hideAll(frames)
        local frameIndex
        for frameIndex = 1, #frames do
            frames[frameIndex]:Hide()
        end
    end

    -- Bio and Log rows: section headings, lines, history entries and empty
    -- states.
    local function textRows(rows, top, editable)
        local used, edits = 0, 0
        local rowIndex
        for rowIndex = 1, #(rows or {}) do
            local row = rows[rowIndex]
            used = used + 1
            local text = line(used)
            local words, color, style, size = row.text or "", "text", "regular", "body"
            if row.kind == "section" then
                words, color, style, size = Theme.Label(row.text), "label", "semibold", "small"
                if rowIndex > 1 then
                    top = top + Theme.SPACING.s
                end
            elseif row.kind == "empty" then
                color = "muted"
            elseif row.kind == "history" then
                local parts = { row.name, row.role }
                if row.dates ~= nil and row.dates ~= "" then
                    table.insert(parts, row.dates)
                end
                if row.reason ~= nil and row.reason ~= "" then
                    table.insert(parts, row.reason)
                end
                words = table.concat(parts, DOT)
            end
            Theme.Font(text, style, size, color)
            text:SetText(words)
            text.kind = row.kind
            place(text, top, PlayerDetailPanel.LINE_HEIGHT)
            if editable and row.kind == "section" and row.field ~= nil then
                edits = edits + 1
                local button = editButton(edits)
                button.field = row.field
                button:ClearAllPoints()
                button:SetPoint("RIGHT", list, "RIGHT", 0, 0)
                button:SetPoint("TOP", text, "TOP", 0, 2)
                button:Show()
            end
            top = top + PlayerDetailPanel.LINE_HEIGHT
        end
        return top
    end

    -- The Rank tab ticking `item` for the shown player.
    local function tick(item, ticked, note)
        if state.view ~= nil and callbacks.onRankTick ~= nil then
            callbacks.onRankTick(state.view, item.id, ticked, note)
        end
    end
    -- A click on a check box: unticking, or ticking a check without a
    -- note, at once; one that needs a note asks for it first.
    local function check(item, wanted)
        if not wanted or not item.needsNote then
            tick(item, wanted, nil)
            return
        end
        panel.prompt:Open({
            title = item.label .. " for " .. (state.view and state.view.header.name or ""),
            maxLetters = PlayerDetailPanel.NOTE_LETTERS,
            onSave = function(note)
                tick(item, true, note)
            end,
        })
    end
    -- A failed automated requirement's right-click menu: Override as met...
    -- (with an optional reason), or Remove override for an overridden one.
    local function itemMenu(anchor, item)
        local items = {}
        if item.state == addon.RankUpViewModel.MISSING then
            table.insert(items, { label = PlayerDetailPanel.OVERRIDE, onClick = function()
                panel.prompt:Open({
                    title = "Override " .. item.label .. " (reason optional)",
                    maxLetters = PlayerDetailPanel.NOTE_LETTERS,
                    onSave = function(reason)
                        tick(item, true, reason)
                    end,
                })
            end })
        elseif item.state == addon.RankUpViewModel.OVERRIDDEN then
            table.insert(items, { label = PlayerDetailPanel.REMOVE_OVERRIDE, onClick = function()
                tick(item, false, nil)
            end })
        end
        if items[1] ~= nil then
            panel.menu:Open(anchor, items, item.label)
        end
    end
    -- Requirement row `index` of the Rank tab, made on first use: a check
    -- box for an officer check, then the label and its detail.
    local function rankRow(index)
        local row = panel.rankRows[index]
        if row == nil then
            row = ui:frame("Button", list)
            row:RegisterForClicks("RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                local rank = state.view and state.view.rank
                if button == "RightButton" and self.item ~= nil and not self.item.check and rank ~= nil
                    and rank.editable
                then
                    itemMenu(self, self.item)
                end
            end)
            row.box = ui:CheckBox(row, function(wanted)
                local rank = state.view and state.view.rank
                if row.item ~= nil and rank ~= nil and rank.editable then
                    check(row.item, wanted)
                end
            end)
            row.box:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
            row.label = ui:Text(row, "", "semibold", "body", "text")
            row.label:SetPoint("TOPLEFT", row, "TOPLEFT", addon.Widgets.CHECK_SIZE + Theme.SPACING.s, 0)
            row.label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row.detail = ui:Text(row, "", "regular", "small", "muted")
            row.detail:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -Theme.SPACING.xs)
            row.detail:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            row.detail:SetJustifyH("LEFT")
            row.detail:SetWordWrap(false)
            panel.rankRows[index] = row
        end
        return row
    end
    -- The Rank tab: the status and rank promoted to, who to promote, the
    -- Snooze button for a Due player, then a row per requirement.
    local function rankBody(rank, top)
        local status = rank.statusText .. (rank.rankText and (DOT .. rank.rankText) or "")
        local rows = { { kind = "line", text = status } }
        if rank.promoteText ~= nil and rank.promoteText ~= "" then
            table.insert(rows, { kind = "line", text = "Promote: " .. rank.promoteText })
        end
        if not rank.editable then
            table.insert(rows, { kind = "empty", text = PlayerDetailPanel.READ_ONLY })
        end
        if rank.items[1] == nil then
            table.insert(rows, { kind = "empty", text = PlayerDetailPanel.NO_REQUIREMENTS })
        end
        top = textRows(rows, top)
        if rank.editable and rank.status == addon.RankUpViewModel.DUE then
            panel.snooze:ClearAllPoints()
            panel.snooze:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
            panel.snooze:Show()
        end
        top = top + Theme.SPACING.s
        local index
        for index = 1, #rank.items do
            local item = rank.items[index]
            local row = rankRow(index)
            row.item = item
            place(row, top, PlayerDetailPanel.RANK_ROW_HEIGHT)
            setShown(row.box, item.check)
            if item.check then
                row.box:SetChecked(item.checked)
                row.box:EnableMouse(rank.editable == true)
            end
            row.label:SetText(item.label or "")
            row.detail:SetText(item.detail or "")
            row.color = PlayerDetailPanel.RANK_COLORS[item.state] or "muted"
            row.detail:SetTextColor(Theme.Color(row.color))
            top = top + PlayerDetailPanel.RANK_ROW_HEIGHT + Theme.SPACING.xs
        end
        return top
    end
    -- Draws the selected tab's body.
    function panel.refreshBody()
        hideAll(panel.characterCards)
        hideAll(panel.lines)
        hideAll(panel.parties)
        hideAll(panel.edits)
        hideAll(panel.rankRows)
        panel.more:Hide()
        panel.snooze:Hide()
        local view = state.view
        if view == nil then
            return
        end
        local top = 0
        if panel.tab == "characters" then
            local characters = view.characters or {}
            local cardIndex
            for cardIndex = 1, #characters do
                local card = characterCard(cardIndex)
                place(card, top, addon.PlayerCards.CHARACTER_HEIGHT)
                card:ShowCharacter(characters[cardIndex])
                top = top + addon.PlayerCards.CHARACTER_HEIGHT + Theme.SPACING.xs
            end
        elseif panel.tab == "bio" then
            top = textRows(view.bioRows, top, view.canEdit == true and callbacks.onEditProfile ~= nil)
        elseif panel.tab == "grouped" then
            local grouped = view.grouped or { parties = {} }
            if grouped.parties[1] == nil then
                top = textRows({ { kind = "empty", text = grouped.empty } }, top)
            end
            local partyIndex
            for partyIndex = 1, #grouped.parties do
                local party = grouped.parties[partyIndex]
                local row = partyRow(partyIndex)
                row.party = party
                local date = callbacks.formatDate and callbacks.formatDate(party.at) or nil
                local title = {}
                if date ~= nil then
                    table.insert(title, date)
                end
                table.insert(title, party.place or "Party")
                row.title:SetText(table.concat(title, DOT))
                -- Their character in gold, the rest in grey.
                local names = {}
                local memberIndex
                for memberIndex = 1, #party.members do
                    local member = party.members[memberIndex]
                    table.insert(names, member.theirs and colored(member.name, PlayerDetailPanel.THEIRS_COLOR) or member.name)
                end
                row.members:SetText(table.concat(names, ", "))
                local lines = math.max(1, math.ceil(#party.members / 6))
                local height = 2 * Theme.SPACING.s + PlayerDetailPanel.LINE_HEIGHT + Theme.SPACING.xs
                    + lines * PlayerDetailPanel.PARTY_MEMBER_HEIGHT
                place(row, top, height)
                top = top + height + Theme.SPACING.xs
            end
            if grouped.more then
                panel.more:ClearAllPoints()
                panel.more:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -top - Theme.SPACING.xs)
                panel.more:Show()
                top = top + addon.Widgets.BUTTON_HEIGHT + Theme.SPACING.s
            end
        elseif panel.tab == "rank" and view.rank ~= nil then
            top = rankBody(view.rank, top)
        else
            top = textRows(view.logRows, top)
        end
        list:SetHeight(math.max(top, 1))
    end

    -- Shows tab `id` from the top.
    function panel.ShowTab(_, id)
        panel.tab = id
        panel.tabs:Select(id)
        area:SetVerticalScroll(0)
        panel.refreshBody()
    end

    -- The empty state's words.
    panel.hint = ui:Text(panel, "", "regular", "body", "muted")
    panel.hint:SetPoint("TOPLEFT", panel, "TOPLEFT", pad, -pad)
    panel.hint:SetPoint("RIGHT", panel, "RIGHT", -pad, 0)
    panel.hint:SetJustifyH("LEFT")
    panel.hint:SetWordWrap(true)

    local function showParts(shown)
        local parts = { panel.name, panel.sub, panel.star, panel.tabs, panel.area }
        if callbacks.onActions ~= nil then
            table.insert(parts, panel.actions)
        else
            table.insert(parts, panel.whisper)
            table.insert(parts, panel.invite)
        end
        local partIndex
        for partIndex = 1, #parts do
            setShown(parts[partIndex], shown)
        end
        for partIndex = 1, #panel.tiles do
            setShown(panel.tiles[partIndex], shown)
        end
        setShown(panel.hint, not shown)
    end

    function panel.ShowPlayer(_, view)
        -- Another player starts at the top; the same one (Show more) keeps
        -- its place.
        if state.view == nil or state.view.playerId ~= view.playerId then
            area:SetVerticalScroll(0)
        end
        state.view, panel.view = view, view
        local header = view.header
        showParts(true)
        panel.name:SetText(header.name or "")
        panel.name:SetTextColor(Theme.Color(header.left and "disabled" or "text"))
        local badge = PlayerDetailPanel.BadgeText(header.badge)
        panel.badge:SetText(badge or "")
        setShown(panel.badge, badge ~= nil)
        setShown(panel.badgeStar, badge ~= nil)
        panel.sub:SetText(subLine(header))
        panel.hint:SetText("")
        panel.whisper:SetActive(header.target ~= nil)
        panel.invite:SetActive(header.target ~= nil)
        panel.star:SetSelected(false)
        tintStar(false)
        local tiles = view.tiles or {}
        local tileIndex
        for tileIndex = 1, #panel.tiles do
            local box, fact = panel.tiles[tileIndex], tiles[tileIndex]
            if fact ~= nil then
                box.label:SetText(Theme.Label(fact.label))
                box.value:SetText(fact.value or "")
                box.value:SetTextColor(Theme.Color(fact.notSet and "muted" or "text"))
                box.notSet = fact.notSet
                box:Show()
            else
                box:Hide()
            end
        end
        local count = #(view.characters or {})
        local grouped = view.grouped and view.grouped.total or 0
        panel.tabs:SetLabel("characters", "Characters" .. DOT .. count)
        panel.tabs:SetLabel("grouped", "Grouped" .. DOT .. grouped)
        -- The Rank tab only for those who may see it; a player without it
        -- opens on Characters.
        setShown(panel.tabs.tabs[#panel.tabs.tabs], view.rank ~= nil)
        if panel.tab == "rank" and view.rank == nil then
            panel.tab = PlayerDetailPanel.TABS[1].id
        end
        panel.tabs:Select(panel.tab)
        panel.refreshBody()
        panel:Show()
    end

    function panel.ShowEmpty(_, text)
        state.view, panel.view = nil, nil
        showParts(false)
        panel.badge:Hide()
        panel.badgeStar:Hide()
        panel.name:SetText("")
        panel.sub:SetText("")
        panel.hint:SetText(text or "")
        panel.refreshBody()
        panel:Show()
    end

    return panel
end
