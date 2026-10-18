local addonName, addon = ...

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

local persistence, rosterController, entryPoints, chatAnnotator, comm, syncSession, settings, settingsPanel, pages
local frameSettings
local guildGreet, greetPrompts, guildRecruit, recruitPrompts, officerAuthority
local guildMail, guildMailWindow
local guildNoteOverlay
local locationBoard, locationScheduler, mapPins, onLocationMessage, startLocations, shareLocationNow
local dropOfflineLocations
local groupFinder, groupSession, syncParty, groupAvailability, joinRequests, joinPrompts, onGroupFinderMessage
local onSlotsChanged, groupBoard, announceGroup
-- Draws the Group Finder on its tab (set up with the Group Finder below).
local drawGroupFinder
-- Draws My Profile on its tab (set up with My Profile below).
local drawProfile
-- Records the party in the local group history (set up with the Group
-- Finder below).
local recordParty = function() end
-- Remembers that this install logged in on the current character (set up
-- with the roster below).
local recordOwnCharacter = function() end
if clientProfile.supported then
    persistence = addon.Persistence.Create(client)
    comm = addon.Comm.Create(client, addon.Identity.commPrefix)
    -- The master frame's tabs, in order. The first is where the general
    -- entry points open it.
    pages = addon.PageNavigator.Create()
    pages:Add("roster", "Roster", addon.MasterFrame.ICONS.roster)
    pages:Add("profile", "My Profile", addon.MasterFrame.ICONS.profile)
    pages:Add("group", "Group Finder", addon.MasterFrame.ICONS.group)
    pages:Add("recruitment", "Recruitment", addon.MasterFrame.ICONS.recruitment)
    pages:Add("ads", "Recent Guild Advertisements", addon.MasterFrame.ICONS.ads)
    pages:Add("greetings", "Greetings", addon.MasterFrame.ICONS.greetings)
    pages:Add("settings", "Settings", addon.MasterFrame.ICONS.settings)
    -- This install has logged in on this character: My Profile can offer it
    -- to the player's other characters as an alt. Recorded once per session
    -- as soon as the roster knows the character (on a roster update or after
    -- a scan), not only after a scan that found something. Local only,
    -- never synced, never linked by itself.
    local recordedOwn
    recordOwnCharacter = function()
        local guild, partition = rosterController:QuietContext()
        local selfKey = rosterController:SelfKey()
        local now = client:Timestamp()
        if guild == nil or selfKey == nil or now == nil or partition:GetCharacter(selfKey) == nil then
            return
        end
        local recorded = partition.key .. "#" .. selfKey
        if recordedOwn ~= recorded and partition:RecordOwnCharacter(selfKey, now) then
            recordedOwn = recorded
        end
    end
    -- Which roles each class can fill here, for role preferences and the
    -- Group Finder.
    local roleCatalog = addon.RoleCatalog.For(clientProfile.id)
    -- The roles a character is willing to play: its own preferences, else
    -- its class's roles. Nil outside a guild or for an unknown character.
    local function rolesOf(key)
        local guild, partition = rosterController:QuietContext()
        if guild == nil or key == nil then
            return nil
        end
        return roleCatalog:PreferencesOf(partition, key)
    end
    rosterController = addon.RosterController.Create({
        pages = pages,
        client = client,
        nameRules = clientProfile.nameRules,
        onMainLinksChanged = function(keys, before)
            syncSession:LocalEdit(keys, before)
        end,
        onAliasChanged = function(key, before)
            syncSession:LocalAliasEdit(key, before)
        end,
        onDiscordChanged = function(key, text)
            return syncSession:LocalDiscordEdit(key, text)
        end,
        onDeclaredChanged = function(key, before)
            syncSession:LocalDeclaredEdit(key, before)
        end,
        onScanFinished = function()
            syncSession:UpgradeLegacy()
            recordOwnCharacter()
        end,
        -- Out-of-date guild notes are worked out again after every scan,
        -- sync, and manual change.
        onChanged = function()
            if guildNoteOverlay ~= nil then
                guildNoteOverlay:Refresh()
            end
        end,
        onSyncResumed = function(key)
            syncSession:Rejoin(key)
        end,
        onDecideSuggestion = function(character, kind, approved)
            return syncSession:Decide(character, kind, approved)
        end,
        adStats = function(keys)
            return guildRecruit:StatsLine(keys)
        end,
        rolesOf = function(key)
            local roles = rolesOf(key)
            return roles and addon.RoleCatalog.Describe(roles) or nil
        end,
        groupedWith = function(keys)
            local guild, partition = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            return addon.GroupHistory.Create(partition):Line(keys, function(timestamp)
                return client:FormatDate(timestamp)
            end)
        end,
        recruitRecord = function(keys)
            return guildRecruit:RecordFor(keys)
        end,
        recentAds = function()
            return guildRecruit:KnownAds()
        end,
        offZones = function()
            return guildRecruit:OffZones()
        end,
        turnBackOn = function(zoneKey)
            guildRecruit:TurnBackOn(zoneKey)
        end,
        isOfficer = function()
            return guildRecruit:IsOfficer()
        end,
        getDatabase = function()
            return persistence:GetDatabase()
        end,
        createWindow = function()
            return addon.RosterWindow.Create(client, {
                navigator = pages,
                drawPages = {
                    group = function(content)
                        if drawGroupFinder ~= nil then
                            drawGroupFinder(content)
                        end
                    end,
                    profile = function(content)
                        if drawProfile ~= nil then
                            drawProfile(content)
                        end
                    end,
                    -- Below the frame's title bar.
                    settings = function(content)
                        frameSettings:Draw(content, settings:SectionsOn("settings"), 28)
                        frameSettings:Refresh()
                    end,
                    -- The Recruitment settings, with room below them for the
                    -- officers' leaderboard (drawn by the roster window).
                    recruitment = function(content)
                        local _, below = frameSettings:Draw(content, settings:SectionsOn("recruitment"), 28,
                            addon.RosterWindow.LEADERBOARD_HEIGHT)
                        frameSettings:Refresh()
                        return below
                    end,
                    -- Guild Greet's settings, with the greetings editor below
                    -- them on the same scrolling page.
                    greetings = function(content, framework)
                        local _, footer = frameSettings:Draw(content, settings:SectionsOn("greetings"), 28,
                            addon.GreetingsPage.HEIGHT)
                        frameSettings:Refresh()
                        local editor, reason = addon.GreetingsPage.Create(framework, footer, {
                            library = function()
                                return guildGreet:Library()
                            end,
                            after = function(seconds, callback)
                                return client:After(seconds, callback)
                            end,
                        })
                        if editor == nil then
                            rosterController:Print("The greetings editor can't be shown: " .. tostring(reason) .. ".")
                        end
                    end,
                },
                -- Modes that last only while the frame is open end with it.
                onHide = function()
                    settings:Closed()
                end,
                onRecentAdsShown = function()
                    rosterController:RefreshRecruiters()
                end,
                onTurnBackOn = function(zoneKey)
                    rosterController:TurnBackOn(zoneKey)
                end,
                loadGeometry = function()
                    local store = rosterController:Store()
                    return store and store:GetFrameState()
                end,
                saveGeometry = function(state)
                    local store = rosterController:Store()
                    if store ~= nil then
                        store:SetFrameState(state)
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
                onReviewBundle = function(group)
                    rosterController:ReviewBundle(group)
                end,
                onDecideBundle = function(group, approved)
                    rosterController:DecideBundle(group, approved)
                end,
                onCloseReview = function()
                    rosterController:CloseReview()
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
                onSetDiscord = function(key, text)
                    rosterController:SetDiscord(key, text)
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
    -- The add-on's own page in the AddOns options; each feature's section
    -- gets a sub-page under it.
    settings:AddSection("about", addon.Identity.displayName, { home = true })
    settings:Add("about", {
        id = "openWindow",
        kind = "action",
        label = "Open window",
        run = function()
            rosterController:Open()
        end,
    })
    settings:Add("about", {
        id = "aboutVersion",
        kind = "text",
        get = function()
            return "Version " .. version .. " on " .. clientProfile.label .. "."
        end,
    })
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
    -- Each kind of tag's color, account-wide; unset, its default.
    local function tagColor(kind, label, sample)
        settings:Add("chatTags", {
            id = "chatTagColor:" .. kind,
            kind = "color",
            label = label,
            sample = sample,
            default = addon.ChatAnnotator.COLORS[kind],
            swatches = addon.ChatAnnotator.SWATCHES,
            get = function()
                local store = rosterController:Store()
                return store and store:ChatTagColor(kind) or addon.ChatAnnotator.COLORS[kind]
            end,
            set = function(color)
                local store = rosterController:Store()
                if store == nil then
                    return nil, "saved data is unavailable"
                end
                if not store:SetChatTagColor(kind, color) then
                    return nil, "the saved colors are unreadable"
                end
                return true
            end,
        })
    end
    tagColor("alias", "Alias tag color", "[TheTool]")
    tagColor("main", "Main's name tag color", "[Hammer]")
    settings:AddSection("guildGreet", "Guild Greet", { page = "greetings" })
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
    -- The character that's logged in; the set of characters it's off on is
    -- account-wide.
    settings:Add("guildGreet", {
        id = "greetCharacter",
        kind = "toggle",
        label = "Greet from this character",
        info = function()
            return "The setting above turns Guild Greet on or off for every character on this account. " ..
                "This one only stops the prompts on the character you're playing now, for example an alt " ..
                "in another guild, and leaves your other characters as they are."
        end,
        get = function()
            local store, selfKey = rosterController:Store(), rosterController:SelfKey()
            return store == nil or selfKey == nil or store:GreetOnCharacter(selfKey)
        end,
        set = function(enabled)
            local store, selfKey = rosterController:Store(), rosterController:SelfKey()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if selfKey == nil then
                return nil, "this character isn't in a guild"
            end
            if not store:SetGreetOnCharacter(selfKey, enabled) then
                return nil, "the saved setting is unreadable, so it stays on"
            end
            return true
        end,
    })
    settings:Add("guildGreet", {
        id = "greetInInstances",
        kind = "toggle",
        label = "Greet while in a dungeon, raid or other instance",
        info = function()
            return "Turn this off to get no greet prompts inside dungeons, raids, battlegrounds, arenas and " ..
                "keystone runs. Guildmates who come online while you're inside aren't prompted for later."
        end,
        get = function()
            local store = rosterController:Store()
            return store == nil or store:GreetInInstances()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetGreetInInstances(enabled) then
                return nil, "the saved setting is unreadable, so it stays on"
            end
            return true
        end,
    })
    -- Not saved, and only while the master frame or the options are open:
    -- closing either, or a reload, locks the prompts again.
    settings:Add("guildGreet", {
        id = "greetUnlock",
        kind = "toggle",
        offOnClose = true,
        label = "Unlock greet prompts to drag them somewhere else",
        get = function()
            return greetPrompts:IsUnlocked()
        end,
        set = function(unlocked)
            return greetPrompts:SetUnlocked(unlocked)
        end,
    })
    settings:Add("guildGreet", {
        id = "greetPromptsHeading",
        kind = "heading",
        label = "Which arrivals to prompt for",
    })
    local categoryIndex
    for categoryIndex = 1, #addon.GreetingLibrary.CATEGORIES do
        local category = addon.GreetingLibrary.CATEGORIES[categoryIndex]
        settings:Add("guildGreet", {
            id = "greetCategory:" .. category.id,
            category = category.id,
            kind = "toggle",
            label = category.toggle,
            get = function()
                local store = rosterController:Store()
                return store == nil or store:GreetCategoryEnabled(category.id)
            end,
            set = function(enabled)
                local store = rosterController:Store()
                if store == nil then
                    return nil, "saved data is unavailable"
                end
                if not store:SetGreetCategoryEnabled(category.id, enabled) then
                    return nil, "the saved setting is unreadable, so it stays on"
                end
                return true
            end,
        })
    end
    local function greetNumber(id, label)
        local range = addon.FellowshipStore.GREET_NUMBERS[id]
        settings:Add("guildGreet", {
            id = id,
            kind = "number",
            label = label,
            min = range.min,
            max = range.max,
            get = function()
                local store = rosterController:Store()
                return store and store:GreetNumber(id) or range.default
            end,
            set = function(value)
                local store = rosterController:Store()
                if store == nil then
                    return nil, "saved data is unavailable"
                end
                if not store:SetGreetNumber(id, value) then
                    return nil, "the saved setting is unreadable"
                end
                return true
            end,
        })
    end
    settings:Add("guildGreet", {
        id = "greetTimingHeading",
        kind = "heading",
        label = "Timing",
    })
    greetNumber("welcomeBackMinutes", "Minutes away before coming back is a welcome back")
    greetNumber("longAbsenceDays", "Days away before a login is a long absence")
    settings:Add("guildGreet", {
        id = "greetCap",
        kind = "number",
        label = "Close my prompt once a player has had this many greetings",
        min = addon.FellowshipStore.GREET_CAP_MIN,
        max = addon.FellowshipStore.GREET_CAP_MAX,
        get = function()
            local store = rosterController:Store()
            return store and store:GreetCap() or addon.FellowshipStore.GREET_CAP_DEFAULT
        end,
        set = function(cap)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetGreetCap(cap) then
                return nil, "the saved setting is unreadable"
            end
            return true
        end,
    })
    -- The greetings are edited below these settings on the master frame's
    -- Greetings tab; the AddOns options get a button to go there.
    local function openGreetings()
        rosterController:Open("greetings")
    end
    settings:Add("guildGreet", {
        id = "editGreetings",
        kind = "action",
        host = "options",
        label = "Edit Greetings",
        run = openGreetings,
    })
    -- Guild Recruit's settings only change for a character that can invite
    -- to the guild.
    local function recruitAvailable()
        if not client:CanGuildInvite() then
            return false, "this character can't invite to the guild"
        end
        return true
    end
    settings:AddSection("groupFinder", "Group Finder")
    -- Account-wide, so it applies on every character.
    settings:Add("groupFinder", {
        id = "dnd",
        kind = "toggle",
        label = "Do Not Disturb: no group requests, on every character",
        get = function()
            local store = rosterController:Store()
            return store ~= nil and store:GroupFinderDnd()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil or not store:SetGroupFinderDnd(enabled) then
                return nil, "saved data is unavailable"
            end
            return true
        end,
    })
    -- Role preferences: which roles the logged-in character is willing to
    -- play, synced to the guild. My Profile changes them through these
    -- settings, offering only the roles the character's class can fill.
    local function rolesAvailable()
        if rosterController:SelfKey() == nil or rolesOf(rosterController:SelfKey()) == nil then
            return false, "this character isn't in the guild roster yet"
        end
        return true
    end
    local ROLE_SETTING_LABELS = {
        tank = "Willing to tank on this character",
        healer = "Willing to heal on this character",
        dps = "Willing to DPS on this character",
    }
    local roleIndex
    for roleIndex = 1, #addon.RoleCatalog.ROLES do
        local role = addon.RoleCatalog.ROLES[roleIndex]
        settings:Add("groupFinder", {
            id = "role_" .. role,
            kind = "toggle",
            label = ROLE_SETTING_LABELS[role],
            enabled = rolesAvailable,
            -- Changed on the My Profile tab only, never on a settings panel.
            shown = function()
                return false
            end,
            get = function()
                local roles = rolesOf(rosterController:SelfKey()) or {}
                local index
                for index = 1, #roles do
                    if roles[index] == role then
                        return true
                    end
                end
                return false
            end,
            set = function(enabled)
                local roles = rolesOf(rosterController:SelfKey())
                if roles == nil then
                    return nil, "this character isn't in the guild roster yet"
                end
                local changed = {}
                local index
                for index = 1, #roles do
                    if roles[index] ~= role then
                        table.insert(changed, roles[index])
                    end
                end
                if enabled then
                    table.insert(changed, role)
                end
                if syncSession:LocalRolesEdit(changed) == nil then
                    return nil, "the server time isn't known yet"
                end
                rosterController:Invalidate()
                return true
            end,
        })
    end
    settings:AddSection("guildMap", "Guild Map")
    -- Account-wide, so they apply on every character.
    local function guildMapToggle(id, setting, label, changed)
        settings:Add("guildMap", {
            id = id,
            kind = "toggle",
            label = label,
            get = function()
                local store = rosterController:Store()
                return store == nil or store:GuildMapEnabled(setting)
            end,
            set = function(enabled)
                local store = rosterController:Store()
                if store == nil or not store:SetGuildMapEnabled(setting, enabled) then
                    return nil, "saved data is unavailable"
                end
                changed()
                return true
            end,
        })
    end
    -- Turned off, the player's dot disappears for everyone at once.
    guildMapToggle("shareLocation", "share", "Share my location with the guild", function()
        if shareLocationNow ~= nil then
            shareLocationNow()
        end
    end)
    guildMapToggle("showGuildMap", "show", "Show guildmates on the map and minimap", function()
        if mapPins ~= nil then
            mapPins:Refresh()
        end
    end)
    settings:AddSection("recruitment", "Recruitment", { page = "recruitment" })
    -- The user's own ad count, across all their characters.
    settings:Add("recruitment", {
        id = "recruitMyCount",
        kind = "text",
        get = function()
            local store = rosterController:Store()
            return addon.RecruitStats.OwnSummary(store and store:RecruitOwnStats(), client:Timestamp())
        end,
    })
    -- Says why the settings below are greyed out, only when they are.
    settings:Add("recruitment", {
        id = "recruitCantInvite",
        kind = "text",
        shown = function()
            return not client:CanGuildInvite()
        end,
        get = function()
            return "This character can't invite to the guild, so these settings can't be changed here."
        end,
    })
    -- Kept for the logged-in character.
    settings:Add("recruitment", {
        id = "recruitOptIn",
        kind = "toggle",
        label = "Offer to post my recruitment ad where the guild hasn't advertised lately",
        enabled = recruitAvailable,
        get = function()
            local store, selfKey = rosterController:Store(), rosterController:SelfKey()
            return store ~= nil and selfKey ~= nil and store:RecruitOptedIn(selfKey)
        end,
        set = function(enabled)
            local store, selfKey = rosterController:Store(), rosterController:SelfKey()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if selfKey == nil then
                return nil, "this character isn't in a guild"
            end
            if not store:SetRecruitOptIn(selfKey, enabled) then
                return nil, "the saved setting is unreadable, so it stays off"
            end
            return true
        end,
    })
    settings:Add("recruitment", {
        id = "recruitAd",
        kind = "input",
        label = "My ad, posted exactly as written",
        lines = 3,
        maxLength = addon.FellowshipStore.RECRUIT_AD_MAX,
        enabled = recruitAvailable,
        get = function()
            local store = rosterController:Store()
            return store and store:RecruitAd() or ""
        end,
        set = function(text)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetRecruitAd(text) then
                return nil, "the saved ad is unreadable"
            end
            return true
        end,
    })
    settings:Add("recruitment", {
        id = "recruitUseOfficerAd",
        kind = "toggle",
        label = "Also post the officers' guild ad",
        enabled = recruitAvailable,
        -- Mousing over the info icon shows the guild ad as it is now.
        info = function()
            local ad = guildRecruit:Config():Get("guildAd")
            if type(ad) ~= "string" or string.find(ad, "%S") == nil then
                return "The officers haven't set a guild ad yet."
            end
            return ad
        end,
        get = function()
            local store = rosterController:Store()
            return store == nil or store:RecruitUseOfficerAd()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            store:SetRecruitUseOfficerAd(enabled)
            return true
        end,
    })
    -- The member's own timers: how long a channel goes without an ad before
    -- they're asked. The guild's gaps are a floor under them.
    local function myGap(id, channel, label)
        settings:Add("recruitment", {
            id = id,
            kind = "number",
            slider = true,
            label = label,
            min = addon.FellowshipStore.RECRUIT_MY_GAP_MIN,
            max = addon.FellowshipStore.RECRUIT_MY_GAP_MAX,
            step = addon.RecruitConfig.GAP_STEP_MINUTES,
            format = addon.GuildRecruit.FormatMinutes,
            enabled = recruitAvailable,
            get = function()
                local store = rosterController:Store()
                return store and store:RecruitMyGap(channel)
                    or addon.FellowshipStore.RECRUIT_MY_GAPS[channel].default
            end,
            set = function(minutes)
                local store = rosterController:Store()
                if store == nil then
                    return nil, "saved data is unavailable"
                end
                if not store:SetRecruitMyGap(channel, minutes) then
                    return nil, "the saved timer is unreadable"
                end
                return true
            end,
        })
    end
    myGap("recruitMyGeneralGap", "general", "Ask me to post in a zone's General after it's gone this long without a guild ad")
    myGap("recruitMyTradeGap", "trade", "Ask me to post in Trade after it's gone this long without a guild ad")
    settings:Add("recruitment", {
        id = "recruitGuildFloor",
        kind = "text",
        get = function()
            local config = guildRecruit:Config()
            return "The guild asks for at least " ..
                addon.GuildRecruit.FormatMinutes(config:Get("generalGapMinutes")) .. " in General and " ..
                addon.GuildRecruit.FormatMinutes(config:Get("tradeGapMinutes")) ..
                " in Trade; a shorter timer of yours waits that long."
        end,
    })
    -- Officers only: the guild ad, saved per guild and sent to every
    -- add-on user.
    local function isOfficer()
        return guildRecruit ~= nil and guildRecruit:IsOfficer()
    end
    local function officerOnly()
        if not isOfficer() then
            return false, "only officers can change it"
        end
        return true
    end
    settings:Add("recruitment", {
        id = "recruitOfficerHeading",
        kind = "heading",
        label = "Officer settings: these apply to everyone in the guild",
        shown = isOfficer,
    })
    settings:Add("recruitment", {
        id = "recruitGuildAd",
        kind = "input",
        label = "Guild ad, for every member",
        lines = 3,
        maxLength = addon.RecruitConfig.AD_MAX,
        shown = isOfficer,
        enabled = officerOnly,
        get = function()
            return guildRecruit:Config():Get("guildAd")
        end,
        set = function(text)
            return guildRecruit:SetOfficerSetting("guildAd", text)
        end,
    })
    local function officerGap(id, setting, label)
        settings:Add("recruitment", {
            id = id,
            kind = "number",
            slider = true,
            label = label,
            min = addon.RecruitConfig.SETTINGS[setting].min,
            max = addon.RecruitConfig.GAP_MAX_MINUTES,
            step = addon.RecruitConfig.GAP_STEP_MINUTES,
            format = addon.GuildRecruit.FormatMinutes,
            shown = isOfficer,
            enabled = officerOnly,
            get = function()
                return guildRecruit:Config():Get(setting)
            end,
            set = function(minutes)
                return guildRecruit:SetOfficerSetting(setting, minutes)
            end,
        })
    end
    officerGap("recruitGeneralGap", "generalGapMinutes",
        "Shortest time between guild ads in a zone's General (no member's timer goes below it)")
    officerGap("recruitTradeGap", "tradeGapMinutes",
        "Shortest time between guild ads in Trade (no member's timer goes below it)")
    settings:Add("recruitment", {
        id = "recruitPaused",
        kind = "toggle",
        label = "Pause recruitment for the whole guild",
        shown = isOfficer,
        enabled = officerOnly,
        get = function()
            return guildRecruit:Config():Get("paused")
        end,
        set = function(paused)
            return guildRecruit:SetOfficerSetting("paused", paused)
        end,
    })
    -- The same settings, drawn twice: in the game's AddOns options and on
    -- the master frame's pages. Each refreshes on every change.
    settingsPanel = addon.SettingsPanel.Create(client, settings)
    frameSettings = addon.SettingsPanel.Create(client, settings, "frame")
    frameSettings:Watch()
    router:Register("options", "open the add-on's settings", function()
        rosterController:Open("settings")
    end)
    router:Register("greet", "edit your Guild Greet greetings", openGreetings)
    router:Register("recruit", "open your Guild Recruit settings", function()
        rosterController:Open("recruitment")
    end)
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
    -- The Group Finder's own window, made on first use. Its dungeons come
    -- from the game's Dungeon Finder where the client has one, read each
    -- time it opens; its place is saved account-wide. The group outlives
    -- the window and follows the party.
    groupSession = addon.GroupSession.Create(roleCatalog)
    -- Group Finder messages the player didn't click to send wait until
    -- they're out of combat (or an encounter or keystone run), in order.
    local waitingToSend = {}
    local function flushWhenFree()
        if comm:IsBusy() then
            if not client:After(2, flushWhenFree) then
                waitingToSend = {}
            end
            return
        end
        local queued = waitingToSend
        waitingToSend = {}
        local index
        for index = 1, #queued do
            comm:Broadcast(queued[index], addon.Comm.PRIORITY_NORMAL)
        end
    end
    local function sendWhenFree(message)
        table.insert(waitingToSend, message)
        if #waitingToSend == 1 then
            flushWhenFree()
        end
    end
    -- The groups other organizers are forming, as their add-ons announce
    -- them, and this player's offers to fill their slots.
    groupBoard = addon.GroupBoard.Create()
    local showJoinPrompts
    -- How many offers the prompts show, so they close when the group ends.
    local promptedOffers = 0
    -- This player's group, as the guild hears it: announced whenever it
    -- changes, every GROUP_RESEND_SECONDS while it lasts, and in answer to
    -- an ask; its end once, when it ends.
    local announced, resending
    local function groupSignature(message)
        local parts = { message.dn, tostring(message.lo), tostring(message.hi) }
        local index
        for index = 1, #message.s do
            local slot = message.s[index]
            table.insert(parts, table.concat({ slot.r, slot.n or "", tostring(slot.l or ""), slot.k or "",
                slot.c or "", slot.w and "w" or "" }, ","))
        end
        return table.concat(parts, ";")
    end
    announceGroup = function(force)
        local dungeon = groupSession:IsActive()
            and addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList()):Get(groupSession:Dungeon()) or nil
        if dungeon == nil then
            if announced ~= nil then
                announced = nil
                sendWhenFree(addon.GroupFinderProtocol.GroupEnd())
            end
            if promptedOffers > 0 and groupSession:Offers()[1] == nil then
                showJoinPrompts()
            end
            return
        end
        local message = addon.GroupFinderProtocol.Group(dungeon, groupSession:Summary())
        local signature = groupSignature(message)
        if force or signature ~= announced then
            announced = signature
            sendWhenFree(message)
        end
        if not resending then
            resending = client:After(addon.GroupFinderProtocol.GROUP_RESEND_SECONDS, function()
                resending = false
                announceGroup(true)
            end)
        end
    end
    syncParty = function()
        if groupSession:IsActive() then
            -- Each member's guild roster key, so an invitee who joined is
            -- recognized. Forever gives party members only their first
            -- name, so the roster decides, as for the player's own key.
            local members = client:GetPartyMembers()
            local index
            for index = 1, #members do
                members[index].rosterKey = rosterController:RosterKeyFor(members[index].name, members[index].guid)
            end
            -- Leaving the party ends the group: invitees still deciding
            -- are told it's off.
            local _, dropped = groupSession:UpdateParty(members, client:IsInGroup())
            for index = 1, #(dropped or {}) do
                sendWhenFree(addon.GroupFinderProtocol.Cancel(dropped[index].to, dropped[index].id))
            end
            if onSlotsChanged ~= nil then
                onSlotsChanged()
            end
        end
        announceGroup()
    end
    -- Who runs the add-on and is available, asked each time the Group
    -- Finder opens.
    groupAvailability = addon.GroupAvailability.Create({
        send = function(message)
            return comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        keyOf = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and normalizer:Key(sender) or nil
        end,
        doNotDisturb = function()
            return settings:Get("dnd") == true
        end,
        occupied = function()
            return client:IsInGroup() or client:IsInInstance()
        end,
        busy = function()
            return comm:IsBusy()
        end,
        onChanged = function()
            if groupFinder ~= nil then
                groupFinder:Refresh()
            end
        end,
    })
    -- Join requests. Small interactive messages, heard within seconds.
    local function sendGroupFinder(message)
        return comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
    end
    local function keyOfSender(sender)
        local guild, _, normalizer = rosterController:QuietContext()
        return guild and normalizer:Key(sender) or nil
    end
    joinRequests = addon.JoinRequests.Create({
        partition = function()
            local guild, partition = rosterController:QuietContext()
            return guild and partition or nil
        end,
        roles = roleCatalog,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        members = function()
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and rosterController:LiveMembers(normalizer) or {}
        end,
        available = function()
            return groupAvailability:IsAvailable()
        end,
        display = function(name)
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and normalizer:Display(name) or name
        end,
    })
    joinPrompts = addon.JoinPrompts.Create(client)
    local function refreshGroupFinder()
        if groupFinder ~= nil then
            groupFinder:Refresh()
        end
    end
    local function bareName(name)
        return string.match(name or "", "^([^%-]+)") or name
    end
    -- The organizer's offers from guildmates to fill a slot, as prompts.
    local function offerPrompts()
        local prompts = {}
        local offers = groupSession:Offers()
        local index
        for index = 1, #offers do
            local offer = offers[index]
            table.insert(prompts, {
                id = offer.id,
                offer = true,
                heading = tostring(bareName(offer.sender)) .. " offers to fill your "
                    .. addon.RoleCatalog.LABELS[offer.role] .. " slot",
                options = {
                    { label = "Accept " .. offer.character.name .. " (" .. tostring(offer.character.level) .. ")" },
                },
            })
        end
        return prompts
    end
    local function findOffer(id)
        local offers = groupSession:Offers()
        local index
        for index = 1, #offers do
            if offers[index].id == id then
                return offers[index]
            end
        end
        return nil
    end
    -- The organizer accepts or turns down offer `id`; the guildmate hears
    -- which.
    local function answerOffer(id, accepted)
        local waiting = findOffer(id)
        if waiting == nil then
            return
        end
        if not accepted then
            groupSession:DeclineOffer(id)
            sendGroupFinder(addon.GroupFinderProtocol.OfferAnswer(waiting.from, id, false))
            return
        end
        local guild, partition = rosterController:QuietContext()
        local character = guild and partition:GetCharacter(waiting.from)
        local offer, request = groupSession:AcceptOffer(id, client:Timestamp() or 0, rosterController:SelfKey(),
            character and character.player)
        if offer ~= nil then
            sendGroupFinder(addon.GroupFinderProtocol.OfferAnswer(offer.from, id, request ~= nil))
            if request ~= nil then
                onSlotsChanged()
            end
            refreshGroupFinder()
        end
    end
    -- The invitee answers by clicking, so an answer goes out even while busy.
    showJoinPrompts = function()
        local prompts = joinRequests:Pending()
        local offers = offerPrompts()
        promptedOffers = #offers
        local index
        for index = 1, #offers do
            table.insert(prompts, offers[index])
        end
        joinPrompts:Show(prompts, {
            -- Accepting one declines the rest: those organizers hear the
            -- invitee joined another group.
            accept = function(id, choice)
                if findOffer(id) ~= nil then
                    answerOffer(id, true)
                    showJoinPrompts()
                    return
                end
                local prompt, option, others = joinRequests:Accept(id, choice)
                if prompt ~= nil then
                    sendGroupFinder(addon.GroupFinderProtocol.Answer(prompt.organizer, id, option))
                    if option.key ~= rosterController:SelfKey() then
                        local organizer = string.match(prompt.sender or "", "^([^%-]+)") or prompt.sender
                        rosterController:Print("Log over to " .. option.name .. " to join " .. tostring(organizer) ..
                            "'s group for " .. prompt.dungeon.name .. ". They'll invite you once you're on.")
                    end
                    local index
                    for index = 1, #others do
                        sendGroupFinder(addon.GroupFinderProtocol.JoinedElsewhere(others[index].organizer,
                            others[index].id))
                    end
                end
                showJoinPrompts()
            end,
            decline = function(id)
                if findOffer(id) ~= nil then
                    answerOffer(id, false)
                    showJoinPrompts()
                    return
                end
                local prompt = joinRequests:Decline(id)
                if prompt ~= nil then
                    sendGroupFinder(addon.GroupFinderProtocol.Answer(prompt.organizer, id, nil))
                end
                showJoinPrompts()
            end,
        })
    end
    -- Requests expire on both sides; while any wait, this checks every few
    -- seconds.
    local ticking = false
    -- Offers left unanswered too long, or whose role filled, close; the
    -- guildmate hears they weren't taken.
    local function dropOffers(now)
        local dropped = groupSession:ExpireOffers(now)
        local index
        for index = 1, #dropped do
            sendWhenFree(addon.GroupFinderProtocol.OfferAnswer(dropped[index].from, dropped[index].id, false))
        end
        if dropped[1] ~= nil then
            showJoinPrompts()
        end
    end
    local function tick()
        local now = client:Timestamp()
        if now ~= nil then
            if groupSession:Expire(now)[1] ~= nil then
                refreshGroupFinder()
            end
            if joinRequests:Expire(now)[1] ~= nil then
                showJoinPrompts()
            end
            dropOffers(now)
        end
        if groupSession:PendingRequests()[1] == nil and joinRequests:Pending()[1] == nil
            and groupSession:Offers()[1] == nil
        then
            ticking = false
            return
        end
        if not client:After(5, tick) then
            ticking = false
        end
    end
    local function startTicking()
        if not ticking then
            ticking = client:After(5, tick)
        end
    end
    local function sendRequest(entry)
        local dungeon = groupFinder ~= nil and groupFinder:Picked() or nil
        local now = client:Timestamp()
        if dungeon == nil or now == nil then
            return
        end
        if comm:IsBusy() then
            rosterController:Print("Requests wait until you're out of combat.")
            return
        end
        -- Nothing open, nothing to ask for: no request is made.
        local open = groupSession:OpenRoleSet()
        if open[1] == nil then
            return
        end
        local request = groupSession:Request({ playerId = entry.id, key = entry.current.key, label = entry.label }, now,
            rosterController:SelfKey())
        if request == nil then
            return
        end
        sendGroupFinder(addon.GroupFinderProtocol.Request(request.to, request.id, dungeon, open))
        startTicking()
    end
    -- After slots filled or freed up: invitees with open requests hear the
    -- roles still open, or that nothing is left; offers for a role that
    -- filled close; the guild hears the group as it is now.
    onSlotsChanged = function()
        local updates, withdrawals = groupSession:SlotChanges()
        local index
        for index = 1, #updates do
            sendWhenFree(addon.GroupFinderProtocol.Slots(updates[index].to, updates[index].id, updates[index].roles))
        end
        for index = 1, #withdrawals do
            sendWhenFree(addon.GroupFinderProtocol.Withdraw(withdrawals[index].to, withdrawals[index].id))
        end
        local now = client:Timestamp()
        if now ~= nil then
            dropOffers(now)
        end
        if updates[1] ~= nil or withdrawals[1] ~= nil then
            refreshGroupFinder()
        end
        announceGroup()
    end
    local function cancelRequest(id)
        local request = groupSession:Cancel(id)
        if request ~= nil then
            sendGroupFinder(addon.GroupFinderProtocol.Cancel(request.to, id))
        end
    end
    -- Every Group Finder message: availability asks and replies, groups
    -- being formed, and targeted messages, which only their recipient
    -- handles.
    onGroupFinderMessage = function(message, sender)
        local protocol = addon.GroupFinderProtocol
        if message.t == protocol.TYPE_ASK or message.t == protocol.TYPE_AVAILABLE then
            groupAvailability:OnMessage(message, sender)
            -- Someone opened the Group Finder: they hear this player's group.
            if message.t == protocol.TYPE_ASK and groupSession:IsActive() then
                announceGroup(true)
            end
            return
        end
        local selfKey = rosterController:SelfKey()
        local senderKey = keyOfSender(sender)
        if message.t == protocol.TYPE_GROUP or message.t == protocol.TYPE_GROUP_END then
            if protocol.IsValid(message) and senderKey ~= nil and senderKey ~= selfKey then
                if message.t == protocol.TYPE_GROUP then
                    groupBoard:OnGroup(message, senderKey, sender, client:Timestamp() or 0)
                else
                    groupBoard:OnEnd(senderKey)
                end
                refreshGroupFinder()
            end
            return
        end
        if not protocol.IsValid(message) or selfKey == nil or message.to ~= selfKey
            or senderKey == nil or senderKey == selfKey
        then
            return
        end
        if message.t == protocol.TYPE_REQUEST then
            local refused = joinRequests:OnRequest(message, senderKey, sender, client:Timestamp() or 0)
            if refused ~= nil then
                sendWhenFree(protocol.Answer(senderKey, message.id, nil))
                return
            end
            showJoinPrompts()
            startTicking()
        elseif message.t == protocol.TYPE_ANSWER then
            local option
            if message.ok then
                option = { role = message.role, key = message.c, name = message.n, level = message.l }
            end
            local state = groupSession:Answer(message.id, senderKey, option, message.w == true)
            if state == addon.GroupSession.ACCEPTED then
                onSlotsChanged()
            end
            if state ~= nil then
                refreshGroupFinder()
            end
        elseif message.t == protocol.TYPE_CANCEL or message.t == protocol.TYPE_WITHDRAW then
            if joinRequests:OnCancel(message.id, senderKey) then
                showJoinPrompts()
            end
        elseif message.t == protocol.TYPE_SLOTS then
            local result = joinRequests:OnSlots(message.id, senderKey, message.r)
            if result == "closed" then
                sendWhenFree(protocol.Answer(senderKey, message.id, nil, true))
            end
            if result ~= nil then
                showJoinPrompts()
            end
        elseif message.t == protocol.TYPE_JOINED_ELSEWHERE then
            if groupSession:JoinedElsewhere(message.id, senderKey) then
                refreshGroupFinder()
            end
        elseif message.t == protocol.TYPE_OFFER then
            -- A guildmate offers to fill a slot: the organizer decides.
            local offer = groupSession:Offer({
                id = message.id, from = senderKey, sender = sender, role = message.role,
                character = { key = message.c, name = message.n, level = message.l },
            }, client:Timestamp() or 0)
            if offer == nil then
                sendWhenFree(protocol.OfferAnswer(senderKey, message.id, false))
                return
            end
            showJoinPrompts()
            startTicking()
        elseif message.t == protocol.TYPE_OFFER_ANSWER then
            local offer = groupBoard:OnOfferAnswer(message.id, senderKey, message.ok)
            if offer ~= nil then
                local organizer = tostring(bareName(sender))
                if not message.ok then
                    rosterController:Print(organizer .. " turned down your offer.")
                elseif offer.key ~= selfKey then
                    rosterController:Print(organizer .. " accepted your offer. Log over to " .. offer.name ..
                        "; they'll invite you once you're on.")
                else
                    rosterController:Print(organizer .. " accepted your offer. They'll invite you.")
                end
                refreshGroupFinder()
            end
        elseif message.t == protocol.TYPE_ROLE then
            -- A party member asks for another role.
            local member = groupSession:MemberByRosterKey(senderKey)
            if member ~= nil and groupSession:ChangeRole(member.key, message.role) then
                onSlotsChanged()
                refreshGroupFinder()
            end
        elseif message.t == protocol.TYPE_ALT then
            -- A party member will come as one of their alts instead: the
            -- alt takes their slot, waiting to be invited.
            local member = groupSession:MemberByRosterKey(senderKey)
            local guild, partition = rosterController:QuietContext()
            local own = guild and partition:GetCharacter(senderKey)
            local alt = guild and partition:GetCharacter(message.c)
            if member ~= nil and own and alt and alt.player == own.player then
                local request = groupSession:Accept({ playerId = own.player, key = senderKey, label = bareName(sender) },
                    { role = message.role, key = message.c, name = message.n, level = message.l },
                    client:Timestamp() or 0, selfKey, member.key)
                if request ~= nil then
                    rosterController:Print(tostring(bareName(sender)) .. " will come as " .. message.n ..
                        ". Invite " .. message.n .. " once it's online.")
                    onSlotsChanged()
                    refreshGroupFinder()
                end
            end
        end
    end
    settings:OnChange(function(id)
        if id == "dnd" and groupFinder ~= nil then
            groupFinder:Refresh()
        end
    end)
    -- Group history: the guildmates in the party now (this player's own
    -- characters left out), and the dungeon when known: the Group Finder's
    -- pick, else the instance the player is in.
    local groupHistory
    recordParty = function()
        local guild, partition = rosterController:QuietContext()
        local now = client:Timestamp()
        if guild == nil or now == nil then
            return
        end
        if groupHistory == nil or groupHistory.partition.key ~= partition.key then
            groupHistory = addon.GroupHistory.Create(partition)
        end
        groupHistory.partition = partition
        local selfKey = rosterController:SelfKey()
        local own = selfKey and partition:GetCharacter(selfKey)
        local keys = {}
        if client:IsInGroup() then
            local members = client:GetPartyMembers()
            local index
            for index = 1, #members do
                local key = not members[index].isPlayer
                    and rosterController:RosterKeyFor(members[index].name, members[index].guid)
                local character = key and partition:GetCharacter(key)
                if character and partition:IsInGuild(key) and not (own and character.player == own.player) then
                    table.insert(keys, key)
                end
            end
        end
        local dungeon = groupSession:IsActive()
            and addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList()):Get(groupSession:Dungeon()) or nil
        local name = dungeon and dungeon.name or nil
        if name == nil and client:IsInInstance() then
            local zone = client:GetZone()
            name = zone and zone.name or nil
        end
        groupHistory:OnParty(keys, now, name)
        rosterController:Invalidate()
    end
    router:Register("dnd", "turn Group Finder Do Not Disturb on or off", function()
        local enabled, reason = settings:Toggle("dnd")
        if enabled == nil then
            rosterController:Print("Do Not Disturb can't be changed: " .. tostring(reason) .. ".")
        elseif enabled then
            rosterController:Print("Do Not Disturb on: you won't get group requests, on any character.")
        else
            rosterController:Print("Do Not Disturb off.")
        end
    end)
    -- Makes each of this player's offers' ids unique.
    local offerCount = 0
    -- The Group Finder's tab, drawn when the master frame is first built.
    -- Each time the tab comes into view it asks the guild who is around.
    drawGroupFinder = function(content)
        local reason
        groupFinder, reason = addon.GroupFinderWindow.Create(client, content, {
            dungeons = function()
                return addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList())
            end,
            playerLevel = function()
                return client:GetPlayerLevel()
            end,
            session = groupSession,
            roles = roleCatalog,
            syncParty = syncParty,
            replies = function()
                return groupAvailability:Replies()
            end,
            openGuildChat = function(text)
                return client:OpenGuildChat(text)
            end,
            request = sendRequest,
            cancelRequest = cancelRequest,
            classColor = function(classToken)
                return client:GetClassColor(classToken)
            end,
            refresh = function()
                syncParty()
                groupAvailability:Ask()
            end,
            zone = function()
                local zone = client:GetZone()
                return zone and zone.name or nil
            end,
            selfKey = function()
                return rosterController:SelfKey()
            end,
            isOnline = function(key)
                local guild, _, normalizer = rosterController:QuietContext()
                local live = guild and rosterController:LiveMembers(normalizer)[key]
                return live ~= nil and live.online == true
            end,
            -- Only ever from the organizer's click on Invite.
            invite = function(key)
                local guild, partition, normalizer = rosterController:QuietContext()
                if guild == nil then
                    return false
                end
                local live = rosterController:LiveMembers(normalizer)[key]
                local character = partition:GetCharacter(key)
                local name = (live and live.name) or (character and character.name)
                return name ~= nil and client:InviteToParty(name)
            end,
            -- From a click on a guildmate's name.
            whisper = function(key)
                local guild, partition, normalizer = rosterController:QuietContext()
                if guild == nil then
                    return false
                end
                local live = rosterController:LiveMembers(normalizer)[key]
                local character = partition:GetCharacter(key)
                local name = (live and live.name) or (character and character.name)
                return name ~= nil and client:OpenWhisper(name)
            end,
            -- The guild as it is now: the live roster, the replies to
            -- the last ask, and who is left out (this character's
            -- player and the party).
            candidates = function()
                local guild, partition, normalizer = rosterController:QuietContext()
                if guild == nil then
                    return nil
                end
                local replies, excluded = {}, {}
                local list = groupAvailability:Replies()
                local index
                for index = 1, #list do
                    replies[list[index].key] = list[index]
                end
                local selfKey = rosterController:SelfKey()
                if selfKey ~= nil then
                    excluded[selfKey] = true
                end
                -- Invitees who accepted already have a slot.
                local requests = groupSession:Requests()
                for index = 1, #requests do
                    if requests[index].state == addon.GroupSession.ACCEPTED then
                        excluded[requests[index].to] = true
                    end
                end
                local members = groupSession:IsActive() and groupSession:Members() or {}
                for index = 1, #members do
                    if members[index].rosterKey ~= nil then
                        excluded[members[index].rosterKey] = true
                    end
                end
                return addon.GroupCandidates.Create({
                    partition = partition,
                    members = rosterController:LiveMembers(normalizer),
                    roles = roleCatalog,
                    replies = replies,
                    excluded = excluded,
                    display = function(name)
                        return normalizer:Display(name)
                    end,
                })
            end,
            dnd = {
                get = function()
                    return settings:Get("dnd") == true
                end,
                set = function(enabled)
                    return settings:Set("dnd", enabled)
                end,
            },
            onShown = function()
                groupAvailability:Ask()
            end,
            changed = function()
                announceGroup()
            end,
            groups = function()
                return groupBoard:Groups(client:GetPlayerLevel(), client:Timestamp())
            end,
            boardGroup = function(id)
                return groupBoard:Get(id, client:Timestamp())
            end,
            -- The group of an organizer in the player's party.
            partyGroup = function()
                if not client:IsInGroup() then
                    return nil
                end
                local now = client:Timestamp()
                local members = client:GetPartyMembers()
                local index
                for index = 1, #members do
                    if not members[index].isPlayer then
                        local key = rosterController:RosterKeyFor(members[index].name, members[index].guid)
                        local group = key and groupBoard:Get(key, now)
                        if group then
                            return group
                        end
                    end
                end
                return nil
            end,
            -- Nothing to fill for a player who already holds a slot, on any
            -- of their characters (an accepted invitee not in the party yet).
            fillOptions = function(group, role)
                local guild, partition = rosterController:QuietContext()
                local selfKey = rosterController:SelfKey()
                local own = guild and selfKey and partition:GetCharacter(selfKey)
                local index
                for index = 1, #group.slots do
                    local key = group.slots[index].key
                    local character = own and key and partition:GetCharacter(key)
                    if key == selfKey or (character and character.player == own.player) then
                        return {}
                    end
                end
                return joinRequests:OptionsFor({ r = { role }, lo = group.dungeon.minLevel, hi = group.dungeon.maxLevel })
            end,
            offer = function(group, option)
                local now = client:Timestamp()
                local selfKey = rosterController:SelfKey()
                if now == nil or selfKey == nil then
                    return false
                end
                offerCount = offerCount + 1
                local id = selfKey .. ":offer:" .. tostring(now) .. "-" .. offerCount
                groupBoard:Offer(group.id, id, option, now)
                return sendGroupFinder(addon.GroupFinderProtocol.Offer(group.organizer, id, option))
            end,
            offerFor = function(group)
                return groupBoard:OfferFor(group.id, client:Timestamp())
            end,
            setRole = function(group, role)
                return sendGroupFinder(addon.GroupFinderProtocol.Role(group.organizer, role))
            end,
            -- The player's other characters that could come instead: in
            -- their own role, or any role still open.
            altOptions = function(group)
                local selfKey = rosterController:SelfKey()
                local roles, seen = {}, {}
                local index
                for index = 1, #group.slots do
                    local slot = group.slots[index]
                    if (slot.name == nil or (slot.key ~= nil and slot.key == selfKey)) and not seen[slot.role] then
                        seen[slot.role] = true
                        table.insert(roles, slot.role)
                    end
                end
                local options = joinRequests:OptionsFor({ r = roles, lo = group.dungeon.minLevel,
                    hi = group.dungeon.maxLevel })
                local alts = {}
                for index = 1, #options do
                    if options[index].key ~= selfKey then
                        table.insert(alts, options[index])
                    end
                end
                return alts
            end,
            joinAsAlt = function(group, option)
                if sendGroupFinder(addon.GroupFinderProtocol.Alt(group.organizer, option)) == false then
                    return false
                end
                rosterController:Print("Log over to " .. option.name .. ". " .. group.label .. " will invite " ..
                    option.name .. " once it's on.")
                return true
            end,
        })
        if groupFinder == nil then
            rosterController:Print("The Group Finder can't be shown: " .. tostring(reason) .. ".")
        end
    end
    -- Opens the master frame on the Group Finder's tab, or closes it when
    -- that tab is already showing.
    router:Register("group", "open or close the Group Finder", function()
        rosterController:Toggle("group")
    end)
    -- My Profile's tab, drawn when the master frame is first built. Its
    -- roles and Do Not Disturb are the settings above, so a change on any of
    -- them shows everywhere.
    local profilePage
    drawProfile = function(content)
        local reason
        profilePage, reason = addon.ProfilePage.Create(client, content, {
            model = function()
                local guild, partition, normalizer = rosterController:QuietContext()
                return addon.ProfileViewModel.Build({
                    inGuild = client:IsInGuild(),
                    partition = guild and partition or nil,
                    selfKey = rosterController:SelfKey(),
                    members = guild and rosterController:LiveMembers(normalizer) or {},
                    normalizer = normalizer,
                    roles = roleCatalog,
                    classColor = function(classToken)
                        return client:GetClassColor(classToken)
                    end,
                    dnd = settings:Get("dnd") == true,
                    pending = guild and syncSession:Suggestions(partition):Pending() or {},
                })
            end,
            setRole = function(role, enabled)
                local changed, why = settings:Set("role_" .. role, enabled)
                if changed == nil then
                    rosterController:Print("Role preferences can't be changed: " .. tostring(why) .. ".")
                end
            end,
            setDnd = function(enabled)
                local changed, why = settings:Set("dnd", enabled)
                if changed == nil then
                    rosterController:Print("Do Not Disturb can't be changed: " .. tostring(why) .. ".")
                end
            end,
            -- The player's own Discord, location and bio: saved and sent to
            -- the guild at once, with no officer involved.
            -- The alias goes through the roster, like Set alias…: official
            -- at once for an officer, a suggestion for a member.
            setText = function(kind, text)
                if kind == "alias" then
                    local selfKey = rosterController:SelfKey()
                    if selfKey ~= nil then
                        rosterController:SetAlias(selfKey, text)
                    end
                    return
                end
                if syncSession:LocalProfileEdit(kind, text) == nil then
                    rosterController:Print("That wasn't saved: this character isn't in the guild roster yet," ..
                        " or the server time isn't known yet.")
                    return
                end
                rosterController:Invalidate()
            end,
            -- Main and alts go through the roster's own actions (Make this
            -- the main, Split off as own player, Link as alt of…), so the
            -- officer and member rules are the same as there.
            makeMain = function(key)
                rosterController:MakeMain(key)
            end,
            removeAlt = function(key)
                rosterController:Detach(key)
            end,
            candidates = function(query)
                local guild, partition, normalizer = rosterController:QuietContext()
                if guild == nil then
                    return {}
                end
                return addon.ProfileViewModel.AltCandidates({
                    partition = partition,
                    selfKey = rosterController:SelfKey(),
                    members = rosterController:LiveMembers(normalizer),
                    normalizer = normalizer,
                    classColor = function(classToken)
                        return client:GetClassColor(classToken)
                    end,
                }, query, addon.ProfilePage.PICKER_ROWS)
            end,
            addAlt = function(key)
                local guild, partition = rosterController:QuietContext()
                local own = guild and partition:GetCharacter(rosterController:SelfKey() or "")
                if own then
                    rosterController:SetMainPlayer(key, own.player)
                end
            end,
            -- A character on its own joins the player of `key`.
            join = function(key)
                local guild, partition = rosterController:QuietContext()
                local selfKey = rosterController:SelfKey()
                local target = guild and partition:GetCharacter(key)
                if target and selfKey ~= nil then
                    rosterController:SetMainPlayer(selfKey, target.player)
                end
            end,
            -- A member takes back a change still waiting for an officer.
            undo = function(character, kind)
                local undone, why = syncSession:Undo(character, kind)
                if not undone then
                    rosterController:Print("That change can't be undone: " .. tostring(why) .. ".")
                end
            end,
            -- Officer data, like the other identity edits: official at
            -- once for an officer, a suggestion for a member.
            declare = function(key)
                rosterController:SetDeclared(key, true)
            end,
            dismiss = function(key)
                local guild, partition = rosterController:QuietContext()
                if guild ~= nil then
                    partition:DismissOwnCharacter(key)
                end
            end,
        })
        if profilePage == nil then
            rosterController:Print("My Profile can't be shown: " .. tostring(reason) .. ".")
        end
    end
    settings:OnChange(function(id)
        if profilePage ~= nil and (id == "dnd" or string.find(id, "^role_") ~= nil) then
            profilePage:Refresh()
        end
    end)
    -- Opens the master frame on My Profile, or closes it when that tab is
    -- already showing.
    router:Register("profile", "open or close My Profile", function()
        rosterController:Toggle("profile")
    end)
    router:SetDefault("roster")
    -- Guild sync: officers are ranks that can view officer notes, judged
    -- from the stored roster (current members only).
    officerAuthority = addon.OfficerAuthority.Create({
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
            if profilePage ~= nil then
                profilePage:Refresh()
            end
        end,
        -- A member hears how an officer decided their changes.
        onDecision = function(items, approved)
            local guild, partition, normalizer = rosterController:QuietContext()
            if guild == nil then
                return
            end
            local texts = {}
            local index
            for index = 1, #items do
                texts[index] = addon.SuggestionBundles.Describe(partition, normalizer, items[index])
            end
            if approved then
                rosterController:Print("An officer approved your change: " .. table.concat(texts, "; ") .. ".")
            else
                rosterController:Print("An officer denied your change: " .. table.concat(texts, "; ") ..
                    ". Your roster went back to the officers' version.")
            end
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
        rolesOf = rolesOf,
    })
    router:Register("channels", "show the chat channels Guild Recruit sees here", function()
        local lines = client:ChannelReport()
        local index
        for index = 1, #lines do
            rosterController:Print(lines[index])
        end
    end)
    router:Register("advertise", "post the guild ad to General here now (advertise trade: to Trade)", function(arguments)
        local channel = string.lower(arguments or "") == "trade" and addon.RecruitPolicy.TRADE
            or addon.RecruitPolicy.GENERAL
        local sent, reason = guildRecruit:Advertise(channel)
        if sent == nil then
            rosterController:Print("Not advertised: " .. tostring(reason) .. ".")
        end
    end)
    router:Register("sync", "show guild sync status", function()
        local lines = addon.RosterViewModel.SyncStatusLines(syncSession:Status(), client:Timestamp())
        local index
        for index = 1, #lines do
            rosterController:Print(lines[index])
        end
    end)
    -- Guild Mail: officers mail the ranks they tick (to each player's main,
    -- their most recently online character, or every character), sent from
    -- a mailbox one at a time.
    guildMailWindow = addon.GuildMailWindow.Create(client, {
        onRank = function(index, checked)
            guildMail:SetRank(index, checked)
        end,
        onMode = function(mode)
            if not guildMail:SetMode(mode) then
                -- Puts the radio buttons back when nothing changed.
                guildMail:Refresh()
            end
        end,
        onSkipDiscord = function(checked)
            if not guildMail:SetSkipDiscord(checked) then
                guildMail:Refresh()
            end
        end,
        onActiveOnly = function(checked)
            if not guildMail:SetActiveOnly(checked) then
                guildMail:Refresh()
            end
        end,
        onStop = function()
            guildMail:Stop()
        end,
        onEnd = function()
            guildMail:End()
        end,
        onRecipient = function(key, checked)
            if not guildMail:SetRecipient(key, checked) then
                guildMail:Refresh()
            end
        end,
        onSubject = function(text)
            guildMail:SetSubject(text)
        end,
        onBody = function(text)
            guildMail:SetBody(text)
        end,
        onSend = function()
            guildMail:RequestSend()
        end,
        onConfirm = function()
            guildMail:Confirm()
        end,
        onCancel = function()
            guildMail:Cancel()
        end,
        onMailboxButton = function()
            guildMail:Open(true)
        end,
    })
    guildMail = addon.GuildMail.Create({
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
        isOfficer = function()
            return officerAuthority:IsOfficer(rosterController:SelfKey())
        end,
        rankNames = function()
            return client:GetGuildRankNames()
        end,
        -- Who is online, and when the others last were, for "most
        -- recently online" and the recipient list.
        live = function()
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and rosterController:LiveMembers(normalizer) or nil
        end,
        send = function(to, subject, body)
            return client:SendMail(to, subject, body)
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        -- The cap on unique recipients pauses sending; the client's own
        -- text for it when it has one.
        capMessage = client:GetMailCapMessage(),
        -- Postage: the game's own price at a mailbox; away from one Guild
        -- Mail estimates the standard text-mail price.
        price = function()
            return client:GetSendMailPrice()
        end,
        money = function()
            return client:GetMoney()
        end,
        formatMoney = function(copper)
            return client:FormatMoney(copper)
        end,
        -- The draft and filter choices, kept account-wide between sessions.
        loadDraft = function()
            local store = rosterController:Store()
            return store and store:GuildMailDraft() or nil
        end,
        saveDraft = function(draft)
            local store = rosterController:Store()
            if store then
                store:SetGuildMailDraft(draft)
            end
        end,
        view = guildMailWindow,
    })
    router:Register("mail", "open Guild Mail, to mail guild ranks (officers)", function()
        if client:IsMailboxOpen() then
            guildMail:OnMailboxOpened()
        end
        local opened, reason = guildMail:Open(client:IsMailboxOpen())
        if not opened then
            rosterController:Print(reason)
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
        inInstance = function()
            return client:IsInInstance()
        end,
        -- Heard within seconds, unlike sync's bulk traffic.
        announce = function(message)
            return comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
        end,
        view = greetPrompts,
    })
    -- The Guild Recruit window stays where it's dragged; the place is saved
    -- account-wide.
    recruitPrompts = addon.RecruitPrompts.Create(client, {
        loadAnchor = function()
            local store = rosterController:Store()
            return store and store:RecruitAnchor()
        end,
        saveAnchor = function(anchor)
            local store = rosterController:Store()
            if store ~= nil then
                store:SetRecruitAnchor(anchor)
            end
        end,
    })
    local function recruitLocation()
        local zone = client:GetZone()
        if zone == nil then
            return nil
        end
        -- Arriving somewhere, the client can put the player in the new
        -- zone's General a moment before it reports the new zone. Until
        -- the two agree there's no General here, so an ad is never sent
        -- to one zone and counted for another.
        local general = client:GetGeneralChannel()
        if general ~= nil and not client:IsChannelOfZone(general, zone.name) then
            general = nil
        end
        return {
            key = zone.key,
            name = zone.name,
            general = general,
            trade = client:GetTradeChannel(),
        }
    end
    -- Guild Recruit keeps its ad times with the current guild.
    guildRecruit = addon.GuildRecruit.Create({
        partition = function()
            local guild, partition = rosterController:QuietContext()
            return guild and partition or nil
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
        canInvite = function()
            return client:CanGuildInvite()
        end,
        location = recruitLocation,
        -- Advertising on demand also works where the client can't place the
        -- player on a map (the Deeprun Tram): the zone is the one General
        -- is named for.
        here = function()
            local location = recruitLocation()
            if location ~= nil then
                return location
            end
            local general = client:GetGeneralChannel()
            local name = general and client:ChannelZoneName(general)
            if name == nil then
                return nil
            end
            return { key = "zone:" .. name, name = name, general = general, trade = client:GetTradeChannel() }
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        send = function(text, channelNumber)
            return client:SendChannelMessage(text, channelNumber)
        end,
        inInstance = function()
            return client:IsInInstance()
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        -- Heard within seconds, so others' prompts close quickly.
        announce = function(message)
            return comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        senderIsOfficer = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(sender)
            return key ~= nil and officerAuthority:IsOfficer(key)
        end,
        keyOf = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and normalizer:Key(sender) or nil
        end,
        isOwnKey = function(key)
            return guildGreet:IsOwn(key)
        end,
        mapName = function(mapID)
            return client:GetMapName(mapID)
        end,
        -- The open leaderboard, recent ads, and the user's own count show
        -- new counts and ad times at once.
        onStatsChanged = function()
            rosterController:RefreshRecruiters()
            frameSettings:Refresh()
            settingsPanel:Refresh()
        end,
        isOwn = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(sender)
            if key == nil then
                return nil
            end
            return guildGreet:IsOwn(key)
        end,
        rosterLoaded = function()
            local count = client:GetGuildRosterCount()
            return count ~= nil and count > 0
        end,
        view = recruitPrompts,
    })
    settings:OnChange(function(id, value)
        local entry = settings:Entry(id)
        if id == "recruitOptIn" or id == "recruitAd" or id == "recruitUseOfficerAd"
            or id == "recruitMyGeneralGap" or id == "recruitMyTradeGap"
        then
            guildRecruit:Refresh()
        elseif id == "guildGreet" or id == "greetCharacter" then
            guildGreet:OnEnabledChanged(guildGreet:IsEnabled())
        elseif id == "greetInInstances" then
            guildGreet:OnZoneChanged()
        elseif entry ~= nil and entry.category ~= nil then
            guildGreet:OnCategoryChanged(entry.category, value)
        end
    end)
    client:ObserveGuildRoster(function()
        rosterController:OnRosterUpdate()
        recordOwnCharacter()
        -- Who is online decides the Group Finder's Invite buttons.
        if groupFinder ~= nil then
            groupFinder:Refresh()
        end
        -- The roster's zones count on the world map, and guildmates it shows
        -- offline or gone leave the board.
        if mapPins ~= nil then
            dropOfflineLocations()
            mapPins:Refresh()
        end
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
        -- The first loaded roster runs Guild Recruit's login check; a rank
        -- change later can grant or take away invite permission.
        guildRecruit:OnRosterUpdate()
        settingsPanel:Refresh()
        frameSettings:Refresh()
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
        colorFor = function(kind)
            local store = rosterController:Store()
            return store and store:ChatTagColor(kind)
        end,
    })
    -- Officers see out-of-date guild notes in the game's guild roster. The
    -- audit is cached until the roster's data changes.
    local auditCache
    local function noteAudit()
        local guild, partition, normalizer = rosterController:QuietContext()
        if guild == nil then
            return nil
        end
        local stamp = partition.key .. "#" .. tostring(rosterController.revision or 0)
        if auditCache == nil or auditCache.stamp ~= stamp then
            local rows = addon.NoteAudit.Build({
                partition = partition,
                members = rosterController:LiveMembers(normalizer),
                normalizer = normalizer,
                rules = clientProfile.nameRules,
            })
            local byKey = {}
            local index
            for index = 1, #rows do
                byKey[rows[index].key] = rows[index]
            end
            auditCache = { stamp = stamp, byKey = byKey, normalizer = normalizer }
        end
        return auditCache
    end
    guildNoteOverlay = addon.GuildNoteOverlay.Create({
        client = client,
        isOfficer = function()
            return officerAuthority:IsOfficer(rosterController:SelfKey())
        end,
        rowFor = function(name)
            local audit = noteAudit()
            local key = audit and audit.normalizer:Key(name)
            return key and audit.byKey[key] or nil
        end,
        ignore = function(row)
            local guild, partition = rosterController:QuietContext()
            if guild ~= nil and partition:IgnoreNote(row.key, row.fingerprint, row.suggested) then
                auditCache = nil
            end
        end,
        -- Anyone sees the selected member's player in brief.
        profileFor = function(name)
            local guild, partition, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(name)
            local character = key and partition:GetCharacter(key)
            if character == nil then
                return nil
            end
            local summary = addon.PlayerPanelViewModel.Summary({
                partition = partition,
                playerId = character.player,
                members = rosterController:LiveMembers(normalizer),
                normalizer = normalizer,
            })
            local selfKey = rosterController:SelfKey()
            local own = selfKey and partition:GetCharacter(selfKey)
            if summary ~= nil and own ~= nil and own.player == character.player then
                summary.own = true
            end
            return summary
        end,
        editProfile = function()
            rosterController:Open("profile")
        end,
    })
    -- Guildmates on the map: add-on users share where they are with the
    -- guild, and each other's dots are drawn on the zone map and minimap.
    local function isOwnCharacter(key)
        local guild, partition = rosterController:QuietContext()
        if guild == nil then
            return false
        end
        local selfKey = rosterController:SelfKey()
        if key == selfKey then
            return true
        end
        local own = selfKey and partition:GetCharacter(selfKey)
        local character = partition:GetCharacter(key)
        if own ~= nil and character ~= nil and own.player == character.player then
            return true
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
    locationBoard = addon.LocationBoard.Create({ isOwn = isOwnCharacter })
    locationScheduler = addon.LocationScheduler.Create()
    -- Guildmates the roster shows offline, or no longer lists, leave the
    -- board (and so stop getting whispers). Nothing is dropped while the
    -- roster hasn't loaded.
    dropOfflineLocations = function()
        local guild, _, normalizer = rosterController:QuietContext()
        if guild == nil then
            return
        end
        local members = rosterController:LiveMembers(normalizer)
        if next(members) == nil then
            return
        end
        locationBoard:Keep(function(key)
            return members[key] ~= nil and members[key].online == true
        end)
    end
    -- The keys of the player's party members, or nil outside a party.
    local function partyKeys(normalizer)
        if not client:IsInGroup() then
            return nil
        end
        local keys = {}
        local members = client:GetPartyMembers()
        local index
        for index = 1, #members do
            local key = normalizer:Key(members[index].name)
            if key ~= nil then
                keys[key] = true
            end
        end
        return keys
    end
    -- A board entry as the map shows it: with the character's name and its
    -- chat tag (alias or main), and dimmed while the player is in a party
    -- it isn't in.
    local function describeLocations(entries)
        local guild, partition, normalizer = rosterController:QuietContext()
        if guild == nil then
            return {}
        end
        local party = partyKeys(normalizer)
        local people = addon.PlayerService.Create(partition, { normalizer = normalizer })
        local described = {}
        local index
        for index = 1, #entries do
            local entry = entries[index]
            local tag = people:ChatTag(entry.key)
            table.insert(described, {
                key = entry.key,
                mapId = entry.mapId,
                x = entry.x,
                y = entry.y,
                class = entry.class,
                level = entry.level,
                name = people:CharacterName(entry.key) or entry.key,
                label = tag and tag.text or nil,
                fromRoster = entry.fromRoster,
                dimmed = party ~= nil and not party[entry.key] or nil,
            })
        end
        return described
    end
    -- The continent and world map each zone map sits in, looked up once.
    local mapParents = {}
    local function parentsOf(mapId)
        if mapParents[mapId] == nil then
            mapParents[mapId] = client:GetMapParents(mapId)
        end
        return mapParents[mapId]
    end
    -- Zone maps by name, looked up once the client's maps give any.
    local zoneMaps
    -- Online guildmates whose roster zone is a zone on the map, for the
    -- world map markers (the board leaves out those it has a position for).
    local function rosterLocations()
        local guild, _, normalizer = rosterController:QuietContext()
        if guild == nil then
            return {}
        end
        if zoneMaps == nil or next(zoneMaps) == nil then
            zoneMaps = client:GetZoneMapIds()
        end
        local found = {}
        local key, member
        for key, member in pairs(rosterController:LiveMembers(normalizer)) do
            local mapId = member.online and member.zone ~= nil and zoneMaps[member.zone] or nil
            if mapId ~= nil then
                table.insert(found, { key = key, mapId = mapId, class = member.classToken, level = member.level })
            end
        end
        return found
    end
    -- Map markers: per zone on its continent's map, and per continent on
    -- the world map, counting guildmates the roster places in a zone.
    local function locationMarkers()
        local markers = {}
        local function add(grouped, shownOn)
            local index
            for index = 1, #grouped do
                local marker = grouped[index]
                local mapId = shownOn(marker.area)
                if mapId ~= nil then
                    marker.mapId = mapId
                    marker.people = describeLocations(marker.people)
                    table.insert(markers, marker)
                end
            end
        end
        local roster = rosterLocations()
        add(locationBoard:Markers(function(mapId)
            return mapId
        end, roster), function(zone)
            return parentsOf(zone).continent
        end)
        add(locationBoard:Markers(function(mapId)
            return parentsOf(mapId).continent
        end, roster), function(continent)
            return parentsOf(continent).world
        end)
        return markers
    end
    -- Guildmates only the roster places, as dots at their zone's center on
    -- the zone map: the roster names nothing closer.
    local function rosterDots()
        local zones = locationBoard:Markers(function(mapId)
            return mapId
        end, rosterLocations())
        local found = {}
        local index, each
        for index = 1, #zones do
            for each = 1, #zones[index].people do
                local person = zones[index].people[each]
                if person.fromRoster then
                    person.x, person.y = 0.5, 0.5
                    table.insert(found, person)
                end
            end
        end
        return found
    end
    mapPins = addon.MapPins.Create({
        client = client,
        dots = function()
            local dots = describeLocations(locationBoard:All())
            local fromRoster = describeLocations(rosterDots())
            local index
            for index = 1, #fromRoster do
                table.insert(dots, fromRoster[index])
            end
            return dots
        end,
        markers = locationMarkers,
        zone = function()
            local spot = client:GetPlayerPosition()
            return spot and spot.mapId or nil
        end,
        shown = function()
            local store = rosterController:Store()
            return store == nil or store:GuildMapEnabled("show")
        end,
    })
    -- A location from a guildmate: only from a character in the guild,
    -- about itself.
    onLocationMessage = function(message, sender)
        if not addon.LocationProtocol.IsValid(message) then
            return
        end
        local guild, partition, normalizer = rosterController:QuietContext()
        local senderKey = guild and normalizer:Key(sender) or nil
        if senderKey == nil or not partition:IsInGuild(senderKey) then
            return
        end
        local changed
        if message.t == addon.LocationProtocol.TYPE_HIDE then
            changed = locationBoard:OnHide(message, senderKey)
        else
            changed = locationBoard:OnLocation(message, senderKey, client:Timestamp() or 0, sender)
        end
        if changed then
            mapPins:Refresh()
        end
    end
    -- Sends the player's location when it's due, and asks again every few
    -- seconds.
    local function shareLocation()
        -- Nothing goes out in combat, a boss encounter or a keystone run.
        if comm:IsBusy() then
            return
        end
        local store = rosterController:Store()
        local sharing = store == nil or store:GuildMapEnabled("share")
        local inInstance = client:IsInInstance()
        local spot
        if sharing and not inInstance then
            spot = client:GetPlayerPosition()
            if spot == nil then
                return
            end
            spot.class = client:GetPlayerClass()
            spot.level = client:GetPlayerLevel()
            if spot.class == nil or spot.level == nil then
                return
            end
        end
        local character = rosterController:SelfKey()
        local now = client:Timestamp()
        local message = locationScheduler:Tick({ now = now, character = character, spot = spot, sharing = sharing,
            inInstance = inInstance })
        if message ~= nil then
            comm:Broadcast(message)
        end
        if not sharing or inInstance then
            return
        end
        -- Guildmates in the same zone hear more often, by whisper.
        local near, targets = locationScheduler:Near({ now = now, character = character, spot = spot,
            guildmates = locationBoard:All() })
        local index
        for index = 1, #(targets or {}) do
            if not comm:Whisper(near, targets[index]) then
                locationScheduler:WhisperFailed()
                return
            end
        end
    end
    shareLocationNow = shareLocation
    local sharing = false
    startLocations = function()
        mapPins:Start()
        if sharing then
            return
        end
        local function tick()
            -- Guildmates who went quiet drop off the map.
            if locationBoard:Expire(client:Timestamp()) then
                mapPins:Refresh()
            end
            shareLocation()
            sharing = client:After(addon.LocationScheduler.TICK_SECONDS, tick)
        end
        tick()
        -- A new zone goes out promptly (within the scheduler's minimum gap),
        -- and the minimap shows the new zone's guildmates.
        client:ObserveZone(function()
            shareLocation()
            mapPins:Refresh()
        end)
    end
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
    -- Without the comm libraries, sync simply stays off, and Guild Greet and
    -- Guild Recruit work uncoordinated.
    if comm:Start(function(message, sender)
        if message.t == addon.GuildGreet.TYPE_GREETED then
            guildGreet:OnGreeted(message, sender)
        elseif addon.GuildRecruit.TYPES[message.t] ~= nil then
            guildRecruit:OnMessage(message, sender)
        elseif addon.GroupFinderProtocol.TYPES[message.t] ~= nil then
            onGroupFinderMessage(message, sender)
        elseif addon.LocationProtocol.TYPES[message.t] ~= nil then
            onLocationMessage(message, sender)
        else
            syncSession:Receive(message, sender)
        end
    end, function(message, sender)
        -- Only guild map updates are whispered.
        if addon.LocationProtocol.TYPES[message.t] ~= nil then
            onLocationMessage(message, sender)
        end
    end) then
        syncSession:Start()
        startLocations()
    end
    -- The minimap button needs saved data for its position.
    entryPoints:Start()
    guildNoteOverlay:Start()
    -- Settings show saved values, so the panel waits for saved data too.
    settingsPanel:Register()
    -- Without the system message event, Guild Greet simply never prompts.
    client:ObservePresence(function(kind, name)
        guildGreet:OnPresence(kind, name)
    end)
    -- Prompts wait out combat and boss encounters.
    local busy = client:ObserveCombat(function(inCombat)
        guildGreet:OnCombatChanged(inCombat)
        guildRecruit:OnCombatChanged(inCombat)
    end)
    if busy then
        guildGreet:OnCombatChanged(true)
        guildRecruit:OnCombatChanged(true)
    end
    -- Advertise prompts follow the player from zone to zone, and greet
    -- prompts close on entering an instance where they're off.
    client:ObserveZone(function()
        guildRecruit:Refresh()
        guildGreet:OnZoneChanged()
    end)
    guildRecruit:Refresh()
    -- The Group Finder's slots follow the party, and every party with
    -- guildmates goes into the local group history.
    client:ObserveParty(function()
        syncParty()
        recordParty()
        if groupFinder ~= nil then
            groupFinder:Refresh()
        end
        -- Guildmates outside the party are dimmed on the maps.
        if mapPins ~= nil then
            mapPins:Refresh()
        end
    end)
    -- Guild Mail follows the mailbox, and sends its next mail when the game
    -- answers the last. Officers get its button on the mailbox.
    client:ObserveMail(function(kind, blockedAddon, blockedCall)
        if kind == "error" then
            -- The text follows an error number; older clients pass only the
            -- text.
            local message = type(blockedCall) == "string" and blockedCall or blockedAddon
            guildMail:OnError(message)
            return
        end
        if kind == "blocked" then
            -- Only this add-on's blocked SendMail matters here; the event
            -- fires for every add-on.
            if blockedAddon ~= addonName or not string.find(tostring(blockedCall), "SendMail", 1, true) then
                return
            end
            if guildMail:OnBlocked() then
                rosterController:Print("The game blocked Guild Mail's send. Press Send next for each mail.")
            end
            return
        end
        if kind == "open" then
            guildMail:OnMailboxOpened()
            pcall(guildMailWindow.ShowMailboxButton, guildMailWindow, guildMail:ShowsMailboxButton())
        elseif kind == "close" then
            guildMail:OnMailboxClosed()
        elseif kind == "sent" then
            guildMail:OnSent()
        elseif kind == "failed" then
            guildMail:OnFailed(nil)
        elseif kind == "money" then
            -- The money line, and whether the postage is affordable.
            guildMail:Refresh()
        end
    end)
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
addon.pages = pages
addon.entryPoints = entryPoints
addon.guildNoteOverlay = guildNoteOverlay
addon.locationBoard = locationBoard
addon.mapPins = mapPins
addon.chatAnnotator = chatAnnotator
addon.comm = comm
addon.settings = settings
addon.settingsPanel = settingsPanel
addon.frameSettings = frameSettings
addon.guildGreet = guildGreet
addon.guildRecruit = guildRecruit
addon.groupSession = groupSession
addon.groupBoard = groupBoard
addon.groupAvailability = groupAvailability
addon.joinRequests = joinRequests
addon.joinPrompts = joinPrompts
addon.syncSession = syncSession
addon.router = router
addon.version = version

lifecycle:Start()
