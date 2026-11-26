local _, addon = ...

-- Player cards for the new window, drawn with the Theme and Widgets in the
-- LFG Board's card look: rounded, bordered, a large class-colored initial
-- and large main text. Built for the Friends page and kept free of its
-- rules, so the roster can show them as-is when it moves to the new window.
local Theme = addon.Theme

local PlayerCards = {
    SMALL_HEIGHT = 44,
    INITIAL_SIZE = 30,
    DOT_SIZE = 8,
    STAR_SIZE = 12,
    REMOVE_SIZE = 20,
}
addon.PlayerCards = PlayerCards

-- A UTF-8 character at the start of a string.
local CHARACTER = "^[%z\1-\127\194-\244][\128-\191]*"

-- The first letter of `name`, upper-cased where it's plain ASCII.
function PlayerCards.Initial(name)
    local first = string.match(name or "", CHARACTER) or ""
    return string.upper(first)
end

-- `text` in `color` ("ffrrggbb"), where it's known.
local function colored(text, color)
    if type(color) ~= "string" then
        return text
    end
    return "|c" .. color .. text .. "|r"
end

-- A small player card on `parent`: the initial on a rounded tile, the big
-- name, a sub line, a gold star, an online dot, a hover X and a selected
-- state. callbacks (each optional, each given the card):
--   onClick       a left click
--   onRightClick  a right click
--   onRemove      the hover X; without it there's no X
-- ShowPlayer(fields) fills and shows it: name, initial?, sub (may carry
-- color codes), color (the initial's class color, "ffrrggbb"), star,
-- online, count (text shown in the online dot's place), greyed. ShowEmpty
-- (text) makes it an empty slot that only shows `text`. SetSelected(on)
-- borders it green.
function PlayerCards.Small(ui, parent, callbacks)
    callbacks = callbacks or {}
    local card = ui:frame("Button", parent)
    card:SetHeight(PlayerCards.SMALL_HEIGHT)
    ui:Round(card, Theme.RADIUS.card, "surface", "border")
    card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local pad = Theme.SPACING.s

    card.tile = ui:Panel(card, { radius = Theme.RADIUS.button, fill = "raised", border = false })
    card.tile:SetSize(PlayerCards.INITIAL_SIZE, PlayerCards.INITIAL_SIZE)
    card.tile:SetPoint("LEFT", card, "LEFT", pad + 2, 0)
    card.initial = ui:Text(card.tile, "", "semibold", "title", "text")
    card.initial:SetPoint("CENTER", card.tile, "CENTER", 0, 0)

    card.name = ui:Text(card, "", "semibold", "title", "text")
    card.name:SetPoint("TOPLEFT", card.tile, "TOPRIGHT", pad, -1)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)
    card.sub = ui:Text(card, "", "regular", "small", "muted")
    card.sub:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
    card.sub:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
    card.sub:SetJustifyH("LEFT")
    card.sub:SetWordWrap(false)

    card.star = card:CreateTexture(nil, "ARTWORK")
    card.star:SetTexture(Theme.TEXTURES.star)
    card.star:SetVertexColor(Theme.Color("gold"))
    card.star:SetSize(PlayerCards.STAR_SIZE, PlayerCards.STAR_SIZE)
    card.star:SetPoint("LEFT", card.name, "RIGHT", 4, 0)
    card.dot = card:CreateTexture(nil, "ARTWORK")
    card.dot:SetTexture(Theme.TEXTURES.rounded)
    card.dot:SetSize(PlayerCards.DOT_SIZE, PlayerCards.DOT_SIZE)
    card.dot:SetPoint("TOPRIGHT", card, "TOPRIGHT", -pad - 2, -pad - 2)
    card.count = ui:Text(card, "", "semibold", "small", "muted")
    card.count:SetPoint("TOPRIGHT", card, "TOPRIGHT", -pad, -pad)

    -- An empty slot's one line.
    card.emptyText = ui:Text(card, "", "semibold", "body", "muted")
    card.emptyText:SetPoint("CENTER", card, "CENTER", 0, 0)

    if callbacks.onRemove ~= nil then
        card.remove = ui:IconButton(card, Theme.TEXTURES.close, PlayerCards.REMOVE_SIZE, function()
            callbacks.onRemove(card)
        end)
        card.remove:SetPoint("RIGHT", card, "RIGHT", -pad, 0)
        card.remove:Hide()
        -- Moving onto the X leaves the card, but the X stays.
        card.remove:HookScript("OnLeave", function()
            if not (type(card.IsMouseOver) == "function" and card:IsMouseOver()) then
                card.remove:Hide()
            end
        end)
    end

    local function hovered(on)
        if not card.empty then
            card:SetFill(on and "hover" or "surface")
        end
        if card.remove ~= nil then
            if on and not card.empty then
                card.remove:Show()
            elseif not (type(card.remove.IsMouseOver) == "function" and card.remove:IsMouseOver()) then
                card.remove:Hide()
            end
        end
    end
    card:SetScript("OnEnter", function()
        hovered(true)
    end)
    card:SetScript("OnLeave", function()
        hovered(false)
    end)
    card:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if callbacks.onRightClick ~= nil and not card.empty then
                callbacks.onRightClick(card)
            end
        elseif callbacks.onClick ~= nil then
            callbacks.onClick(card)
        end
    end)

    local function showParts(shown)
        local parts = { card.tile, card.initial, card.name, card.sub }
        local index
        for index = 1, #parts do
            if shown then
                parts[index]:Show()
            else
                parts[index]:Hide()
            end
        end
    end

    function card.ShowPlayer(_, fields)
        card.empty = false
        card.fields = fields
        showParts(true)
        card.emptyText:Hide()
        card.initial:SetText(fields.initial or PlayerCards.Initial(fields.name))
        if type(fields.color) == "string" and not fields.greyed then
            card.initial:SetText(colored(fields.initial or PlayerCards.Initial(fields.name), fields.color))
        end
        card.name:SetText(fields.name or "")
        card.name:SetTextColor(Theme.Color(fields.greyed and "disabled" or "text"))
        card.sub:SetText(fields.sub or "")
        if fields.star and not fields.greyed then
            card.star:Show()
        else
            card.star:Hide()
        end
        card.dot:SetVertexColor(Theme.Color(fields.online and "green" or "disabled"))
        card.count:SetText(fields.count or "")
        if fields.greyed or fields.count ~= nil then
            card.dot:Hide()
        else
            card.dot:Show()
        end
        card:SetSelected(card.selected)
        card:Show()
    end

    function card.ShowEmpty(_, text)
        card.empty = true
        card.fields = nil
        showParts(false)
        card.star:Hide()
        card.dot:Hide()
        card.count:SetText("")
        if card.remove ~= nil then
            card.remove:Hide()
        end
        card.emptyText:SetText(text or "")
        card.emptyText:Show()
        card:SetFill("background")
        card:SetSelected(false)
        card:Show()
    end

    function card.SetSelected(_, selected)
        card.selected = selected == true
        card:SetBorder(card.selected and "green" or "border")
    end

    return card
end
