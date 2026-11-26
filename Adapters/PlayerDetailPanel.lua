local _, addon = ...

-- The player detail panel for the new window: one player's header and
-- tiles, drawn from PlayerDetailViewModel. The header has the big name, a
-- gold Friend or Most grouped badge, the main's name in class color with
-- their level, class and rank, and where they are, then a star button and
-- Whisper and Invite. Four tiles sit under it: Discord, Grouped, Last
-- grouped and Joined guild.
--
-- It takes the view and callbacks only, with no Friends-specific code, so
-- the roster can embed it as-is when it moves to the new window.
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

-- Draws the panel on `parent` with widget factory `ui`. callbacks (each
-- given the target or player id, then the view):
--   onWhisper       function(target, view)
--   onInvite        function(target, view)
--   onToggleFriend  function(view): the star button
-- ShowPlayer(view) fills and shows it; ShowEmpty(text) shows only `text`.
function PlayerDetailPanel.Create(ui, parent, callbacks)
    callbacks = callbacks or {}
    local pad = Theme.SPACING.l
    local panel = ui:frame("Frame", parent)
    panel:SetAllPoints(parent)

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
    panel.sub:SetJustifyH("LEFT")
    panel.sub:SetWordWrap(false)

    -- Invite, Whisper and the star, from the right.
    panel.invite = ui:Button(panel, "Invite", "secondary", function()
        local view = panel.view
        if view ~= nil and view.header.target ~= nil and callbacks.onInvite ~= nil then
            callbacks.onInvite(view.header.target, view)
        end
    end)
    panel.invite:SetWidth(PlayerDetailPanel.BUTTON_WIDTH)
    panel.invite:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -pad, -pad)
    panel.whisper = ui:Button(panel, "Whisper", "secondary", function()
        local view = panel.view
        if view ~= nil and view.header.target ~= nil and callbacks.onWhisper ~= nil then
            callbacks.onWhisper(view.header.target, view)
        end
    end)
    panel.whisper:SetWidth(PlayerDetailPanel.BUTTON_WIDTH)
    panel.whisper:SetPoint("RIGHT", panel.invite, "LEFT", -Theme.SPACING.s, 0)
    panel.star = ui:IconButton(panel, Theme.TEXTURES.star, PlayerDetailPanel.STAR_SIZE, function()
        local view = panel.view
        if view ~= nil and view.header.canToggle and callbacks.onToggleFriend ~= nil then
            callbacks.onToggleFriend(view)
        end
    end)
    panel.star:SetPoint("RIGHT", panel.whisper, "LEFT", -Theme.SPACING.s, 0)
    -- Gold for a Friend, grey to add one, dim when every slot is taken.
    local function tintStar(hovered)
        local header = panel.view and panel.view.header or {}
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

    -- The tiles, side by side under the header.
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
    -- Each tile takes a quarter of the width.
    local function layoutTiles(width)
        local gap = Theme.SPACING.s
        local tileWidth = math.max(1, (width - 2 * pad - (PlayerDetailPanel.TILE_COUNT - 1) * gap)
            / PlayerDetailPanel.TILE_COUNT)
        local tileIndex
        for tileIndex = 1, #panel.tiles do
            local box = panel.tiles[tileIndex]
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", panel, "TOPLEFT", pad + (tileIndex - 1) * (tileWidth + gap), -pad - 64)
            box:SetWidth(tileWidth)
        end
    end
    layoutTiles(parent:GetWidth() or 0)
    panel:SetScript("OnSizeChanged", function(_, width)
        if type(width) == "number" and width > 0 then
            layoutTiles(width)
        end
    end)

    -- The empty state's words.
    panel.hint = ui:Text(panel, "", "regular", "body", "muted")
    panel.hint:SetPoint("TOPLEFT", panel, "TOPLEFT", pad, -pad)
    panel.hint:SetPoint("RIGHT", panel, "RIGHT", -pad, 0)
    panel.hint:SetJustifyH("LEFT")
    panel.hint:SetWordWrap(true)

    local function showParts(shown)
        local parts = { panel.name, panel.sub, panel.star, panel.whisper, panel.invite }
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
        panel.view = view
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
        panel:Show()
    end

    function panel.ShowEmpty(_, text)
        panel.view = nil
        showParts(false)
        panel.badge:Hide()
        panel.badgeStar:Hide()
        panel.name:SetText("")
        panel.sub:SetText("")
        panel.hint:SetText(text or "")
        panel:Show()
    end

    return panel
end
