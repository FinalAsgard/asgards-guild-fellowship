local _, addon = ...

-- Composition root: builds the modules in order. Besides the adapter, this is
-- the only place that consults the client profile.
local client = addon.Compatibility.Create()
local clientProfile = client:GetClientProfile()
local version = client:GetAddOnMetadata("Version") or "unknown"
local router = addon.CommandRouter.Create(function(message)
    client:Print(message)
end)

local libraryCheck = addon.LibraryCheck.Create(client)

router:Register("help", "show available commands", function()
    router:PrintHelp()
    client:Print(addon.Identity.chatPrefix .. " Version " .. version ..
        " on " .. clientProfile.label .. ".")
    client:Print(libraryCheck:Summary())
end)

-- Libraries load before this file, so they are checked now. The router still
-- starts, so `help` works with libraries missing.
local missingLibraries = libraryCheck:MissingMessage()
if missingLibraries ~= nil then
    client:Print(missingLibraries)
end

local persistence, rosterController, entryPoints, chatAnnotator, comm, syncSession, settings, settingsPanel
local guildGreet, greetingsWindow, greetPrompts
if clientProfile.supported then
    persistence = addon.Persistence.Create(client)
    comm = addon.Comm.Create(client, addon.Identity.commPrefix)
    rosterController = addon.RosterController.Create({
        client = client,
        nameRules = clientProfile.nameRules,
        onMainLinksChanged = function(keys, before)
            syncSession:LocalEdit(keys, before)
        end,
        onAliasChanged = function(key)
            syncSession:LocalAliasEdit(key)
        end,
        onScanFinished = function()
            syncSession:UpgradeLegacy()
        end,
        onSyncResumed = function(key)
            syncSession:Rejoin(key)
        end,
        onDecideSuggestion = function(character, kind, approved)
            return syncSession:Decide(character, kind, approved)
        end,
        getDatabase = function()
            return persistence:GetDatabase()
        end,
        createWindow = function()
            return addon.RosterWindow.Create(client, {
                loadGeometry = function()
                    local store = rosterController:Store()
                    return store and store:GetWindowState()
                end,
                saveGeometry = function(state)
                    local store = rosterController:Store()
                    if store ~= nil then
                        store:SetWindowState(state)
                    end
                end,
                onToggleGroup = function(playerId)
                    rosterController:ToggleGroup(playerId)
                end,
                onRescan = function()
                    rosterController:Rescan()
                end,
                onAcceptConflict = function(character, kind)
                    rosterController:AcceptConflict(character, kind)
                end,
                onRejectConflict = function(character, kind)
                    rosterController:RejectConflict(character, kind)
                end,
                onAcceptAll = function()
                    rosterController:AcceptAllConflicts()
                end,
                onRejectAll = function()
                    rosterController:RejectAllConflicts()
                end,
                onToggleDeparted = function()
                    return rosterController:ToggleDeparted()
                end,
                onPurge = function(key)
                    rosterController:Purge(key)
                end,
                onPurgeAll = function()
                    rosterController:PurgeAllDeparted()
                end,
                menuFor = function(row)
                    return rosterController:MenuFor(row)
                end,
                onSetMain = function(key, playerId)
                    rosterController:SetMainPlayer(key, playerId)
                end,
                onMakeMain = function(key)
                    rosterController:MakeMain(key)
                end,
                onSetAlias = function(key, text)
                    rosterController:SetAlias(key, text)
                end,
                onDetach = function(key)
                    rosterController:Detach(key)
                end,
                searchPlayers = function(key, query)
                    return rosterController:SearchPlayers(key, query)
                end,
                aliasOf = function(key)
                    return rosterController:AliasOf(key)
                end,
                onSearch = function(text)
                    rosterController:SetSearch(text)
                end,
                onToggleOnlineOnly = function()
                    return rosterController:ToggleOnlineOnly()
                end,
                onExpandAll = function()
                    rosterController:ExpandAll()
                end,
                onCollapseAll = function()
                    rosterController:CollapseAll()
                end,
                onSelectCharacter = function(key)
                    rosterController:SelectPlayerOf(key)
                end,
                onClosePanel = function()
                    rosterController:ClosePanel()
                end,
                onSetDontSync = function(key, enabled)
                    rosterController:SetDontSync(key, enabled)
                end,
                onMenuUnavailable = function()
                    rosterController:Print("The organize menu isn't available on this client.")
                end,
            })
        end,
    })
    router:Register("roster", "show or hide the roster window", function()
        rosterController:Toggle()
    end)
    router:Register("rescan", "rescan the guild roster now", function()
        rosterController:Rescan()
    end)
    -- Every setting, one section per feature. The panel and the slash
    -- commands both go through it.
    settings = addon.SettingsModel.Create()
    settings:AddSection("general", "General")
    settings:Add("general", {
        id = "minimap",
        kind = "toggle",
        label = "Show the minimap button",
        get = function()
            return entryPoints:MinimapShown()
        end,
        set = function(shown)
            return entryPoints:SetMinimapShown(shown)
        end,
    })
    settings:Add("general", {
        id = "openRoster",
        kind = "action",
        label = "Open Roster",
        run = function()
            rosterController:Open()
        end,
    })
    settings:Add("general", {
        id = "version",
        kind = "text",
        get = function()
            return "Version " .. version .. " on " .. clientProfile.label .. "."
        end,
    })
    settings:AddSection("chatTags", "Chat Tags")
    settings:Add("chatTags", {
        id = "chatTags",
        kind = "toggle",
        label = "Tag guild chat speakers with their alias or main",
        get = function()
            local store = rosterController:Store()
            return store == nil or store:ChatTagsEnabled()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetChatTagsEnabled(enabled) then
                return nil, "the saved setting is unreadable, so they stay on"
            end
            return true
        end,
    })
    settings:AddSection("guildGreet", "Guild Greet")
    settings:Add("guildGreet", {
        id = "guildGreet",
        kind = "toggle",
        label = "Offer to greet guild members as they come online",
        get = function()
            local store = rosterController:Store()
            return store == nil or store:GreetEnabled()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetGreetEnabled(enabled) then
                return nil, "the saved setting is unreadable, so it stays on"
            end
            return true
        end,
    })
    -- Not saved: the prompts lock again after a reload.
    settings:Add("guildGreet", {
        id = "greetUnlock",
        kind = "toggle",
        label = "Unlock greet prompts to drag them somewhere else",
        get = function()
            return greetPrompts:IsUnlocked()
        end,
        set = function(unlocked)
            return greetPrompts:SetUnlocked(unlocked)
        end,
    })
    -- The greetings themselves are edited in their own window, made on
    -- first use.
    local function openGreetings()
        if greetingsWindow == nil then
            local reason
            greetingsWindow, reason = addon.GreetingsWindow.Create(client, {
                library = function()
                    return guildGreet:Library()
                end,
                after = function(seconds, callback)
                    return client:After(seconds, callback)
                end,
            })
            if greetingsWindow == nil then
                rosterController:Print("The Greetings window can't open: " .. tostring(reason) ..
                    ". Reinstall the add-on, or in a development checkout run tools/Fetch-Libraries.ps1.")
                return
            end
        end
        greetingsWindow:Open()
    end
    settings:Add("guildGreet", {
        id = "editGreetings",
        kind = "action",
        label = "Edit Greetings",
        run = openGreetings,
    })
    settingsPanel = addon.SettingsPanel.Create(client, settings)
    router:Register("options", "open the settings panel", function()
        if not settingsPanel:Open() then
            rosterController:Print("The settings panel isn't available on this client.")
        end
    end)
    router:Register("greet", "edit your Guild Greet greetings", openGreetings)
    router:Register("minimap", "show or hide the minimap button", function()
        local shown, reason = settings:Toggle("minimap")
        if shown == nil then
            rosterController:Print("Can't change the minimap button: " .. reason .. ".")
        elseif shown then
            rosterController:Print("Minimap button shown.")
        else
            rosterController:Print("Minimap button hidden. Type the command again to bring it back.")
        end
    end)
    router:Register("tags", "turn chat tags on or off", function()
        local enabled, reason = settings:Toggle("chatTags")
        if enabled == nil then
            rosterController:Print("Chat tags can't be changed: " .. reason .. ".")
        elseif enabled then
            rosterController:Print("Chat tags on.")
        else
            rosterController:Print("Chat tags off.")
        end
    end)
    router:SetDefault("roster")
    -- Guild sync: officers are ranks that can view officer notes, judged
    -- from the stored roster (current members only).
    local officerAuthority = addon.OfficerAuthority.Create({
        rankOf = function(key)
            local guild, partition = rosterController:QuietContext()
            if guild == nil or not partition:IsInGuild(key) then
                return nil
            end
            return partition:GetCharacter(key).rank
        end,
        rankCanViewOfficerNotes = function(rank)
            return comm:RankCanViewOfficerNotes(rank)
        end,
    })
    syncSession = addon.SyncSession.Create({
        comm = comm,
        context = function()
            local guild, partition, normalizer = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            return partition, normalizer
        end,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        now = function()
            return client:Timestamp()
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        -- Read from the live roster, only when a member has suggestions to
        -- send.
        officerOnline = function()
            local guild, _, normalizer = rosterController:QuietContext()
            local count = client:GetGuildRosterCount()
            if guild == nil or count == nil then
                return false
            end
            local selfKey = syncSession.selfKey()
            local index
            for index = 1, count do
                local member = client:GetGuildMember(index)
                local key = member and member.online and normalizer:Key(member.name)
                if key and key ~= selfKey and officerAuthority:IsOfficer(key) then
                    return true
                end
            end
            return false
        end,
        onApplied = function()
            rosterController:Invalidate()
        end,
        onForgery = function(count, relayedBy)
            rosterController:Print("Warning: " .. tostring(relayedBy) .. " passed on " ..
                (count == 1 and "a guild sync edit" or (count .. " guild sync edits")) ..
                " in your name that you never made. Your own data was sent to the guild to correct it," ..
                " and the forgery was logged.")
        end,
        -- Sync never competes with play.
        busy = function()
            return comm:IsBusy()
        end,
        preciseMs = function()
            return client:PreciseMilliseconds()
        end,
        onError = function(problem)
            rosterController:Print("Guild sync failed: " .. tostring(problem))
        end,
        onSynced = function()
            rosterController:UpdateStatus()
        end,
    })
    router:Register("sync", "show guild sync status", function()
        local lines = addon.RosterViewModel.SyncStatusLines(syncSession:Status(), client:Timestamp())
        local index
        for index = 1, #lines do
            rosterController:Print(lines[index])
        end
    end)
    -- Prompts stack from a place the user can move; it's saved account-wide.
    greetPrompts = addon.GreetPrompts.Create(client, {
        loadAnchor = function()
            local store = rosterController:Store()
            return store and store:GreetAnchor()
        end,
        saveAnchor = function(anchor)
            local store = rosterController:Store()
            if store ~= nil then
                store:SetGreetAnchor(anchor)
            end
        end,
    })
    -- Guild Greet reads the same guild context as the roster.
    guildGreet = addon.GuildGreet.Create({
        context = function()
            local guild, partition, normalizer = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            return partition, normalizer
        end,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        store = function()
            return rosterController:Store()
        end,
        now = function()
            return client:Timestamp()
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        send = function(text)
            return client:SendGuildMessage(text)
        end,
        view = greetPrompts,
    })
    settings:OnChange(function(id, value)
        if id == "guildGreet" then
            guildGreet:OnEnabledChanged(value)
        end
    end)
    client:ObserveGuildRoster(function()
        rosterController:OnRosterUpdate()
        -- The first loaded roster tells Guild Greet who was already online
        -- and how long everyone else has been away.
        guildGreet:OnRosterUpdate(function()
            local count = client:GetGuildRosterCount()
            if count == nil or count == 0 then
                return nil
            end
            local members = {}
            local index
            for index = 1, count do
                local member = client:GetGuildMember(index)
                if member ~= nil then
                    table.insert(members, member)
                end
            end
            return members
        end)
    end)
    -- Chat tags read the same guild context as the roster.
    chatAnnotator = addon.ChatAnnotator.Create({
        context = function()
            local guild, partition, normalizer = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            return partition, normalizer
        end,
        isSecret = function(value)
            return client:IsSecretValue(value)
        end,
        enabled = function()
            local store = rosterController:Store()
            return store == nil or store:ChatTagsEnabled()
        end,
    })
    entryPoints = addon.EntryPoints.Create({
        client = client,
        toggle = function()
            rosterController:Toggle()
        end,
        conflictCount = function()
            return rosterController:PendingConflictCount()
        end,
        minimapState = function()
            local store = rosterController:Store()
            return store and store:GetMinimapState()
        end,
    })
else
    -- Never touch saved data on a client we cannot identify.
    client:Print(addon.Identity.chatPrefix .. " This game client is not supported (" ..
        clientProfile.reason .. "). Supported clients are WoW Forever and WoW Retail. " ..
        "Saved data was left unchanged.")
end

local lifecycle = addon.Lifecycle.Create(client, router, persistence, rosterController and function()
    rosterController:OnSavedDataReady()
    -- Without the comm libraries, sync simply stays off.
    if comm:Start(function(message, sender)
        syncSession:Receive(message, sender)
    end) then
        syncSession:Start()
    end
    -- The minimap button needs saved data for its position.
    entryPoints:Start()
    -- Settings show saved values, so the panel waits for saved data too.
    settingsPanel:Register()
    -- Without the system message event, Guild Greet simply never prompts.
    client:ObservePresence(function(kind, name)
        guildGreet:OnPresence(kind, name)
    end)
    -- Prompts wait out combat and boss encounters.
    local busy = client:ObserveCombat(function(inCombat)
        guildGreet:OnCombatChanged(inCombat)
    end)
    if busy then
        guildGreet:OnCombatChanged(true)
    end
    -- Without a chat filter API, chat is simply left untagged.
    client:AddChatMessageFilter(addon.ChatAnnotator.EVENTS, function(event, message, sender)
        return chatAnnotator:Annotate(event, message, sender)
    end)
end)

addon.client = client
addon.clientProfile = clientProfile
addon.libraryCheck = libraryCheck
addon.lifecycle = lifecycle
addon.persistence = persistence
addon.rosterController = rosterController
addon.entryPoints = entryPoints
addon.chatAnnotator = chatAnnotator
addon.comm = comm
addon.settings = settings
addon.settingsPanel = settingsPanel
addon.guildGreet = guildGreet
addon.syncSession = syncSession
addon.router = router
addon.version = version

lifecycle:Start()
