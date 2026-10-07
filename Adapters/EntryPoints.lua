local _, addon = ...

-- The ways to open the roster besides `/agf`:
--   * a minimap button (LibDataBroker launcher shown by LibDBIcon), whose
--     tooltip shows the pending-conflict count; its position and hidden
--     state live in SavedVariables
--   * an add-on compartment entry on clients that have the compartment
--   * a "Guild Fellowship" button on the game's guild window, left of its
--     Invite Member button, when that button can be found
-- Each one is optional: a missing library, compartment, or anchor simply
-- skips that entry point, never raising an error. Everything goes through
-- the client's environment, so specs can model each client.
local EntryPoints = {
    ICON = "Interface\\Icons\\INV_Misc_GroupNeedMore",
    -- Guild-window addons that create the frame holding Invite Member; the
    -- button is attached when either loads (or at once if already loaded).
    GUILD_ADDONS = { "Blizzard_Communities", "Blizzard_GuildUI" },
}
addon.EntryPoints = EntryPoints

local Points = {}
Points.__index = Points

-- options:
--   client          the compatibility adapter
--   toggle          function() that shows or hides the roster
--   conflictCount   function() -> pending conflicts for the current guild
--   minimapState    function() -> the saved LibDBIcon table, or nil
function EntryPoints.Create(options)
    return setmetatable({
        client = options.client,
        toggle = options.toggle,
        conflictCount = options.conflictCount or function()
            return 0
        end,
        minimapState = options.minimapState or function()
            return nil
        end,
        environment = options.client.environment,
    }, Points)
end

local function library(environment, major)
    local libStub = environment.LibStub
    if type(libStub) ~= "table" or type(libStub.GetLibrary) ~= "function" then
        return nil
    end
    local ok, found = pcall(libStub.GetLibrary, libStub, major, true)
    if ok then
        return found
    end
    return nil
end

function Points:TooltipLines()
    local count = self.conflictCount() or 0
    local lines = {
        addon.Identity.displayName,
        "Click to open or close the roster.",
    }
    if count > 0 then
        table.insert(lines, count .. (count == 1 and " conflict" or " conflicts") .. " to review")
    else
        table.insert(lines, "No conflicts to review")
    end
    return lines
end

-- The minimap button. Returns true when it was registered.
function Points:StartMinimap()
    local broker = library(self.environment, "LibDataBroker-1.1")
    local icon = library(self.environment, "LibDBIcon-1.0")
    if type(broker) ~= "table" or type(broker.NewDataObject) ~= "function"
        or type(icon) ~= "table" or type(icon.Register) ~= "function"
    then
        return false
    end

    local name = addon.Identity.addonName
    local ok = pcall(function()
        local launcher = broker:NewDataObject(name, {
            type = "launcher",
            label = addon.Identity.displayName,
            icon = EntryPoints.ICON,
            OnClick = function()
                self.toggle()
            end,
            OnTooltipShow = function(tooltip)
                local lines = self:TooltipLines()
                local index
                for index = 1, #lines do
                    tooltip:AddLine(lines[index], 1, 1, 1)
                end
            end,
        })
        -- LibDBIcon keeps the button's angle and hidden flag in this table.
        local state = self.minimapState() or {}
        icon:Register(name, launcher, state)
        self.launcher = launcher
        self.icon, self.iconState = icon, state
    end)
    self.minimapRegistered = ok and self.launcher ~= nil
    return self.minimapRegistered
end

-- `/agf minimap`: shows or hides the minimap button and saves the choice.
-- Returns true when the button is now shown, false when hidden, or nil
-- and a reason when there is no minimap button.
function Points:ToggleMinimap()
    if not self.minimapRegistered then
        return nil, "the minimap button isn't available (LibDBIcon is missing)"
    end
    local hide = not self.iconState.hide
    local ok = pcall(function()
        if hide then
            self.icon:Hide(addon.Identity.addonName)
        else
            self.icon:Show(addon.Identity.addonName)
        end
    end)
    if not ok then
        return nil, "the minimap button couldn't be changed"
    end
    self.iconState.hide = hide
    return not hide
end

-- The add-on compartment entry, where the client has the compartment.
function Points:StartCompartment()
    local compartment = self.environment.AddonCompartmentFrame
    if type(compartment) ~= "table" or type(compartment.RegisterAddon) ~= "function" then
        return false
    end
    local ok = pcall(compartment.RegisterAddon, compartment, {
        text = addon.Identity.displayName,
        icon = EntryPoints.ICON,
        notCheckable = true,
        func = function()
            self.toggle()
        end,
    })
    self.compartmentRegistered = ok
    return ok
end

-- The guild window's Invite Member button, found defensively: Retail's
-- Communities frame, then older guild frames.
function Points:FindGuildAnchor()
    local environment = self.environment
    local communities = environment.CommunitiesFrame
    if type(communities) == "table" and type(communities.InviteButton) == "table" then
        return communities.InviteButton
    end
    local candidates = { "CommunitiesFrameInviteButton", "GuildFrameAddMemberButton", "GuildAddMemberButton" }
    local index
    for index = 1, #candidates do
        local frame = environment[candidates[index]]
        if type(frame) == "table" then
            return frame
        end
    end
    return nil
end

-- Adds the guild-window button if its anchor exists. Safe to call again;
-- the button is created once.
function Points:AttachGuildButton()
    if self.guildButton ~= nil then
        return true
    end
    local anchor = self:FindGuildAnchor()
    if anchor == nil or type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    local ok, button = pcall(function()
        local parent = type(anchor.GetParent) == "function" and anchor:GetParent() or nil
        local created = self.environment.CreateFrame("Button", addon.Identity.addonName .. "GuildButton",
            parent, "UIPanelButtonTemplate")
        created:SetText("Guild Fellowship")
        created:SetWidth(120)
        if type(anchor.GetHeight) == "function" then
            created:SetHeight(anchor:GetHeight())
        end
        created:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
        created:SetScript("OnClick", function()
            self.toggle()
        end)
        return created
    end)
    if ok and button ~= nil then
        self.guildButton = button
        return true
    end
    return false
end

-- Starts every entry point. The guild window loads on demand, so its button
-- is attached when the guild add-on loads.
function Points:Start()
    self:StartMinimap()
    self:StartCompartment()
    if self:AttachGuildButton() then
        return
    end
    local frame = self.client:CreateEventFrame()
    if frame == nil then
        return
    end
    self.client:SetEventHandler(frame, function(_, eventName, loaded)
        if eventName ~= "ADDON_LOADED" then
            return
        end
        local index
        for index = 1, #EntryPoints.GUILD_ADDONS do
            if loaded == EntryPoints.GUILD_ADDONS[index] then
                self:AttachGuildButton()
            end
        end
    end)
    self.client:RegisterEvent(frame, "ADDON_LOADED")
    self.guildWatcher = frame
end
