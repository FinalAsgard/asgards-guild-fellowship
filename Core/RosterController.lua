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
--   pages         optional PageNavigator: the window's pages, chosen by
--                 the entry point that opens it
--   onMainLinksChanged  optional function(keys, before): after a manual
--                 change to main links, with the set of every character
--                 key whose player was involved, and each one's main before
--                 the change (for guild sync)
--   onDeclaredChanged optional function(key, before): after `key` was
--                 declared its player's main by hand, or that was taken back,
--                 with whether it was declared before (for guild sync)
--   onAliasChanged  optional function(key, before): after a manual alias
--                 change to the player of `key`, with the alias before it
--                 ("" for none) (for guild sync)
--   onScanFinished  optional function(): after every completed scan
--   onChanged     optional function(): after anything the roster shows
--                 changed (a scan, sync, manual change, or roster update)
--   onSyncResumed  optional function(key): after "Don't sync" was turned
--                 off for the player of `key`
--   onDecideSuggestion  optional function(character, kind, approved) ->
--                 ok, reason: decides a member's suggestion in the queue
--   adStats       optional function(keys) -> a player's ad count line for
--                 the player panel, or nil
--   rolesOf       optional function(key) -> a character's role preferences
--                 for the player panel ("Tank, DPS"), or nil
--   groupedWith   optional function(keys) -> how often this user grouped
--                 with a player, for the player panel, or nil
--   recruitRecord optional function(keys) -> a player's ad record (see
--                 RecruitStats), for the officers' Recruiters leaderboard
--   isOfficer     optional function() -> true when the logged-in character
--                 is an officer; only officers get the Recruiters leaderboard
--   recentAds     optional function() -> the channels advertised in lately,
--                 newest first, as { label, ago } (see GuildRecruit:KnownAds)
function RosterController.Create(options)
    local controller = setmetatable({
        client = options.client,
        adStats = options.adStats,
        rolesOf = options.rolesOf,
        groupedWith = options.groupedWith,
        recruitRecord = options.recruitRecord,
        recentAds = options.recentAds,
        isOfficer = options.isOfficer or function()
            return false
        end,
        onDecideSuggestion = options.onDecideSuggestion,
        onMainLinksChanged = options.onMainLinksChanged,
        onAliasChanged = options.onAliasChanged,
        onDeclaredChanged = options.onDeclaredChanged,
        onScanFinished = options.onScanFinished,
        onChanged = options.onChanged,
        onSyncResumed = options.onSyncResumed,
        collapsed = {},
        showDeparted = false,
        createWindow = options.createWindow,
        pages = options.pages,
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

-- The logged-in character's key in the current guild's roster, or nil.
-- The game spells the player's own name differently from the roster on
-- some clients (WoW Forever reports only the first name), so the roster
-- decides: the stored character named "Name-Realm" when there is one,
-- otherwise the roster member with the player's GUID, otherwise (with
-- two-part names) the only roster member with the player's first name.
-- A key found in the roster is remembered for this guild and character.
function Controller:SelfKey()
    local guild, partition, normalizer = self:QuietContext()
    local fullName = self.client:GetPlayerFullName()
    if guild == nil or fullName == nil then
        return nil
    end
    local guid = self.client:GetPlayerGuid()
    local cache = self.selfKeyCache
    if cache ~= nil and cache.partition == partition.key and cache.fullName == fullName and cache.guid == guid then
        return cache.key
    end
    local key = normalizer:Key(fullName)
    if key == nil or partition:GetCharacter(key) == nil then
        key = self:FindInRoster(normalizer, fullName, guid)
        if key == nil then
            -- Not in the roster yet: Name-Realm is the best guess, except
            -- where it can't be right (only the first name).
            return not self.nameRules.twoPartNames and normalizer:Key(fullName) or nil
        end
    end
    self.selfKeyCache = { partition = partition.key, fullName = fullName, guid = guid, key = key }
    return key
end

-- Another character's key in the current guild's roster (a party member,
-- say), by the same rules as SelfKey: the stored character named
-- "Name-Realm", otherwise the roster member with that GUID, otherwise (with
-- two-part names) the only roster member with that first name and no
-- other GUID. Nil when they aren't in the guild, or the first name is
-- shared.
function Controller:RosterKeyFor(name, guid)
    local guild, partition, normalizer = self:QuietContext()
    if guild == nil then
        return nil
    end
    local key = normalizer:Key(name)
    if key ~= nil and partition:GetCharacter(key) ~= nil then
        return key
    end
    return self:FindInRoster(normalizer, name, guid)
end

function Controller:FindInRoster(normalizer, fullName, guid)
    local firstName = normalizer:FirstName(fullName)
    local byName
    local count = self.client:GetGuildRosterCount() or 0
    local index
    for index = 1, count do
        local member = self.client:GetGuildMember(index)
        if member ~= nil then
            if guid ~= nil and member.guid == guid then
                return normalizer:Key(member.name)
            end
            -- A member whose GUID differs is someone else with that first
            -- name (an outsider in the party, say).
            if firstName ~= nil and normalizer:FirstName(member.name) == firstName
                and (guid == nil or member.guid == nil or member.guid == guid) then
                -- Two members sharing the first name: can't tell which.
                byName = byName == nil and normalizer:Key(member.name) or false
            end
        end
    end
    return byName or nil
end

function Controller:Context()
    local guild, partition, normalizer = self:QuietContext()
    if guild == nil then
        self:Print(partition)
        return nil
    end
    return guild, partition, normalizer
end

-- Pending conflicts for the current guild, for the minimap tooltip: each
-- note conflict, and each player's suggestions once.
function Controller:PendingConflictCount()
    local guild, partition = self:QuietContext()
    if guild == nil then
        return 0
    end
    return addon.ConflictViewModel.CountQueue(partition)
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

-- "Last scan 5 minutes ago: 3 new characters, 1 alt linked", and below it
-- "Synced 2 minutes ago".
function Controller:StatusText(partition)
    local now = self.client:Timestamp()
    local sync = addon.RosterViewModel.SyncText(partition:GetLastSync(), now)
    if self.scheduler:IsRunning() then
        return "Scanning the guild roster...\n" .. sync
    end
    local summary = partition:GetLastScanSummary()
    if summary == nil then
        return "Not scanned yet. The roster is scanned once it loads, or use Rescan.\n" .. sync
    end
    local when = addon.RosterViewModel.Ago(math.max(0, (now or summary.at) - summary.at))
    return "Last scan " .. when .. ": " .. RosterController.DescribeScan(summary) .. "\n" .. sync
end

function Controller:UpdateStatus()
    if self.window ~= nil and self.current ~= nil then
        self.window:SetStatus(self:StatusText(self.current.partition))
    end
end

-- Decides members' suggestions in the queue (all of them, or the one about
-- `character` of `kind`) through onDecideSuggestion. Returns how many were
-- decided, the last refusal, and how many were refused.
function Controller:DecideSuggestions(approved, character, kind)
    local decided, reason = 0, nil
    local entries = {}
    local conflicts = self.current.partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local entry = conflicts[index]
        if entry.from ~= nil and (character == nil or (entry.character == character and entry.kind == kind)) then
            table.insert(entries, { character = entry.character, kind = entry.kind })
        end
    end
    if self.onDecideSuggestion == nil then
        return 0, "guild sync is not available", #entries
    end
    for index = 1, #entries do
        local ok, why = self.onDecideSuggestion(entries[index].character, entries[index].kind, approved)
        if ok then
            decided = decided + 1
        else
            reason = why
        end
    end
    return decided, reason, #entries - decided
end

-- After deciding everything: says how many members' suggestions are still
-- waiting, and why.
function Controller:PrintUndecided(refused, reason)
    if refused == nil or refused == 0 then
        return
    end
    local count = refused == 1 and "1 suggestion wasn't" or (refused .. " suggestions weren't")
    self:Print(count .. " decided: " .. (reason or "it was refused") .. ".")
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
        local approved, why, refused = self:DecideSuggestions(true)
        local accepted, dismissed = service:AcceptAll()
        self:Print("Accepted " .. plural(accepted + approved, "conflict") .. " and dismissed " .. dismissed .. ".")
        self:PrintUndecided(refused, why)
        ok = true
    elseif action == "rejectAll" then
        local declined, why, refused = self:DecideSuggestions(false)
        local rejected = service:RejectAll()
        self:Print("Rejected " .. plural(rejected + declined, "conflict") .. ".")
        self:PrintUndecided(refused, why)
        ok = true
    end
    if not ok and reason ~= nil then
        self:Print("That conflict can't be accepted: " .. reason .. ".")
    end
    self:Refresh()
    return ok == true
end

-- Members' suggestions are reviewed one player's bundle at a time (see
-- ConflictViewModel.GroupOf): opens the review of bundle `group`.
function Controller:ReviewBundle(group)
    if self.current == nil then
        return false
    end
    self.reviewing = group
    self:Refresh()
    return true
end

-- Redraws the bundle under review from `rows` (ConflictViewModel rows), or
-- closes the review once that bundle is all decided.
function Controller:RedrawReview(rows, normalizer)
    if self.reviewing == nil or type(self.window.ShowReview) ~= "function" then
        return
    end
    local index
    for index = 1, #rows do
        if rows[index].kind == "bundle" and rows[index].group == self.reviewing then
            self.window:ShowReview(addon.BundleReviewViewModel.Build({
                partition = self.current.partition,
                normalizer = normalizer,
                bundle = rows[index],
            }))
            return
        end
    end
    self.reviewing = nil
    if type(self.window.HideReview) == "function" then
        self.window:HideReview()
    end
end

-- The review closed.
function Controller:CloseReview()
    self.reviewing = nil
end

-- Approve all or Deny all for bundle `group`: decides each of that player's
-- suggestions, as Accept and Reject do one at a time.
function Controller:DecideBundle(group, approved)
    if self.current == nil then
        return 0
    end
    local partition = self.current.partition
    local entries = {}
    local conflicts = partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        local entry = conflicts[index]
        if entry.from ~= nil and addon.ConflictViewModel.GroupOf(partition, entry.from) == group then
            table.insert(entries, { character = entry.character, kind = entry.kind })
        end
    end
    local decided, reason = 0, nil
    for index = 1, #entries do
        local ok, why = false, "guild sync is not available"
        if self.onDecideSuggestion ~= nil then
            ok, why = self.onDecideSuggestion(entries[index].character, entries[index].kind, approved)
        end
        if ok then
            decided = decided + 1
        else
            reason = why
        end
    end
    self:Print((approved and "Approved " or "Denied ") .. plural(decided, "change") .. ".")
    self:PrintUndecided(#entries - decided, reason)
    self:Refresh()
    return decided
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
        -- A main with alts can't join another player.
        if not addon.PlayerService.HasAlts(partition, row.key) then
            table.insert(entries, { text = "Link as alt of...", action = "setMain", key = row.key })
        end
        if player ~= nil and player.main ~= row.key then
            table.insert(entries, { text = "Make this the main", action = "makeMain", key = row.key })
        end
    end
    table.insert(entries, { text = "Set alias...", action = "alias", key = row.key })
    table.insert(entries, { text = "View player...", action = "view", key = row.key })
    if partition:CharactersOf(character.player)[2] ~= nil then
        table.insert(entries, { text = "Split off as own player", action = "detach", key = row.key })
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
-- change; an alias change reports its character to onAliasChanged, with
-- the alias before the change ("" for none).
function Controller:Organize(operation, key, ...)
    if self.current == nil then
        return false
    end
    local service = self:Service()
    local involved, before
    local aliasBefore = operation == "SetAlias" and self:AliasOf(key) or nil
    local declaredBefore = operation == "SetDeclared" and self.current.partition:IsDeclared(key) or nil
    if MAIN_LINK_OPERATIONS[operation] then
        involved = self:AddPlayerKeys({}, key)
        -- "Link as alt of…" also involves the player the character joins.
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
        self.onAliasChanged(key, aliasBefore)
    elseif operation == "SetDeclared" and self.onDeclaredChanged ~= nil then
        self.onDeclaredChanged(key, declaredBefore == true)
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

-- "Declare as my main": `key` must be its player's main.
function Controller:SetDeclared(key, declared)
    return self:Organize("SetDeclared", key, declared)
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

-- Results for the "Link as alt of…" picker, without `key`'s own player.
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
        adStats = self.adStats,
        rolesOf = self.rolesOf,
        groupedWith = self.groupedWith,
        -- The window wraps the bio to the panel's width, when it can
        -- measure text.
        wrap = self.window.WrapAbout and function(text)
            return self.window:WrapAbout(text)
        end or nil,
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
    self:NotifyChanged()
end

function Controller:NotifyChanged()
    if self.onChanged ~= nil then
        self.onChanged()
    end
end

-- Data changed: the rows are stale even while the window is hidden, so the
-- next open rebuilds them. Only a shown window redraws now.
function Controller:Invalidate()
    self.revision = (self.revision or 0) + 1
    if self.window ~= nil and self.window:IsShown() then
        self:Redraw()
    end
    self:NotifyChanged()
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
        local conflictRows = addon.ConflictViewModel.Build({
            partition = self.current.partition,
            members = members,
            normalizer = normalizer,
            pending = self.current.partition:GetSuggestions(),
        })
        self.window:SetConflicts(conflictRows)
        self:RedrawReview(conflictRows, normalizer)
        self:RedrawPanel()
    end
    self:RefreshRecruiters()
    self:UpdateStatus()
end

-- The officers' Recruiters rows (see RecruitStats.Recruiters) for the
-- current guild, or nil for anyone who isn't an officer.
function Controller:Recruiters()
    local ok, officer = pcall(self.isOfficer)
    local guild, partition, normalizer = self:QuietContext()
    if not ok or officer ~= true or guild == nil or self.recruitRecord == nil then
        return nil
    end
    return addon.RecruitStats.Recruiters({
        partition = partition,
        normalizer = normalizer,
        recordOf = self.recruitRecord,
        now = self.client:Timestamp(),
    })
end

-- The Recruiters leaderboard's rows for an officer, or nil for anyone else.
-- It starts with a heading row ({ kind = "heading", label, recent, total }:
-- its column titles), and says so when nobody has advertised.
--   { kind = "recruiter", label, recent, total }
--   { kind = "empty", label }
function Controller:RecruitersView()
    local recruiters = self:Recruiters()
    if recruiters == nil then
        return nil
    end
    local rows = { { kind = "heading", label = "Player", recent = "Last 30 days", total = "All time" } }
    local index
    for index = 1, #recruiters do
        local row = recruiters[index]
        table.insert(rows, { kind = "recruiter", label = row.label, recent = row.recent, total = row.total })
    end
    if recruiters[1] == nil then
        table.insert(rows, { kind = "empty", label = "Nobody has advertised yet." })
    end
    return rows
end

-- Who posted an ad, as the Recruiters leaderboard names players: the alias,
-- else the main's name. Someone the roster doesn't know goes by their own
-- name. Nil when the poster isn't known.
function Controller:PosterLabel(poster, partition, normalizer)
    if type(poster) ~= "table" then
        return nil
    end
    local character = type(poster.k) == "string" and partition:GetCharacter(poster.k) or nil
    local player = character and partition:GetPlayer(character.player)
    if player ~= nil then
        if player.alias ~= nil then
            return player.alias
        end
        local main = partition:GetCharacter(player.main)
        return normalizer:Display(main and main.name or player.main)
    end
    local name = poster.n or poster.k
    return name and normalizer:Display(name) or nil
end

-- The Recent ads page's rows, for every member: the channels this client
-- knows were advertised in lately, newest first, with who posted and how
-- long ago. It starts with a heading row ({ kind = "heading", label, by,
-- recent }: its column titles), and says so when there are none.
--   { kind = "ad", label, by, recent }    -- recent: how long ago
--   { kind = "empty", label }
function Controller:RecentAdsView()
    local rows = { { kind = "heading", label = "Channel", by = "Posted by", recent = "When" } }
    local guild, partition, normalizer = self:QuietContext()
    local ok, ads = pcall(self.recentAds or function() return {} end)
    ads = ok and type(ads) == "table" and ads or {}
    local index
    for index = 1, #ads do
        local by = guild ~= nil and self:PosterLabel(ads[index].poster, partition, normalizer) or nil
        table.insert(rows, {
            kind = "ad",
            label = ads[index].label,
            by = by or "|cff9d9d9dnot known|r",
            recent = ads[index].ago,
        })
    end
    if ads[1] == nil then
        table.insert(rows, { kind = "empty", label = "No recent ads known." })
    end
    return rows
end

-- Redraws the Recruiters leaderboard on the Recruitment page, and the
-- Recent ads page, when the window is open: officers get their leaderboard
-- rows, everyone else no leaderboard; everyone gets the recent ads.
function Controller:RefreshRecruiters()
    if self.window == nil or not self.window:IsShown() then
        return
    end
    if type(self.window.SetRecruiters) == "function" then
        self.window:SetRecruiters(self:RecruitersView())
    end
    if type(self.window.SetRecentAds) == "function" then
        self.window:SetRecentAds(self:RecentAdsView())
    end
end

-- Selects the page `entry` opens (see PageNavigator:PageFor) and shows it
-- in the window.
function Controller:ShowPage(entry)
    if self.pages == nil then
        return
    end
    self.pages:Select(self.pages:PageFor(entry))
    if type(self.window.ShowPage) == "function" then
        self.window:ShowPage(self.pages:Current())
    end
end

-- `/agf` and the other entry points: opens the window on the page `entry`
-- opens (the Roster page unless it names another), whatever page showed
-- last. When the window is already showing that page, it closes instead.
-- Never scans.
function Controller:Toggle(entry)
    if self.window ~= nil and self.window:IsShown() then
        if self.pages ~= nil and self.pages:Current() ~= self.pages:PageFor(entry) then
            self:ShowPage(entry)
            return true
        end
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
    self:ShowPage(entry)
    self.window:Show()
    self:RefreshRecruiters()
    return true
end

-- The AddOns options' Open window button: shows the window on the page
-- `entry` opens, leaving it open when it already is.
function Controller:Open(entry)
    if self.window ~= nil and self.window:IsShown() then
        self:ShowPage(entry)
        return true
    end
    return self:Toggle(entry)
end
