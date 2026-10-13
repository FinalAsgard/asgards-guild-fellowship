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

local persistence, rosterController, entryPoints, chatAnnotator, comm, syncSession, settings, settingsPanel, pages
local frameSettings
local guildGreet, greetPrompts, guildRecruit, recruitPrompts, officerAuthority
local groupFinder, groupSession, syncParty, groupAvailability, joinRequests, joinPrompts, onGroupFinderMessage
local onSlotsChanged
-- Draws the Group Finder on its tab (set up with the Group Finder below).
local drawGroupFinder
-- Records the party in the local group history (set up with the Group
-- Finder below).
local recordParty = function() end
if clientProfile.supported then
    persistence = addon.Persistence.Create(client)
    comm = addon.Comm.Create(client, addon.Identity.commPrefix)
    -- The master frame's tabs, in order. The first is where the general
    -- entry points open it.
    pages = addon.PageNavigator.Create()
    pages:Add("roster", "Roster", addon.MasterFrame.ICONS.roster)
    pages:Add("group", "Group Finder", addon.MasterFrame.ICONS.group)
    pages:Add("recruitment", "Recruitment", addon.MasterFrame.ICONS.recruitment)
    pages:Add("ads", "Recent Guild Advertisements", addon.MasterFrame.ICONS.ads)
    pages:Add("greetings", "Greetings", addon.MasterFrame.ICONS.greetings)
    pages:Add("settings", "Settings", addon.MasterFrame.ICONS.settings)
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
    -- Role preferences: which roles the logged-in character is willing to
    -- play, synced to the guild. Only the roles its class can fill are
    -- offered.
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
    local function selfClass()
        local guild, partition = rosterController:QuietContext()
        local key = rosterController:SelfKey()
        local character = guild and key and partition:GetCharacter(key)
        return character and character.class or nil
    end
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
            shown = function()
                return roleCatalog:Can(selfClass(), role)
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
    syncParty = function()
        if groupSession:IsActive() then
            -- Each member's guild roster key, so an invitee who joined is
            -- recognized.
            local members = client:GetPartyMembers()
            local guild, _, normalizer = rosterController:QuietContext()
            local index
            for index = 1, #members do
                members[index].rosterKey = guild and normalizer:Key(members[index].name) or nil
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
    local showJoinPrompts
    -- The invitee answers by clicking, so an answer goes out even while busy.
    showJoinPrompts = function()
        joinPrompts:Show(joinRequests:Pending(), {
            -- Accepting one declines the rest: those organizers hear the
            -- invitee joined another group.
            accept = function(id, choice)
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
    local function tick()
        local now = client:Timestamp()
        if now ~= nil then
            if groupSession:Expire(now)[1] ~= nil then
                refreshGroupFinder()
            end
            if joinRequests:Expire(now)[1] ~= nil then
                showJoinPrompts()
            end
        end
        if groupSession:PendingRequests()[1] == nil and joinRequests:Pending()[1] == nil then
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
    -- roles still open, or that nothing is left.
    onSlotsChanged = function()
        local updates, withdrawals = groupSession:SlotChanges()
        local index
        for index = 1, #updates do
            sendWhenFree(addon.GroupFinderProtocol.Slots(updates[index].to, updates[index].id, updates[index].roles))
        end
        for index = 1, #withdrawals do
            sendWhenFree(addon.GroupFinderProtocol.Withdraw(withdrawals[index].to, withdrawals[index].id))
        end
        if updates[1] ~= nil or withdrawals[1] ~= nil then
            refreshGroupFinder()
        end
    end
    local function cancelRequest(id)
        local request = groupSession:Cancel(id)
        if request ~= nil then
            sendGroupFinder(addon.GroupFinderProtocol.Cancel(request.to, id))
        end
    end
    -- Every Group Finder message: availability asks and replies, and
    -- targeted messages, which only their recipient handles.
    onGroupFinderMessage = function(message, sender)
        local protocol = addon.GroupFinderProtocol
        if message.t == protocol.TYPE_ASK or message.t == protocol.TYPE_AVAILABLE then
            groupAvailability:OnMessage(message, sender)
            return
        end
        local selfKey = rosterController:SelfKey()
        local senderKey = keyOfSender(sender)
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
        local guild, partition, normalizer = rosterController:QuietContext()
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
                local key = not members[index].isPlayer and normalizer:Key(members[index].name)
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
            postToGuild = function(text)
                return client:SendGuildMessage(text)
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
                    local key = normalizer:Key(members[index].name)
                    if key ~= nil then
                        excluded[key] = true
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
        location = function()
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
        elseif entry ~= nil and entry.category ~= nil then
            guildGreet:OnCategoryChanged(entry.category, value)
        end
    end)
    client:ObserveGuildRoster(function()
        rosterController:OnRosterUpdate()
        -- Who is online decides the Group Finder's Invite buttons.
        if groupFinder ~= nil then
            groupFinder:Refresh()
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
        else
            syncSession:Receive(message, sender)
        end
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
        guildRecruit:OnCombatChanged(inCombat)
    end)
    if busy then
        guildGreet:OnCombatChanged(true)
        guildRecruit:OnCombatChanged(true)
    end
    -- Advertise prompts follow the player from zone to zone.
    client:ObserveZone(function()
        guildRecruit:Refresh()
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
addon.chatAnnotator = chatAnnotator
addon.comm = comm
addon.settings = settings
addon.settingsPanel = settingsPanel
addon.frameSettings = frameSettings
addon.guildGreet = guildGreet
addon.guildRecruit = guildRecruit
addon.groupSession = groupSession
addon.groupAvailability = groupAvailability
addon.joinRequests = joinRequests
addon.joinPrompts = joinPrompts
addon.syncSession = syncSession
addon.router = router
addon.version = version

lifecycle:Start()
