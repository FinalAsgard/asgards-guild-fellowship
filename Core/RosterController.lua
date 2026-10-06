local _, addon = ...

-- Connects the guild roster, the store, and the roster window for `/agf`
-- and `/agf rescan`.
--
-- A scan reads the whole roster into the guild's partition. It only runs on
-- the first open of a guild that has never been scanned, or on request.
-- Opening the window otherwise only reads live roster facts for display.
-- Each scan seeds players from `>Main` and `@Alias` notes through the
-- ReconcileEngine. Scheduling and chunked scanning come in later slices.
local RosterController = {}
addon.RosterController = RosterController

local Controller = {}
Controller.__index = Controller

-- options:
--   client        the compatibility adapter
--   nameRules     the client profile's name rules
--   getDatabase   function() -> the SavedVariables root, or nil
--   createWindow  function() -> window or nil, reason
function RosterController.Create(options)
    return setmetatable({
        client = options.client,
        createWindow = options.createWindow,
        getDatabase = options.getDatabase,
        collapsed = {},
        nameRules = options.nameRules or {},
    }, Controller)
end

-- Collapses or expands a player's group. The state lasts for the session.
function Controller:ToggleGroup(playerId)
    if playerId == nil then
        return
    end
    self.collapsed[playerId] = not self.collapsed[playerId] or nil
    self:Refresh()
end

function Controller:Print(message)
    self.client:Print(addon.Identity.chatPrefix .. " " .. message)
end

function Controller:Normalizer(guild)
    return addon.NameNormalizer.Create({
        homeRealm = guild.realm,
        twoPartNames = self.nameRules.twoPartNames,
    })
end

function Controller:Store()
    local database = self.getDatabase()
    if database == nil then
        return nil
    end
    if self.store == nil or self.store.database ~= database then
        self.store = addon.FellowshipStore.Create(database)
    end
    return self.store
end

-- The current guild and its partition, or nil after telling the player why.
function Controller:Context()
    local guild = self.client:GetGuildIdentity()
    if guild == nil then
        if self.client:IsInGuild() then
            self:Print("Guild information isn't available yet. Try again in a moment.")
        else
            self:Print("You're not in a guild, so there is no roster to show.")
        end
        return nil
    end

    local store = self:Store()
    if store == nil then
        self:Print("Saved data is unavailable, so the roster can't be shown.")
        return nil
    end
    local partition, reason = store:Partition(guild)
    if partition == nil then
        self:Print("The roster can't be shown: " .. tostring(reason) .. ".")
        return nil
    end
    return guild, partition
end

-- Reads every roster member keyed by character key. `complete` is false
-- when the roster isn't fully loaded yet (it loads asynchronously).
function Controller:ReadRoster(guild)
    local normalizer = self:Normalizer(guild)
    local members = {}
    local count = self.client:GetGuildRosterCount()
    local complete = count ~= nil and count > 0
    local index
    for index = 1, count or 0 do
        local member = self.client:GetGuildMember(index)
        local key = member and normalizer:Key(member.name)
        if key == nil then
            complete = false
        else
            members[key] = member
        end
    end
    return members, complete, normalizer
end

-- Applies a complete roster to the partition. Returns false when the
-- roster isn't ready, leaving the scan pending.
function Controller:CompleteScan()
    local pending = self.pendingScan
    if pending == nil then
        return false
    end
    local members, complete = self:ReadRoster(pending.guild)
    if not complete then
        return false
    end

    local plan = addon.ReconcileEngine.Plan({
        partition = pending.partition,
        members = members,
        normalizer = self:Normalizer(pending.guild),
        rules = self.nameRules,
        mode = pending.partition:HasBeenScanned() and "full" or "initial",
    })
    local result = addon.ReconcileEngine.Apply(pending.partition, plan)
    pending.partition:MarkScanned(self.client:Timestamp() or 0)
    self.pendingScan = nil

    local summary = "Roster scanned: " .. result.recorded .. " characters"
    if result.linked > 0 or result.aliased > 0 then
        summary = summary .. ", " .. result.linked .. " linked and " .. result.aliased ..
            " aliases set from notes"
    end
    if result.unapplied > 0 then
        summary = summary .. ", " .. result.unapplied .. " note markers left for review"
    end
    self:Print(summary .. ".")
    self:Refresh()
    return true
end

-- Starts a full roster scan for the current guild.
function Controller:Scan(guild, partition)
    self.pendingScan = { guild = guild, partition = partition }
    self.client:RequestGuildRoster()
    -- The roster is often already loaded; otherwise GUILD_ROSTER_UPDATE
    -- finishes the scan.
    return self:CompleteScan()
end

function Controller:Rescan()
    local guild, partition = self:Context()
    if guild == nil then
        return false
    end
    return self:Scan(guild, partition)
end

function Controller:OnRosterUpdate()
    if self.pendingScan ~= nil then
        self:CompleteScan()
    elseif self.window ~= nil and self.window:IsShown() then
        self:Refresh()
    end
end

-- Redraws the window from the store plus live roster facts.
function Controller:Refresh()
    if self.window == nil or self.current == nil then
        return
    end
    local members, _, normalizer = self:ReadRoster(self.current.guild)
    local rows = addon.RosterViewModel.Build({
        partition = self.current.partition,
        members = members,
        normalizer = normalizer,
        classColor = function(classToken)
            return self.client:GetClassColor(classToken)
        end,
        collapsed = self.collapsed,
    })
    self.window:SetTitle(addon.Identity.displayName .. " - " .. self.current.guild.name)
    self.window:SetRows(rows)
end

-- `/agf`: shows or hides the roster window.
function Controller:Toggle()
    if self.window ~= nil and self.window:IsShown() then
        self.window:Hide()
        return true
    end

    local guild, partition = self:Context()
    if guild == nil then
        return false
    end
    if self.window == nil then
        local window, reason = self.createWindow()
        if window == nil then
            self:Print("The roster window can't open: " .. tostring(reason) ..
                ". Reinstall the add-on, or in a development checkout run tools/Fetch-Libraries.ps1.")
            return false
        end
        self.window = window
    end

    self.current = { guild = guild, partition = partition }
    if not partition:HasBeenScanned() and self.pendingScan == nil then
        self:Scan(guild, partition)
    end
    self:Refresh()
    self.window:Show()
    return true
end
