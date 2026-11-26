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
-- The officers' guild log for the current guild, or nil for everyone else
-- (set up with guild sync below).
local guildLogOf = function()
    return nil
end
local requestGuildLog, readGuildLog, recordLiveMembership = function() end, function() end, function() end
-- Shares the officers' guild log between officers (see GuildLogSync).
local guildLogSync
-- Membership dates (see MembershipDates), set up with guild sync below:
-- what a roster scan saw, and the officer's lines for the player panel.
local observeMembership, membershipLines, earliestJoin = function() end, function() end, function() end
-- An add-on message was heard from a character (see MembershipDates:Heard).
local heardFrom = function() end
-- The officers' Promotions page, the requirements editor (see
-- RankRequirements), set up with guild sync below: view() gives its
-- model, and the rest edit it.
local promotions = {
    view = function()
        return nil
    end,
    askOnce = function() end,
    prune = function() end,
    shown = function() end,
    changed = function() end,
    readyKeys = function()
        return nil
    end,
    timeMetKeys = function()
        return nil
    end,
    panelRows = function()
        return nil
    end,
}
local guildGreet, greetPrompts, guildRecruit, recruitPrompts, officerAuthority, slowModeConfig
local guildMail, guildMailWindow, mailboxTab, guildWelcome
local resync
local guildNoteOverlay
-- The add-on's new window (see AgfWindow) and the LFG button (see
-- LfgButton), set up with the settings below.
local agfWindow, lfgButton
-- The Guild LFG Board: the player's own listing, the listings heard from
-- guildmates, and the page drawing them (set up with the settings below).
local lfgListing, lfgBoard, lfgPage, drawLfgBoard, onLfgMessage, probeLfg
-- What the LFG button and drawer show (LfgDrawerModel), and the redraw of
-- the button and the board when anything they show may have changed.
local lfgDrawer = addon.LfgDrawerModel.Create()
local lfgRefresh = function() end
-- When the party changes, what happens to the listing (LfgTrigger), and
-- how long a leader who handed the lead on keeps it before ending it.
local lfgTrigger = addon.LfgTrigger.Create()
local lfgOnParty = function() end
local lfgOnZone = function() end
-- The player says yes to listing a party led from outside the guild: they
-- claim contact (see LfgTrigger).
local lfgClaim = function() end
-- A guildmate logged off: their listing is handed on or dropped.
local lfgOnOffline = function() end
-- Ask to join: the roles the current character can ask a dungeon listing
-- for, asking, and the leader's Invite and Decline; and announcing the
-- player's listing again (when whether it takes asks changed); and the
-- slot-open path: the party as last seen, the open slot (false, or { role
-- }), the answer to "fill the empty slot?" and the party's listing.
-- (One table: the main chunk is near Lua's 200-local limit.)
local lfgJoin = {
    askRoles = function() return {} end,
    ask = function() end,
    invite = function() end,
    decline = function() end,
    announce = function() end,
    sweep = function() return {} end,
    before = {},
    slot = false,
    fillSlot = function() end,
    postSlot = function() end,
    partyListing = function() return nil end,
    -- /agfdev lfgtest's stand-in "fill the empty slot?" is showing.
    standInSlot = false,
    -- A questing listing's leader moved: the zone they're asked to move it
    -- to (false when not asking), the zones they said No to (a set), looking
    -- at the zone, and the answer.
    zoneMove = false,
    zoneDeclined = {},
    checkZone = function() end,
    moveZone = function() end,
    -- The guildmates in the player's zone, for the button's Show Nearby.
    nearby = function() return nil end,
}
local LFG_HAND_OFF_SECONDS = 5
-- A guildmate's group-friend tier by character key (set up with the group
-- friends below).
local lfgFriendTier = function() return nil end
-- The Friends page in the new window, and drawing it, set up with the group
-- friends below. (One table: the main chunk is near Lua's 200-local limit.)
local friendsUi = {
    page = nil,
    draw = function() end,
}
-- The Greetings page in the new window, once it's drawn.
local greetingsUi = {
    page = nil,
}
-- The key the new UI saves this character's layout under: its GUID, the
-- same in every guild (or with none), else its full name.
local function layoutKey()
    return client:GetPlayerGuid() or client:GetPlayerFullName()
end
local locationBoard, locationScheduler, mapPins, onLocationMessage, startLocations, shareLocationNow
local dropOfflineLocations, dropLocationOf
-- Draws My Profile on its tab (set up with My Profile below).
local drawProfile
-- Records the party in the local group history (set up with the Guild LFG
-- Board below).
local recordParty = function() end
-- Remembers that this install logged in on the current character (set up
-- with the roster below).
local recordOwnCharacter = function() end
if clientProfile.supported then
    -- Where the region stands in for the realm (WoW Forever), data saved
    -- under the realm the game used to name moves to the region.
    persistence = addon.Persistence.Create(client, {
        homeRealm = function()
            return client:RealmIsRegion() and client:GetRegionName() or nil
        end,
    })
    comm = addon.Comm.Create(client, addon.Identity.commPrefix, addon.Identity.liveCommPrefix)
    -- The master frame's tabs, in order. The first is where the general
    -- entry points open it.
    pages = addon.PageNavigator.Create()
    pages:Add("roster", "Roster", addon.MasterFrame.ICONS.roster)
    pages:Add("profile", "My Profile", addon.MasterFrame.ICONS.profile)
    pages:Add("recruitment", "Recruitment", addon.MasterFrame.ICONS.recruitment)
    pages:Add("ads", "Recent Guild Advertisements", addon.MasterFrame.ICONS.ads)
    pages:Add("greetings", "Greetings", addon.MasterFrame.ICONS.greetings)
    -- Officers only: they come and go with the character's rank.
    pages:Add("promotions", "Promotion Requirements", addon.MasterFrame.ICONS.promotions, function()
        return guildLogOf() ~= nil
    end)
    pages:Add("guildlog", "Guild Log", addon.MasterFrame.ICONS.guildlog, function()
        return guildLogOf() ~= nil
    end)
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
    -- Guild LFG Board.
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
        -- Their own player's is their own edit; an officer's for someone
        -- else is stamped on that player's main.
        onProfileTextChanged = function(key, kind, text)
            if rosterController:IsOwnPlayer(key) then
                return syncSession:LocalProfileEdit(kind, text)
            end
            return syncSession:LocalPlayerTextEdit(key, kind, text)
        end,
        onDeclaredChanged = function(key, before)
            syncSession:LocalDeclaredEdit(key, before)
        end,
        onScanFinished = function(_, result)
            syncSession:UpgradeLegacy()
            recordOwnCharacter()
            observeMembership()
            -- Once ranks are known, catch up on promotion requirements and
            -- ticks; a rank change makes a character's ticks stale.
            promotions.prune()
            promotions.askOnce()
            promotions.changed()
            -- Every add-on follows the guild's Slow mode setting, so each
            -- asks the officers' add-ons for it once ranks are known.
            if slowModeConfig ~= nil then
                slowModeConfig:AskOnce()
            end
            -- A scan that saw a promotion or demotion shows or hides the
            -- officers' tabs.
            rosterController:RefreshPages()
            -- Characters new to the guild may be due a welcome mail.
            if guildWelcome ~= nil and type(result) == "table" then
                guildWelcome:OnScan(result.newKeys)
            end
        end,
        -- Out-of-date guild notes are worked out again after every scan,
        -- sync, and manual change.
        onChanged = function()
            if guildNoteOverlay ~= nil then
                guildNoteOverlay:Refresh()
            end
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
        joined = function(keys)
            return earliestJoin(keys)
        end,
        membership = function(keys)
            return membershipLines(keys)
        end,
        promotionsView = function()
            return promotions.view()
        end,
        promotion = function(keys, playerId)
            return promotions.panelRows(keys, playerId)
        end,
        readyKeys = function()
            return promotions.readyKeys()
        end,
        timeMetKeys = function()
            return promotions.timeMetKeys()
        end,
        grouped = function(keys)
            local guild, partition = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            return addon.GroupHistory.Create(partition):Stats(keys)
        end,
        recruitRecord = function(keys)
            return guildRecruit:RecordFor(keys)
        end,
        recentAds = function()
            return guildRecruit:KnownAds()
        end,
        guildLog = function()
            return (guildLogOf())
        end,
        rankName = function(index)
            local names = client:GetGuildRankNames()
            return names and names[index + 1] or nil
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
                timerIcon = addon.RosterViewModel.TimerIcon(client:TextureLoads(addon.RosterViewModel.TIMER_TEXTURE)),
                drawPages = {
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
                onGuildLogShown = function()
                    rosterController:RefreshGuildLog()
                end,
                onPromotionsShown = function()
                    promotions.shown()
                end,
                onPromotionsRank = function(step)
                    return promotions.rank(step)
                end,
                onPromotionsAdd = function(label, needsNote)
                    return promotions.add(label, needsNote)
                end,
                onPromotionsRename = function(id, label, needsNote)
                    return promotions.rename(id, label, needsNote)
                end,
                onPromotionsAutomated = function(kind, enabled, n)
                    return promotions.automated(kind, enabled, n)
                end,
                onPromotionsMatchAlts = function(on)
                    return promotions.matchAlts(on)
                end,
                onPromotionsSnoozeDays = function(days)
                    return promotions.snoozeDays(days)
                end,
                onPromotionsMove = function(id, step)
                    return promotions.move(id, step)
                end,
                onPromotionsDelete = function(id)
                    return promotions.delete(id)
                end,
                onPromotionsTick = function(key, item, ticked, note)
                    return promotions.tick(key, item, ticked, note)
                end,
                onPanelPromotionToggle = function(key, expanded)
                    return promotions.togglePanel(key, expanded)
                end,
                onPromotionsSnooze = function(key)
                    return promotions.snooze(key)
                end,
                onGuildLogSearch = function(text)
                    rosterController:SetGuildLogSearch(text)
                end,
                onGuildLogSort = function(sort)
                    rosterController:SetGuildLogSort(sort)
                end,
                onGuildLogRange = function(days)
                    rosterController:SetGuildLogRange(days)
                end,
                onGuildLogType = function(eventType, shown)
                    rosterController:SetGuildLogType(eventType, shown)
                end,
                onGuildLogPage = function(page)
                    rosterController:SetGuildLogPage(page)
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
                loadPlayerPanelPosition = function()
                    local store = rosterController:Store()
                    return store and store:GetPlayerPanelPosition()
                end,
                savePlayerPanelPosition = function(position)
                    local store = rosterController:Store()
                    if store ~= nil then
                        store:SetPlayerPanelPosition(position)
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
                onSetProfileText = function(key, kind, text)
                    rosterController:SetProfileText(key, kind, text)
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
    -- The LFG button, per character. Hidden means "not participating right
    -- now"; later parts of the Guild LFG Board read it from here.
    settings:Add("general", {
        id = "lfgButton",
        kind = "toggle",
        label = "Show LFG button",
        get = function()
            local store, key = rosterController:Store(), layoutKey()
            return store == nil or key == nil or store:LfgButtonShown(key)
        end,
        set = function(shown)
            local store, key = rosterController:Store(), layoutKey()
            if store == nil or key == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetLfgButtonShown(key, shown) then
                return nil, "the saved layout is unreadable"
            end
            return true
        end,
    })
    -- A chat line for each new Guild LFG Board group the character could
    -- join, account-wide, off unless turned on.
    settings:Add("general", {
        id = "lfgChatLine",
        kind = "toggle",
        label = "Chat line for new LFG groups for you",
        get = function()
            local store = rosterController:Store()
            return store ~= nil and store:LfgChatLine()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetLfgChatLine(enabled) then
                return nil, "the saved setting is unreadable"
            end
            return true
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
        label = "Show greet prompts",
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
    settings:Add("guildGreet", {
        id = "greetPromptOptionsHeading",
        kind = "heading",
        label = "Prompts",
    })
    -- The character that's logged in; the set of characters it's off on is
    -- account-wide.
    settings:Add("guildGreet", {
        id = "greetCharacter",
        kind = "toggle",
        label = "Greet from this character",
        info = function()
            return "\"Show greet prompts\" turns Guild Greet on or off for every character on this account. " ..
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
        label = "Greet guild members during dungeons and raids",
        info = function()
            return "Off by default: you get no greet prompts inside dungeons, raids, battlegrounds, arenas and " ..
                "keystone runs. Guildmates who come online while you're inside aren't prompted for later. " ..
                "Turn this on to be prompted there too."
        end,
        get = function()
            local store = rosterController:Store()
            return store ~= nil and store:GreetInInstances()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetGreetInInstances(enabled) then
                return nil, "the saved setting is unreadable, so it stays off"
            end
            return true
        end,
    })
    settings:Add("guildGreet", {
        id = "greetHighlightFriends",
        kind = "toggle",
        label = "Highlight group friends",
        info = function()
            return "On by default. Players you've grouped with show in blue on their prompts. The ones you've " ..
                "grouped with 4 or more times get a star too, and your 5 most grouped-with players a star and " ..
                "a purple name. It only uses your own party history, which is never shared."
        end,
        get = function()
            local store = rosterController:Store()
            return store == nil or store:GreetHighlightFriends()
        end,
        set = function(enabled)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetGreetHighlightFriends(enabled) then
                return nil, "the saved setting is unreadable, so it stays on"
            end
            return true
        end,
    })
    settings:Add("guildGreet", {
        id = "greetFor",
        kind = "choice",
        label = "Greet prompts for",
        choices = {
            { id = addon.FellowshipStore.GREET_FOR.everyone, label = "Everyone" },
            { id = addon.FellowshipStore.GREET_FOR.grouped, label = "Grouped with" },
            { id = addon.FellowshipStore.GREET_FOR.friends, label = "My Friends" },
        },
        info = function()
            return "Everyone by default. Grouped with: you only get greet prompts, welcomes to the guild " ..
                "included, for players you've grouped with at least once, and your Friends. My Friends: only " ..
                "for your Friends and your 5 most grouped-with players. Changing it closes waiting prompts " ..
                "that no longer fit. It works whether or not \"Highlight group friends\" is on."
        end,
        get = function()
            local store = rosterController:Store()
            return store ~= nil and store:GreetFor() or addon.FellowshipStore.GREET_FOR.everyone
        end,
        set = function(choice)
            local store = rosterController:Store()
            if store == nil then
                return nil, "saved data is unavailable"
            end
            if not store:SetGreetFor(choice) then
                return nil, "the saved setting is unreadable, so it stays as it is"
            end
            return true
        end,
    })
    -- Not saved, and only while the master frame or the options are open:
    -- closing either, or a reload, locks the prompts again.
    settings:Add("guildGreet", {
        id = "greetMove",
        kind = "action",
        offOnClose = true,
        label = "Move greeting pop-ups",
        activeLabel = "Done moving",
        active = function()
            return greetPrompts:IsUnlocked()
        end,
        run = function()
            return greetPrompts:SetUnlocked(not greetPrompts:IsUnlocked())
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
    settings:Add("guildGreet", {
        id = "greetCloseHeading",
        kind = "heading",
        label = "Close my prompt after",
    })
    settings:Add("guildGreet", {
        id = "greetCap",
        kind = "number",
        label = "Greetings (login, welcome back)",
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
    greetNumber("welcomeCap", "Guild join welcomes")
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
    -- Officers set Slow mode for the whole guild; everyone else sees the
    -- guild's value but can't change it.
    local function slowModeOfficer()
        return slowModeConfig ~= nil and slowModeConfig:IsOfficer()
    end
    settings:Add("guildGreet", {
        id = "greetOfficerHeading",
        kind = "heading",
        style = "officer",
        label = "Officer settings (officer only): these apply to everyone in the guild",
    })
    local slowMode = addon.SlowModeConfig.SETTINGS.slowModeMinutes
    settings:Add("guildGreet", {
        id = "greetSlowMode",
        kind = "number",
        slider = true,
        label = "Slow mode: minutes between each greeter's greetings (0 = off)",
        min = slowMode.min,
        max = slowMode.max,
        format = function(minutes)
            if minutes == 0 then
                return "Off"
            end
            return minutes .. " min"
        end,
        enabled = function()
            if not slowModeOfficer() then
                return false, "only officers can change it"
            end
            return true
        end,
        get = function()
            return slowModeConfig and slowModeConfig:Minutes() or slowMode.default
        end,
        set = function(minutes)
            if slowModeConfig == nil then
                return nil, "saved data is unavailable"
            end
            return slowModeConfig:SetMinutes(minutes)
        end,
    })
    -- Says why the slider is greyed out, only when it is.
    settings:Add("guildGreet", {
        id = "greetSlowModeReadOnly",
        kind = "text",
        shown = function()
            return not slowModeOfficer()
        end,
        get = function()
            return "Only officers can change it."
        end,
    })
    -- Guild Recruit's settings only change for a character that can invite
    -- to the guild.
    local function recruitAvailable()
        if not client:CanGuildInvite() then
            return false, "this character can't invite to the guild"
        end
        return true
    end
    settings:AddSection("groupFinder", "Do Not Disturb")
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
    -- The add-on's new window, which features move into one at a time; for
    -- now it has the Guild LFG Board. Its fonts are shared through
    -- LibSharedMedia. It's made on first open, and its place is saved per
    -- character.
    addon.Theme.Register(client:GetLibrary("LibSharedMedia-3.0"))
    agfWindow = addon.AgfWindow.Create(client, {
        frameName = addon.Identity.addonName .. "Window",
        modules = {
            -- First, so it's the window's default page.
            { id = "friends", label = "Friends", title = "Friends",
                draw = function(content, ui)
                    friendsUi.draw(content, ui)
                end,
                -- Given a player id (Open in Guild Fellowship), shows them.
                onShow = function(playerId)
                    if friendsUi.page ~= nil then
                        friendsUi.page:Refresh(playerId)
                    end
                end },
            { id = "lfg", label = "LFG", title = "Guild LFG Board",
                settingsRows = {
                    { id = "lfgButton", label = "Show LFG button" },
                    { id = "lfgChatLine", label = "Chat line for new groups",
                        info = "A line in chat for each new group you could join." },
                },
                draw = function(content, ui)
                    drawLfgBoard(content, ui)
                end,
                onShow = function()
                    if lfgPage ~= nil then
                        lfgPage:Refresh()
                    end
                end },
            -- Guild Greet's greetings, from saved data each time it's shown.
            { id = "greetings", label = "Greetings", title = "Greetings",
                headerSwitch = { id = "guildGreet", label = "Greet prompts", on = "Greet prompts on",
                    off = "Greet prompts off" },
                -- The same entries as the AddOns options' Guild Greet settings.
                settingsRows = {
                    { id = "greetCharacter", info = true },
                    { id = "greetInInstances", label = "Greet in dungeons and raids", info = true },
                    { id = "greetHighlightFriends" },
                    { id = "greetFor" },
                    { id = "greetMove" },
                },
                draw = function(content, ui)
                    greetingsUi.page = addon.AgfGreetingsPage.Create(content, ui, {
                        editor = addon.GreetingsEditor.Create({
                            library = function()
                                return guildGreet:Library()
                            end,
                            enabled = function(category)
                                return settings:Get("greetCategory:" .. category) == true
                            end,
                            minutes = function()
                                return settings:Get("welcomeBackMinutes")
                            end,
                            promptsOn = function()
                                return settings:Get("guildGreet") == true
                            end,
                            -- The preview fills in the user's own names.
                            names = function()
                                local fullName = client:GetPlayerFullName()
                                local _, _, normalizer = rosterController:QuietContext()
                                if fullName == nil then
                                    return {}
                                end
                                return guildGreet:Names(normalizer and normalizer:Key(fullName) or fullName, fullName)
                            end,
                            now = function()
                                return client:Timestamp()
                            end,
                            characterOn = function()
                                return settings:Get("greetCharacter") ~= false
                            end,
                            -- As the roster spells it: Forever's game reports only
                            -- the first name.
                            character = function()
                                local _, partition, normalizer = rosterController:QuietContext()
                                local key = rosterController:SelfKey()
                                local stored = partition and key and partition:GetCharacter(key)
                                local name = stored and stored.name or client:GetPlayerFullName()
                                return name and normalizer and normalizer:Display(name) or name
                            end,
                        }),
                        settings = settings,
                        onError = function(text)
                            rosterController:Print(text)
                        end,
                        after = function(seconds, callback)
                            return client:After(seconds, callback)
                        end,
                    })
                    addon.greetingsPage = greetingsUi.page
                end,
                onShow = function()
                    if greetingsUi.page ~= nil then
                        greetingsUi.page:Refresh()
                    end
                end },
        },
        settings = settings,
        settingsTabs = {
            {
                id = "chat",
                label = "Chat",
                rows = {
                    { id = "chatTags", label = "Chat tags",
                        info = "Tag guild chat speakers with their alias or main." },
                    { id = "chatTagColor:alias", label = "Alias tag color",
                        info = "The color of a speaker's alias tag." },
                    { id = "chatTagColor:main", label = "Main's name tag color",
                        info = "The color of a speaker's main's name tag." },
                },
            },
        },
        character = function()
            local fullName = client:GetPlayerFullName()
            return {
                name = fullName and string.match(fullName, "^[^%-]+") or nil,
                level = client:GetPlayerLevel(),
                className = client:GetPlayerClassName(),
                classColor = client:GetClassColor(client:GetPlayerClass()),
            }
        end,
        version = version,
        loadPosition = function()
            local store, key = rosterController:Store(), layoutKey()
            return store and key and store:WindowPosition(key) or nil
        end,
        savePosition = function(position)
            local store, key = rosterController:Store(), layoutKey()
            if store ~= nil and key ~= nil then
                store:SetWindowPosition(key, position)
            end
        end,
    })
    local function openBoard()
        local opened, failure = agfWindow:Open("lfg")
        if not opened then
            rosterController:Print("The Guild LFG Board can't open on this client: " .. tostring(failure))
        end
    end
    lfgButton = addon.LfgButton.Create(client, {
        frameName = addon.Identity.addonName .. "LfgButton",
        shown = function()
            return settings:Get("lfgButton") == true
        end,
        onOpenBoard = openBoard,
        onDrawerOpened = function()
            lfgDrawer:Seen()
            lfgRefresh()
        end,
        onStartGroup = function()
            openBoard()
            if lfgPage ~= nil and not lfgListing:IsActive() then
                lfgPage:StartEditing()
            end
        end,
        -- The leader's question: what it's for goes through the board's
        -- card; Not looking (or no answer) and the snooze ask nothing more.
        -- Yes to listing a party led from outside the guild makes the
        -- player its contact first.
        onListParty = function()
            if lfgTrigger:Gating() and client:IsInGroup() and not client:IsGroupLeader() then
                lfgClaim()
            else
                lfgTrigger:Answered()
            end
            openBoard()
            if lfgPage ~= nil and not lfgListing:IsActive() then
                lfgPage:StartEditing()
            end
            lfgRefresh()
        end,
        onNotLooking = function()
            lfgTrigger:NotLooking()
            lfgRefresh()
        end,
        onSnooze = function()
            lfgTrigger:Snooze(client:Timestamp() or 0)
            lfgRefresh()
        end,
        onFillSlot = function(yes)
            lfgJoin.fillSlot(yes)
        end,
        onMoveZone = function(yes)
            lfgJoin.moveZone(yes)
        end,
        nearby = function()
            return lfgJoin.nearby()
        end,
        dungeonIcon = function(name)
            local dungeon = addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList()):Named(name)
            return dungeon and dungeon.icon or nil
        end,
        askRoles = function(listing)
            return lfgJoin.askRoles(listing)
        end,
        onAsk = function(listing, role)
            lfgJoin.ask(listing, role)
        end,
        onWhisper = function(name)
            client:OpenWhisper(name)
        end,
        onInvite = function(request)
            lfgJoin.invite(request)
        end,
        onDecline = function(request)
            lfgJoin.decline(request)
        end,
        classColor = function(classToken)
            return client:GetClassColor(classToken)
        end,
        onHide = function()
            local hidden, reason = settings:Set("lfgButton", false)
            if hidden then
                rosterController:Print("LFG button hidden. Type " .. addon.Identity.slashCommand ..
                    " lfg to bring it back.")
            else
                rosterController:Print("Can't hide the LFG button: " .. tostring(reason) .. ".")
            end
        end,
        loadPosition = function()
            local store, key = rosterController:Store(), layoutKey()
            return store and key and store:LfgButtonPosition(key) or nil
        end,
        savePosition = function(position)
            local store, key = rosterController:Store(), layoutKey()
            if store ~= nil and key ~= nil then
                store:SetLfgButtonPosition(key, position)
            end
        end,
    })
    -- However it's switched (the gear popup, the old window, the menu), the
    -- button follows.
    settings:OnChange(function(id)
        if id == "lfgButton" then
            lfgButton:Refresh()
            -- A hidden button takes no asks: guildmates see Whisper.
            lfgJoin.announce()
            -- An open slot waits while it's hidden, and is asked about again
            -- when it's back.
            if settings:Get("lfgButton") ~= true then
                lfgTrigger:Pause()
            elseif lfgTrigger:Resume(client:Timestamp() or 0) then
                lfgJoin.slotTimer()
                lfgRefresh()
                if lfgButton:IsShowing() and not lfgButton:DrawerOpen() then
                    lfgButton:OpenDrawer()
                end
            end
        end
        -- Do Not Disturb stops the glow; a shown button needs its count.
        if id == "lfgButton" or id == "dnd" then
            lfgRefresh()
        end
    end)
    -- Brings the button back if it was hidden, and opens the board.
    router:Register("lfg", "show the LFG button and open the Guild LFG Board", function()
        if settings:Get("lfgButton") ~= true then
            local shown, reason = settings:Set("lfgButton", true)
            if not shown then
                rosterController:Print("Can't show the LFG button: " .. tostring(reason) .. ".")
            end
        end
        openBoard()
    end)
    local function keyOfSender(sender)
        local guild, _, normalizer = rosterController:QuietContext()
        return guild and normalizer:Key(sender) or nil
    end
    -- The Guild LFG Board. The player's listing is announced when it
    -- starts or changes and every HEARTBEAT_SECONDS while it lasts; its end
    -- once. Nothing goes out in combat, a boss encounter or a keystone run:
    -- the latest announcement waits until they're over.
    lfgListing = addon.LfgListing.Create()
    lfgBoard = addon.LfgBoard.Create()
    -- Ask to join requests to the player's listing.
    lfgJoin.requests = addon.LfgRequests.Create()
    local lfgWaiting, lfgFlushing, lfgHeartbeat
    local function refreshLfg()
        lfgRefresh()
    end
    local function flushLfg()
        lfgFlushing = false
        if lfgWaiting == nil then
            return
        end
        if comm:IsBusy() then
            lfgFlushing = client:After(2, flushLfg)
            if not lfgFlushing then
                lfgWaiting = nil
            end
            return
        end
        local message = lfgWaiting
        lfgWaiting = nil
        comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
    end
    local function sendLfg(message)
        lfgWaiting = message
        if not lfgFlushing then
            flushLfg()
        end
    end
    -- The party as the listing announces it, the leader first: the player
    -- alone, or their party (the whole raid in a raid). Each member's role
    -- is the game's (set in its party menu), else the first their class
    -- can play (the player's own: the first they're willing to).
    local function lfgMembers()
        local classToken = client:GetPlayerClass()
        local preferred = (rolesOf(rosterController:SelfKey()) or {})[1]
        local members = {}
        if client:IsInGroup() then
            local group = client:IsInRaid() and client:GetGroupMembers() or client:GetPartyMembers()
            local leaderIndex
            local index
            for index = 1, #(group or {}) do
                local member = group[index]
                local inGuild = member.inGuild
                if inGuild == nil then
                    -- The client can't say: the guild roster does.
                    local guildKey = rosterController:RosterKeyFor(member.name, member.guid)
                    local _, partition = rosterController:QuietContext()
                    inGuild = guildKey ~= nil and partition ~= nil and partition:IsInGuild(guildKey)
                end
                table.insert(members, {
                    key = member.key,
                    name = string.match(member.name, "^[^%-]+") or member.name,
                    fullName = member.name,
                    guid = member.guid,
                    classToken = member.classToken,
                    level = member.level,
                    assignedRole = member.assignedRole,
                    role = member.isPlayer and preferred or nil,
                    isPlayer = member.isPlayer,
                    isLeader = member.isLeader,
                    inGuild = inGuild,
                    online = member.online,
                })
                if member.isLeader then
                    leaderIndex = #members
                end
            end
            if leaderIndex ~= nil and leaderIndex > 1 then
                table.insert(members, 1, table.remove(members, leaderIndex))
            end
        end
        if members[1] == nil then
            local fullName = client:GetPlayerFullName()
            members[1] = {
                key = "player",
                name = fullName and string.match(fullName, "^[^%-]+") or fullName or "?",
                classToken = classToken,
                level = client:GetPlayerLevel(),
                role = preferred,
                isPlayer = true,
            }
        end
        return addon.LfgListing.FillRoles(members, function(token)
            return roleCatalog:RolesFor(token)
        end)
    end
    local function announceListing()
        local fields = lfgListing:Announcement(lfgMembers(), settings:Get("lfgButton") == true)
        if fields ~= nil then
            sendLfg(addon.LfgProtocol.Listing(fields))
        end
    end
    -- Ends the listing; `left` when the player left the party, so a
    -- guildmate still in it can take it over.
    local function endListing(left)
        if lfgListing:IsActive() then
            lfgListing:End()
            sendLfg(addon.LfgProtocol.End(left))
        end
        lfgJoin.requests:Clear()
        refreshLfg()
    end
    -- Whether the player speaks for their listing: solo, leading the
    -- party, or its contact.
    local function lfgLister()
        if not client:IsInGroup() or client:IsGroupLeader() then
            return true
        end
        local selfKey = rosterController:SelfKey()
        return selfKey ~= nil and lfgTrigger:Contact() == selfKey
    end
    -- A listing on the board by its lister's key, or the one they had when
    -- they left the party or logged off.
    local function lfgListingOf(key, now)
        return lfgBoard:Get(key, now) or lfgBoard:Ended(key)
    end
    -- The party's members' roster keys.
    local function lfgKeyOf(member)
        return rosterController:RosterKeyFor(member.fullName or member.name, member.guid)
    end
    -- The player's party's listing on the board, by its contact or leader,
    -- when someone else lists it.
    lfgJoin.partyListing = function()
        local key = lfgTrigger:Contact()
        if key == nil then
            local leader = lfgMembers()[1]
            key = leader and leader.isLeader and lfgKeyOf(leader)
        end
        return key and lfgBoard:Get(key, client:Timestamp()) or nil
    end
    local function lfgTick()
        lfgHeartbeat = false
        if not lfgListing:IsActive() then
            return
        end
        if lfgListing:Expired(client:Timestamp() or 0, #lfgMembers()) then
            endListing()
            rosterController:Print("Your Guild LFG Board listing ended: nobody joined in 30 minutes.")
            return
        end
        announceListing()
        lfgHeartbeat = client:After(addon.LfgProtocol.HEARTBEAT_SECONDS, lfgTick)
    end
    -- The player's zone's level range (ZoneLevels): the game's, else the
    -- party's levels ± ZoneLevels.MARGIN.
    local function lfgZoneLevels()
        local levels = {}
        local members = lfgMembers()
        local index
        -- Only the levels known, with no gaps.
        for index = 1, #members do
            if members[index].level ~= nil then
                table.insert(levels, members[index].level)
            end
        end
        return addon.ZoneLevels.For(client:GetZoneLevels(), levels)
    end
    -- Who the board is sorted for: the logged-in character ({ level, roles
    -- }), and its player's other characters in the guild as alts ({ name,
    -- level, roles }), highest level first.
    local function lfgCharacters()
        local selfKey = rosterController:SelfKey()
        local current = {
            level = client:GetPlayerLevel(),
            roles = rolesOf(selfKey) or roleCatalog:RolesFor(client:GetPlayerClass()),
        }
        local guild, partition, normalizer = rosterController:QuietContext()
        local own = guild and selfKey and partition:GetCharacter(selfKey)
        if own == nil then
            return current, {}
        end
        local live = rosterController:LiveMembers(normalizer)
        local alts = {}
        local keys = partition:CharactersOf(own.player)
        local index
        for index = 1, #keys do
            local key = keys[index]
            local character = partition:GetCharacter(key)
            if key ~= selfKey and character ~= nil and partition:IsInGuild(key) then
                table.insert(alts, {
                    name = normalizer:Display((live[key] and live[key].name) or character.name or key) or key,
                    level = (live[key] and live[key].level) or character.level,
                    roles = roleCatalog:PreferencesOf(partition, key) or {},
                })
            end
        end
        table.sort(alts, function(a, b)
            if (a.level or 0) ~= (b.level or 0) then
                return (a.level or 0) > (b.level or 0)
            end
            return a.name < b.name
        end)
        return current, alts
    end
    -- Guildmates online in the player's zone, for the Nearby card: each
    -- character there, whispered by their full name.
    local function lfgNearby()
        local zone = client:GetZone()
        local guild, partition, normalizer = rosterController:QuietContext()
        if zone == nil or guild == nil then
            return nil
        end
        local entries = addon.LfgNearby.List({
            partition = partition,
            members = rosterController:LiveMembers(normalizer),
            display = function(name)
                return normalizer:Display(name)
            end,
        }, zone.name, rosterController:SelfKey())
        local people = {}
        local index, position
        for index = 1, #entries do
            for position = 1, #entries[index].characters do
                local character = entries[index].characters[position]
                local saved = partition:GetCharacter(character.key)
                table.insert(people, { name = character.name, whisper = saved and saved.name or character.name,
                    level = character.level, classToken = character.class })
            end
        end
        return { zone = zone.name, people = people }
    end
    lfgJoin.nearby = lfgNearby
    -- /agf probe lfg: where questing's zone levels come from, and what's on
    -- the board for this character.
    probeLfg = function()
        rosterController:Print("Guild LFG Board probe:")
        local zone = client:GetZone()
        local levels = lfgZoneLevels()
        local zoneLine = "  Zone levels" .. (zone and (" in " .. zone.name) or "") .. ": "
        if levels == nil then
            client:Print(zoneLine .. "unknown.")
        elseif levels.source == addon.ZoneLevels.GAME then
            client:Print(zoneLine .. levels.minLevel .. "-" .. levels.maxLevel .. ", from the game.")
        else
            client:Print(zoneLine .. levels.minLevel .. "-" .. levels.maxLevel .. ", the fallback (your party's" ..
                " levels, " .. addon.ZoneLevels.MARGIN .. " either way); the game gives none here.")
        end
        local own = lfgListing:Announcement(lfgMembers())
        client:Print("  Your listing: " .. (own and addon.LfgListing.Label(own.k, own.p) or "none") .. ".")
        local current, alts = lfgCharacters()
        local groups = lfgBoard:Groups(client:Timestamp(), current, alts)
        client:Print("  On the board: " .. #groups.relevant .. " relevant, " .. #groups.alts .. " for your alts, " ..
            #groups.other .. " other.")
        local function describe(where, listing, alt)
            local parts = { where, addon.LfgListing.Label(listing.kind, listing.purpose), "by " .. listing.leader,
                listing.size .. "/" .. listing.maxSize }
            if listing.minLevel ~= nil then
                table.insert(parts, "levels " .. listing.minLevel .. "-" .. listing.maxLevel)
            end
            if alt ~= nil then
                table.insert(parts, "fits " .. alt.name)
            end
            client:Print("    " .. table.concat(parts, ", "))
        end
        local index
        for index = 1, #groups.relevant do
            describe("Relevant", groups.relevant[index])
        end
        for index = 1, #groups.alts do
            describe("Alts", groups.alts[index].listing, groups.alts[index].alt)
        end
        for index = 1, #groups.other do
            describe("Other", groups.other[index])
        end
    end
    -- The player's party for the drawer, or nil when they're not in one:
    -- its listing when they lead one, else just its size.
    local function lfgParty()
        if not client:IsInGroup() then
            return nil
        end
        local raid = client:IsInRaid() == true
        -- A raid's every subgroup, not just the player's own.
        local size = #((raid and client:GetGroupMembers() or client:GetPartyMembers()) or {})
        local party = { kind = raid and "raid" or "other", size = math.max(size, 1),
            maxSize = raid and addon.LfgListing.RAID_SIZE or addon.LfgListing.PARTY_SIZE }
        local fields = lfgListing:IsActive() and lfgListing:Announcement(lfgMembers()) or nil
        if fields ~= nil then
            party.kind, party.label, party.note = fields.k, addon.LfgListing.Label(fields.k, fields.p), fields.no
            party.openRoles = fields.r
            -- The roster as announced, for the drawer's role tiles.
            party.members = {}
            local index
            for index = 1, #fields.mb do
                party.members[index] = { role = fields.mb[index].r }
            end
        end
        -- Fill the empty slot? What it would be posted as: the party's
        -- purpose (from the board when a guildmate lists it) and, for a
        -- dungeon, the open role.
        if lfgTrigger:SlotOpen() then
            local listing = fields == nil and lfgJoin.partyListing() or nil
            if listing ~= nil then
                party.kind, party.label = listing.kind, addon.LfgListing.Label(listing.kind, listing.purpose)
            end
            party.slotRole = party.kind == "dungeon" and lfgJoin.slot and lfgJoin.slot.role or nil
        end
        return party
    end
    -- Redraws the button (count, glow, drawer) and the board. New groups for
    -- the player get a chat line when they asked for one.
    lfgRefresh = function()
        if lfgPage ~= nil then
            lfgPage:Refresh()
        end
        -- With nothing heard, there's nothing to sort (and the guild's saved
        -- data isn't touched).
        local groups = { relevant = {}, alts = {}, other = {} }
        if lfgBoard:Listings(client:Timestamp())[1] ~= nil then
            local current, alts = lfgCharacters()
            groups = lfgBoard:Groups(client:Timestamp(), current, alts)
        end
        local view = lfgDrawer:Update({
            groups = groups,
            party = lfgJoin.standInSlot and addon.LfgStandIns.Party() or lfgParty(),
            combat = comm:IsBusy(),
            instance = client:IsInInstance(),
            dnd = settings:Get("dnd") == true,
            ask = lfgTrigger:Asking(),
            gate = lfgTrigger:Gating(),
            slotOpen = lfgTrigger:SlotOpen() or lfgJoin.standInSlot,
            zoneMove = lfgJoin.zoneMove ~= false and lfgListing:IsActive()
                and lfgListing:Purpose().kind == "questing" and lfgJoin.zoneMove or nil,
            requests = lfgJoin.sweep(),
            requestOf = function(id)
                return lfgBoard:Request(id, client:Timestamp())
            end,
        })
        if lfgButton ~= nil then
            lfgButton:Update(view)
        end
        if settings:Get("lfgChatLine") == true then
            local index
            for index = 1, #view.fresh do
                local listing = view.fresh[index]
                rosterController:Print("New group for you on the Guild LFG Board: " ..
                    addon.LfgListing.Label(listing.kind, listing.purpose) .. " (" .. listing.leader .. "). Type " ..
                    addon.Identity.slashCommand .. " lfg to see it.")
            end
        end
    end
    -- Start a group (or Edit) saved: the listing starts or changes, and the
    -- guild hears it now. Questing is in the zone's level range.
    local function saveListing(purpose, note)
        if type(purpose) == "table" and purpose.kind == "questing" then
            local levels = lfgZoneLevels()
            purpose.minLevel = levels and levels.minLevel or nil
            purpose.maxLevel = levels and levels.maxLevel or nil
        end
        -- Only the party's leader lists it, or its contact when the leader
        -- isn't in the guild.
        local inGroup = client:IsInGroup()
        if not lfgLister() then
            return false, "only your party's leader can list it"
        end
        if type(purpose) == "table" and purpose.kind ~= "raid" and #lfgMembers() > addon.LfgListing.PARTY_SIZE then
            return false, "a group of more than five can only be listed as a raid"
        end
        local saved, reason
        if lfgListing:IsActive() then
            saved, reason = lfgListing:Update(purpose, note)
        else
            saved, reason = lfgListing:Start(purpose, note, client:Timestamp() or 0, inGroup)
        end
        if not saved then
            return false, reason
        end
        -- The party as last seen keeps its members, with the roles as
        -- they're listed now (the game's may have changed since), for
        -- whoever leaves next.
        local listed = {}
        local members = lfgMembers()
        local index
        for index = 1, #members do
            listed[members[index].key] = members[index].role
        end
        for index = 1, #(lfgJoin.before or {}) do
            local member = lfgJoin.before[index]
            if listed[member.key] ~= nil then
                member.role = listed[member.key]
            end
        end
        lfgTrigger:Answered()
        announceListing()
        if not lfgHeartbeat then
            lfgHeartbeat = client:After(addon.LfgProtocol.HEARTBEAT_SECONDS, lfgTick)
        end
        lfgRefresh()
        return true
    end
    -- A board listing's purpose, as the listing keeps it, for taking over
    -- the party's listing from the leader before.
    local function purposeOf(listing)
        if listing.kind == "dungeon" then
            return { kind = "dungeon", dungeon = {
                name = listing.purpose, minLevel = listing.minLevel, maxLevel = listing.maxLevel,
            } }
        elseif listing.kind == "questing" then
            return { kind = "questing", zone = listing.purpose, minLevel = listing.minLevel,
                maxLevel = listing.maxLevel }
        elseif listing.kind == "other" then
            return { kind = "other", text = listing.purpose }
        end
        return { kind = "raid" }
    end
    -- The dungeon the player is in, from the dungeon list, or nil.
    local function lfgCurrentDungeon()
        local name = client:GetDungeonInstanceName()
        local dungeon = name and addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList()):Named(name)
        if dungeon == nil then
            return nil
        end
        return { id = dungeon.id, name = dungeon.name, minLevel = dungeon.minLevel, maxLevel = dungeon.maxLevel }
    end
    -- A best guess at the party's purpose: its dungeon, else questing here.
    local function lfgGuess()
        local zone = client:GetZone()
        return addon.LfgListing.Guess(lfgCurrentDungeon(), zone and zone.name, lfgZoneLevels())
    end
    -- Entering a dungeon makes a guessed purpose that dungeon.
    lfgOnZone = function()
        if lfgListing:IsActive() and lfgListing:EnteredDungeon(lfgCurrentDungeon()) then
            announceListing()
        end
        lfgJoin.checkZone()
        lfgRefresh()
    end
    -- The leader of a questing listing moved to another zone, outside an
    -- instance: the drawer asks whether to move the listing there. A zone
    -- they said No to isn't asked about again; back in the listing's zone,
    -- nothing's asked. With the button hidden, nothing is.
    lfgJoin.checkZone = function()
        local purpose = lfgListing:IsActive() and lfgListing:Purpose() or nil
        local zone = client:GetZone()
        local name = zone and zone.name or nil
        if purpose == nil or purpose.kind ~= "questing" or not lfgLister() or client:IsInInstance()
            or name == nil or name == purpose.zone or lfgJoin.zoneDeclined[name]
            or settings:Get("lfgButton") ~= true
        then
            lfgJoin.zoneMove = false
            return
        end
        if lfgJoin.zoneMove ~= name then
            lfgJoin.zoneMove = name
            if lfgButton ~= nil and lfgButton:IsShowing() and not lfgButton:DrawerOpen() then
                lfgRefresh()
                lfgButton:OpenDrawer()
            end
        end
    end
    -- Yes moves the questing listing to the zone, with its levels, and the
    -- guild hears it; No leaves it where it is.
    lfgJoin.moveZone = function(yes)
        local zone = lfgJoin.zoneMove
        lfgJoin.zoneMove = false
        if zone and yes then
            local saved, reason = saveListing({ kind = "questing", zone = zone }, lfgListing:Note())
            if not saved then
                rosterController:Print("Couldn't move your listing: " .. tostring(reason) .. ".")
            end
        elseif zone then
            lfgJoin.zoneDeclined[zone] = true
        end
        lfgRefresh()
    end
    -- The party changed: LfgTrigger says what that means for the listing
    -- (ask, take over, hand off, end, become a raid's), and a live listing
    -- is announced with the party as it is now.
    lfgOnParty = function()
        local now = client:Timestamp() or 0
        local inGroup = client:IsInGroup()
        local leaderKey
        local size, guildmates, outsiders = 0, 0, 0
        local guildLed = true
        local selfKey = rosterController:SelfKey()
        local present = {}
        if inGroup then
            local members = lfgMembers()
            if members[1] ~= nil and members[1].isLeader then
                leaderKey = lfgKeyOf(members[1])
                guildLed = members[1].isPlayer == true
                    or (members[1].inGuild == true and members[1].online ~= false)
            end
            size = #members
            local index
            for index = 1, #members do
                local member = members[index]
                if not member.isPlayer and member.inGuild then
                    guildmates = guildmates + 1
                elseif not member.isPlayer then
                    outsiders = outsiders + 1
                end
                if member.isPlayer then
                    table.insert(present, selfKey)
                elseif member.inGuild and member.online ~= false then
                    table.insert(present, lfgKeyOf(member))
                end
            end
            table.sort(present, function(a, b)
                return tostring(a) < tostring(b)
            end)
        end
        local actions = lfgTrigger:Observe({
            inGroup = inGroup,
            isLeader = inGroup and client:IsGroupLeader(),
            isRaid = inGroup and client:IsInRaid(),
            leaderKey = leaderKey,
            listed = lfgListing:IsActive(),
            listingOf = function(key)
                return lfgListingOf(key, now)
            end,
            size = size,
            guildmates = guildmates,
            outsiders = outsiders,
            guildLed = guildLed,
            selfKey = selfKey,
            present = present,
            hidden = settings:Get("lfgButton") ~= true,
        }, now)
        local index
        for index = 1, #actions do
            local action = actions[index]
            if action.action == addon.LfgTrigger.ASK or action.action == addon.LfgTrigger.GATE then
                if lfgButton ~= nil and lfgButton:IsShowing() then
                    lfgRefresh()
                    lfgButton:OpenDrawer()
                end
            elseif action.action == addon.LfgTrigger.LIST_QUIETLY then
                local purpose = lfgGuess()
                if purpose ~= nil then
                    lfgListing:Start(purpose, nil, now, true, true)
                end
            elseif action.action == addon.LfgTrigger.REMIND then
                if lfgListing:IsActive() then
                    local fields = lfgListing:Announcement(lfgMembers())
                    rosterController:Print("Your party is listed on the Guild LFG Board as " ..
                        addon.LfgListing.Label(fields.k, fields.p) .. ". Type " .. addon.Identity.slashCommand ..
                        " lfg to take part.")
                end
            elseif action.action == addon.LfgTrigger.TAKE_OVER then
                lfgListing:Start(purposeOf(action.listing), action.listing.note, now, true)
            elseif action.action == addon.LfgTrigger.RAID then
                lfgListing:Update({ kind = "raid" }, lfgListing:Note())
            elseif action.action == addon.LfgTrigger.CLAIM then
                lfgClaim()
            elseif action.action == addon.LfgTrigger.END then
                endListing(not inGroup)
            elseif action.action == addon.LfgTrigger.SLOT_OPEN or action.action == addon.LfgTrigger.SLOT_REMIND then
                -- The listing stays as the party was until the slot's
                -- posted: by Yes, or with no answer after SLOT_SECONDS.
                lfgJoin.slot = { role = lfgJoin.leftRole(lfgJoin.before, lfgMembers()) }
                lfgListing:Hold(lfgJoin.before)
                if action.action == addon.LfgTrigger.SLOT_REMIND then
                    rosterController:Print("Someone left your party. Type " .. addon.Identity.slashCommand ..
                        " lfg to fill the empty slot on the Guild LFG Board.")
                else
                    lfgJoin.slotTimer()
                end
            elseif action.action == addon.LfgTrigger.HAND_OFF then
                -- The new leader takes it over from the board, so it ends a
                -- little later: after the latest hand-off only.
                lfgJoin.handOffs = (lfgJoin.handOffs or 0) + 1
                local handOff = lfgJoin.handOffs
                client:After(LFG_HAND_OFF_SECONDS, function()
                    if handOff == lfgJoin.handOffs and lfgListing:IsActive() and not lfgLister() then
                        endListing()
                    end
                end)
            end
        end
        if lfgListing:IsActive() and lfgLister() then
            -- Grown past five (a raid that filled up): only a raid listing
            -- can say so.
            local purpose = lfgListing:Purpose()
            if purpose.kind ~= "raid" and size > addon.LfgListing.PARTY_SIZE then
                lfgListing:Update({ kind = "raid" }, lfgListing:Note())
            end
            announceListing()
            if not lfgHeartbeat then
                lfgHeartbeat = client:After(addon.LfgProtocol.HEARTBEAT_SECONDS, lfgTick)
            end
        end
        lfgJoin.before = inGroup and lfgMembers() or {}
        lfgRefresh()
    end
    -- The role of whoever left (in `before`, not in `after`): the one the
    -- party's slotting gave them (the game's, the leader's, or their
    -- class's); else DPS, the best guess.
    lfgJoin.leftRole = function(before, after)
        local still = {}
        local index
        for index = 1, #after do
            still[after[index].key] = true
        end
        for index = 1, #before do
            local member = before[index]
            if not still[member.key] then
                return member.role or "dps"
            end
        end
        return "dps"
    end
    -- An open slot unanswered after SLOT_SECONDS is posted.
    lfgJoin.slotTimer = function()
        client:After(addon.LfgTrigger.SLOT_SECONDS + 1, function()
            if lfgTrigger:SlotDue(client:Timestamp() or 0) then
                lfgJoin.postSlot()
            end
            lfgRefresh()
        end)
    end
    -- The open slot goes on the board: the lister announces the party as it
    -- is now. Never with the button hidden.
    lfgJoin.postSlot = function()
        if lfgListing:IsActive() and lfgLister() and settings:Get("lfgButton") == true then
            lfgListing:Post(lfgJoin.slot and lfgJoin.slot.role or nil)
            announceListing()
        end
    end
    -- The player answered "fill the empty slot?": the party's other
    -- guildmates hear it (and stop being asked); Yes posts it.
    lfgJoin.fillSlot = function(yes)
        -- The stand-in's answer goes nowhere.
        if lfgJoin.standInSlot then
            lfgJoin.standInSlot = false
            rosterController:Print("Stand-in slot answered " .. (yes and "Yes" or "No") .. "; nothing was sent.")
        elseif lfgTrigger:SlotAnswered(yes) then
            comm:Broadcast(addon.LfgProtocol.Slot(yes), addon.Comm.PRIORITY_NORMAL)
            if yes then
                lfgJoin.postSlot()
            end
        end
        lfgRefresh()
    end
    -- The player claims contact for their party, led from outside the
    -- guild, and tells its guildmates (they stop being asked).
    lfgClaim = function()
        lfgTrigger:Claim(rosterController:SelfKey())
        local leader = lfgMembers()[1]
        if client:IsInGroup() and leader ~= nil and leader.isPlayer == false then
            comm:Broadcast(addon.LfgProtocol.Contact(leader.fullName or leader.name), addon.Comm.PRIORITY_NORMAL)
        end
        lfgRefresh()
    end
    -- A guildmate logged off: their listing comes off the board, kept so a
    -- guildmate in their party can take it over, and the party is looked
    -- at again.
    lfgOnOffline = function(name)
        local key = keyOfSender(name)
        if key ~= nil and lfgBoard:Get(key, client:Timestamp()) ~= nil then
            lfgBoard:OnEnd(key, true)
        end
        if client:IsInGroup() then
            lfgOnParty()
        else
            lfgRefresh()
        end
    end
    lfgJoin.announce = function()
        if lfgListing:IsActive() and lfgLister() then
            announceListing()
        end
    end
    -- Of a dungeon listing's open roles, those the current character plays.
    lfgJoin.askRoles = function(listing)
        local current = lfgCharacters()
        local playable = {}
        local index
        for index = 1, #(current.roles or {}) do
            playable[current.roles[index]] = true
        end
        local roles = {}
        for index = 1, #(listing.openRoles or {}) do
            if playable[listing.openRoles[index]] then
                table.insert(roles, listing.openRoles[index])
            end
        end
        return roles
    end
    -- Asks to join `listing` as the current character, whispered to its
    -- leader.
    lfgJoin.ask = function(listing, role)
        -- A stand-in's leader isn't real: the request stays pending here.
        if addon.LfgStandIns.IsStandIn(listing.id) then
            lfgBoard:Ask(listing.id, role, client:Timestamp() or 0)
            rosterController:Print("Asked the stand-in " .. listing.leader .. "; nothing was sent.")
            lfgRefresh()
            return
        end
        local message = addon.LfgProtocol.Ask(role, client:GetPlayerLevel(), client:GetPlayerClass())
        if comm:Whisper(message, listing.sender, true) then
            lfgBoard:Ask(listing.id, role, client:Timestamp() or 0)
        else
            rosterController:Print("Couldn't ask to join " .. listing.leader .. "'s group. Try whispering them.")
        end
        lfgRefresh()
    end
    -- The leader's answers: Invite sends the game's party invite (the
    -- add-on never invites by itself) and tells the asker; Decline tells
    -- them no.
    lfgJoin.answer = function(request, answer)
        if type(request) ~= "table" or lfgJoin.requests:Remove(request.key) == nil then
            return
        end
        if request.standIn then
            rosterController:Print("Stand-in request " .. answer .. "; nothing was sent.")
        else
            comm:Whisper(addon.LfgProtocol.Answer(answer), request.sender, true)
        end
        lfgRefresh()
    end
    lfgJoin.invite = function(request)
        if type(request) == "table" and not request.standIn and lfgJoin.requests:Get(request.key) ~= nil
            and not client:InviteToParty(request.sender)
        then
            -- The request stays, to try again.
            rosterController:Print("Couldn't invite " .. tostring(request.name) .. ". Try inviting them yourself.")
            return
        end
        lfgJoin.answer(request, "invited")
    end
    lfgJoin.decline = function(request)
        lfgJoin.answer(request, "declined")
    end
    -- Tidies the requests and returns those left: ones unanswered for two
    -- minutes are expired, and once a role (or the whole party) fills, the
    -- ones it no longer has room for are declined with "role filled".
    lfgJoin.sweep = function()
        local requests = lfgJoin.requests
        if requests:List()[1] == nil then
            return {}
        end
        local function tell(dropped, answer)
            local index
            for index = 1, #dropped do
                if not dropped[index].standIn then
                    comm:Whisper(addon.LfgProtocol.Answer(answer), dropped[index].sender, true)
                end
            end
        end
        tell(requests:Expire(client:Timestamp()), "expired")
        local fields = lfgListing:Announcement(lfgMembers())
        if fields ~= nil then
            tell(requests:Filled(fields.k == "dungeon" and fields.r or nil, fields.s >= fields.x), "roleFilled")
        end
        return requests:List()
    end
    -- Dev build only: every look of the board without five people online.
    -- Stand-in listings go on this player's board alone, and a stand-in slot
    -- question and Ask to join request show on the button; nothing about
    -- them is ever sent.
    if addon.Identity.isDev then
        router:Register("lfgtest", "fill the Guild LFG Board with stand-in listings, and show a stand-in" ..
            " slot question and Ask to join request; nothing is sent", function()
            local now = client:Timestamp() or 0
            local current, alts = lfgCharacters()
            local listings, why = addon.LfgStandIns.Listings({ level = current.level, alt = alts[1], alts = alts,
                dungeons = addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList()) })
            local index
            for index = 1, #listings do
                lfgBoard:OnListing(listings[index].message, listings[index].key, listings[index].sender, now)
            end
            lfgJoin.standInSlot = true
            lfgJoin.requests:Add(addon.LfgStandIns.Request(), now)
            rosterController:Print(#listings .. " stand-in listings are on your Guild LFG Board for " ..
                math.floor(addon.LfgBoard.STALE_SECONDS / 60) .. " minutes, with a stand-in slot question and" ..
                " Ask to join request." .. (why and (" Left out: " .. why .. ".") or ""))
            lfgRefresh()
            if lfgButton ~= nil and lfgButton:IsShowing() and not lfgButton:DrawerOpen() then
                lfgButton:OpenDrawer()
            end
        end)
    end
    drawLfgBoard = function(content, ui)
        lfgPage = addon.LfgBoardPage.Create(content, ui, {
            listing = lfgListing,
            members = lfgMembers,
            level = function()
                return client:GetPlayerLevel()
            end,
            zone = function()
                local zone = client:GetZone()
                return zone and zone.name or nil
            end,
            catalog = function()
                return addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList())
            end,
            groups = function()
                local current, alts = lfgCharacters()
                return lfgBoard:Groups(client:Timestamp(), current, alts)
            end,
            nearby = lfgNearby,
            classColor = function(classToken)
                return client:GetClassColor(classToken)
            end,
            friendTier = function(name)
                local key = keyOfSender(name)
                return key and lfgFriendTier(key) or nil
            end,
            -- History: the player's own parties, as GroupHistory keeps them.
            history = function()
                local guild, partition = rosterController:QuietContext()
                return guild and partition:GetGroupHistory() or {}
            end,
            historyMember = function(key)
                local guild, partition = rosterController:QuietContext()
                local character = guild and partition:GetCharacter(key)
                if not character then
                    return nil
                end
                local name = character.name or key
                return { name = string.match(name, "^[^%-]+") or name, whisper = name, classToken = character.class }
            end,
            keyTier = function(key)
                return lfgFriendTier(key)
            end,
            formatDate = function(at)
                return client:FormatDate(at)
            end,
            dungeonIcon = function(name)
                local dungeon = addon.DungeonCatalog.For(clientProfile.id, client:GetDungeonList()):Named(name)
                return dungeon and dungeon.icon or nil
            end,
            onWhisper = function(name)
                client:OpenWhisper(name)
            end,
            requestOf = function(id)
                return lfgBoard:Request(id, client:Timestamp())
            end,
            askRoles = function(listing)
                return lfgJoin.askRoles(listing)
            end,
            onAsk = function(listing, role)
                lfgJoin.ask(listing, role)
            end,
            party = function()
                if not client:IsInGroup() then
                    return { inParty = false, isLeader = true }
                end
                -- The contact for a party led from outside the guild edits
                -- its listing as a leader would.
                local isLeader = lfgLister()
                local listing
                if not isLeader then
                    listing = lfgJoin.partyListing()
                end
                return { inParty = true, isLeader = isLeader, listing = listing }
            end,
            partyRoles = function()
                local members = lfgMembers()
                local rows = {}
                local index
                for index = 1, #members do
                    local member = members[index]
                    rows[index] = {
                        key = member.key,
                        name = member.name,
                        classToken = member.classToken,
                        role = member.role,
                    }
                end
                return rows
            end,
            onSave = saveListing,
            onAskInGuild = function(line)
                client:OpenGuildChat(line)
            end,
            onNotLooking = function()
                lfgTrigger:NotLooking()
                endListing()
            end,
        })
        -- Drawn on the window's first open; specs reach it here.
        addon.lfgPage = lfgPage
    end
    -- Guildmates' listings and their ends; the player's own echo is
    -- ignored.
    onLfgMessage = function(message, sender)
        local senderKey = keyOfSender(sender)
        if not addon.LfgProtocol.IsValid(message) or senderKey == nil
            or senderKey == rosterController:SelfKey()
        then
            return
        end
        if message.t == addon.LfgProtocol.TYPE_LISTING then
            lfgBoard:OnListing(message, senderKey, sender, client:Timestamp() or 0)
        elseif message.t == addon.LfgProtocol.TYPE_CONTACT or message.t == addon.LfgProtocol.TYPE_SLOT then
            -- Only a claim or an answer from a guildmate in the player's
            -- party counts.
            local inParty = false
            local members = client:IsInGroup() and lfgMembers() or {}
            local index
            for index = 1, #members do
                if not members[index].isPlayer and lfgKeyOf(members[index]) == senderKey then
                    inParty = true
                end
            end
            if not inParty then
                return
            end
            if message.t == addon.LfgProtocol.TYPE_SLOT then
                if lfgTrigger:SlotAnswered(message.y) and message.y then
                    lfgJoin.postSlot()
                end
            elseif lfgTrigger:Claimed(senderKey, rosterController:SelfKey()) then
                endListing()
            end
        elseif message.t == addon.LfgProtocol.TYPE_ASK then
            -- Only a listing that takes asks hears them: led by the player,
            -- with the LFG button shown, and asked by a guildmate. A new one
            -- opens the drawer.
            local _, partition = rosterController:QuietContext()
            if not lfgListing:IsActive() or not (not client:IsInGroup() or client:IsGroupLeader())
                or partition == nil or not partition:IsInGuild(senderKey)
                or settings:Get("lfgButton") ~= true
            then
                return
            end
            -- Do Not Disturb declines them without a word to the player.
            if settings:Get("dnd") == true then
                comm:Whisper(addon.LfgProtocol.Answer("declined"), sender, true)
                return
            end
            local added = lfgJoin.requests:Add({ key = senderKey, sender = sender,
                name = string.match(sender, "^[^%-]+") or sender, classToken = message.c, level = message.l,
                role = message.r }, client:Timestamp() or 0)
            -- Looked at again when it would expire.
            client:After(addon.LfgRequests.EXPIRE_SECONDS, lfgRefresh)
            lfgRefresh()
            if added and lfgButton ~= nil and lfgButton:IsShowing() and not lfgButton:DrawerOpen() then
                lfgButton:OpenDrawer()
            end
            return
        elseif message.t == addon.LfgProtocol.TYPE_ANSWER then
            lfgBoard:OnAnswer(senderKey, message.a)
        else
            lfgBoard:OnEnd(senderKey, message.lf == true)
        end
        refreshLfg()
    end
    -- Group history: the guildmates in the party or raid now (this player's own
    -- characters left out), and the dungeon when known: the party's Guild LFG
    -- Board listing's, else the instance the player is in.
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
            -- The whole raid, every subgroup, not just the player's own.
            local members = client:GetGroupMembers()
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
        local purpose = lfgListing:IsActive() and lfgListing:Purpose() or nil
        local listing = client:IsInGroup() and lfgJoin.partyListing() or nil
        local name = purpose and purpose.kind == "dungeon" and purpose.dungeon.name
            or listing and listing.kind == "dungeon" and listing.purpose or nil
        if name == nil and client:IsInInstance() then
            local zone = client:GetZone()
            name = zone and zone.name or nil
        end
        groupHistory:OnParty(keys, now, name)
        rosterController:Invalidate()
    end
    router:Register("dnd", "turn Do Not Disturb on or off", function()
        local enabled, reason = settings:Toggle("dnd")
        if enabled == nil then
            rosterController:Print("Do Not Disturb can't be changed: " .. tostring(reason) .. ".")
        elseif enabled then
            rosterController:Print("Do Not Disturb on: you won't get Ask to join requests, on any character.")
        else
            rosterController:Print("Do Not Disturb off.")
        end
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
                    -- A member picks only characters the add-on knows are theirs.
                    known = not rosterController:IsOfficerUser() and function(key)
                        return rosterController:IsKnownOwn(key)
                    end or nil,
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
    -- The officers' guild log (see GuildLog): only an officer's add-on
    -- records or stores it. It's read from the game's guild event log
    -- (asked for again at most every LOG_REQUEST_SECONDS, as the roster
    -- updates) and from joins and leaves seen live. A client without the
    -- event log keeps only the live events.
    -- The character's own rank is read live, so a promotion or demotion
    -- counts at once, not after the next full scan.
    local function selfIsOfficer()
        local rank = client:GetPlayerGuildRankIndex()
        if rank == nil then
            return officerAuthority:IsOfficer(rosterController:SelfKey())
        end
        return officerAuthority:IsOfficerRank(rank)
    end
    -- Membership dates: every add-on works them out from its own roster
    -- scans; an officer's add-on also from the guild log, and shares those
    -- (and dates set by hand) with the guild as officer facts.
    local function datesOf(partition)
        return addon.MembershipDates.Create(partition:GetMembershipDates(), {
            isOfficer = function(key)
                return officerAuthority:IsOfficer(key)
            end,
        })
    end
    local function shareDates(facts)
        if facts ~= nil and facts[1] ~= nil then
            syncSession:ShareOfficerFacts(facts)
        end
    end
    -- Dates from guild log entries this officer's add-on just recorded.
    local function datesFromLog(entries)
        local guild, partition = rosterController:QuietContext()
        local now = client:Timestamp()
        if guild == nil or now == nil or not selfIsOfficer() then
            return
        end
        shareDates(datesOf(partition):FromLog(entries, rosterController:SelfKey(), now))
    end
    observeMembership = function()
        local guild, partition = rosterController:QuietContext()
        local now = client:Timestamp()
        if guild == nil or now == nil then
            return
        end
        local present = {}
        partition:EachCharacter(function(key, character)
            if partition:IsInGuild(key) then
                present[key] = character.rank or false
            end
        end)
        local dates = datesOf(partition)
        if dates:ObserveScan(present, now) and selfIsOfficer() then
            shareDates({ dates:StampTracking(rosterController:SelfKey(), now) })
        end
    end
    -- Every add-on message heard proves its sender has the add-on. Writes
    -- are throttled per character, so busy sync costs a table lookup. An
    -- officer's add-on notes who it heard and, every few minutes, makes
    -- and shares their last-heard facts together, not one message per
    -- character; until then its digest is unchanged.
    local HEARD_THROTTLE_SECONDS = 60
    local HEARD_FLUSH_SECONDS = 300
    local lastHeard = {}
    -- Every character heard since loading, kept even before a scan has
    -- stored them (Guild Greet counts add-on users online by it).
    local heardThisSession = {}
    local heardKeys, heardFlushing = {}, false
    local function flushHeard()
        heardFlushing = false
        local keys = heardKeys
        heardKeys = {}
        local guild, partition = rosterController:QuietContext()
        local author, now = rosterController:SelfKey(), client:Timestamp()
        if guild == nil or author == nil or now == nil or not selfIsOfficer() then
            return
        end
        local dates = datesOf(partition)
        local sorted = {}
        local key
        for key in pairs(keys) do
            table.insert(sorted, key)
        end
        table.sort(sorted)
        local facts = {}
        local index
        for index = 1, #sorted do
            local fact = dates:ShareHeard(sorted[index], author, now)
            if fact ~= nil then
                table.insert(facts, fact)
            end
        end
        shareDates(facts)
    end
    heardFrom = function(sender)
        local now = client:Timestamp()
        local guild, partition, normalizer = rosterController:QuietContext()
        local key = guild and normalizer:Key(sender)
        if key ~= nil then
            heardThisSession[key] = true
        end
        if key == nil or now == nil or (lastHeard[key] ~= nil and now - lastHeard[key] < HEARD_THROTTLE_SECONDS)
            or partition:GetCharacter(key) == nil
        then
            return
        end
        lastHeard[key] = now
        datesOf(partition):Heard(key, now)
        if selfIsOfficer() then
            heardKeys[key] = true
            if not heardFlushing then
                heardFlushing = true
                if not client:After(HEARD_FLUSH_SECONDS, flushHeard) then
                    flushHeard()
                end
            end
        end
    end
    -- The player panel's dates, for officers only: the player's earliest
    -- current join (its header), and each character's join and time at its
    -- rank (its Log).
    local function inGuildKeys(partition, keys)
        local current = {}
        local index
        for index = 1, #keys do
            if partition:IsInGuild(keys[index]) then
                table.insert(current, keys[index])
            end
        end
        return current
    end
    local function formatDate(timestamp)
        return client:FormatDate(timestamp)
    end
    earliestJoin = function(keys)
        local guild, partition = rosterController:QuietContext()
        if guild == nil or not selfIsOfficer() then
            return nil
        end
        return addon.MembershipDates.Describe(datesOf(partition):EarliestJoin(inGuildKeys(partition, keys)),
            formatDate)
    end
    membershipLines = function(keys)
        local guild, partition, normalizer = rosterController:QuietContext()
        if guild == nil or not selfIsOfficer() then
            return nil
        end
        local dates = datesOf(partition)
        local current = inGuildKeys(partition, keys)
        local lines = {}
        local index
        for index = 1, #current do
            local character = partition:GetCharacter(current[index])
            table.insert(lines, (normalizer:Display(character.name) or current[index]) .. ": joined " ..
                addon.MembershipDates.Describe(dates:Joined(current[index]), formatDate) .. ", at this rank since " ..
                addon.MembershipDates.Describe(dates:RankSince(current[index], character.rank), formatDate))
        end
        return lines
    end
    router:Register("setdate",
        "set a character's join or rank date (officers): setdate join|rank <character> <YYYY-MM-DD>",
        function(arguments)
            local which, name, text = string.match(arguments or "", "^%s*(%S+)%s+(.-)%s+(%S+)%s*$")
            local kind = which and ({ join = addon.MembershipDates.KIND_JOINED,
                rank = addon.MembershipDates.KIND_RANK_SINCE })[string.lower(which)]
            local time = addon.MembershipDates.ParseDate(text)
            if kind == nil or name == nil or name == "" or time == nil then
                rosterController:Print("Use " .. addon.Identity.slashCommand ..
                    " setdate join|rank <character> <YYYY-MM-DD>.")
                return
            end
            local guild, partition, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(name)
            local character = key and partition:GetCharacter(key)
            if character == nil then
                rosterController:Print("No character named " .. name .. " in the roster.")
                return
            end
            local author = rosterController:SelfKey()
            if not selfIsOfficer() or author == nil then
                rosterController:Print("Only officers can set dates.")
                return
            end
            local fact, reason = datesOf(partition):SetByOfficer(key, kind, time, character.rank, author,
                client:Timestamp())
            if fact == nil then
                rosterController:Print("Date not set: " .. tostring(reason) .. ".")
                return
            end
            shareDates({ fact })
            rosterController:Print("Set " .. (normalizer:Display(character.name) or key) ..
                (kind == addon.MembershipDates.KIND_JOINED and "'s join date" or "'s rank date") ..
                " to " .. client:FormatDate(time) .. ".")
            rosterController:Invalidate()
        end)
    local guildLogs = {}
    guildLogOf = function()
        local guild, partition, normalizer = rosterController:QuietContext()
        if guild == nil or not selfIsOfficer() then
            return nil
        end
        local log = guildLogs[partition.key]
        if log == nil then
            log = addon.GuildLog.Create(partition:GetGuildLog())
            guildLogs[partition.key] = log
        end
        return log, normalizer
    end
    -- Promotion requirements: officers edit them on the Promotions page;
    -- every add-on keeps them, shares edits with the guild, and asks for
    -- them once a session.
    local function requirementsOf()
        local guild, partition = rosterController:QuietContext()
        if guild == nil then
            return nil
        end
        return addon.RankRequirements.Create(partition:GetRankRequirements(), {
            isOfficer = function(key)
                return officerAuthority:IsOfficer(key)
            end,
        })
    end
    local requirementsSync = addon.RankRequirements.CreateSync({
        store = requirementsOf,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        senderKey = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and normalizer:Key(sender) or nil
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        announce = function(message)
            return comm:Broadcast(message)
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        onChange = function()
            promotions.changed()
        end,
    })
    promotions.sync = requirementsSync
    -- Officers' ticks: shared the same way.
    local function checksOf()
        local guild, partition = rosterController:QuietContext()
        if guild == nil then
            return nil
        end
        local dates = datesOf(partition)
        return addon.PromotionChecks.Create(partition:GetPromotionChecks(), {
            isOfficer = function(key)
                return officerAuthority:IsOfficer(key)
            end,
            rankOf = function(key)
                local character = partition:GetCharacter(key)
                if character == nil or not partition:IsInGuild(key) then
                    return nil
                end
                return character.rank
            end,
            -- When the character's current stint at its rank began, from
            -- the guild log (or an officer's date), less the log's doubt and
            -- SAME_JOIN_SECONDS: ticks made before it are from an earlier
            -- stint (promoted, then demoted back). A roster scan's date
            -- only says the change happened by then, so it decides nothing.
            stintStart = function(key)
                local character = partition:GetCharacter(key)
                local since = character and dates:RankSince(key, character.rank)
                if since == nil or (since.source ~= addon.MembershipDates.LOG
                    and since.source ~= addon.MembershipDates.OFFICER)
                then
                    return nil
                end
                return since.time - math.max(since.tolerance or 0, addon.MembershipDates.SAME_JOIN_SECONDS)
            end,
        })
    end
    local ticksSync = addon.RankRequirements.CreateSync({
        store = checksOf,
        stateType = addon.PromotionChecks.TYPE_STATE,
        askType = addon.PromotionChecks.TYPE_ASK,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        senderKey = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and normalizer:Key(sender) or nil
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        announce = function(message)
            return comm:Broadcast(message)
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        onChange = function()
            promotions.changed()
        end,
    })
    promotions.ticks = ticksSync
    promotions.askOnce = function()
        requirementsSync:AskOnce()
        ticksSync:AskOnce()
    end
    promotions.prune = function()
        local checks = checksOf()
        if checks ~= nil then
            checks:Prune()
        end
    end
    -- Requirements or ticks changed: redraw the page, the player panel and
    -- the roster's Ready markers, here and on the game's guild roster.
    promotions.changed = function()
        rosterController:RefreshPromotions()
        if guildNoteOverlay ~= nil then
            guildNoteOverlay:Refresh()
        end
    end
    -- The Promotions page (the requirements editor) opened: redraw it.
    promotions.shown = function()
        rosterController:RefreshPromotions()
    end
    -- What the rules engine reads, or nil before the guild is known.
    local function promotionInputs()
        local guild, partition = rosterController:QuietContext()
        local requirements, checks = requirementsOf(), checksOf()
        if guild == nil or requirements == nil or checks == nil then
            return nil
        end
        return {
            partition = partition,
            requirements = requirements,
            checks = checks,
            dates = datesOf(partition),
            now = client:Timestamp(),
            rankNames = client:GetGuildRankNames() or {},
        }
    end
    -- The characters ready for promotion, as a set, for the roster's marker:
    -- officers only.
    promotions.readyKeys = function()
        local inputs = promotionInputs()
        if inputs == nil or not selfIsOfficer() then
            return nil
        end
        return addon.PromotionPolicy.ReadySet(inputs)
    end
    -- The characters whose time is up but who aren't ready, as a set, for
    -- the roster's timer marker: officers only.
    promotions.timeMetKeys = function()
        local inputs = promotionInputs()
        if inputs == nil or not selfIsOfficer() then
            return nil
        end
        return addon.PromotionPolicy.TimeMetSet(inputs)
    end
    -- The characters to promote to match their player, as key -> target
    -- rank, for the roster's marker: officers only.
    promotions.matchKeys = function()
        local inputs = promotionInputs()
        if inputs == nil or not selfIsOfficer() then
            return nil
        end
        return addon.PromotionPolicy.MatchSet(inputs)
    end
    -- Why the character named `name` (in the game's guild roster) should be
    -- promoted to match its player: { rankName, highestName,
    -- highestRankName }, the rank to promote it to and the player's
    -- highest character and its rank; nil when it needn't be, or for a
    -- member.
    promotions.matchFor = function(name)
        local inputs = promotionInputs()
        if inputs == nil or not selfIsOfficer() then
            return nil
        end
        local _, _, normalizer = rosterController:QuietContext()
        local key = normalizer and normalizer:Key(name)
        local character = key and inputs.partition:GetCharacter(key)
        local target = character and addon.PromotionPolicy.MatchTarget(inputs, key)
        if target == nil then
            return nil
        end
        local highestKey, highest = addon.PromotionPolicy.HighestCharacter(inputs.partition, character.player)
        local highestCharacter = highestKey and inputs.partition:GetCharacter(highestKey)
        if highestCharacter == nil then
            return nil
        end
        local function rankName(rank)
            return inputs.rankNames[rank + 1] or ("Rank " .. rank)
        end
        return {
            rankName = rankName(target),
            highestName = normalizer:Display(highestCharacter.name) or highestKey,
            highestRankName = rankName(highest),
        }
    end
    -- The game's name for rank index `rank`.
    promotions.rankName = function(rank)
        return (client:GetGuildRankNames() or {})[rank + 1] or ("Rank " .. rank)
    end
    -- The characters whose checklists were opened (true) or closed (false)
    -- on the player panel's Promotion tab, for the session; the top one
    -- opens until it's closed.
    local panelExpanded = {}
    promotions.togglePanel = function(key, expanded)
        panelExpanded[key] = not expanded
        rosterController:RedrawPanel()
        return true
    end
    -- The player panel's Promotion tab (see PromotionsViewModel.PanelRows):
    -- an officer's for anyone, a member's for their own player only, and
    -- nil for everyone else. `expanded` is the set of open checklists
    -- (the panel's own, by default).
    promotions.panelRows = function(keys, playerId, expanded)
        local inputs = promotionInputs()
        if inputs == nil then
            return nil
        end
        local partition = inputs.partition
        local _, _, normalizer = rosterController:QuietContext()
        local officer = selfIsOfficer()
        local selfKey = rosterController:SelfKey()
        local own = selfKey ~= nil and partition:GetCharacter(selfKey) ~= nil
            and partition:GetCharacter(selfKey).player == playerId
        if not officer and not own then
            return nil
        end
        local function nameOf(key)
            local character = partition:GetCharacter(key)
            return (character and normalizer:Display(character.name)) or key
        end
        local dates = inputs.dates
        local characters = {}
        local index
        for index = 1, #keys do
            local key = keys[index]
            local character = partition:GetCharacter(key)
            if character ~= nil and partition:IsInGuild(key) and type(character.rank) == "number" then
                local match = officer and addon.PromotionPolicy.MatchTarget(inputs, key) or nil
                local snoozed = officer and inputs.checks:IsSnoozed(key, inputs.now)
                local profile = addon.PromotionPolicy.ProfileOf(partition, key)
                table.insert(characters, {
                    follows = profile ~= key and nameOf(profile) or nil,
                    key = key,
                    name = nameOf(key),
                    rankName = inputs.rankNames[character.rank + 1] or ("Rank " .. character.rank),
                    evaluated = addon.PromotionPolicy.Evaluate(inputs, key),
                    lastPromotion = dates and dates:LastPromotion(key) or nil,
                    matchRankName = match and (inputs.rankNames[match + 1] or ("Rank " .. match)) or nil,
                    snooze = snoozed and inputs.checks:SnoozeOf(key) or nil,
                })
            end
        end
        local highest = addon.PromotionPolicy.HighestRank(partition, playerId)
        return addon.PromotionsViewModel.PanelRows(characters, {
            officer = officer,
            expanded = expanded or panelExpanded,
            openFirst = true,
            highestRankName = highest and (inputs.rankNames[highest + 1] or ("Rank " .. highest)) or nil,
            nameOf = nameOf,
            formatDate = function(timestamp)
                return client:FormatDate(timestamp)
            end,
        })
    end
    promotions.tick = function(key, itemId, ticked, note)
        local requirements, checks = requirementsOf(), checksOf()
        local author = rosterController:SelfKey()
        local now = client:Timestamp()
        if requirements == nil or checks == nil or author == nil or now == nil then
            return false, "saved data is unavailable"
        end
        if not selfIsOfficer() then
            return false, "only officers can tick promotion requirements"
        end
        local item = requirements:Item(itemId)
        if item == nil then
            return false, "that requirement no longer exists"
        end
        local records, reason = checks:Set(key, item, ticked, note, author, now)
        if records == nil then
            return false, reason
        end
        ticksSync:Share(records)
        promotions.changed()
        return true
    end
    -- Not ready: snoozes `key`'s timer marker for its rank's snooze length,
    -- from now. Returns true, or false and why.
    promotions.snooze = function(key)
        local inputs = promotionInputs()
        local author = rosterController:SelfKey()
        if inputs == nil or author == nil or inputs.now == nil then
            return false, "saved data is unavailable"
        end
        if not selfIsOfficer() then
            return false, "only officers can snooze a promotion check"
        end
        local character = inputs.partition:GetCharacter(key)
        if character == nil or type(character.rank) ~= "number" then
            return false, "that character isn't in the guild"
        end
        local days = inputs.requirements:SnoozeDays(character.rank)
        local records, reason = inputs.checks:Snooze(key, character.rank,
            inputs.now + days * addon.PromotionPolicy.DAY, author, inputs.now)
        if records == nil then
            return false, reason
        end
        ticksSync:Share(records)
        promotions.changed()
        return true
    end
    local selectedRank
    local function rankNames()
        return client:GetGuildRankNames() or {}
    end
    promotions.view = function()
        local requirements = requirementsOf()
        if requirements == nil then
            return nil
        end
        local model = addon.PromotionsViewModel.Editor({
            requirements = requirements,
            rank = selectedRank,
            rankNames = rankNames(),
        })
        selectedRank = model.rank
        return model
    end
    -- Makes an edit with `change(requirements, author, now)` -> records, or
    -- nil and why, shares it, and redraws. Returns true, or false and why.
    local function editRequirements(change)
        local requirements = requirementsOf()
        local author = rosterController:SelfKey()
        local now = client:Timestamp()
        if requirements == nil or author == nil or now == nil then
            return false, "saved data is unavailable"
        end
        if not selfIsOfficer() then
            return false, "only officers can change promotion requirements"
        end
        local records, reason = change(requirements, author, now)
        if records == nil then
            return false, reason
        end
        requirementsSync:Share(records)
        promotions.changed()
        return true
    end
    promotions.rank = function(step)
        local requirements = requirementsOf()
        if requirements == nil then
            return false, "saved data is unavailable"
        end
        local names = rankNames()
        selectedRank = addon.PromotionsViewModel.StepRank(
            addon.PromotionsViewModel.PickRank(selectedRank, requirements, names), step, names)
        promotions.changed()
        return true
    end
    -- Adds a custom requirement: a checkbox, needing a note when
    -- `needsNote`. (Automated checks are turned on with promotions.automated.)
    promotions.add = function(label, needsNote)
        return editRequirements(function(requirements, author, now)
            local names = rankNames()
            local rank = addon.PromotionsViewModel.PickRank(selectedRank, requirements, names)
            if rank == nil then
                return nil, "the guild's ranks aren't known yet"
            end
            local kind = needsNote and addon.RankRequirements.KIND_CHECK_NOTE or addon.RankRequirements.KIND_CHECK
            return requirements:Add(rank, label, kind, names[rank + 1], author, now)
        end)
    end
    -- Renames checkbox item `id`, and sets whether it needs a note when
    -- `needsNote` is given (true or false).
    promotions.rename = function(id, label, needsNote)
        return editRequirements(function(requirements, author, now)
            local item = requirements:Item(id)
            if item == nil then
                return nil, "that item no longer exists"
            end
            local records = {}
            if label ~= nil and string.gsub(label, "^%s*(.-)%s*$", "%1") ~= item.label then
                local renamed, reason = requirements:Rename(id, label, author, now)
                if renamed == nil then
                    return nil, reason
                end
                records = renamed
            end
            if needsNote ~= nil then
                local changed, reason = requirements:SetNeedsNote(id, needsNote == true, author, now)
                if changed == nil then
                    return nil, reason
                end
                local index
                for index = 1, #changed do
                    table.insert(records, changed[index])
                end
            end
            return records
        end)
    end
    -- Turns automated check `kind` on (with its number `n`, as typed) or
    -- off for the rank shown.
    promotions.automated = function(kind, enabled, n)
        return editRequirements(function(requirements, author, now)
            local names = rankNames()
            local rank = addon.PromotionsViewModel.PickRank(selectedRank, requirements, names)
            if rank == nil then
                return nil, "the guild's ranks aren't known yet"
            end
            return requirements:SetAutomated(rank, kind, enabled == true, tonumber(n), names[rank + 1], author, now)
        end)
    end
    -- Sets whether alts are matched to the rank shown.
    promotions.matchAlts = function(on)
        return editRequirements(function(requirements, author, now)
            local rank = addon.PromotionsViewModel.PickRank(selectedRank, requirements, rankNames())
            if rank == nil then
                return nil, "the guild's ranks aren't known yet"
            end
            return requirements:SetMatchesAlts(rank, on == true, author, now)
        end)
    end
    -- Sets how many days Not ready snoozes for at the rank shown (`days`
    -- as typed).
    promotions.snoozeDays = function(days)
        return editRequirements(function(requirements, author, now)
            local rank = addon.PromotionsViewModel.PickRank(selectedRank, requirements, rankNames())
            if rank == nil then
                return nil, "the guild's ranks aren't known yet"
            end
            return requirements:SetSnoozeDays(rank, tonumber(days), author, now)
        end)
    end
    promotions.move = function(id, step)
        return editRequirements(function(requirements, author, now)
            return requirements:Move(id, step, author, now)
        end)
    end
    promotions.delete = function(id)
        return editRequirements(function(requirements, author, now)
            return requirements:Delete(id, author, now)
        end)
    end
    local LOG_REQUEST_SECONDS = 10 * 60
    local logRequestedAt
    requestGuildLog = function()
        local now = client:Timestamp()
        if guildLogOf() == nil or now == nil
            or (logRequestedAt ~= nil and now - logRequestedAt < LOG_REQUEST_SECONDS)
        then
            return
        end
        logRequestedAt = now
        client:RequestGuildEventLog()
    end
    readGuildLog = function()
        local log, normalizer = guildLogOf()
        local raw = log ~= nil and client:ReadGuildEventLog() or nil
        if raw == nil then
            return
        end
        local rankNames = client:GetGuildRankNames() or {}
        local events = addon.GuildLog.FromGameEntries(raw, client:Timestamp(), function(name)
            return normalizer:Key(name)
        end, function(rank)
            local index
            for index = 1, #rankNames do
                if rankNames[index] == rank then
                    return index - 1
                end
            end
            return nil
        end)
        local _, changed = log:RecordBatch(events)
        if changed[1] ~= nil then
            rosterController:RefreshGuildLog()
            guildLogSync:Share(changed)
            datesFromLog(changed)
        end
    end
    recordLiveMembership = function(kind, name)
        local log, normalizer = guildLogOf()
        local key = log ~= nil and normalizer:Key(name) or nil
        local now = client:Timestamp()
        if key == nil or now == nil then
            return
        end
        local eventType = kind == "join" and addon.GuildLog.JOIN or addon.GuildLog.LEAVE
        local _, changed = log:RecordLive(eventType, key, now, name)
        if changed[1] ~= nil then
            rosterController:RefreshGuildLog()
            guildLogSync:Share(changed)
            datesFromLog(changed)
        end
    end
    -- The other officers online: { key, name, rank }, as the live roster
    -- reports them.
    local function onlineOfficers()
        local guild, _, normalizer = rosterController:QuietContext()
        local officers = {}
        if guild == nil then
            return officers
        end
        local selfKey = rosterController:SelfKey()
        local key, member
        for key, member in pairs(rosterController:LiveMembers(normalizer)) do
            if member.online and key ~= selfKey and officerAuthority:IsOfficer(key) then
                table.insert(officers, { key = key, name = member.name, rank = member.rankIndex })
            end
        end
        -- In a steady order, whatever order the roster copy keeps.
        table.sort(officers, function(first, second)
            return first.key < second.key
        end)
        return officers
    end
    -- Guild log messages go to the add-on officer channel. Officers whose
    -- rank can't listen to officer chat are whispered too, and every
    -- officer online is when this character's rank can't speak in it (or
    -- it can't be sent): the add-on's officer rule (viewing officer notes)
    -- and officer chat are separate rank permissions. `live` sends them
    -- live, as the probe's answers are.
    local function sendToOfficers(message, live)
        local canSpeak = comm:RankHasFlag(client:GetPlayerGuildRankIndex(), addon.Comm.OFFICER_CHAT_SPEAK_FLAG)
        local sent = canSpeak ~= false and comm:SendOfficers(message, live)
        local officers = onlineOfficers()
        local index
        for index = 1, #officers do
            if not sent or comm:RankHasFlag(officers[index].rank, addon.Comm.OFFICER_CHAT_LISTEN_FLAG) == false then
                comm:Whisper(message, officers[index].name, live)
            end
        end
    end
    -- Pings the officer channel only, so the officers it misses show.
    local function probeOfficerChannel()
        if guildLogOf() == nil then
            rosterController:Print("Only officers can probe the officer channel.")
            return
        end
        local id, sent = guildLogSync:Ping()
        if not sent then
            rosterController:Print("The officer channel couldn't be sent from here; guild log entries are" ..
                " whispered to each officer online instead.")
            return
        end
        rosterController:Print("Pinged the officer channel; answers in a few seconds.")
        local function report()
            local _, normalizer = guildLogOf()
            local lines = addon.GuildLogSync.ProbeLines(guildLogSync:Answers(id), onlineOfficers(), function(name)
                return normalizer and normalizer:Key(name)
            end)
            local index
            for index = 1, #lines do
                rosterController:Print(lines[index])
            end
        end
        if not client:After(addon.GuildLogSync.PROBE_SECONDS, report) then
            report()
        end
    end
    -- Whether the Ready flags reach the game's guild roster: how many
    -- characters are ready, whether the roster's rows are followed, and how
    -- many show a flag now. Changes nothing.
    local function probeReady()
        if not selfIsOfficer() then
            rosterController:Print("Only officers can probe the Ready flags.")
            return
        end
        local ready = promotions.readyKeys() or {}
        local count = 0
        local key
        for key in pairs(ready) do
            count = count + 1
        end
        rosterController:Print("Ready flag probe:")
        client:Print("  Ready for promotion: " .. count)
        -- The alts to promote to match, by name, A to Z.
        local match = promotions.matchKeys() or {}
        local _, partition, normalizer = rosterController:QuietContext()
        local matched = {}
        local rank
        for key, rank in pairs(match) do
            local character = partition and partition:GetCharacter(key)
            local name = character and normalizer:Display(character.name) or key
            table.insert(matched, name .. " to " .. promotions.rankName(rank))
        end
        table.sort(matched)
        client:Print("  Promote to match: " .. #matched)
        local matchIndex
        for matchIndex = 1, #matched do
            client:Print("    " .. matched[matchIndex])
        end
        local lines = guildNoteOverlay ~= nil and guildNoteOverlay:ReadyProbeLines() or { "No guild roster overlay" }
        local index
        for index = 1, #lines do
            client:Print("  " .. lines[index])
        end
    end
    -- Whether the timer marker's art loads, and how many characters it
    -- marks. Changes nothing.
    local function probeTimer()
        if not selfIsOfficer() then
            rosterController:Print("Only officers can probe the timer marker.")
            return
        end
        local loads = client:TextureLoads(addon.RosterViewModel.TIMER_TEXTURE)
        local count = 0
        local key
        for key in pairs(promotions.timeMetKeys() or {}) do
            count = count + 1
        end
        rosterController:Print("Timer marker probe:")
        client:Print("  Texture: " .. addon.RosterViewModel.TIMER_TEXTURE)
        if loads == true then
            client:Print("  Loaded: yes")
        elseif loads == false then
            client:Print("  Loaded: no, so the roster shows " .. addon.RosterViewModel.TIMER_FALLBACK .. " instead")
        else
            client:Print("  Loaded: unknown (this client can't say)")
        end
        client:Print("  Time requirement met: " .. count)
    end
    router:Register("probe",
        "check what the game reports to the add-on (probe: when the roster was last scanned and how many" ..
        " notes changed; probe forgeries: the guild sync edits caught as forged in your name; probe log: the" ..
        " guild event log; probe officer: the officer channel; probe ready: the Ready flags on the game's" ..
        " guild roster; officers; probe timer: the roster's timer marker, officers; probe player <name or" ..
        " alias>: a player's alias, links and Discord, with who" ..
        " set each and when, and its logged changes; probe greet: your greet weight and how long it holds your" ..
        " prompts back; probe realm: the realm or region your guild's data is kept under; probe lfg: the Guild" ..
        " LFG Board's zone levels and listings; probe menu: which of the game's right-click menus have Open in" ..
        " Guild Fellowship)",
        function(arguments)
            local what = string.match(arguments or "", "^%s*(%S*)")
            what = string.lower(what or "")
            if what == "" or what == "scan" then
                rosterController:Print("Roster scan probe:")
                local lines = rosterController:ScanProbeLines()
                local index
                for index = 1, #lines do
                    client:Print("  " .. lines[index])
                end
                if what == "" then
                    client:Print("  Also: " .. addon.Identity.slashCommand .. " probe forgeries, probe log," ..
                        " probe officer, probe ready, probe timer, probe player <name>, probe greet, probe realm," ..
                        " probe lfg or probe menu.")
                end
                return
            end
            if what == "forgeries" then
                local _, partition = rosterController:QuietContext()
                if partition == nil then
                    rosterController:Print("Not in a guild.")
                    return
                end
                rosterController:Print("Forged edit probe:")
                local lines = addon.SyncLedger.ForgeryLines(partition, function(timestamp)
                    return client:FormatDateTime(timestamp)
                end, 10)
                local index
                for index = 1, #lines do
                    client:Print("  " .. lines[index])
                end
                return
            end
            if what == "player" then
                local _, partition, normalizer = rosterController:QuietContext()
                if partition == nil then
                    rosterController:Print("Not in a guild.")
                    return
                end
                local query = string.match(arguments or "", "^%s*%S+%s+(.-)%s*$")
                local ids = addon.PlayerAudit.FindPlayers(partition, query, function(name)
                    return normalizer:Key(name)
                end)
                if ids[1] == nil then
                    rosterController:Print("Use " .. addon.Identity.slashCommand ..
                        " probe player <character name or alias>; no player matches " ..
                        (query and query ~= "" and ('"' .. query .. '"') or "nothing") .. ".")
                    return
                end
                rosterController:Print("Player probe:")
                local function nameOf(key)
                    local character = type(key) == "string" and partition:GetCharacter(key) or nil
                    return normalizer:Display((character and character.name) or key) or tostring(key)
                end
                local index, lineIndex
                for index = 1, #ids do
                    local lines = addon.PlayerAudit.ProbeLines(partition, ids[index], {
                        name = nameOf,
                        formatTime = function(timestamp)
                            return client:FormatDateTime(timestamp)
                        end,
                    })
                    for lineIndex = 1, #lines do
                        client:Print("  " .. lines[lineIndex])
                    end
                end
                return
            end
            if what == "officer" then
                probeOfficerChannel()
                return
            end
            if what == "ready" then
                probeReady()
                return
            end
            if what == "timer" then
                probeTimer()
                return
            end
            if what == "realm" then
                rosterController:Print("Realm probe:")
                local guild = client:GetGuildIdentity()
                if client:RealmIsRegion() then
                    client:Print("  This client hides realm names, so the region stands in for the realm: " ..
                        tostring(client:GetRegionName() or "none reported") .. ".")
                end
                client:Print("  Guild: " .. (guild and (guild.name .. ", realm " .. guild.realm) or "unknown") .. ".")
                local current, partition = rosterController:QuietContext()
                client:Print("  Saved data: " .. (current and partition.key or tostring(partition)) .. ".")
                local moved, kept = persistence:HomeRealmMoves()
                if moved > 0 then
                    client:Print("  Moved to the region this session: " .. moved .. " guild(s).")
                end
                if kept[1] ~= nil then
                    client:Print("  Left under the old realm, because the region's key was taken: " ..
                        table.concat(kept, ", ") .. ".")
                end
                return
            end
            if what == "lfg" then
                probeLfg()
                return
            end
            if what == "menu" then
                rosterController:Print("Right-click menu probe:")
                local lines = friendsUi.menu:ProbeLines()
                local index
                for index = 1, #lines do
                    client:Print("  " .. lines[index])
                end
                return
            end
            if what == "greet" then
                rosterController:Print("Greet weight probe:")
                local lines = guildGreet:WeightProbeLines(client:Timestamp())
                local index
                for index = 1, #lines do
                    client:Print("  " .. lines[index])
                end
                return
            end
            if what ~= "log" then
                rosterController:Print("Use " .. addon.Identity.slashCommand .. " probe forgeries, " ..
                    addon.Identity.slashCommand .. " probe log, " ..
                    addon.Identity.slashCommand .. " probe officer, " .. addon.Identity.slashCommand ..
                    " probe ready, " .. addon.Identity.slashCommand .. " probe timer, " ..
                    addon.Identity.slashCommand .. " probe player <name>, " ..
                    addon.Identity.slashCommand .. " probe greet, " ..
                    addon.Identity.slashCommand .. " probe lfg or " ..
                    addon.Identity.slashCommand .. " probe menu.")
                return
            end
            if guildLogOf() == nil then
                rosterController:Print("Only officers can probe the guild event log.")
                return
            end
            client:RequestGuildEventLog()
            local function report()
                local present = client:GuildEventLogCalls()
                local calls = {}
                local index
                for index = 1, #addon.Compatibility.EVENT_LOG_CALLS do
                    local name = addon.Compatibility.EVENT_LOG_CALLS[index]
                    table.insert(calls, { name = name, present = present[name] })
                end
                rosterController:Print("Guild event log probe:")
                local lines = addon.GuildLog.ProbeLines(calls, client:ReadGuildEventLog(), 5)
                for index = 1, #lines do
                    client:Print("  " .. lines[index])
                end
            end
            -- The log the game sends back takes a moment to arrive.
            if not client:After(2, report) then
                report()
            end
        end)
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
            if guild == nil then
                return false
            end
            local selfKey = syncSession.selfKey()
            local key, member
            for key, member in pairs(rosterController:LiveMembers(normalizer)) do
                if member.online and key ~= selfKey and officerAuthority:IsOfficer(key) then
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
    guildLogSync = addon.GuildLogSync.Create({
        send = sendToOfficers,
        -- The probe and its answers go out live, so a sync backlog doesn't
        -- read as a missed officer.
        probe = function(message)
            return comm:SendOfficers(message, true)
        end,
        answer = function(message)
            sendToOfficers(message, true)
        end,
        log = function()
            return guildLogOf()
        end,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        -- Within guild sync's frame budget, and never while busy.
        worker = syncSession,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        onMerged = function(entries)
            rosterController:RefreshGuildLog()
            datesFromLog(entries)
        end,
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
    router:Register("perf", "show the add-on's memory and CPU use, and counts of its costly work since login",
        function()
            rosterController:Print("Performance:")
            local lines = addon.PerfCounters.Lines(client:AddOnUsage())
            local index
            for index = 1, #lines do
                client:Print("  " .. lines[index])
            end
        end)
    router:Register("sync", "show guild sync status", function()
        local lines = addon.RosterViewModel.SyncStatusLines(syncSession:Status(), client:Timestamp())
        local index
        for index = 1, #lines do
            rosterController:Print(lines[index])
        end
    end)
    -- Copying an officer's roster data over this client's, when it went
    -- wrong and newest-wins keeps it so.
    resync = addon.Resync.Create({
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
        isOwn = function(key)
            return guildGreet:IsOwn(key)
        end,
        online = function()
            local guild, _, normalizer = rosterController:QuietContext()
            local names = {}
            if guild == nil then
                return names
            end
            local key, member
            for key, member in pairs(rosterController:LiveMembers(normalizer)) do
                if member.online then
                    names[key] = member.name
                end
            end
            return names
        end,
        now = function()
            return client:Timestamp()
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        whisper = function(message, name, options)
            return comm:Whisper(message, name, false, options)
        end,
        print = function(text)
            rosterController:Print(text)
        end,
        onApplied = function()
            rosterController:Invalidate()
            if profilePage ~= nil then
                profilePage:Refresh()
            end
        end,
    })
    router:Register("resync", "copy an online officer's roster data over yours: /agf resync <name>",
        function(arguments)
            local _, text = resync:Ask(arguments)
            rosterController:Print(text)
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
        onRecipientFilter = function(text)
            guildMail:SetRecipientFilter(text)
        end,
        onCheckAll = function()
            guildMail:SetAllRecipients(true)
        end,
        onUncheckAll = function()
            guildMail:SetAllRecipients(false)
        end,
        onReuseEntry = function(position)
            guildMail:RequestReuseEntry(position)
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
        -- A sent mail's page (View in the mailbox's Guild Mail tab).
        onBack = function()
            guildMail:CloseEntry()
        end,
        onResumeEntry = function(position)
            if not guildMail:ResumeEntry(position) then
                guildMail:Refresh()
            end
        end,
        onCancelEntry = function(position)
            guildMail:RequestCancelEntry(position)
        end,
        onRemoveEntry = function(position)
            guildMail:RequestRemoveEntry(position)
        end,
        onSettle = function(index, send)
            if not guildMail:Settle(index, send) then
                guildMail:Refresh()
            end
        end,
        onConfirmAction = function()
            guildMail:ConfirmAction()
        end,
        onDismissAction = function()
            guildMail:DismissAction()
        end,
        onWelcomeSubject = function(text)
            guildMail:SetWelcomeSubject(text)
        end,
        onWelcomeBody = function(text)
            guildMail:SetWelcomeBody(text)
        end,
        onWelcomeSave = function()
            local saved, reason = guildMail:SaveWelcome()
            if not saved and reason ~= nil then
                rosterController:Print("Welcome mail wasn't saved: " .. reason .. ".")
            end
        end,
        onWelcomeOn = function(checked)
            local saved, reason = guildMail:SetWelcomeOn(checked)
            if not saved and reason ~= nil then
                rosterController:Print("Welcome mail wasn't changed: " .. reason .. ".")
            end
        end,
        onWelcomeBack = function()
            guildMail:CloseWelcome()
        end,
    })
    -- Officers' Guild Mail tab on the mailbox: the guild mails, to continue
    -- or manage; Edit, New and View open the Guild Mail window.
    mailboxTab = addon.MailboxTab.Create(client, {
        onNew = function()
            guildMail:RequestNew()
        end,
        onEdit = function()
            guildMail:EditDraft()
        end,
        onView = function(position)
            guildMail:ViewEntry(position)
        end,
        onResume = function(position)
            if not guildMail:ResumeEntry(position) then
                guildMail:Refresh()
            end
        end,
        onCancel = function(position)
            guildMail:RequestCancelEntry(position)
        end,
        onRemove = function(position)
            guildMail:RequestRemoveEntry(position)
        end,
        onConfirm = function()
            guildMail:ConfirmAction()
        end,
        onDismiss = function()
            guildMail:DismissAction()
        end,
        onShown = function()
            guildMail:Refresh()
        end,
        onEditWelcome = function()
            guildMail:OpenWelcome()
        end,
        onReuse = function(position)
            guildMail:RequestReuseEntry(position)
        end,
        onSendWelcomes = function()
            if not guildMail:SendWelcomes() then
                guildMail:Refresh()
            end
        end,
    })
    -- Guild Greet's Slow mode: an officer setting shared with every add-on
    -- user over guild sync.
    slowModeConfig = addon.SlowModeConfig.Create({
        partition = function()
            local guild, partition = rosterController:QuietContext()
            return guild and partition or nil
        end,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        senderIsOfficer = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(sender)
            return key ~= nil and officerAuthority:IsOfficer(key)
        end,
        isOwn = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(sender)
            if key == nil then
                return nil
            end
            return guildGreet:IsOwn(key)
        end,
        now = function()
            return client:Timestamp()
        end,
        announce = function(message)
            return comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        onChange = function()
            settingsPanel:Refresh()
            frameSettings:Refresh()
            -- The prompts' Slow mode notice follows the new value.
            guildGreet:Refresh()
        end,
    })
    -- The guild's welcome mail: officer settings shared over guild sync.
    guildWelcome = addon.GuildWelcome.Create({
        partition = function()
            local guild, partition = rosterController:QuietContext()
            return guild and partition or nil
        end,
        keyOf = function(rawName)
            local guild, _, normalizer = rosterController:QuietContext()
            return guild and normalizer:Key(rawName) or nil
        end,
        selfKey = function()
            return rosterController:SelfKey()
        end,
        isOfficer = function(key)
            return officerAuthority:IsOfficer(key)
        end,
        senderIsOfficer = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(sender)
            return key ~= nil and officerAuthority:IsOfficer(key)
        end,
        isOwn = function(sender)
            local guild, _, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(sender)
            if key == nil then
                return nil
            end
            return guildGreet:IsOwn(key)
        end,
        now = function()
            return client:Timestamp()
        end,
        announce = function(message)
            return comm:Broadcast(message, addon.Comm.PRIORITY_NORMAL)
        end,
        random = function(low, high)
            return client:Random(low, high)
        end,
        after = function(seconds, callback)
            return client:After(seconds, callback)
        end,
        onChange = function()
            guildMail:OnWelcomeChanged()
        end,
        -- Another officer sent someone's welcome: it's dropped here.
        onWelcomed = function(key, main)
            guildMail:OnWelcomedElsewhere(key, main)
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
        -- Sends are saved as they go, so they survive a reload and can be
        -- resumed from any character on the account.
        outbox = function()
            local store = rosterController:Store()
            return store and store:GuildMailOutbox() or nil
        end,
        now = function()
            return client:Timestamp()
        end,
        view = guildMailWindow,
        tab = mailboxTab,
        welcome = guildWelcome,
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
        slowModeMinutes = function()
            return slowModeConfig and slowModeConfig:Minutes() or 0
        end,
    })
    -- Guild Greet reads the same guild context as the roster.
    -- How many guildmates with the add-on are online, counting the user: the
    -- players online whose add-on this add-on heard since it loaded (their
    -- login announcement, location updates or any other add-on message),
    -- unless their location last said they're inside an instance, where
    -- they get no greet prompts by default. Nil without a guild.
    local function addonOnline()
        local guild, partition, normalizer = rosterController:QuietContext()
        if guild == nil then
            return nil
        end
        local selfCharacter = partition:GetCharacter(rosterController:SelfKey() or "")
        local selfPlayer = selfCharacter and selfCharacter.player
        local counted = {}
        local count = 1
        local key, member
        for key, member in pairs(rosterController:LiveMembers(normalizer)) do
            local character = member.online and partition:GetCharacter(key)
            local player = character and character.player or key
            if character and player ~= selfPlayer and not counted[player]
                and not (locationBoard ~= nil and locationBoard:Inside(key))
            then
                local keys = character.player and partition:CharactersOf(character.player) or { key }
                local index
                for index = 1, #keys do
                    if heardThisSession[keys[index]] then
                        counted[player] = true
                        count = count + 1
                        break
                    end
                end
            end
        end
        return count
    end
    -- The user's group friends in the current guild, from their own party
    -- history. Worked out again when the history changes or saved data does
    -- (a scan linking an alt to its main changes who counts as whom).
    local groupFriends
    local function currentFriends()
        local guild, partition = rosterController:QuietContext()
        if guild == nil then
            return nil
        end
        if groupFriends == nil or groupFriends.partition.key ~= partition.key then
            groupFriends = addon.GroupFriends.Create({
                partition = partition,
                playerOf = function(characterKey)
                    local character = groupFriends.partition:GetCharacter(characterKey)
                    return character and character.player or nil
                end,
                version = function()
                    return rosterController.dataRevision
                end,
                friends = function()
                    return groupFriends.partition:GetFriends()
                end,
            })
        end
        groupFriends.partition = partition
        return groupFriends
    end
    -- The Friends page: the Friend slots and the picker, built from saved
    -- data and the live roster each time it's shown.
    friendsUi.draw = function(content, ui)
        local function inputs(extra)
            local guild, partition, normalizer = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            local fields = {
                partition = partition,
                friendKeys = partition:GetFriends(),
                members = rosterController:LiveMembers(normalizer),
                normalizer = normalizer,
                classColor = function(classToken)
                    return client:GetClassColor(classToken)
                end,
                className = function(classToken)
                    return client:GetClassName(classToken)
                end,
            }
            local name, value
            for name, value in pairs(extra) do
                fields[name] = value
            end
            return fields, partition
        end
        local function change(operation, ...)
            local _, partition = rosterController:QuietContext()
            if partition == nil then
                return false, "you're not in a guild"
            end
            return partition[operation](partition, ...)
        end
        friendsUi.page = addon.FriendsPage.Create(content, ui, {
            model = function(selected)
                local friends = currentFriends()
                local fields = inputs({ selected = selected, mostGrouped = friends and friends:MostGrouped() or {} })
                return fields and addon.FriendsViewModel.Build(fields) or nil
            end,
            picker = function(query)
                local friends = currentFriends()
                local fields = inputs({
                    query = query,
                    selfKey = rosterController:SelfKey(),
                    statsOf = function(key)
                        return friends and friends:StatsOf(key) or 0
                    end,
                })
                return fields and addon.FriendsViewModel.Picker(fields) or {}
            end,
            onAdd = function(key)
                return change("AddFriend", key)
            end,
            onRemove = function(playerId)
                return change("RemoveFriend", playerId)
            end,
            onReplace = function(playerId, key)
                return change("ReplaceFriend", playerId, key)
            end,
            onError = function(text)
                rosterController:Print(text)
            end,
            detail = function(playerId, groupedShown)
                local friends = currentFriends()
                local fields = inputs({
                    playerId = playerId,
                    groupedShown = groupedShown,
                    rolesOf = function(key)
                        local roles = rolesOf(key)
                        return roles and addon.RoleCatalog.Describe(roles) or nil
                    end,
                    adStats = function(keys)
                        return guildRecruit:StatsLine(keys)
                    end,
                    membership = function(keys)
                        return membershipLines(keys)
                    end,
                    history = function()
                        local _, partition = rosterController:QuietContext()
                        return partition:GetGroupHistory()
                    end,
                    historyMember = function(key)
                        local _, partition, normalizer = rosterController:QuietContext()
                        local character = partition:GetCharacter(key)
                        if not character then
                            return nil
                        end
                        local name = character.name or key
                        return { name = normalizer:Display(name) or name, whisper = name,
                            classToken = character.class }
                    end,
                    tierOf = function(key)
                        return lfgFriendTier(key)
                    end,
                    mostGrouped = friends and friends:MostGrouped() or {},
                    formatDate = function(timestamp)
                        return client:FormatDate(timestamp)
                    end,
                    grouped = function(keys)
                        local _, partition = rosterController:QuietContext()
                        return addon.GroupHistory.Create(partition):Stats(keys)
                    end,
                    joined = function(keys)
                        return earliestJoin(keys)
                    end,
                })
                return fields and addon.PlayerDetailViewModel.Build(fields) or nil
            end,
            formatDate = function(at)
                return client:FormatDate(at)
            end,
            onWhisper = function(target)
                client:OpenWhisper(target)
            end,
            onInvite = function(target)
                client:InviteToParty(target)
            end,
        })
        -- Drawn on the window's first open; specs reach it here.
        addon.friendsPage = friendsUi.page
    end
    -- Open in Guild Fellowship, on the game's right-click menus for a
    -- guildmate: the new window on Friends, showing their player.
    friendsUi.menu = addon.GameMenu.Create(client.environment, {
        resolve = function(name)
            local guild, partition, normalizer = rosterController:QuietContext()
            local key = guild and normalizer:Key(name) or nil
            if key == nil or partition:GetCharacter(key) == nil or not partition:IsInGuild(key) then
                return nil
            end
            return key
        end,
        onOpen = function(key)
            local _, partition = rosterController:QuietContext()
            local character = partition and partition:GetCharacter(key)
            if character == nil then
                return
            end
            local opened, failure = agfWindow:Open("friends", character.player)
            if not opened then
                rosterController:Print("Couldn't open the window: " .. tostring(failure))
            end
        end,
    })
    friendsUi.menu:Install()
    addon.gameMenu = friendsUi.menu
    local function friendTier(key)
        local friends = currentFriends()
        return friends and friends:TierOf(key) or nil
    end
    lfgFriendTier = friendTier
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
        -- Older versions' "greeted" message (GuildGreet.LEGACY_GREETED),
        -- heard within seconds, however much sync traffic is waiting.
        announce = function(message)
            return comm:BroadcastLive(message)
        end,
        addonOnline = addonOnline,
        slowModeMinutes = function()
            return slowModeConfig and slowModeConfig:Minutes() or 0
        end,
        friendTier = friendTier,
        view = greetPrompts,
    })
    -- Dev build only: a test prompt in each group friend tier's look (and
    -- one never grouped with), since waiting for a friend to log in can take
    -- days. Each tier shows a guildmate really in it when the party history
    -- has one, else another guildmate drawn in that tier's look. Greet on
    -- them posts nothing.
    if addon.Identity.isDev then
        local PREVIEW_HOLD_SECONDS = 30
        local TIERS = {
            { tier = nil, name = "Not grouped" },
            { tier = addon.GroupFriends.GROUPED, name = "Grouped" },
            { tier = addon.GroupFriends.FREQUENT, name = "Frequent" },
            { tier = addon.GroupFriends.TOP, name = "Top 5" },
            { tier = addon.GroupFriends.FRIEND, name = "Friend" },
        }
        router:Register("greettest",
            "show a test greet prompt in each group friend tier's look; Greet on them posts nothing" ..
            " (greettest hold: Frequent and Top 5 shown as held in Slow mode for " .. PREVIEW_HOLD_SECONDS ..
            " seconds)",
            function(arguments)
                local friends = currentFriends()
                local _, partition = rosterController:QuietContext()
                if friends == nil or partition == nil then
                    rosterController:Print("Greet test needs a guild.")
                    return
                end
                local function usable(key)
                    local character = partition:GetCharacter(key)
                    return character ~= nil and character.departed == nil and partition:IsInGuild(key)
                        and not guildGreet:IsOwn(key)
                end
                local samples = friends:Samples(usable)
                -- One prompt per player, so each tier needs its own.
                local usedPlayers = {}
                local function claim(key)
                    usedPlayers[guildGreet.policy:PlayerOf(key)] = true
                    return key
                end
                local index
                for index = 1, #TIERS do
                    if TIERS[index].tier ~= nil and samples[TIERS[index].tier] ~= nil then
                        claim(samples[TIERS[index].tier])
                    end
                end
                -- Stand-ins: guildmates never grouped with first, so a
                -- stand-in's real tier doesn't confuse, then anyone.
                local others, grouped = {}, {}
                partition:EachCharacter(function(key)
                    if usable(key) then
                        table.insert(friends:TierOf(key) == nil and others or grouped, key)
                    end
                end)
                table.sort(others)
                table.sort(grouped)
                for index = 1, #grouped do
                    table.insert(others, grouped[index])
                end
                local function standIn()
                    local otherIndex
                    for otherIndex = 1, #others do
                        if not usedPlayers[guildGreet.policy:PlayerOf(others[otherIndex])] then
                            return claim(others[otherIndex])
                        end
                    end
                    return nil
                end
                local entries, shown = {}, {}
                for index = 1, #TIERS do
                    local key = TIERS[index].tier and samples[TIERS[index].tier] or nil
                    local real = key ~= nil
                    key = key or standIn()
                    if key ~= nil then
                        table.insert(entries, { key = key, tier = TIERS[index].tier })
                        local rawName = partition:GetCharacter(key).name or key
                        table.insert(shown, TIERS[index].name .. " (" .. guildGreet:Names(key, rawName).name ..
                            ((real or TIERS[index].tier == nil) and "" or ", stand-in") .. ")")
                    end
                end
                local hold = string.lower(string.match(arguments or "", "^%s*(%S*)") or "") == "hold"
                    and PREVIEW_HOLD_SECONDS or nil
                if guildGreet:Preview(entries, hold) == 0 then
                    rosterController:Print("Greet test: no guildmates to show.")
                    return
                end
                rosterController:Print("Greet test prompts: " .. table.concat(shown, ", ") ..
                    ". Greet on them posts nothing.")
                if not guildGreet:HighlightsFriends() then
                    rosterController:Print("Highlight group friends is off, so they show without marks.")
                end
            end)
    end
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
        -- Heard within seconds, so others' prompts close quickly, however
        -- much sync traffic is waiting.
        announce = function(message)
            return comm:BroadcastLive(message)
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
        elseif id == "greetHighlightFriends" or id == "greetFor" then
            guildGreet:Refresh()
        elseif entry ~= nil and entry.category ~= nil then
            guildGreet:OnCategoryChanged(entry.category, value)
        end
        -- The Greetings page shows these; changed elsewhere, it follows.
        if greetingsUi.page ~= nil and (id == "guildGreet" or id == "welcomeBackMinutes" or id == "greetCharacter"
            or (entry ~= nil and entry.category ~= nil))
        then
            greetingsUi.page:Refresh()
        end
    end)
    -- What follows a roster update, run once per burst of them (see below).
    local function afterRosterUpdates()
        addon.PerfCounters.Bump("rosterRefreshes")
        recordOwnCharacter()
        -- A promotion or demotion shows or hides the officers' tabs, and an
        -- officer's add-on keeps the guild log up to date.
        rosterController:RefreshPages()
        requestGuildLog()
        -- The roster's zones count on the world map, and guildmates it shows
        -- offline or gone leave the board.
        if mapPins ~= nil then
            dropOfflineLocations()
            mapPins:Refresh()
        end
        -- The first loaded roster runs Guild Recruit's login check; a rank
        -- change later can grant or take away invite permission.
        guildRecruit:OnRosterUpdate()
        settingsPanel:Refresh()
        frameSettings:Refresh()
    end
    -- Roster updates come in bursts (logins, the game's own guild window,
    -- other add-ons asking). The scan and the roster window hear each at
    -- once (the scan coalesces them itself). The rest runs at once for the
    -- first update after a quiet second, then at most once a second while
    -- more keep coming, once more after the last of them.
    local ROSTER_BURST_SECONDS = 1
    -- The first loaded roster tells Guild Greet who was already online and
    -- how long everyone else has been away. Tried on every update, burst or
    -- not, until it takes, so nobody coming online meanwhile is missed.
    local function seedGreet()
        guildGreet:OnRosterUpdate(function()
            local guild, _, normalizer = rosterController:QuietContext()
            if guild == nil then
                return nil
            end
            local members = {}
            local _, member
            for _, member in pairs(rosterController:LiveMembers(normalizer)) do
                table.insert(members, member)
            end
            if members[1] == nil then
                return nil
            end
            return members
        end)
    end
    local rosterBurst = { open = false, more = false }
    local function endRosterBurst()
        if rosterBurst.more then
            rosterBurst.more = false
            afterRosterUpdates()
            rosterBurst.open = client:After(ROSTER_BURST_SECONDS, endRosterBurst)
        else
            rosterBurst.open = false
        end
    end
    client:ObserveGuildRoster(function()
        addon.PerfCounters.Bump("rosterUpdates")
        rosterController:OnRosterUpdate()
        seedGreet()
        if rosterBurst.open then
            rosterBurst.more = true
            return
        end
        afterRosterUpdates()
        -- Without a timer, every update runs at once.
        rosterBurst.open = client:After(ROSTER_BURST_SECONDS, endRosterBurst)
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
        -- Tags follow local edits, scans and guild sync.
        revision = function()
            local guild, partition = rosterController:QuietContext()
            return (guild and partition.key or "") .. "#" .. rosterController:DataRevision()
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
        local members = rosterController:LiveMembers(normalizer)
        local stamp = rosterController:AuditStamp(partition)
        if auditCache == nil or auditCache.stamp ~= stamp then
            local rows = addon.NoteAudit.Build({
                partition = partition,
                members = members,
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
        -- Selecting a member there opens the player panel for their
        -- player, for anyone.
        showPlayer = function(name)
            return rosterController:ShowPlayerNamed(name)
        end,
        -- Officers see why a selected alt should be promoted to match.
        matchFor = function(name)
            return promotions.matchFor(name)
        end,
        -- Officers see which members are ready for promotion, and which
        -- alts to promote to match their player (that flag wins): worked
        -- out once per redraw of the rows.
        readyCheck = function()
            local ready = promotions.readyKeys()
            local match = promotions.matchKeys()
            local guild, _, normalizer = rosterController:QuietContext()
            if ready == nil or guild == nil then
                return nil
            end
            match = match or {}
            return function(name)
                local key = normalizer:Key(name)
                if key == nil then
                    return nil
                end
                if match[key] ~= nil then
                    return "match", promotions.rankName(match[key])
                end
                return ready[key] == true and "ready" or nil
            end
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
    -- A guildmate the game reports offline, gone from the guild, or not
    -- playing (a whisper to them failed) leaves the board at once, without
    -- waiting for the roster, so they get no more whispers.
    dropLocationOf = function(name)
        local guild, _, normalizer = rosterController:QuietContext()
        local key = guild and normalizer:Key(name) or nil
        if key ~= nil and locationBoard:Drop(key) then
            mapPins:Refresh()
        end
    end
    -- The roster keys of everyone in the player's party or raid, or nil
    -- outside a group. Forever gives group members only their first name,
    -- so the roster decides, as for the group history. Looked up again when
    -- the group or the roster's size changes, or while a guildmate in it
    -- can't be placed.
    local groupCache = { signature = nil, keys = nil }
    local function groupKeys()
        if not client:IsInGroup() then
            return nil
        end
        local members = client:GetGroupMembers()
        local parts = {}
        local index
        for index = 1, #members do
            parts[index] = tostring(members[index].name) .. "/" .. tostring(members[index].guid)
        end
        -- A roster still loading may not name everyone yet.
        local signature = tostring(client:GetGuildRosterCount()) .. "|" .. table.concat(parts, ";")
        if groupCache.signature == signature then
            return groupCache.keys
        end
        local keys = {}
        local complete = true
        for index = 1, #members do
            local key = rosterController:RosterKeyFor(members[index].name, members[index].guid)
            if key ~= nil then
                keys[key] = true
            elseif members[index].inGuild then
                -- A guildmate the roster can't place yet: looked up again
                -- next time.
                complete = false
            end
        end
        groupCache.signature = complete and signature or nil
        groupCache.keys = keys
        return keys
    end
    -- A board entry as the map shows it: with the character's name and its
    -- chat tag (alias or main), dimmed while the player is in a group it
    -- isn't in, and marked `grouped` when it's in the player's group.
    local function describeLocations(entries)
        local guild, partition, normalizer = rosterController:QuietContext()
        if guild == nil then
            return {}
        end
        local group = groupKeys()
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
                dimmed = group ~= nil and not group[entry.key] or nil,
                grouped = group ~= nil and group[entry.key] or nil,
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
        -- Groupmates get no zone map or minimap dot: the game marks them
        -- already. They still count in the markers.
        dots = function()
            local dots = {}
            local described = describeLocations(locationBoard:All())
            local fromRoster = describeLocations(rosterDots())
            local index
            for index = 1, #fromRoster do
                table.insert(described, fromRoster[index])
            end
            for index = 1, #described do
                if not described[index].grouped then
                    table.insert(dots, described[index])
                end
            end
            return dots
        end,
        markers = locationMarkers,
        -- The minimap only needs the guildmates heard in the player's zone.
        nearby = function(zone)
            local entries = locationBoard:All()
            local inZone = {}
            local index
            for index = 1, #entries do
                if entries[index].mapId == zone then
                    table.insert(inZone, entries[index])
                end
            end
            local dots = {}
            local described = describeLocations(inZone)
            for index = 1, #described do
                if not described[index].grouped then
                    table.insert(dots, described[index])
                end
            end
            return dots
        end,
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
        -- Guildmates in the same zone hear more often: by whisper when
        -- there are few, in one guild message when there are many.
        local near, targets, toGuild = locationScheduler:Near({ now = now, character = character, spot = spot,
            guildmates = locationBoard:All() })
        if toGuild then
            comm:Broadcast(near)
            return
        end
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
            local scheduler = addon.LocationScheduler
            sharing = client:After(scheduler.NEAR_ENABLED and scheduler.NEAR_TICK_SECONDS or scheduler.TICK_SECONDS,
                tick)
        end
        tick()
        -- A new zone goes out promptly (within the scheduler's minimum gap:
        -- asked again once it has passed), and the minimap shows the new
        -- zone's guildmates.
        client:ObserveZone(function()
            shareLocation()
            client:After(addon.LocationScheduler.MIN_GAP_SECONDS, shareLocation)
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
    -- In case the region wasn't known yet when saved data loaded.
    persistence:MoveToHomeRealm()
    rosterController:OnSavedDataReady()
    -- Long absence is gone: its saved greetings and switch go too.
    local store = rosterController:Store()
    if store ~= nil then
        addon.GreetingLibrary.RemoveLongAbsence(store:GetGreetState())
    end
    if lfgButton ~= nil then
        lfgButton:Refresh()
    end
    -- The board drops listings gone quiet, and the button follows, even
    -- with nothing else happening.
    local function tickLfg()
        lfgRefresh()
        client:After(addon.LfgBoard.REFRESH_SECONDS, tickLfg)
    end
    tickLfg()
    -- Without the comm libraries, sync simply stays off, and Guild Greet and
    -- Guild Recruit work uncoordinated.
    comm:OnHeard(function(sender)
        heardFrom(sender)
    end)
    if comm:Start(function(message, sender)
        if message.t == addon.GuildGreet.TYPE_GREETED then
            guildGreet:OnGreeted(message, sender)
        elseif addon.GuildRecruit.TYPES[message.t] ~= nil then
            guildRecruit:OnMessage(message, sender)
        elseif addon.GuildWelcome.TYPES[message.t] ~= nil then
            guildWelcome:OnMessage(message, sender)
        elseif addon.SlowModeConfig.TYPES[message.t] ~= nil then
            slowModeConfig:OnMessage(message, sender)
        elseif addon.LfgProtocol.TYPES[message.t] ~= nil and message.t ~= addon.LfgProtocol.TYPE_ASK
            and message.t ~= addon.LfgProtocol.TYPE_ANSWER
        then
            -- Asks and answers are only ever whispered.
            onLfgMessage(message, sender)
        elseif addon.LocationProtocol.TYPES[message.t] ~= nil then
            onLocationMessage(message, sender)
        elseif addon.RankRequirements.TYPES[message.t] ~= nil then
            promotions.sync:OnMessage(message, sender)
        elseif addon.PromotionChecks.TYPES[message.t] ~= nil then
            promotions.ticks:OnMessage(message, sender)
        else
            syncSession:Receive(message, sender)
        end
    end, function(message, sender)
        -- Only guild map updates, resync requests and answers, Guild LFG
        -- Board asks and answers, and, to officers who miss the officer
        -- channel, guild log messages are whispered.
        if addon.LocationProtocol.TYPES[message.t] ~= nil then
            onLocationMessage(message, sender)
        elseif message.t == addon.LfgProtocol.TYPE_ASK or message.t == addon.LfgProtocol.TYPE_ANSWER then
            onLfgMessage(message, sender)
        elseif addon.GuildLogSync.TYPES[message.t] ~= nil then
            guildLogSync:Receive(message, sender)
        elseif addon.Resync.TYPES[message.t] ~= nil then
            resync:OnMessage(message, sender)
        end
    end, function(message, sender)
        -- Only guild log messages go to the officer channel.
        if addon.GuildLogSync.TYPES[message.t] ~= nil then
            guildLogSync:Receive(message, sender)
        end
    end) then
        syncSession:Start()
        guildLogSync:Start()
        startLocations()
    end
    -- The minimap button needs saved data for its position.
    entryPoints:Start()
    guildNoteOverlay:Start()
    -- Settings show saved values, so the panel waits for saved data too.
    settingsPanel:Register()
    -- Without the system message event, Guild Greet simply never prompts.
    client:ObserveGuildEventLog(function()
        readGuildLog()
    end)
    -- A guild chat line naming someone with a greet prompt counts as a
    -- greeting for them, whoever typed it.
    client:ObserveGuildChat(function(message, sender)
        guildGreet:OnGuildChat(message, sender)
    end)
    client:ObservePresence(function(kind, name)
        if kind == "join" or kind == "leave" then
            recordLiveMembership(kind, name)
        end
        if dropLocationOf ~= nil and (kind == "offline" or kind == "leave" or kind == "removed"
            or kind == "notFound")
        then
            dropLocationOf(name)
        end
        if kind == "offline" then
            lfgOnOffline(name)
        end
        if kind == "notFound" then
            return
        end
        guildGreet:OnPresence(kind, name)
        if kind == "join" then
            guildWelcome:OnJoined(name)
        end
    end)
    -- Prompts wait out combat and boss encounters.
    local busy = client:ObserveCombat(function(inCombat)
        guildGreet:OnCombatChanged(inCombat)
        guildRecruit:OnCombatChanged(inCombat)
        -- The LFG button's glow waits out combat.
        lfgRefresh()
        -- A location held back by combat goes out once it ends.
        if not inCombat and shareLocationNow ~= nil then
            client:After(1, shareLocationNow)
        end
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
        -- A guessed purpose follows the party into a dungeon; relevance and
        -- Nearby follow the zone; no glow in instances.
        lfgOnZone()
    end)
    guildRecruit:Refresh()
    -- Every party with guildmates goes into the local group history.
    client:ObserveParty(function()
        -- The listing follows the party, and the drawer shows it; no glow
        -- while in one. A listing taken over first, so history has its
        -- dungeon.
        lfgOnParty()
        recordParty()
        -- Groupmates leave the maps' dots, and those outside the group
        -- are dimmed.
        if mapPins ~= nil then
            mapPins:Refresh()
        end
    end)
    -- Guild Mail follows the mailbox, and sends its next mail when the game
    -- answers the last. Officers get its tab on the mailbox.
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
            -- The tab first, so its title shows the welcomes waiting.
            pcall(mailboxTab.Install, mailboxTab, guildMail:ShowsMailboxTab())
            guildMail:OnMailboxOpened()
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
        -- Errors, money and blocked calls only matter while mailing.
        client:SetMailListening(guildMail:WantsGameEvents())
    end)
    -- Without a chat filter API, chat is simply left untagged.
    client:AddChatMessageFilter(addon.ChatAnnotator.EVENTS, function(event, message, sender, lineId)
        return chatAnnotator:Annotate(event, message, sender, lineId)
    end)
    -- The game answers a whisper to someone who just logged off with "No
    -- player named ... is currently playing."; when the add-on sent that
    -- whisper, the line is hidden.
    client:HidePlayerNotFound(function(name)
        return comm:WhisperedRecently(name)
    end, function()
        return comm:WhisperedAnyRecently()
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
addon.agfWindow = agfWindow
addon.lfgButton = lfgButton
addon.settingsPanel = settingsPanel
addon.frameSettings = frameSettings
addon.guildGreet = guildGreet
addon.guildRecruit = guildRecruit
addon.guildWelcome = guildWelcome
addon.promotions = promotions
addon.lfgListing = lfgListing
addon.lfgBoard = lfgBoard
addon.lfgTrigger = lfgTrigger
addon.syncSession = syncSession
addon.router = router
addon.version = version

lifecycle:Start()
