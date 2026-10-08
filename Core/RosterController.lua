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
--   onMainLinksChanged  optional function(keys, before): after a manual
--                 change to main links, with the set of every character
--                 key whose player was involved, and each one's main before
--                 the change (for guild sync)
--   onAliasChanged  optional function(key): after a manual alias change to
--                 the player of `key` (for guild sync)
--   onScanFinished  optional function(): after every completed scan
--   onSyncResumed  optional function(key): after "Don't sync" was turned
--                 off for the player of `key`
--   onDecideSuggestion  optional function(character, kind, approved) ->
--                 ok, reason: decides a member's suggestion in the queue
function RosterController.Create(options)
    local controller = setmetatable({
        client = options.client,
        onDecideSuggestion = options.onDecideSuggestion,
        onMainLinksChanged = options.onMainLinksChanged,
        onAliasChanged = options.onAliasChanged,
        onScanFinished = options.onScanFinished,
        onSyncResumed = options.onSyncResumed,
        collapsed = {},
        showDeparted = false,
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

-- Pending conflicts for the current guild, for the minimap tooltip.
function Controller:PendingConflictCount()
    local guild, partition = self:QuietContext()
    if guild == nil then
        return 0
    end
    return #(partition:GetConflicts() or {})
end

-- Saved data is ready (after login): let the scheduler run its daily check.
function Controller:OnSavedDataReady()
    self.scheduler:OnSavedDataReady()
end

function Controller:OnRosterUpdate()
    self.scheduler:OnRosterUpdate()
    self:Invalidate()
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
    if (summary.departed or 0) > 0 then
        table.insert(parts, plural(summary.departed, "character") .. " left")
    end
    if (summary.rejoined or 0) > 0 then
        table.insert(parts, plural(summary.rejoined, "character") .. " rejoined")
    end
    if (summary.promoted or 0) > 0 then
        table.insert(parts, plural(summary.promoted, "new acting main"))
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
    self:Invalidate()
    if self.onScanFinished ~= nil then
        self.onScanFinished()
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

-- Decides members' suggestions in the queue (all of them, or the one about
-- `character` of `kind`) through onDecideSuggestion. Returns how many were
-- decided, and the last refusal.
function Controller:DecideSuggestions(approved, character, kind)
    local decided, reason = 0, nil
    if self.onDecideSuggestion == nil then
        return 0, "guild sync is not available"
    end
    local entries = {}
    local conflicts = self.current.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local entry = conflicts[index]
        if entry.from ~= nil and (character == nil or (entry.character == character and entry.kind == kind)) then
            table.insert(entries, { character = entry.character, kind = entry.kind })
        end
    end
    for index = 1, #entries do
        local ok, why = self.onDecideSuggestion(entries[index].character, entries[index].kind, approved)
        if ok then
            decided = decided + 1
        else
            reason = why
        end
    end
    return decided, reason
end

-- Conflict review. Note conflicts resolve through PlayerService, members'
-- suggestions through guild sync; then the roster and the conflict list are
-- redrawn.
function Controller:ResolveConflicts(action, character, kind)
    if self.current == nil then
        return false
    end
    local service = self:Service()
    local ok, reason
    local suggestion = addon.SuggestionService.KINDS[kind] == true
    if (action == "accept" or action == "reject") and suggestion then
        local decided
        decided, reason = self:DecideSuggestions(action == "accept", character, kind)
        ok = decided > 0
    elseif action == "accept" then
        ok, reason = service:AcceptConflict(character, kind)
    elseif action == "reject" then
        ok, reason = service:RejectConflict(character, kind)
    elseif action == "acceptAll" then
        local approved = self:DecideSuggestions(true)
        local accepted, dismissed = service:AcceptAll()
        self:Print("Accepted " .. plural(accepted + approved, "conflict") .. " and dismissed " .. dismissed .. ".")
        ok = true
    elseif action == "rejectAll" then
        local declined = self:DecideSuggestions(false)
        local rejected = service:RejectAll()
        self:Print("Rejected " .. plural(rejected + declined, "conflict") .. ".")
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

function Controller:Service()
    return addon.PlayerService.Create(self.current.partition, {
        normalizer = self:Normalizer(self.current.guild),
        now = function()
            return self.client:Timestamp() or 0
        end,
    })
end

-- The right-click menu for a roster row: a list of { text, action }.
-- Character rows offer every organizing action that applies; player
-- headers offer the alias.
function Controller:MenuFor(row)
    if self.current == nil or type(row) ~= "table" then
        return {}
    end
    if row.kind == "player" then
        local player = self.current.partition:GetPlayer(row.id)
        return player and {
            { text = "Set alias...", action = "alias", key = player.main },
            { text = "View player...", action = "view", key = player.main },
        } or {}
    end
    local partition = self.current.partition
    local character = partition:GetCharacter(row.key)
    if character == nil then
        return {}
    end
    local player = partition:GetPlayer(character.player)
    local entries = {}
    if partition:IsInGuild(row.key) then
        table.insert(entries, { text = "Set main...", action = "setMain", key = row.key })
        if player ~= nil and player.main ~= row.key then
            table.insert(entries, { text = "Make this the main", action = "makeMain", key = row.key })
        end
    end
    table.insert(entries, { text = "Set alias...", action = "alias", key = row.key })
    table.insert(entries, { text = "View player...", action = "view", key = row.key })
    if partition:CharactersOf(character.player)[2] ~= nil then
        table.insert(entries, { text = "Detach as own player", action = "detach", key = row.key })
    end
    return entries
end

-- Manual changes that move characters between players or change a main.
local MAIN_LINK_OPERATIONS = { SetMainPlayer = true, MakeMain = true, Detach = true }

-- Adds every character of `key`'s player to the set `keys`.
function Controller:AddPlayerKeys(keys, key)
    local character = self.current.partition:GetCharacter(key)
    if character == nil then
        return keys
    end
    local members = self.current.partition:CharactersOf(character.player)
    local index
    for index = 1, #members do
        keys[members[index]] = true
    end
    return keys
end

-- The main of each character's player, for a set of character keys.
function Controller:MainsOf(keys)
    local mains = {}
    local key
    for key in pairs(keys) do
        local character = self.current.partition:GetCharacter(key)
        local player = character and self.current.partition:GetPlayer(character.player)
        mains[key] = player and player.main
    end
    return mains
end

-- Runs a manual change, reports a refusal, and redraws at once (no scan).
-- A change to main links reports every character of the players involved,
-- before and after, to onMainLinksChanged, with each one's main before the
-- change; an alias change reports its character to onAliasChanged.
function Controller:Organize(operation, key, ...)
    if self.current == nil then
        return false
    end
    local service = self:Service()
    local involved, before
    if MAIN_LINK_OPERATIONS[operation] then
        involved = self:AddPlayerKeys({}, key)
        -- "Set main…" also involves the player the character joins.
        local target = operation == "SetMainPlayer" and select(1, ...) or nil
        local joined = target ~= nil and self.current.partition:GetPlayer(target)
        if joined then
            self:AddPlayerKeys(involved, joined.main)
        end
        before = self:MainsOf(involved)
    end
    local ok, reason = service[operation](service, key, ...)
    if not ok then
        self:Print("That change wasn't made: " .. tostring(reason) .. ".")
    elseif involved ~= nil and self.onMainLinksChanged ~= nil then
        self.onMainLinksChanged(self:AddPlayerKeys(involved, key), before)
    elseif operation == "SetAlias" and self.onAliasChanged ~= nil then
        self.onAliasChanged(key)
    end
    self:Refresh()
    return ok == true
end

function Controller:SetMainPlayer(key, playerId)
    return self:Organize("SetMainPlayer", key, playerId)
end

function Controller:MakeMain(key)
    return self:Organize("MakeMain", key)
end

function Controller:SetAlias(key, alias)
    return self:Organize("SetAlias", key, alias)
end

function Controller:Detach(key)
    return self:Organize("Detach", key)
end

-- Turns "Don't sync" on or off for `key`'s player. Turning it off reports
-- the player to onSyncResumed, so guild sync can bring it back in line.
function Controller:SetDontSync(key, enabled)
    if self.current == nil then
        return false
    end
    local ok, reason = self:Service():SetDontSync(key, enabled)
    if not ok then
        self:Print("That change wasn't made: " .. tostring(reason) .. ".")
    elseif not enabled and self.onSyncResumed ~= nil then
        self.onSyncResumed(key)
    end
    self:Refresh()
    return ok == true
end

-- Results for the "Set main…" picker, without `key`'s own player.
function Controller:SearchPlayers(key, query)
    if self.current == nil then
        return {}
    end
    local service = self:Service()
    local ownPlayer = service:PlayerOf(key)
    local results = {}
    local found = service:SearchPlayers(query, 50)
    local index
    for index = 1, #found do
        if found[index].id ~= ownPlayer then
            table.insert(results, found[index])
        end
    end
    return results
end

-- The alias to prefill in "Set alias…".
function Controller:AliasOf(key)
    if self.current == nil then
        return ""
    end
    local _, player = self:Service():PlayerOf(key)
    return player and player.alias or ""
end

-- Shows or hides characters who left the guild. Lasts for the session.
function Controller:ToggleDeparted()
    self.showDeparted = not self.showDeparted
    self:Refresh()
    return self.showDeparted
end

-- Purges one departed character, keeping its player's history entry.
function Controller:Purge(key)
    if self.current == nil then
        return false
    end
    local ok, reason = self:Service():Purge(key)
    if not ok then
        self:Print("That character can't be purged: " .. reason .. ".")
    end
    self:Refresh()
    return ok
end

function Controller:PurgeAllDeparted()
    if self.current == nil then
        return 0
    end
    local purged = self:Service():PurgeAllDeparted()
    self:Print("Purged " .. plural(purged, "departed character") .. ".")
    self:Refresh()
    return purged
end

-- The player edit panel ------------------------------------------------------

-- Selects a player (by id, or by one of its characters' keys) and opens the
-- edit panel for it.
function Controller:SelectPlayer(playerId)
    if self.current == nil or self.current.partition:GetPlayer(playerId) == nil then
        return false
    end
    self.selected = playerId
    self:RedrawPanel()
    return true
end

function Controller:SelectPlayerOf(key)
    local character = self.current and self.current.partition:GetCharacter(key)
    return character ~= nil and self:SelectPlayer(character.player)
end

function Controller:ClosePanel()
    self.selected = nil
    if self.window ~= nil then
        self.window:HidePlayer()
    end
end

-- Rebuilds the panel for the selected player, or closes it when that player
-- no longer exists (merged away, or purged).
function Controller:RedrawPanel()
    if self.window == nil or self.current == nil or self.selected == nil then
        return
    end
    local normalizer = self:Normalizer(self.current.guild)
    local model = addon.PlayerPanelViewModel.Build({
        partition = self.current.partition,
        playerId = self.selected,
        members = self.liveMembers or self:LiveMembers(normalizer),
        normalizer = normalizer,
        formatDate = function(timestamp)
            return self.client:FormatDate(timestamp)
        end,
    })
    if model == nil then
        self:ClosePanel()
        return
    end
    self.window:ShowPlayer(model)
end

-- Collapses or expands a player's group. The state lasts for the session,
-- so groups stay as they were when the window is reopened.
function Controller:ToggleGroup(playerId)
    if playerId == nil then
        return
    end
    self.collapsed[playerId] = not self.collapsed[playerId] or nil
    self:Refresh()
end

function Controller:ExpandAll()
    self.collapsed = {}
    self:Refresh()
end

function Controller:CollapseAll()
    if self.current == nil then
        return
    end
    self.collapsed = {}
    local ids = addon.RosterViewModel.GroupIds(self.current.partition)
    local index
    for index = 1, #ids do
        self.collapsed[ids[index]] = true
    end
    self:Refresh()
end

-- The search box: matches character names and aliases.
function Controller:SetSearch(text)
    local search = type(text) == "string" and text or ""
    if search == self.search then
        return
    end
    self.search = search
    self:Refresh()
end

function Controller:ToggleOnlineOnly()
    self.onlineOnly = not self.onlineOnly
    self:Refresh()
    return self.onlineOnly
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

-- Something the roster shows changed (saved data, live facts, or a view
-- setting): bump the revision and redraw.
function Controller:Refresh()
    self.revision = (self.revision or 0) + 1
    self:Redraw()
end

-- Data changed: the rows are stale even while the window is hidden, so the
-- next open rebuilds them. Only a shown window redraws now.
function Controller:Invalidate()
    self.revision = (self.revision or 0) + 1
    if self.window ~= nil and self.window:IsShown() then
        self:Redraw()
    end
end

-- Draws the window from the store plus live roster facts. The rows are
-- only rebuilt when the revision or guild changed since the last build.
function Controller:Redraw()
    if self.window == nil or self.current == nil then
        return
    end
    local stamp = self.current.partition.key .. "#" .. tostring(self.revision or 0)
    if self.cache == nil then
        self.cache = addon.RosterViewModel.CreateCache()
    end
    if self.cache.stamp ~= stamp then
        local normalizer = self:Normalizer(self.current.guild)
        local members = self:LiveMembers(normalizer)
        self.liveMembers = members
        local rows = self.cache:Build({
            partition = self.current.partition,
            members = members,
            normalizer = normalizer,
            classColor = function(classToken)
                return self.client:GetClassColor(classToken)
            end,
            collapsed = self.collapsed,
            showDeparted = self.showDeparted == true,
            onlineOnly = self.onlineOnly == true,
            search = self.search,
            now = self.client:Timestamp(),
        }, stamp)
        self.window:SetTitle(addon.Identity.displayName .. " - " .. self.current.guild.name)
        self.window:SetRows(rows)
        self.window:SetConflicts(addon.ConflictViewModel.Build({
            partition = self.current.partition,
            members = members,
            normalizer = normalizer,
        }))
        self:RedrawPanel()
    end
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

    -- Reopening with nothing changed reuses the last build.
    self.current = { guild = guild, partition = partition }
    self:Redraw()
    self.window:Show()
    return true
end
