local _, addon = ...

-- Connects the guild roster, the store and the scan scheduler, for the AGF
-- window's Guild Roster and `/agf rescan`, and draws the old window's
-- pages (My Profile, Recruitment, Recent ads, Guild Log, Settings) and its
-- guild note Conflicts.
--
-- Opening the window never scans: it only reads live roster facts for
-- display. Scans are the ScanScheduler's job (daily at login, new members
-- as they appear, and on request).
-- Counts an expensive operation for `/agf perf`.
local function bump(name)
    if addon.PerfCounters ~= nil then
        addon.PerfCounters.Bump(name)
    end
end

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
--   onDiscordChanged  optional function(key, text) -> facts or nil: this
--                 user set the Discord username of `key`'s player from the
--                 player panel ("" clears it): official at once for an
--                 officer, a suggestion for a member; nil when it wasn't
--                 saved
--   onProfileTextChanged optional function(key, kind, text) -> facts or
--                 nil: this user set the location or bio ("location" or
--                 "bio") of `key`'s player from the player panel ("" clears
--                 it): their own player's as their own, an officer's for
--                 anyone else; nil when it wasn't saved
--   onAliasChanged  optional function(key, before): after a manual alias
--                 change to the player of `key`, with the alias before it
--                 ("" for none) (for guild sync)
--   onScanFinished  optional function(summary, result): after every
--                   completed scan, with its summary and what ReconcileEngine
--                   applied (result.newKeys: the characters new to the store)
--   onChanged     optional function(): after anything the roster shows
--                 changed (a scan, sync, manual change, or roster update)
--   onDecideSuggestion  optional function(character, kind, approved) ->
--                 ok, reason: decides a member's suggestion in the queue
--   recruitRecord optional function(keys) -> a player's ad record (see
--                 RecruitStats), for the officers' Recruiters leaderboard
--   isOfficer     optional function() -> true when the logged-in character
--                 is an officer; only officers get the Recruiters leaderboard
--   recentAds     optional function() -> the channels advertised in lately,
--                 newest first, as { label, ago } (see GuildRecruit:KnownAds)
--   offZones      optional function() -> the zones turned off with Off
--                 here, as { key, name, at } (see GuildRecruit:OffZones)
--   turnBackOn    optional function(zoneKey): turns a zone's prompts back on
function RosterController.Create(options)
    local controller = setmetatable({
        client = options.client,
        recruitRecord = options.recruitRecord,
        recentAds = options.recentAds,
        offZones = options.offZones,
        turnBackOn = options.turnBackOn,
        guildLog = options.guildLog,
        rankName = options.rankName,
        isOfficer = options.isOfficer or function()
            return false
        end,
        onDecideSuggestion = options.onDecideSuggestion,
        onMainLinksChanged = options.onMainLinksChanged,
        onAliasChanged = options.onAliasChanged,
        onDiscordChanged = options.onDiscordChanged,
        onProfileTextChanged = options.onProfileTextChanged,
        onDeclaredChanged = options.onDeclaredChanged,
        onScanFinished = options.onScanFinished,
        onChanged = options.onChanged,
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

-- The name normalizer for `guild`, made once per guild and reused: it only
-- depends on the guild's home realm and the client's name rules.
function Controller:Normalizer(guild)
    local key = addon.FellowshipStore.PartitionKey(guild) or tostring(guild.realm)
    self.normalizers = self.normalizers or {}
    if self.normalizers[key] == nil then
        self.normalizers[key] = addon.NameNormalizer.Create({
            homeRealm = guild.realm,
            twoPartNames = self.nameRules.twoPartNames,
        })
    end
    return self.normalizers[key]
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
    local key, member
    for key, member in pairs(self:LiveMembers(normalizer)) do
        if member ~= nil then
            if guid ~= nil and member.guid == guid then
                return key
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
-- note conflict, and each player's suggestions once. Nil for a member,
-- who never sees conflicts.
function Controller:PendingConflictCount()
    if not self:IsOfficerUser() then
        return nil
    end
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
    -- The shared roster copy is stale now (see LiveMembers).
    self.rosterGeneration = (self.rosterGeneration or 0) + 1
    self.snapshot = nil
    self.scheduler:OnRosterUpdate()
    self:Invalidate(true)
end

-- Changes whenever saved data the roster shows changes (local edits,
-- scans, guild sync), not on roster updates alone.
function Controller:DataRevision()
    return self.dataRevision or 0
end

-- A stamp for things worked out from saved data and the roster's notes,
-- ranks and levels (the guild note audit): it changes when saved data or
-- what the roster says about anyone changes, not on every roster update.
-- Read the roster (LiveMembers) first, so a new update is counted.
function Controller:AuditStamp(partition)
    return partition.key .. "#" .. tostring(self.dataRevision or 0) .. "#" .. tostring(self.rosterVersion or 0)
end

-- `/agf rescan` and the Guild Roster's Rescan.
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
    -- A Rescan, the first scan, and any scan that found something are
    -- reported; a login scan or a quiet check that found nothing is not. A
    -- member never hears about conflicts.
    local described = summary
    if not self:IsOfficerUser() and (summary.conflicts or 0) > 0 then
        described = {}
        local key, value
        for key, value in pairs(summary) do
            described[key] = value
        end
        described.conflicts = nil
    end
    local found = (described.newCharacters or 0) + (described.linked or 0) + (described.aliased or 0)
        + (described.departed or 0) + (described.rejoined or 0) + (described.promoted or 0)
        + (described.conflicts or 0)
    if described.forced or described.mode == "initial" or found > 0 then
        self:Print("Roster scanned: " .. RosterController.DescribeScan(described) .. ".")
    end
    self:Invalidate()
    if self.onScanFinished ~= nil then
        self.onScanFinished(summary, result)
    end
end

-- For `/agf probe`: when the last full scan ran, and how many notes the
-- latest scan that found anything changed (an incremental scan that found
-- nothing records nothing). Returns lines of text.
function Controller:ScanProbeLines()
    local guild, partition = self:QuietContext()
    if guild == nil then
        return { partition }
    end
    local now = self.client:Timestamp()
    local function ago(at)
        return addon.RosterViewModel.Ago(math.max(0, (now or at) - at))
    end
    local lines = {}
    local full = partition:GetLastScan()
    table.insert(lines, "Last full scan: " .. (full ~= nil and ago(full) or "never") .. ".")
    local summary = partition:GetLastScanSummary()
    if summary == nil then
        table.insert(lines, "Last scan: none yet.")
    else
        local kind = summary.mode == "incremental" and "on a roster update" or "full"
        table.insert(lines, "Last scan (" .. kind .. ", " .. ago(summary.at) .. "): " ..
            plural(summary.notesChanged or 0, "note") .. " changed.")
    end
    if self.scheduler ~= nil and self.scheduler:IsRunning() then
        table.insert(lines, "A scan is running now.")
    end
    return lines
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

-- How many members' suggestions wait for an officer in the current guild
-- (each suggestion, not each player's bundle), or 0 without one.
function Controller:SuggestionCount()
    local guild, partition = self:QuietContext()
    if guild == nil then
        return 0
    end
    local count = 0
    local conflicts = partition:GetConflicts() or {}
    local index
    for index = 1, #conflicts do
        if type(conflicts[index]) == "table" and conflicts[index].from ~= nil then
            count = count + 1
        end
    end
    return count
end

-- The new window's Approve all and Deny all: decides every member's
-- suggestion, and no guild note conflict. Returns how many were decided.
function Controller:DecideAllSuggestions(approved)
    if self.current == nil or not self:IsOfficerUser() then
        return 0
    end
    local decided, reason, refused = self:DecideSuggestions(approved)
    self:Print((approved and "Approved " or "Denied ") .. plural(decided, "suggestion") .. ".")
    self:PrintUndecided(refused, reason)
    self:Refresh()
    return decided
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
    -- Only officers decide conflicts, even from a window left open across
    -- a demotion.
    if self.current == nil or not self:IsOfficerUser() then
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

-- Redraws the bundle under review from `rows` (ConflictViewModel rows) and
-- `members` (live roster facts, for the guild notes), or closes the review
-- once that bundle is all decided.
function Controller:RedrawReview(rows, normalizer, members)
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
                members = members,
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

-- Makes the current guild the one menus and organizing changes apply to,
-- for the new window's Roster, which works without the old window having
-- opened. False without a guild.
function Controller:UseCurrentGuild()
    local guild, partition = self:QuietContext()
    if guild == nil then
        return false
    end
    if self.current == nil or self.current.partition ~= partition then
        self.current = { guild = guild, partition = partition }
    end
    return true
end

-- The right-click menu for a roster row: a list of { text, action }.
-- Character rows offer every organizing action that applies; player
-- headers offer the alias. A member is offered the alias only on their
-- own player.
function Controller:MenuFor(row)
    if self.current == nil or type(row) ~= "table" then
        return {}
    end
    if row.kind == "player" then
        local player = self.current.partition:GetPlayer(row.id)
        if player == nil then
            return {}
        end
        local entries = {}
        if self:CanEditPlayer(player.main) then
            table.insert(entries, { text = "Set alias...", action = "alias", key = player.main })
        end
        table.insert(entries, { text = "View player...", action = "view", key = player.main })
        return entries
    end
    local partition = self.current.partition
    local character = partition:GetCharacter(row.key)
    if character == nil then
        return {}
    end
    local player = partition:GetPlayer(character.player)
    local entries = {}
    -- A member gets the organizing actions only for their own characters.
    local editable = self:CanEditPlayer(row.key)
    if partition:IsInGuild(row.key) then
        -- A main with alts can't join another player.
        if not addon.PlayerService.HasAlts(partition, row.key)
            and (self:IsOfficerUser() or self:IsKnownOwn(row.key))
        then
            table.insert(entries, { text = "Link as alt of...", action = "setMain", key = row.key })
        end
        if editable and player ~= nil and player.main ~= row.key then
            table.insert(entries, { text = "Make this the main", action = "makeMain", key = row.key })
        end
    end
    if editable then
        table.insert(entries, { text = "Set alias...", action = "alias", key = row.key })
    end
    table.insert(entries, { text = "View player...", action = "view", key = row.key })
    if editable and partition:CharactersOf(character.player)[2] ~= nil then
        table.insert(entries, { text = "Split off as own player", action = "detach", key = row.key })
    end
    return entries
end

-- Manual changes that move characters between players or change a main.
local MAIN_LINK_OPERATIONS = { SetMainPlayer = true, MakeMain = true, Detach = true }
-- Manual changes a member may make only to their own player.
local OWN_PLAYER_OPERATIONS = { SetAlias = true, MakeMain = true, Detach = true, SetDeclared = true }
local NOT_OWN_PLAYER = "members can only change their own player"
local NOT_KNOWN_OWN = "members can only link characters the add-on knows are theirs"

function Controller:IsOfficerUser()
    local ok, officer = pcall(self.isOfficer)
    return ok and officer == true
end

-- Whether `key` is on the logged-in character's player.
function Controller:IsOwnPlayer(key)
    local guild, partition = self:QuietContext()
    local selfKey = self:SelfKey()
    if guild == nil or selfKey == nil or type(key) ~= "string" then
        return false
    end
    if key == selfKey then
        return true
    end
    local own = partition:GetCharacter(selfKey)
    local character = partition:GetCharacter(key)
    return own ~= nil and character ~= nil and own.player == character.player
end

-- Whether this user may change the player of `key`: an officer anyone's,
-- a member only their own (the logged-in character's player).
function Controller:CanEditPlayer(key)
    return self:IsOfficerUser() or self:IsOwnPlayer(key)
end

-- Whether the add-on knows `key` is this user's character: on their
-- player, or one this install has logged in on.
function Controller:IsKnownOwn(key)
    if self:IsOwnPlayer(key) then
        return true
    end
    local guild, partition = self:QuietContext()
    if guild == nil then
        return false
    end
    local owned = partition:OwnCharacters()
    local index
    for index = 1, #owned do
        if owned[index] == key then
            return true
        end
    end
    return false
end

-- Whether the player `playerId` has a character the add-on knows is this
-- user's.
function Controller:IsKnownOwnPlayer(playerId)
    local guild, partition = self:QuietContext()
    if guild == nil or playerId == nil then
        return false
    end
    local keys = partition:CharactersOf(playerId)
    local index
    for index = 1, #keys do
        if self:IsKnownOwn(keys[index]) then
            return true
        end
    end
    return false
end

-- Whether this user may link `key` as an alt of the player `playerId`: an
-- officer any; a member only a character the add-on knows is theirs, onto
-- a player the add-on knows is theirs.
function Controller:CanLink(key, playerId)
    return self:IsOfficerUser() or (self:IsKnownOwn(key) and self:IsKnownOwnPlayer(playerId))
end

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
    if OWN_PLAYER_OPERATIONS[operation] and not self:CanEditPlayer(key) then
        self:Print("That change wasn't made: " .. NOT_OWN_PLAYER .. ".")
        return false
    end
    if operation == "SetMainPlayer" and not self:CanLink(key, (...)) then
        self:Print("That change wasn't made: " .. NOT_KNOWN_OWN .. ".")
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

-- "Set Discord…" from the player panel:
-- sets the Discord username of `key`'s player to `text` ("" clears it), as
-- an officer's or as a member's suggestion about their own player, and
-- redraws. The add-on's window needn't have been opened.
function Controller:SetDiscord(key, text)
    if self.onDiscordChanged == nil or (self.current == nil and self:QuietContext() == nil) then
        return false
    end
    if not self:CanEditPlayer(key) then
        self:Print("That Discord username wasn't saved: " .. NOT_OWN_PLAYER .. ".")
        return false
    end
    if self.onDiscordChanged(key, text) == nil then
        self:Print("That Discord username wasn't saved: the server time isn't known yet.")
        return false
    end
    self:Refresh()
    return true
end

-- The Bio tab's Edit: sets the location or bio (`kind`) of `key`'s player
-- to `text` ("" clears it), for the user's own player or, as an officer,
-- anyone's, and redraws.
function Controller:SetProfileText(key, kind, text)
    if self.onProfileTextChanged == nil or (self.current == nil and self:QuietContext() == nil) then
        return false
    end
    local label = kind == "bio" and "That bio" or "That location"
    if not addon.FellowshipStore.IsProfileText(kind, text) then
        self:Print(label .. " wasn't saved: it's longer than " .. tostring(addon.FellowshipStore.PROFILE_FIELDS[kind])
            .. " bytes (an accented letter takes two).")
        return false
    end
    if not self:CanEditPlayer(key) then
        self:Print(label .. " wasn't saved: " .. NOT_OWN_PLAYER .. ".")
        return false
    end
    if self.onProfileTextChanged(key, kind, text) == nil then
        self:Print(label .. " wasn't saved: this character isn't in the guild roster yet, or the server time "
            .. "isn't known yet.")
        return false
    end
    -- The panel can be open without the window.
    self:Invalidate()
    return true
end

-- "Declare as my main": `key` must be its player's main.
function Controller:SetDeclared(key, declared)
    return self:Organize("SetDeclared", key, declared)
end

-- How many players the "Link as alt of…" picker lists at most.
RosterController.SEARCH_LIMIT = 50

-- Results for the "Link as alt of…" picker, without `key`'s own player; a
-- member gets only players the add-on knows are theirs.
function Controller:SearchPlayers(key, query)
    if self.current == nil then
        return {}
    end
    local service = self:Service()
    local ownPlayer = service:PlayerOf(key)
    local results = {}
    -- Filtered before the limit, so a member's own players aren't crowded
    -- out by matches they can't pick.
    local found = service:SearchPlayers(query)
    local index
    for index = 1, #found do
        if #results >= RosterController.SEARCH_LIMIT then
            break
        end
        if found[index].id ~= ownPlayer and self:CanLink(key, found[index].id) then
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

-- True when two roster reads hold the same characters with the same notes,
-- ranks and levels.
local function sameRosterFacts(members, last)
    if last == nil then
        return false
    end
    local count = 0
    local key, member
    for key, member in pairs(members) do
        local before = last[key]
        if before == nil or before.note ~= member.note or before.rankIndex ~= member.rankIndex
            or before.level ~= member.level
        then
            return false
        end
        count = count + 1
    end
    for _ in pairs(last) do
        count = count - 1
    end
    return count == 0
end

-- Live roster facts for display, keyed by character key. Unlike a scan,
-- this tolerates a partial roster.
--
-- The roster is read once per roster update and that one copy is shared by
-- every caller until the next update (OnRosterUpdate): callers must treat
-- it as read-only. An empty roster (not loaded yet) is read again next time.
function Controller:LiveMembers(normalizer)
    local snapshot = self.snapshot
    if snapshot ~= nil and snapshot.normalizer == normalizer and snapshot.generation == self.rosterGeneration then
        return snapshot.members
    end
    bump("rosterReads")
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
    if next(members) ~= nil then
        self.snapshot = { normalizer = normalizer, generation = self.rosterGeneration, members = members }
        -- What the roster says about anyone changed (see AuditStamp).
        if not sameRosterFacts(members, self.lastMembers) then
            self.rosterVersion = (self.rosterVersion or 0) + 1
        end
        self.lastMembers = members
    end
    return members
end

-- Something the roster shows changed (saved data, live facts, or a view
-- setting): bump the revision and redraw.
function Controller:Refresh()
    self.revision = (self.revision or 0) + 1
    self.dataRevision = (self.dataRevision or 0) + 1
    self:Redraw()
    self:NotifyChanged()
end

function Controller:NotifyChanged()
    if self.onChanged ~= nil then
        self.onChanged()
    end
end

-- Data changed: a shown window redraws now; a hidden one when it next
-- opens. `fromRoster` when it's only the live roster that may have changed
-- (a roster update), not saved data.
function Controller:Invalidate(fromRoster)
    self.revision = (self.revision or 0) + 1
    if not fromRoster then
        self.dataRevision = (self.dataRevision or 0) + 1
    end
    if self.window ~= nil and self.window:IsShown() then
        self:Redraw()
    end
    self:NotifyChanged()
end

-- Draws the old window's guild note Conflicts from the store plus live
-- roster facts, only when the revision or guild changed since the last
-- draw.
function Controller:Redraw()
    if self.window == nil or self.current == nil then
        return
    end
    local stamp = self.current.partition.key .. "#" .. tostring(self.revision or 0)
    if self.drawnStamp ~= stamp then
        self.drawnStamp = stamp
        local normalizer = self:Normalizer(self.current.guild)
        local members = self:LiveMembers(normalizer)
        self.window:SetTitle(addon.Identity.displayName .. " - " .. self.current.guild.name)
        local conflictRows = addon.ConflictViewModel.Build({
            partition = self.current.partition,
            members = members,
            normalizer = normalizer,
            pending = self.current.partition:GetSuggestions(),
        })
        self.window:SetConflicts(conflictRows)
        -- Only officers see Conflicts; this follows a promotion or
        -- demotion at the next redraw.
        if type(self.window.SetConflictsShown) == "function" then
            self.window:SetConflictsShown(self:IsOfficerUser())
        end
        self:RedrawReview(conflictRows, normalizer, members)
    end
    self:RefreshRecruiters()
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
-- recent }: its column titles), and says so when there are none. Then,
-- when any zone was turned off with Off here, a heading and a row for each,
-- with when it was turned off and a button (`action`) to turn it back on.
--   { kind = "ad", label, by, recent }    -- recent: how long ago
--   { kind = "empty", label }
--   { kind = "off", label, by, action, zoneKey }
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
    local okZones, zones = pcall(self.offZones or function() return {} end)
    zones = okZones and type(zones) == "table" and zones or {}
    if zones[1] ~= nil then
        table.insert(rows, { kind = "empty", label = "" })
        table.insert(rows, { kind = "heading", label = "Turned off with Off here", by = "Since", recent = "" })
    end
    for index = 1, #zones do
        table.insert(rows, {
            kind = "off",
            label = zones[index].name .. " (General and Trade)",
            by = self.client:FormatDate(zones[index].at),
            action = "Turn back on",
            zoneKey = zones[index].key,
        })
    end
    return rows
end

-- "Turn back on" on the Recent ads page: prompts in the zone `zoneKey`
-- may show again, and the page redraws.
function Controller:TurnBackOn(zoneKey)
    if self.turnBackOn ~= nil then
        pcall(self.turnBackOn, zoneKey)
    end
    self:RefreshRecruiters()
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

-- How the Guild Log page is sorted and filtered now (see GuildLog:Query):
-- sort ("date" or "name"), types (shown entry types, as a set), range
-- (days back, or nil for all), search text, and page.
function Controller:GuildLogFilters()
    if self.logFilters == nil then
        local types = {}
        local index
        for index = 1, #addon.GuildLog.TYPES do
            types[addon.GuildLog.TYPES[index]] = true
        end
        self.logFilters = { sort = "date", types = types, range = nil, search = "", page = 1 }
    end
    return self.logFilters
end

-- The characters a Guild Log search for `text` matches: every character of
-- each player whose alias, or any of whose characters' names, contains it,
-- and characters the roster no longer knows whose logged name contains it.
-- Nil for no search.
function Controller:GuildLogSearchSet(text, log, partition, normalizer)
    local needle = string.lower((string.gsub(text or "", "^%s*(.-)%s*$", "%1")))
    if needle == "" then
        return nil
    end
    local function contains(value)
        return type(value) == "string" and string.find(string.lower(value), needle, 1, true) ~= nil
    end
    local set = {}
    if partition ~= nil then
        partition:EachPlayer(function(id, player)
            local keys = partition:CharactersOf(id)
            local matched = contains(player.alias)
            local index
            for index = 1, #keys do
                local character = partition:GetCharacter(keys[index])
                matched = matched or contains(normalizer:Display(character and character.name or keys[index]))
            end
            if matched then
                for index = 1, #keys do
                    set[keys[index]] = true
                end
            end
        end)
    end
    local entries = log:Entries()
    local index
    for index = 1, #entries do
        local entry = entries[index]
        local known = partition ~= nil and partition:GetCharacter(entry.character) ~= nil
        if not known and (contains(entry.name) or contains(entry.character)) then
            set[entry.character] = true
        end
    end
    return set
end

-- The Guild Log page, for officers: one page of entries that pass the
-- filters (see GuildLogFilters), with a heading row naming the columns
-- first, or a line saying nothing matches. The second result says where
-- the page is: { page, pages, total, filters }. Nil for anyone else (see
-- GuildLog).
--   { kind = "heading" | "entry", date, event, eventType, character, player,
--     actor }, `eventType` an entry's GuildLog type
--   { kind = "empty", event }
function Controller:GuildLogView()
    local ok, log = pcall(self.guildLog or function() return nil end)
    if not ok or log == nil then
        return nil
    end
    local guild, partition, normalizer = self:QuietContext()
    if guild == nil then
        partition, normalizer = nil, nil
    end
    local filters = self:GuildLogFilters()
    local function name(key, given)
        if key == nil then
            return ""
        end
        local character = partition ~= nil and partition:GetCharacter(key) or nil
        local raw = (character and character.name) or given or key
        return normalizer and normalizer:Display(raw) or raw
    end
    local now = self.client:Timestamp()
    local result = log:Query({
        types = filters.types,
        from = (filters.range ~= nil and now ~= nil) and (now - filters.range * addon.GuildLog.DAY) or nil,
        characters = self:GuildLogSearchSet(filters.search, log, partition, normalizer),
        sort = filters.sort,
        nameOf = function(entry)
            return name(entry.character, entry.name)
        end,
        page = filters.page,
    })
    filters.page = result.page
    local rows = { {
        kind = "heading", date = "Date", event = "Event", character = "Character", player = "Player",
        actor = "By",
    } }
    local index
    for index = 1, #result.entries do
        local entry = result.entries[index]
        table.insert(rows, {
            kind = "entry",
            date = self.client:FormatDate(entry.at),
            event = addon.GuildLog.Describe(entry, self.rankName),
            eventType = entry.type,
            character = name(entry.character, entry.name),
            player = partition ~= nil and self:PosterLabel({ k = entry.character, n = entry.name }, partition,
                normalizer) or "",
            actor = name(entry.actor, entry.actorName),
        })
    end
    if result.entries[1] == nil then
        table.insert(rows, { kind = "empty", event = "Nothing in the guild log matches." })
    end
    return rows, { page = result.page, pages = result.pages, total = result.total, filters = filters }
end

-- The Guild Log page's controls: each changes the filters, goes back to
-- the first page, and redraws.
function Controller:SetGuildLogSort(sort)
    self:GuildLogFilters().sort = sort == "name" and "name" or "date"
    self:GuildLogFilters().page = 1
    self:RefreshGuildLog()
end

function Controller:SetGuildLogType(eventType, shown)
    self:GuildLogFilters().types[eventType] = shown == true or nil
    self:GuildLogFilters().page = 1
    self:RefreshGuildLog()
end

-- `days` back (7, 30, or 90), or nil for all.
function Controller:SetGuildLogRange(days)
    self:GuildLogFilters().range = type(days) == "number" and days or nil
    self:GuildLogFilters().page = 1
    self:RefreshGuildLog()
end

function Controller:SetGuildLogSearch(text)
    self:GuildLogFilters().search = type(text) == "string" and text or ""
    self:GuildLogFilters().page = 1
    self:RefreshGuildLog()
end

-- Shows page `page` of the filtered log (kept within the pages there are).
function Controller:SetGuildLogPage(page)
    self:GuildLogFilters().page = page
    self:RefreshGuildLog()
end

-- Redraws the Guild Log page when the window is open.
function Controller:RefreshGuildLog()
    if self.window == nil or not self.window:IsShown() or type(self.window.SetGuildLog) ~= "function" then
        return
    end
    local rows, state = self:GuildLogView()
    if rows ~= nil then
        self.window:SetGuildLog(rows, state)
    end
end

-- Shows or hides the tabs whose pages follow the character's rank (see
-- PageNavigator), falling back to the home page when the page showing is
-- hidden now. Run when the roster changes, so a promotion or demotion
-- needs no reload.
function Controller:RefreshPages()
    if self.window ~= nil and type(self.window.ShowPage) == "function" then
        self.window:ShowPage(nil)
    end
end

-- Selects the page `entry` opens (see PageNavigator:PageFor) and shows it
-- in the window.
function Controller:ShowPage(entry)
    if self.pages == nil or self.window == nil then
        return
    end
    self.pages:Select(self.pages:PageFor(entry))
    if type(self.window.ShowPage) == "function" then
        self.window:ShowPage(self.pages:Current())
    end
end

-- `/agf profile` and the like: opens the old window on the page `entry`
-- opens (My Profile unless it names another), whatever page showed last. When the window is already showing that page, it closes instead.
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
    self:RefreshGuildLog()
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
