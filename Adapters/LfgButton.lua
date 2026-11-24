local _, addon = ...

-- The LFG button: a small rounded-square tile with a thin green frame and
-- the tree icon, free on the screen and separate from the minimap icon.
-- It's dragged anywhere, with its place saved per character, and stays put
-- in instances. Right-click gives Open Guild LFG Board and Hide LFG button.
-- Whether it shows is the caller's (a per-character setting); hidden means
-- "not participating right now", and it never comes back by itself.
--
-- Made the first time it shows. Like the other adapters, a frame call that
-- fails just leaves it out.
local Theme = addon.Theme

local LfgButton = {
    SIZE = 40,
    ICON_INSET = 7,
    -- Where it starts before it's ever moved: near the minimap.
    DEFAULT_POINT = { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -230, y = -30 },
}
addon.LfgButton = LfgButton

local Button = {}
Button.__index = Button

-- options:
--   frameName     the button's global name
--   shown         function() -> whether it shows on this character
--   onOpenBoard   function(): the menu's Open Guild LFG Board
--   onHide        function(): the menu's Hide LFG button
--   onClick       function(): a left click (the drawer, later); optional
--   loadPosition  function() -> saved { point, relativePoint, x, y } or nil
--   savePosition  function(position)
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
    self.button = button
    self.menu = ui:ContextMenu(environment.UIParent)
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
            if owner.options.onClick ~= nil then
                owner.options.onClick()
            end
        end
    end)
    button:Hide()
end

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
