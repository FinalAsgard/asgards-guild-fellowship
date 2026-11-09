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
    function widget:SetVertexColor(...) self.tint = { ... } end
    function widget:EnableMouse(enabled) self.mouse = enabled end
    function widget:SetMouseClickEnabled(enabled) self.clicks = enabled end
    function widget:CreateFontString()
        return fakeWidget()
    end
    function widget:CreateTexture()
        return fakeWidget()
    end
    return widget
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
    local detail = { displayed = {}, hooks = {} }
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
        -- The note panel.
        if parent == detail and detail.panel == nil then
            detail.panel = fakeWidget()
            return detail.panel
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
    return test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua", "Adapters/GuildNoteOverlay.lua")
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
        showPlayer = function(name)
            options.shownPlayers = options.shownPlayers or {}
            table.insert(options.shownPlayers, name)
            return not (options.unknown or {})[name]
        end,
        matchFor = function(name)
            return (options.matches or {})[name]
        end,
        readyCheck = function()
            options.readyChecks = (options.readyChecks or 0) + 1
            local ready = options.ready
            return ready and function(name)
                local match = (options.match or {})[name]
                if match ~= nil then
                    return "match", match
                end
                return ready[name] == true and "ready" or nil
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
        -- Under the detail panel, never drawn inside it.
        test.assertEqual("BOTTOMLEFT", panel.points[1][3])
        test.assertEqual(0, panel.points[1][5])
        -- Tall enough for its lines, the suggestion then the problems, with
        -- Ignore along the bottom below them, never over the text.
        test.assertEqual(12 + 3 + 12 + 6 + 18 + 16, panel.height)
        test.assertEqual("BOTTOMRIGHT", panel.button.points[1][1])
        test.assertEqual(panel, panel.suggested.points[2][2], "the suggestion runs the full width")

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

    test.test(profile .. ": the note panel hangs under the detail panel, as wide as it", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local overlay = build(world, { rows = { Hammer = ROW } })

        overlay:Attach()
        detail:DisplayMember(1, { name = "Hammer" })

        local panel = detail.panel
        test.assertTrue(panel.shown)
        test.assertEqual(2, #panel.points)
        test.assertEqual("TOPLEFT", panel.points[1][1])
        test.assertEqual(detail, panel.points[1][2])
        test.assertEqual("BOTTOMLEFT", panel.points[1][3])
        test.assertEqual("TOPRIGHT", panel.points[2][1])
        test.assertEqual("BOTTOMRIGHT", panel.points[2][3])
        test.assertEqual(nil, panel.width, "its width follows the detail panel")
    end)

    test.test(profile .. ": an alt to promote to match gets a line naming the rank and the player's highest",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local match = { rankName = "Officer", highestName = "Toolbox", highestRankName = "Guild Master" }
        local options = { rows = { Hammer = ROW }, matches = { Hammer = match, Wrench = match } }
        local overlay = build(world, options)
        overlay:Attach()

        -- With an out-of-date note: under the note's lines, Ignore kept.
        detail:DisplayMember(1, { name = "Hammer" })
        local panel = detail.panel
        test.assertTrue(panel.shown)
        test.assertContains(panel.match.text, "Promote to Officer to match Toolbox (Guild Master), this player's "
            .. "highest.")
        test.assertTrue(panel.match.shown)
        test.assertEqual(panel.problems, panel.match.points[1][2], "under the problems")
        test.assertTrue(panel.button.shown)
        test.assertEqual(12 + 3 + 12 + 3 + 12 + 6 + 18 + 16, panel.height)

        -- Note fine: the match line alone, first, with no Ignore.
        detail:DisplayMember(1, { name = "Wrench" })
        test.assertTrue(panel.shown)
        test.assertFalse(panel.suggested.shown)
        test.assertFalse(panel.button.shown)
        test.assertEqual(panel, panel.match.points[1][2])
        test.assertEqual(12 + 16, panel.height)

        -- Neither: hidden. Members never see it.
        detail:DisplayMember(1, { name = "Toolbox" })
        test.assertFalse(panel.shown)
        options.officer = false
        detail:DisplayMember(1, { name = "Wrench" })
        test.assertFalse(panel.shown)
    end)

    test.test(profile .. ": a player panel that couldn't open is tried again when the member is shown again",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local options = { officer = false, unknown = { ["Newt-Area52"] = true } }
        local overlay = build(world, options)
        overlay:Start()

        detail:DisplayMember(1, { name = "Newt-Area52" })
        test.assertEqual(1, #options.shownPlayers)
        -- The scan records Newt; the game shows them again.
        options.unknown = {}
        detail:DisplayMember(1, { name = "Newt-Area52" })
        test.assertEqual(2, #options.shownPlayers)
        -- Opened now: shown again, it stays as the user left it.
        detail:DisplayMember(1, { name = "Newt-Area52" })
        test.assertEqual(2, #options.shownPlayers)
    end)

    test.test(profile .. ": selecting a member opens the add-on's player panel, for anyone, once per selection",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local options = { officer = false }
        local overlay = build(world, options)
        overlay:Start()

        detail:DisplayMember(1, { name = "Hammer-Area52" })
        test.assertEqual("Hammer-Area52", table.concat(options.shownPlayers, ","))
        -- The game shows the same member again on a roster update: a
        -- panel the user closed stays closed.
        detail:DisplayMember(1, { name = "Hammer-Area52" })
        overlay:Refresh()
        test.assertEqual(1, #options.shownPlayers)
        detail:DisplayMember(1, { name = "Wrench-Area52" })
        test.assertEqual("Wrench-Area52", options.shownPlayers[2])
        -- Closing the details and picking the same member again reopens it.
        detail.hooks.OnHide()
        detail:DisplayMember(1, { name = "Wrench-Area52" })
        test.assertEqual(3, #options.shownPlayers)
        test.assertEqual(nil, detail.profile, "no panels of its own under the details")
        test.assertEqual(nil, detail.promotion)
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
            -- The add-on's window, never shown here: only its player panel.
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
            function window:ShowPlayer(model) self.player = model return true end
            function window:HidePlayer() self.player = nil return true end
            world.addon.RosterWindow.Create = function()
                return window
            end
            fixtures.fire(world, "ADDON_LOADED", world.addonName)
            world.loggedIn = true
            fixtures.fire(world, "PLAYER_LOGIN")
            fixtures.fire(world, "PLAYER_ENTERING_WORLD")
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(world)

            local officerName = world.guild.members[1].name
            detail:DisplayMember(1, { name = officerName })
            test.assertFalse(detail.panel.shown, "the officer's own note reads correctly")
            -- The officer's player opens in the player panel, without the
            -- window.
            test.assertEqual("TheTool (", string.sub(window.player.label, 1, #"TheTool ("))
            test.assertFalse(window.shown)

            world.guild.members[1].note = "raid lead"
            fixtures.fire(world, "GUILD_ROSTER_UPDATE")
            fixtures.runTimers(world)

            test.assertTrue(detail.panel.shown)
            test.assertEqual("Should be: @TheTool raid lead", detail.panel.suggested.text)
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

    test.test(profile .. ": an alt to promote to match gets the arrow tinted, with a tooltip, over a Ready flag",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local tooltip = { shown = false }
        function tooltip:SetOwner(owner) self.owner = owner end
        function tooltip:SetText(text) self.text = text end
        function tooltip:Show() self.shown = true end
        function tooltip:Hide() self.shown = false end
        world.environment.GameTooltip = tooltip
        local list = detail.memberList
        list.rows = { fakeRow("Hammer"), fakeRow("Bolt"), fakeRow("Nail") }
        local options = { ready = { Hammer = true, Bolt = true }, match = { Hammer = "Officer", Nail = "Veteran" } }
        local overlay = build(world, options)
        overlay:AttachRows()

        local hammer, bolt, nail = list.rows[1].readyMarker, list.rows[2].readyMarker, list.rows[3].readyMarker
        test.assertTrue(hammer.shown, "behind and ready: the match flag shows")
        test.assertTrue(nail.shown)
        test.assertTrue(bolt.shown)
        test.assertEqual(0.30, hammer.picture.tint[1])
        test.assertEqual(1, bolt.picture.tint[1], "a Ready flag keeps the plain arrow")
        test.assertTrue(hammer.mouse)
        test.assertFalse(hammer.clicks, "the match flag's clicks go through to the row")
        test.assertFalse(bolt.mouse, "a Ready flag doesn't take the mouse")

        hammer.OnEnter()
        test.assertTrue(tooltip.shown)
        test.assertEqual("Promote to match: Officer", tooltip.text)
        test.assertEqual(hammer, tooltip.owner)
        hammer.OnLeave()
        test.assertFalse(tooltip.shown)
        bolt.OnEnter()
        test.assertFalse(tooltip.shown, "no tooltip on a Ready flag")

        -- A client that can't pass clicks through: the flag never takes
        -- the mouse, so the row still gets its clicks.
        nail.SetMouseClickEnabled = nil
        overlay:SetFlag(nail, "match", "Veteran")
        test.assertFalse(nail.mouse)
        test.assertEqual(0.30, nail.picture.tint[1], "still tinted")

        local lines = overlay:ReadyProbeLines()
        test.assertEqual("Rows with a Ready flag now: 1", lines[2])
        test.assertEqual("Rows with a Promote to match flag now: 2", lines[4])

        -- Scrolling reuses a row; the alt reaches its rank and the flag
        -- goes back to Ready, untinted.
        list.rows[2]:SetMember({ name = "Nail" })
        test.assertEqual(0.30, bolt.picture.tint[1], "the flag follows the member")
        options.match = { Nail = "Veteran" }
        overlay:Refresh()
        test.assertEqual(1, hammer.picture.tint[1])
        test.assertFalse(hammer.mouse)
        options.match = {}
        options.ready = {}
        overlay:Refresh()
        test.assertFalse(bolt.shown)
        test.assertFalse(nail.shown)
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
        local options = { officer = false, rows = { Hammer = ROW }, ready = { Hammer = true },
            match = { Hammer = "Officer" } }
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

    test.test(profile .. ": in the whole add-on, an officer sees an alt that's behind flagged to match, until it is",
        function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        local alt = world.guild.members[2]
        detail.memberList.rows = { fakeRow(alt.name), fakeRow(world.guild.members[1].name) }
        fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world)
        local arrow = detail.memberList.rows[1].readyMarker
        local function arrowTinted()
            return arrow.shown and arrow.picture.tint ~= nil and arrow.picture.tint[1] < 1
        end
        -- The game's roster: a tinted arrow on the alt's row, none on the
        -- main's.
        test.assertTrue(arrowTinted(), "the alt's row has the match arrow")
        test.assertFalse(detail.memberList.rows[2].readyMarker.shown)
        world.messages = {}
        fixtures.slash(world, "probe ready")
        local printed = table.concat(world.messages, "\n")
        test.assertContains(printed, "Promote to match: 1")
        test.assertContains(printed, " to Officer")
        test.assertContains(printed, "Rows with a Promote to match flag now: 1")
        local _, partition, normalizer = world.addon.rosterController:QuietContext()
        local altKey = normalizer:Key(alt.name)
        local promotions = world.addon.promotions
        -- The player panel's Promotion tab line for the alt.
        local function matchLine()
            local rows = promotions.panelRows({ altKey }, partition:GetCharacter(altKey).player) or {}
            local index
            for index = 1, #rows do
                if string.find(rows[index].text or "", "Promote to match", 1, true) then
                    return rows[index].text
                end
            end
            return nil
        end

        -- The alt's rank has no requirements: the match line still shows.
        test.assertContains(matchLine(), "Promote to match: Officer")
        -- Selected in the game's roster, the panel under the details says
        -- which rank and why.
        detail:DisplayMember(1, { name = alt.name })
        test.assertTrue(detail.panel.shown)
        local main = partition:GetCharacter(partition:GetPlayer(partition:GetCharacter(altKey).player).main)
        test.assertContains(detail.panel.match.text, "Promote to Officer to match "
            .. normalizer:Display(main.name) .. " (")

        -- The officer turns matching off for Officer, then Veteran too:
        -- the flag moves down, then goes, then comes back.
        test.assertTrue(promotions.rank(1), "from the newest members' rank round to Officer")
        test.assertEqual(1, promotions.view().rank)
        test.assertTrue(promotions.view().matchAlts, "ticked by default")
        test.assertTrue(promotions.matchAlts(false))
        test.assertFalse(promotions.view().matchAlts)
        test.assertContains(matchLine(), "Promote to match: Veteran")
        test.assertTrue(promotions.rank(1))
        test.assertTrue(promotions.matchAlts(false))
        test.assertEqual(nil, matchLine(), "no rank in range is on")
        test.assertFalse(arrow.shown, "and the roster's arrow goes")
        test.assertTrue(promotions.rank(-1))
        test.assertTrue(promotions.matchAlts(true))
        test.assertContains(matchLine(), "Promote to match: Officer")

        -- Promoted in the game's own guild window: the flag clears on the
        -- roster update, with no Rescan.
        alt.rank, alt.rankName = 1, "Officer"
        fixtures.fire(world, "GUILD_ROSTER_UPDATE")
        fixtures.runTimers(world, 5)
        test.assertEqual(nil, matchLine())
        test.assertFalse(arrow.shown, "the roster's arrow clears too")
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
