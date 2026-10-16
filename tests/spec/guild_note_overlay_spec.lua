local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- A font string or frame that records what the overlay does with it.
local function fakeWidget()
    local widget = { points = {}, shown = true }
    function widget:SetPoint(...) table.insert(self.points, { ... }) end
    function widget:SetHeight(height) self.height = height end
    function widget:SetJustifyH(justify) self.justify = justify end
    function widget:SetText(text) self.text = text end
    function widget:GetText() return self.text end
    function widget:SetColorTexture(...) self.color = { ... } end
    function widget:Show() self.shown = true end
    function widget:Hide() self.shown = false end
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
        if parent == detail then
            detail.panel = fakeWidget()
            return detail.panel
        end
        if parent ~= nil and parent == detail.panel then
            detail.panel.button = fakeWidget()
            return detail.panel.button
        end
        if type(parent) == "table" and parent.SetMember ~= nil then
            parent.marker = fakeWidget()
            return parent.marker
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
        -- Hung under the detail panel, never drawn inside it.
        test.assertEqual("TOPLEFT", panel.points[1][1])
        test.assertEqual(detail, panel.points[1][2])
        test.assertEqual("BOTTOMLEFT", panel.points[1][3])
        test.assertEqual("TOPRIGHT", panel.points[2][1])
        test.assertEqual("BOTTOMRIGHT", panel.points[2][3])
        local panelPoints = #panel.points
        for index = 1, panelPoints do
            test.assertTrue(panel.points[index][2] ~= detail.NoteBackground)
        end
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

    test.test(profile .. ": members who aren't officers see no row markers", function()
        local world = fixtures.newEnvironment(profile)
        local detail = installGuildRoster(world.environment)
        detail.memberList.rows = { fakeRow("Hammer") }
        local overlay = build(world, { officer = false, rows = { Hammer = ROW } })

        overlay:AttachRows()

        test.assertFalse(detail.memberList.rows[1].marker.shown)
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
end

local index
for index = 1, #fixtures.PROFILES do
    registerRowTests(fixtures.PROFILES[index])
    registerProfileTests(fixtures.PROFILES[index])
end
