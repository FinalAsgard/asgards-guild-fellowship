local _, addon = ...

-- Connects the guild roster, the store, the scan scheduler, and the roster
-- window for `/agf`, `/agf rescan`, and the window's Rescan button.
--
-- Opening the window never scans: it only reads live roster facts for
-- display. Scans are the ScanScheduler's job (daily at login, new members
-- as they appear, and on request).
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
    local controller = setmetatable({
        client = options.client,
        collapsed = {},
        createWindow = options.createWindow,
        getDatabase = options.getDatabase,
        nameRules = options.nameRules or {},
    }, Controller)
    controller.scheduler = addon.ScanScheduler.Create({
        client = controller.client,
        rules = controller.nameRules,
        context = function()
            return controller:QuietContext()
        end,
        onFinished = function(result, summary)
            controller:OnScanFinished(result, summary)
        end,
    })
    return controller
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

-- The current guild, its partition, and a normalizer, or nil and the
-- message explaining why not.
function Controller:QuietContext()
    local guild = self.client:GetGuildIdentity()
    if guild == nil then
        if self.client:IsInGuild() then
            return nil, "Guild information isn't available yet. Try again in a moment."
        end
        return nil, "You're not in a guild, so there is no roster to show."
    end
    local store = self:Store()
    if store == nil then
        return nil, "Saved data is unavailable, so the roster can't be shown."
    end
    local partition, reason = store:Partition(guild)
    if partition == nil then
        return nil, "The roster can't be shown: " .. tostring(reason) .. "."
    end
    return guild, partition, self:Normalizer(guild)
end

function Controller:Context()
    local guild, partition, normalizer = self:QuietContext()
    if guild == nil then
        self:Print(partition)
        return nil
    end
    return guild, partition, normalizer
end

-- Saved data is ready (after login): let the scheduler run its daily check.
function Controller:OnSavedDataReady()
    self.scheduler:OnSavedDataReady()
end

function Controller:OnRosterUpdate()
    self.scheduler:OnRosterUpdate()
    if self.window ~= nil and self.window:IsShown() then
        self:Refresh()
    end
end

-- `/agf rescan` and the Rescan button.
function Controller:Rescan()
    if self.scheduler:IsRunning() then
        self:Print("A roster scan is already running.")
        return false
    end
    local guild = self:Context()
    if guild == nil then
        return false
    end
    self:Print("Scanning the guild roster...")
    self:UpdateStatus()
    return self.scheduler:RequestFull(true)
end

local function plural(count, word, many)
    return count .. " " .. (count == 1 and word or (many or (word .. "s")))
end

-- What a scan found, in words.
function RosterController.DescribeScan(summary)
    local parts = { plural(summary.newCharacters or 0, "new character") }
    if (summary.linked or 0) > 0 then
        table.insert(parts, plural(summary.linked, "alt") .. " linked")
    end
    if (summary.aliased or 0) > 0 then
        table.insert(parts, plural(summary.aliased, "alias", "aliases") .. " set")
    end
    if (summary.conflicts or 0) > 0 then
        table.insert(parts, plural(summary.conflicts, "new conflict") .. " to review")
    end
    return table.concat(parts, ", ")
end

function Controller:OnScanFinished(result, summary)
    -- Incremental pickups that found new characters, and every full scan,
    -- are reported; quiet checks are not.
    if summary.mode ~= "incremental" or summary.newCharacters > 0 then
        self:Print("Roster scanned: " .. RosterController.DescribeScan(summary) .. ".")
    end
    if self.window ~= nil and self.window:IsShown() then
        self:Refresh()
    end
end

-- "Last scan 5 minutes ago: 3 new characters, 1 alt linked".
function Controller:StatusText(partition)
    if self.scheduler:IsRunning() then
        return "Scanning the guild roster..."
    end
    local summary = partition:GetLastScanSummary()
    if summary == nil then
        return "Not scanned yet. The roster is scanned once it loads, or use Rescan."
    end
    local now = self.client:Timestamp() or summary.at
    local elapsed = math.max(0, now - summary.at)
    local when
    if elapsed < 60 then
        when = "just now"
    elseif elapsed < 3600 then
        when = plural(math.floor(elapsed / 60), "minute") .. " ago"
    elseif elapsed < 86400 then
        when = plural(math.floor(elapsed / 3600), "hour") .. " ago"
    else
        when = plural(math.floor(elapsed / 86400), "day") .. " ago"
    end
    return "Last scan " .. when .. ": " .. RosterController.DescribeScan(summary)
end

function Controller:UpdateStatus()
    if self.window ~= nil and self.current ~= nil then
        self.window:SetStatus(self:StatusText(self.current.partition))
    end
end

-- Conflict review. Each action resolves through PlayerService, then
-- redraws the roster and the conflict list.
function Controller:ResolveConflicts(action, character, kind)
    if self.current == nil then
        return false
    end
    local service = addon.PlayerService.Create(self.current.partition)
    local ok, reason
    if action == "accept" then
        ok, reason = service:AcceptConflict(character, kind)
    elseif action == "reject" then
        ok, reason = service:RejectConflict(character, kind)
    elseif action == "acceptAll" then
        local accepted, dismissed = service:AcceptAll()
        self:Print("Accepted " .. plural(accepted, "conflict") .. " and dismissed " .. dismissed .. ".")
        ok = true
    elseif action == "rejectAll" then
        local rejected = service:RejectAll()
        self:Print("Rejected " .. plural(rejected, "conflict") .. ".")
        ok = true
    end
    if not ok and reason ~= nil then
        self:Print("That conflict can't be accepted: " .. reason .. ".")
    end
    self:Refresh()
    return ok == true
end

function Controller:AcceptConflict(character, kind)
    return self:ResolveConflicts("accept", character, kind)
end

function Controller:RejectConflict(character, kind)
    return self:ResolveConflicts("reject", character, kind)
end

function Controller:AcceptAllConflicts()
    return self:ResolveConflicts("acceptAll")
end

function Controller:RejectAllConflicts()
    return self:ResolveConflicts("rejectAll")
end

-- Collapses or expands a player's group. The state lasts for the session.
function Controller:ToggleGroup(playerId)
    if playerId == nil then
        return
    end
    self.collapsed[playerId] = not self.collapsed[playerId] or nil
    self:Refresh()
end

-- Live roster facts for display, keyed by character key. Unlike a scan,
-- this tolerates a partial roster.
function Controller:LiveMembers(normalizer)
    local members = {}
    local count = self.client:GetGuildRosterCount() or 0
    local index
    for index = 1, count do
        local member = self.client:GetGuildMember(index)
        local key = member and normalizer:Key(member.name)
        if key ~= nil then
            members[key] = member
        end
    end
    return members
end

-- Redraws the window from the store plus live roster facts.
function Controller:Refresh()
    if self.window == nil or self.current == nil then
        return
    end
    local normalizer = self:Normalizer(self.current.guild)
    local members = self:LiveMembers(normalizer)
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
    self.window:SetConflicts(addon.ConflictViewModel.Build({
        partition = self.current.partition,
        members = members,
        normalizer = normalizer,
    }))
    self:UpdateStatus()
end

-- `/agf`: shows or hides the roster window. Never scans.
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
    self:Refresh()
    self.window:Show()
    return true
end
