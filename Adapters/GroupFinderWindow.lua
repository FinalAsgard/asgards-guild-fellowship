local _, addon = ...

-- The Group Finder's own window, separate from the master frame, built with
-- the Details! Framework's simple panel (draggable, with a close button, and
-- Escape closes it). It remembers where it was dropped, across reloads and
-- on every character. It starts with a dungeon picker: the dungeons that fit
-- the character's level first, and the rest behind "Show all". Picking one
-- shows it, with its level range, as the group's dungeon.
--
-- Like the other adapters, it reaches the game only through the client's
-- environment (CreateFrame, UIParent) and the framework, so specs can draw
-- it with fake frames.
local GroupFinderWindow = {
    WIDTH = 380,
    HEIGHT = 440,
    PADDING = 12,
    ROW_HEIGHT = 20,
    -- Where the dungeon list starts, below the title bar and its headings.
    LIST_TOP = 86,
    CHECK_SIZE = 24,
    STRATA = "HIGH",
}
addon.GroupFinderWindow = GroupFinderWindow

local Window = {}
Window.__index = Window

-- "The Deadmines (17–26)".
function GroupFinderWindow.Label(dungeon)
    return dungeon.name .. " (" .. dungeon.minLevel .. "–" .. dungeon.maxLevel .. ")"
end

-- options:
--   dungeons()          the DungeonCatalog to pick from, read on every open
--   playerLevel()       the character's level, or nil
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
        loadAnchor = options.loadAnchor or function() return nil end,
        saveAnchor = options.saveAnchor or function() end,
        showAll = false,
        rows = {},
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

function Window:build()
    local createFrame = self.environment.CreateFrame
    local padding = GroupFinderWindow.PADDING
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
    self.dungeonText:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -34)
    self.dungeonText:SetPoint("RIGHT", panel, "RIGHT", -padding, 0)
    self.dungeonText:SetJustifyH("LEFT")

    self.hintText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.hintText:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -60)
    self.hintText:SetJustifyH("LEFT")

    local showAll = createFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    showAll:SetWidth(GroupFinderWindow.CHECK_SIZE)
    showAll:SetHeight(GroupFinderWindow.CHECK_SIZE)
    showAll:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -70, -54)
    showAll:SetScript("OnClick", function(button)
        self.showAll = button:GetChecked() == true
        self:refresh()
    end)
    local showAllLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    showAllLabel:SetPoint("LEFT", showAll, "RIGHT", 2, 0)
    showAllLabel:SetText("Show all")
    self.showAllButton = showAll

    local scroll = createFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", padding, -GroupFinderWindow.LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -padding - 22, padding)
    local list = createFrame("Frame", nil, scroll)
    list:SetWidth(GroupFinderWindow.WIDTH - 2 * padding - 22)
    list:SetHeight(GroupFinderWindow.ROW_HEIGHT)
    scroll:SetScrollChild(list)
    self.list = list

    panel:Hide()
end

-- The list's row `index`, made on first use: a button showing one dungeon
-- that picks it when clicked.
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

-- Redraws the picked dungeon and the list from the catalog and level.
function Window:refresh()
    local catalog = self.catalog
    local level = self.level
    local picked = catalog:Get(self.picked)
    if picked ~= nil then
        self.dungeonText:SetText("Dungeon: " .. GroupFinderWindow.Label(picked))
    else
        self.dungeonText:SetText("Pick a dungeon")
    end

    local fitting, others = catalog:Split(level)
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
        row.label:SetText(GroupFinderWindow.Label(shown[index]))
        row.button:Show()
    end
    for index = #shown + 1, #self.rows do
        self.rows[index].dungeonId = nil
        self.rows[index].button:Hide()
    end
    self.list:SetHeight(math.max(#shown, 1) * GroupFinderWindow.ROW_HEIGHT)
end

-- Picks the dungeon with `id` as the group's dungeon.
function Window:Pick(id)
    if self.catalog == nil or self.catalog:Get(id) == nil then
        return false
    end
    self.picked = id
    pcall(self.refresh, self)
    return true
end

-- The picked dungeon, or nil.
function Window:Picked()
    return self.catalog ~= nil and self.catalog:Get(self.picked) or nil
end

function Window:IsShown()
    local ok, shown = pcall(self.panel.IsShown, self.panel)
    return ok and shown == true
end

-- Opens the window with the current dungeons and level, or closes it.
-- Returns whether it's now open.
function Window:Toggle()
    if self:IsShown() then
        self.panel:Hide()
        return false
    end
    self.catalog = self.dungeons()
    self.level = self.playerLevel()
    self.showAllButton:SetChecked(self.showAll)
    pcall(self.refresh, self)
    self.panel:Show()
    return true
end
