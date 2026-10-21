local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- A font string or frame that records what the overlay does with it.
local function fakeWidget()
    local widget = { points = {}, shown = true }
    function widget:SetPoint(...) table.insert(self.points, { ... }) end
    function widget:SetHeight(height) self.height = height end
    function widget:SetWidth(width) self.width = width end
    function widget:ClearAllPoints() self.points = {} end
    function widget:SetJustifyH(justify) self.justify = justify end
    function widget:SetText(text) self.text = text end
    function widget:GetText() return self.text end
    function widget:SetColorTexture(...) self.color = { ... } end
    function widget:Show() self.shown = true end
    function widget:Hide() self.shown = false end
    function widget:IsShown() return self.shown end
    function widget:SetSize(width, height) self.size = { width, height } end
    function widget:SetAllPoints(target) self.allPoints = target end
    function widget:SetTexture(texture) self.texture = texture end
    function widget:SetScript(name, handler) self[name] = handler end
    function widget:CreateFontString()
        return fakeWidget()
    end
    function widget:CreateTexture()
        return fakeWidget()
    end
    return widget
end

-- A widget of the promotion panel: it records its text, whether it's
-- shown and checked, its scripts and children; any other method does
-- nothing.
local function promotionWidget()
    local widget = { shown = true, scripts = {}, children = {}, points = {} }
    local methods = {}
    function methods:SetPoint(...) table.insert(self.points, { ... }) end
    function methods:ClearAllPoints() self.points = {} end
    function methods:SetText(text) self.text = text end
    function methods:GetText() return self.text or "" end
    function methods:Show() self.shown = true end
    function methods:Hide() self.shown = false end
    function methods:IsShown() return self.shown end
    function methods:SetChecked(checked) self.checked = checked end
    function methods:GetChecked() return self.checked == true end
    function methods:Enable() self.enabled = true end
    function methods:Disable() self.enabled = false end
    function methods:HasFocus() return false end
    function methods:SetScript(name, handler) self.scripts[name] = handler end
    function methods:SetHeight(height) self.height = height end
    function methods:CreateFontString()
        local text = promotionWidget()
        table.insert(self.children, text)
        return text
    end
    function methods:CreateTexture()
        return promotionWidget()
    end
    return setmetatable(widget, {
        __index = function(_, name)
            return methods[name] or function() end
        end,
    })
end

-- A member list row showing `name`; the list reuses rows for other members
-- through SetMember.
local function fakeRow(name)
    local row = { memberInfo = name and { name = name } or nil }
    function row:SetMember(memberInfo)
        self.memberInfo = memberInfo
    end
    return row
end

-- Gives `environment` the Communities guild roster's member detail panel
-- (the same frames on Forever and Retail), hooksecurefunc, and a
-- CreateFrame that records the overlay's panel. Returns the detail panel.
local function installGuildRoster(environment)
    local detail = { displayed = {}, hooks = {}, NoteBackground = fakeWidget() }
    function detail:DisplayMember(clubId, memberInfo)
        table.insert(self.displayed, memberInfo.name)
    end
    function detail:HookScript(name, handler)
        self.hooks[name] = handler
    end
    local list = { rows = {}, refreshes = 0 }
    list.ScrollBox = {
        ForEachFrame = function(_, callback)
            local index
            for index = 1, #list.rows do
                callback(list.rows[index])
            end
        end,
    }
    function list:RefreshListDisplay()
        self.refreshes = self.refreshes + 1
    end
    detail.memberList = list
    environment.CommunitiesFrame = { GuildMemberDetailFrame = detail, MemberList = list }
    environment.securelyHooked = {}
    environment.hooksecurefunc = function(target, method, hook)
        table.insert(environment.securelyHooked, method)
        local original = target[method]
        target[method] = function(...)
            original(...)
            hook(...)
        end
    end
    local createFrame = environment.CreateFrame
    environment.CreateFrame = function(frameType, name, parent, ...)
        -- The note panel first, then the profile panel, then the
        -- promotion panel, whose widgets record into promotionWidget.
        if parent == detail then
            if detail.panel == nil then
                detail.panel = fakeWidget()
                return detail.panel
            end
            if detail.profile == nil then
                detail.profile = fakeWidget()
                return detail.profile
            end
            detail.promotion = promotionWidget()
            detail.promotion.lines = {}
            detail.promotion.isPromotion = true
            return detail.promotion
        end
        if type(parent) == "table" and (parent.isPromotion or parent.inPromotion) then
            local widget = promotionWidget()
            widget.inPromotion = true
            widget.frameType = frameType
            table.insert(parent.children, widget)
            return widget
        end
        if parent ~= nil and parent == detail.profile then
            detail.profile.editButton = fakeWidget()
            return detail.profile.editButton
        end
        if parent ~= nil and parent == detail.panel then
            detail.panel.button = fakeWidget()
            return detail.panel.button
        end
        -- A row's note marker first, then its Ready flag.
        if type(parent) == "table" and parent.SetMember ~= nil then
            if parent.marker == nil then
                parent.marker = fakeWidget()
                return parent.marker
            end
            parent.readyMarker = fakeWidget()
            return parent.readyMarker
        end
        return createFrame(frameType, name, parent, ...)
    end
    return detail
end

local function loadAdapter()
    return test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua", "Core/PromotionChecks.lua",
        "Adapters/PromotionLines.lua", "Adapters/GuildNoteOverlay.lua")
end

local ROW = {
    key = "hammer-area52",
    name = "Hammer",
    current = "Healer",
    suggested = ">TheTool Healer",
    problems = { "missing main", "wrong alias" },
    tooLong = false,
}

local function build(world, options)
    options = options or {}
    options.ignored = {}
    local addon = loadAdapter()
    local client = addon.Compatibility.Create(world.environment)
    local overlay = addon.GuildNoteOverlay.Create({
        client = client,
        isOfficer = function()
            return options.officer ~= false
        end,
        rowFor = function(name)
            return (options.rows or {})[name]
        end,
        ignore = function(row)
            table.insert(options.ignored, row)
            options.rows[row.name] = nil
        end,
        profileFor = function(name)
            return (options.profiles or {})[name]
        end,
        editProfile = function()
            options.edited = (options.edited or 0) + 1
        end,
        promotionFor = function(name)
            return (options.promotions or {})[name]
        end,
        tick = function(key, item, ticked, note)
            options.ticks = options.ticks or {}
            table.insert(options.ticks, { key = key, item = item, ticked = ticked, note = note })
            return true
        end,
        toggle = function(key)
            options.toggled = options.toggled or {}
            table.insert(options.toggled, key)
        end,
        readyCheck = function()
            options.readyChecks = (options.readyChecks or 0) + 1
            local ready = options.ready
            return ready and function(name)
                return ready[name] == true
            end or nil
        end,
    })
    return overlay, addon
end

test.test("the overlay's lines name the suggestion, each problem, and a too-long warning", function()
    local addon = loadAdapter()

    local lines = addon.GuildNoteOverlay.Lines(ROW)
    test.assertEqual("Should be: >TheTool Healer", lines.suggested)
    test.assertEqual("No main marker; Wrong alias", lines.problems)
    test.assertEqual("", lines.tooLong)

    lines = addon.GuildNoteOverlay.Lines({ suggested = "", problems = { "stale main" }, tooLong = true })
    test.assertEqual("Should be: (empty)", lines.suggested)
    test.assertEqual("Main marker shouldn't be there", lines.problems)
    test.assertEqual(addon.GuildNoteOverlay.TOO_LONG_TEXT, lines.tooLong)
end)

local function registerProfileTests(profile)
    test.test(profile .. ": an officer selecting a member with an out-of-date note sees what it should say", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local overlay = build(world, { rows = { Hammer = ROW } })

        test.assertTrue(overlay:Attach())
        detail:DisplayMember(1, { name = "Hammer" })

        -- The game's own function still ran; the overlay only followed it.
        test.assertEqual("Hammer", detail.displayed[1])
        test.assertEqual("DisplayMember", world.environment.securelyHooked[1])
        local panel = detail.panel
        test.assertTrue(panel.shown)
        test.assertEqual("Should be: >TheTool Healer", panel.suggested.text)
        test.assertEqual("No main marker; Wrong alias", panel.problems.text)
        -- To the right of the detail panel, never drawn inside it.
        test.assertEqual(1, #panel.points)
        test.assertEqual("TOPLEFT", panel.points[1][1])
        test.assertEqual(detail, panel.points[1][2])
        test.assertEqual("TOPRIGHT", panel.points[1][3])
        test.assertEqual(0, panel.points[1][5])
        test.assertEqual(240, panel.width)
        -- Tall enough for its lines: the suggestion beside Ignore, then
        -- the problems.
        test.assertEqual(18 + 3 + 12 + 16, panel.height)

        -- A member whose note is up to date: nothing shows.
        detail:DisplayMember(1, { name = "Toolbox" })
        test.assertFalse(panel.shown)
        -- Closing the detail panel hides it too.
        detail:DisplayMember(1, { name = "Hammer" })
        detail.hooks.OnHide()
        test.assertFalse(panel.shown)
    end)

    test.test(profile .. ": Ignore leaves the shown mismatch alone and hides it", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        detail.memberList.rows = { fakeRow("Hammer") }
        local options = { rows = { Hammer = ROW } }
        local overlay = build(world, options)
        overlay:Attach()
        overlay:AttachRows()
        detail:DisplayMember(1, { name = "Hammer" })

        local button = detail.panel.button
        test.assertEqual("Ignore", button.text)
        button.OnClick()

        test.assertEqual(ROW, options.ignored[1])
        test.assertFalse(detail.panel.shown)
        test.assertFalse(detail.memberList.rows[1].marker.shown)
    end)

    test.test(profile .. ": members who aren't officers never see the overlay", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local overlay = build(world, { officer = false, rows = { Hammer = ROW } })

        overlay:Attach()
        detail:DisplayMember(1, { name = "Hammer" })

        test.assertFalse(detail.panel.shown)
    end)

    test.test(profile .. ": the overlay attaches when the guild roster loads, and redraws on refresh", function()
        local world = fixtures.newEnvironment(profile)
        local rows = {}
        local overlay = build(world, { rows = rows })

        overlay:Start()
        test.assertEqual(nil, overlay.panel)
        local detail = installGuildRoster(world.environment)
        fixtures.fire(world, "ADDON_LOADED", "Blizzard_Communities")
        test.assertTrue(overlay.panel ~= nil)

        detail:DisplayMember(1, { name = "Hammer" })
        test.assertFalse(detail.panel.shown)
        rows.Hammer = ROW
        overlay:Refresh()
        test.assertTrue(detail.panel.shown)
    end)

    test.test(profile .. ": the note panel sits level with the detail panel's public note", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        function detail:GetTop() return 500 end
        function detail.NoteBackground:GetTop() return 380 end
        local overlay = build(world, { rows = { Hammer = ROW } })

        overlay:Attach()
        detail:DisplayMember(1, { name = "Hammer" })

        local panel = detail.panel
        test.assertEqual(1, #panel.points)
        test.assertEqual("TOPRIGHT", panel.points[1][3])
        test.assertEqual(-120, panel.points[1][5])
    end)

    test.test(profile .. ": a selected member's promotion status shows between the details and the mini profile, to work on",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local rows = {
            { kind = "promotion", key = "bolt", text = "[-] Bolt: Initiate -> Member, 0 of 2", toggle = true },
            { kind = "promotion", key = "bolt", item = "rules", text = "Read the rules", check = true,
                checked = false, canCheck = true },
            { kind = "promotion", key = "bolt", item = "level", text = "Level 50  level 12 of 50", check = true,
                checked = false, action = "Override" },
            { kind = "promotion", key = "bolt", item = "level", noteInput = true, reason = true, ticked = false },
        }
        local options = { profiles = { Bolt = { title = "Bolt", lines = {} } }, promotions = { Bolt = rows } }
        local overlay = build(world, options)
        overlay:Attach()
        detail:DisplayMember(1, { name = "Bolt" })

        local promotion = detail.promotion
        test.assertTrue(promotion.shown)
        test.assertEqual("Promotion", promotion.title.text)
        -- Hung under the detail panel, as wide as the mini profile, which
        -- then hangs under it.
        test.assertEqual(detail, promotion.points[1][2])
        test.assertEqual("BOTTOMLEFT", promotion.points[1][3])
        test.assertEqual(6, promotion.points[1][4])
        test.assertEqual("BOTTOMRIGHT", promotion.points[2][3])
        test.assertEqual(promotion, detail.profile.points[1][2])
        test.assertEqual("BOTTOMLEFT", detail.profile.points[1][3])
        test.assertEqual(0, detail.profile.points[1][4])
        test.assertEqual("BOTTOMRIGHT", detail.profile.points[2][3])
        local lines = promotion.lines
        test.assertTrue(lines[1].shown)
        test.assertContains(lines[1].text.text, "Bolt: Initiate -> Member")
        test.assertTrue(lines[2].check.shown, "an item has a check box")
        test.assertTrue(lines[2].check.enabled, "an officer's custom item can be ticked")
        test.assertEqual(false, lines[3].check.enabled, "an automated item's box only shows whether it's met")
        test.assertTrue(lines[3].act.shown)
        test.assertEqual("Override", lines[3].act.text)
        test.assertTrue(lines[4].note.shown, "the override's reason line")
        test.assertFalse(lines[5].shown, "unused lines are hidden")

        -- Ticking, overriding with a reason, and closing a checklist.
        lines[2].check.scripts.OnClick(lines[2].check)
        test.assertEqual("rules", options.ticks[1].item)
        test.assertTrue(options.ticks[1].ticked)
        lines[4].note:SetText("Raid leader")
        lines[4].note.scripts.OnTextChanged(lines[4].note, true)
        lines[3].act.scripts.OnClick(lines[3].act)
        test.assertEqual("Raid leader", options.ticks[2].note)
        lines[1].scripts.OnMouseUp(lines[1])
        test.assertEqual("bolt", options.toggled[1])

        -- Someone this user may not see: no panel, and the mini profile
        -- moves back up under the details.
        detail:DisplayMember(1, { name = "Nail" })
        test.assertFalse(promotion.shown)
        test.assertEqual(detail, detail.profile.points[1][2])
        test.assertEqual(6, detail.profile.points[1][4])
    end)

    test.test(profile .. ": a long promotion list ends with a pointer to the add-on's player panel", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local rows = {}
        local index
        for index = 1, 30 do
            table.insert(rows, { kind = "promotion", key = "bolt", text = "Line " .. index })
        end
        local overlay = build(world, { promotions = { Bolt = rows } })
        overlay:Attach()
        detail:DisplayMember(1, { name = "Bolt" })
        local lines = detail.promotion.lines
        test.assertContains(lines[#lines].text.text, "More in the add-on's player panel")
        test.assertContains(lines[#lines - 1].text.text, "Line " .. (#lines - 1))
    end)

    test.test(profile .. ": anyone selecting a member sees their player's mini profile under the details", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local summary = { title = "TheTool (Toolbox)", lines = { "Discord: thetool", "Main: Toolbox (80)",
            "Alts: Hammer (70)" } }
        local overlay = build(world, { officer = false, profiles = { Hammer = summary } })

        overlay:Attach()
        detail:DisplayMember(1, { name = "Hammer" })

        local shown = detail.profile
        test.assertTrue(shown.shown)
        test.assertFalse(detail.panel.shown)
        test.assertEqual("TheTool (Toolbox)", shown.title.text)
        test.assertEqual("Discord: thetool\nMain: Toolbox (80)\nAlts: Hammer (70)", shown.body.text)
        -- Hung under the detail panel, as wide as it, moved a little right
        -- to clear the guild roster window.
        test.assertEqual("TOPLEFT", shown.points[1][1])
        test.assertEqual(detail, shown.points[1][2])
        test.assertEqual("BOTTOMLEFT", shown.points[1][3])
        test.assertEqual(6, shown.points[1][4])
        test.assertEqual("BOTTOMRIGHT", shown.points[2][3])
        test.assertEqual(6, shown.points[2][4])
        -- Tall enough for the title and three lines; someone else's
        -- profile has no Edit button.
        test.assertEqual(12 + 3 + 3 * 12 + 16, shown.height)
        test.assertFalse(shown.editButton.shown)

        -- Someone the add-on has no record of: no profile.
        detail:DisplayMember(1, { name = "Stranger" })
        test.assertFalse(shown.shown)
        -- Closing the details hides it.
        detail:DisplayMember(1, { name = "Hammer" })
        detail.hooks.OnHide()
        test.assertFalse(shown.shown)
    end)

    test.test(profile .. ": the user's own mini profile has an Edit button that opens My Profile", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local options = { officer = false, profiles = {
            Toolbox = { title = "TheTool (Toolbox)", lines = { "Main: Toolbox (80)" }, own = true },
        } }
        local overlay = build(world, options)

        overlay:Attach()
        detail:DisplayMember(1, { name = "Toolbox" })

        local edit = detail.profile.editButton
        test.assertTrue(edit.shown)
        test.assertEqual("Edit", edit.text)
        test.assertEqual("BOTTOMRIGHT", edit.points[1][1])
        -- Room between the last line and the button.
        test.assertEqual(12 + 3 + 12 + 10 + 18 + 16, detail.profile.height)
        edit.OnClick()
        test.assertEqual(1, options.edited)
    end)

    test.test(profile .. ": without the guild roster or hooksecurefunc, the overlay stays off", function()
        local world = fixtures.newEnvironment(profile)
        local overlay = build(world)

        test.assertFalse(overlay:Attach())
        installGuildRoster(world.environment)
        world.environment.hooksecurefunc = nil
        test.assertFalse(overlay:Attach())
        overlay:ShowMember("Hammer")
    end)

    test.test(profile .. ": in the whole add-on, an officer sees a note go out of date after the next roster update",
        function()
            local world = fixtures.newEnvironment(profile)
            local detail = installGuildRoster(world.environment)
            fixtures.loadAddon(world)
            fixtures.fire(world, "ADDON_LOADED", world.addonName)
            world.loggedIn = true
            fixtures.fire(world, "PLAYER_LOGIN")
            fixtures.fire(world, "PLAYER_ENTERING_WORLD")
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(world)

            local officerName = world.guild.members[1].name
            detail:DisplayMember(1, { name = officerName })
            test.assertFalse(detail.panel.shown, "the officer's own note reads correctly")

            world.guild.members[1].note = "raid lead"
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(world)

            test.assertTrue(detail.panel.shown)
            test.assertEqual("Should be: @TheTool raid lead", detail.panel.suggested.text)
            -- The officer's player, in brief, under the details.
            test.assertTrue(detail.profile.shown)
            test.assertEqual("TheTool (", string.sub(detail.profile.title.text, 1, #"TheTool ("))
            -- It's the officer's own player: Edit opens My Profile.
            test.assertTrue(detail.profile.editButton.shown)
            local window = { shown = false }
            function window:IsShown() return self.shown end
            function window:Show() self.shown = true end
            function window:Hide() self.shown = false end
            function window:ShowPage(id) self.page = id end
            function window:SetTitle() end
            function window:SetStatus() end
            function window:SetRows() return true end
            function window:SetConflicts() return true end
            function window:SetRecruiters() return true end
            function window:SetRecentAds() return true end
            world.addon.RosterWindow.Create = function()
                return window
            end
            detail.profile.editButton.OnClick()
            test.assertTrue(window.shown)
            test.assertEqual("profile", window.page)
            test.assertEqual("Alias missing", detail.panel.problems.text)

            -- Ignored: hidden until the note changes again.
            detail.panel.button.OnClick()
            test.assertFalse(detail.panel.shown)
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(world)
            detail:DisplayMember(1, { name = officerName })
            test.assertFalse(detail.panel.shown)

            world.guild.members[1].note = "raid lead, tank"
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(world)
            test.assertTrue(detail.panel.shown)
            test.assertEqual("Should be: @TheTool raid lead, tank", detail.panel.suggested.text)
        end)
end

local function registerRowTests(profile)
    test.test(profile .. ": an officer sees a marker on rows of members with an out-of-date note", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local list = detail.memberList
        list.rows = { fakeRow("Hammer"), fakeRow("Toolbox"), fakeRow(nil) }
        local overlay = build(world, { rows = { Hammer = ROW } })

        test.assertTrue(overlay:AttachRows())

        test.assertTrue(list.rows[1].marker.shown)
        test.assertFalse(list.rows[2].marker.shown)
        test.assertFalse(list.rows[3].marker.shown)
        test.assertEqual("RIGHT", list.rows[1].marker.points[1][1])
        -- The list's own redraw still ran.
        list:RefreshListDisplay()
        test.assertEqual(1, list.refreshes)
    end)

    test.test(profile .. ": markers follow scrolling, sorting and refreshes", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local list = detail.memberList
        list.rows = { fakeRow("Hammer"), fakeRow("Toolbox") }
        local rows = { Hammer = ROW }
        local overlay = build(world, { rows = rows })
        overlay:AttachRows()

        -- Scrolling: a row is reused for another member.
        list.rows[1]:SetMember({ name = "Toolbox" })
        list.rows[2]:SetMember({ name = "Hammer" })
        test.assertFalse(list.rows[1].marker.shown)
        test.assertTrue(list.rows[2].marker.shown)

        -- Sorting or a roster refresh redraws the list.
        list.rows[1].memberInfo = { name = "Hammer" }
        list:RefreshListDisplay()
        test.assertTrue(list.rows[1].marker.shown)

        -- The note was fixed: the next refresh after a scan clears it.
        rows.Hammer = nil
        overlay:Refresh()
        test.assertFalse(list.rows[1].marker.shown)
        test.assertFalse(list.rows[2].marker.shown)
    end)

    test.test(profile .. ": an officer sees a Ready flag on rows of members ready for promotion", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local list = detail.memberList
        list.rows = { fakeRow("Hammer"), fakeRow("Bolt"), fakeRow(nil) }
        local options = { rows = { Hammer = ROW }, ready = { Bolt = true } }
        local overlay = build(world, options)
        overlay:AttachRows()

        test.assertFalse(list.rows[1].readyMarker.shown)
        test.assertTrue(list.rows[1].marker.shown, "the note marker is separate")
        test.assertTrue(list.rows[2].readyMarker.shown)
        test.assertFalse(list.rows[2].marker.shown)
        test.assertFalse(list.rows[3].readyMarker.shown)
        test.assertEqual("RIGHT", list.rows[2].readyMarker.points[1][1])
        test.assertEqual(-20, list.rows[2].readyMarker.points[1][4])
        test.assertEqual(1, options.readyChecks, "worked out once per redraw, not per row")

        -- Scrolling reuses a row: the flag follows the member.
        list.rows[1]:SetMember({ name = "Bolt" })
        list.rows[2]:SetMember({ name = "Hammer" })
        test.assertTrue(list.rows[1].readyMarker.shown)
        test.assertFalse(list.rows[2].readyMarker.shown)

        -- Promoted in the game's window: the next refresh clears the flag.
        options.ready = {}
        overlay:Refresh()
        test.assertFalse(list.rows[1].readyMarker.shown)
        local lines = overlay:ReadyProbeLines()
        test.assertEqual("Guild roster rows followed: yes (3 shown)", lines[1])
        test.assertEqual("Rows with a Ready flag now: 0", lines[2])
    end)

    test.test(profile .. ": the Ready flag sits just after the row's rank, within the rank column", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local list = detail.memberList
        list.rows = { fakeRow("Bolt"), fakeRow("Nail") }
        -- The row's rank text: "Initiate" is 46 wide; a long rank is cut at
        -- the column's 80.
        local function rank(text, column)
            local widget = fakeWidget()
            function widget:GetStringWidth() return text end
            function widget:GetWidth() return column end
            return widget
        end
        list.rows[1].Rank = rank(46, 80)
        list.rows[2].Rank = rank(120, 80)
        local overlay = build(world, { ready = { Bolt = true, Nail = true } })
        overlay:AttachRows()

        local point = list.rows[1].readyMarker.points[1]
        test.assertEqual("LEFT", point[1])
        test.assertEqual(list.rows[1].Rank, point[2])
        test.assertEqual(50, point[4], "4 past the rank's text")
        test.assertEqual(84, list.rows[2].readyMarker.points[1][4], "no further than the rank column's edge")
        test.assertEqual(1, #list.rows[1].readyMarker.points, "placed afresh on each redraw")
        test.assertContains(overlay:ReadyProbeLines()[3], "Flags next to the rank: 2")

        -- With the rank column hidden, it falls back to the row's edge.
        list.rows[1].Rank.shown = false
        overlay:Refresh()
        test.assertEqual("RIGHT", list.rows[1].readyMarker.points[1][1])
        test.assertContains(overlay:ReadyProbeLines()[3], "at the row's right edge (no rank text found): 1")
    end)

    test.test(profile .. ": before the guild roster opens, the probe says its rows aren't followed yet", function()
        local world = fixtures.newEnvironment(profile)
        local overlay = build(world, { ready = { Bolt = true } })
        test.assertContains(overlay:ReadyProbeLines()[1], "Guild roster rows followed: no")
    end)

    test.test(profile .. ": members who aren't officers see no row markers", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        detail.memberList.rows = { fakeRow("Hammer") }
        local options = { officer = false, rows = { Hammer = ROW }, ready = { Hammer = true } }
        local overlay = build(world, options)

        overlay:AttachRows()

        test.assertFalse(detail.memberList.rows[1].marker.shown)
        test.assertFalse(detail.memberList.rows[1].readyMarker.shown)
        test.assertEqual(nil, options.readyChecks, "a member's add-on never works out who's ready")
    end)

    test.test(profile .. ": in the whole add-on, an officer's row marker appears after the next roster update", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local officerName = world.guild.members[1].name
        detail.memberList.rows = { fakeRow(officerName) }
        fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)
        local row = detail.memberList.rows[1]
        test.assertFalse(row.marker.shown)

        world.guild.members[1].note = "raid lead"
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)

        test.assertTrue(row.marker.shown)
    end)

    test.test(profile .. ": in the whole add-on, an officer works anyone's promotion from the guild roster",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local member = world.guild.members[#world.guild.members]
        fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)
        local promotions = world.addon.promotions
        local _, partition, normalizer = world.addon.rosterController:QuietContext()
        local key = normalizer:Key(member.name)
        local rank = partition:GetCharacter(key).rank
        local guard = 0
        while promotions.view().rank ~= rank and guard < 10 do
            promotions.rank(1)
            guard = guard + 1
        end
        test.assertTrue(promotions.add("Read the rules", false))

        detail:DisplayMember(1, { name = member.name })
        local lines = detail.promotion.lines
        test.assertTrue(detail.promotion.shown)
        test.assertContains(lines[1].text.text, "Highest rank")
        test.assertContains(lines[2].text.text, "[-] ", "the selected member's checklist is open")
        test.assertContains(lines[2].text.text, "0 of 1")
        test.assertTrue(lines[3].check.enabled)
        lines[3].check.scripts.OnClick(lines[3].check)
        test.assertContains(lines[2].text.text, "Ready for promotion", "redrawn at once")
        lines[2].scripts.OnMouseUp(lines[2])
        test.assertContains(lines[2].text.text, "[+] ", "closed")
        test.assertFalse(lines[3].shown)
    end)

    test.test(profile .. ": in the whole add-on, a member sees only their own promotion status, read-only",
        function()
        local world = fixtures.newEnvironment(profile, { playerName = fixtures.GUILDS[profile].members[2].name })
        local detail = installGuildRoster(world.environment)
        fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)
        local _, partition, normalizer = world.addon.rosterController:QuietContext()
        local selfKey = world.addon.rosterController:SelfKey()
        local requirements = world.addon.RankRequirements.Create(partition:GetRankRequirements(), {
            isOfficer = function()
                return true
            end,
        })
        requirements:Add(partition:GetCharacter(selfKey).rank, "Read the rules", "check", nil, "boss", world.time)
        requirements:Add(4, "Read the rules", "check", nil, "boss", world.time)

        -- Another player's character, at a rank with requirements.
        detail:DisplayMember(1, { name = world.guild.members[3].name })
        test.assertFalse(detail.promotion.shown, "never someone else's")
        detail:DisplayMember(1, { name = world.guild.members[2].name })
        test.assertTrue(detail.promotion.shown, "their own character")
        local headers = 0
        local index
        for index = 1, #detail.promotion.lines do
            local line = detail.promotion.lines[index]
            if line.shown and line.row ~= nil and line.row.toggle then
                headers = headers + 1
                test.assertContains(line.text.text, "Member", "the selected character, not its player's others")
            end
        end
        test.assertEqual(1, headers, "only the selected character")
        local other = string.match(world.guild.members[1].name, "^[^%- ]+")
        for index = 1, #detail.promotion.lines do
            local line = detail.promotion.lines[index]
            test.assertFalse(line.shown and string.find(line.text.text or "", other, 1, true) ~= nil,
                "not its player's other characters")
        end
        local item
        for index = 1, #detail.promotion.lines do
            local line = detail.promotion.lines[index]
            if line.shown and line.row ~= nil and line.row.check then
                item = line
            end
        end
        test.assertTrue(item.check.shown)
        test.assertEqual(false, item.check.enabled, "read-only")
    end)

    test.test(profile .. ": in the whole add-on, a ticked character's row gets its Ready flag at once", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local member = world.guild.members[#world.guild.members]
        detail.memberList.rows = { fakeRow(member.name) }
        fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)
        local row = detail.memberList.rows[1]
        test.assertFalse(row.readyMarker.shown)

        local promotions = world.addon.promotions
        local _, partition, normalizer = world.addon.rosterController:QuietContext()
        local key = normalizer:Key(member.name)
        local rank = partition:GetCharacter(key).rank
        local step = rank - (promotions.view().rank or rank)
        local guard = 0
        while promotions.view().rank ~= rank and guard < 10 do
            promotions.rank(step > 0 and 1 or -1)
            guard = guard + 1
        end
        test.assertTrue(promotions.add("Read the rules", false))
        test.assertFalse(row.readyMarker.shown)
        test.assertTrue(promotions.tick(key, promotions.view().items[1].id, true))
        test.assertTrue(row.readyMarker.shown, "flagged without waiting for a scan")
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerRowTests(fixtures.PROFILES[index])
    registerProfileTests(fixtures.PROFILES[index])
end
