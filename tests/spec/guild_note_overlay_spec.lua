local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

-- A font string or frame that records what the overlay does with it.
local function fakeWidget()
    local widget = { points = {}, shown = true }
    function widget:SetPoint(...) table.insert(self.points, { ... }) end
    function widget:SetHeight(height) self.height = height end
    function widget:SetJustifyH(justify) self.justify = justify end
    function widget:SetText(text) self.text = text end
    function widget:Show() self.shown = true end
    function widget:Hide() self.shown = false end
    function widget:CreateFontString()
        return fakeWidget()
    end
    return widget
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
    environment.CommunitiesFrame = { GuildMemberDetailFrame = detail }
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
        -- Just above the public note.
        test.assertEqual("BOTTOMLEFT", panel.points[1][1])
        test.assertEqual(detail.NoteBackground, panel.points[1][2])
        test.assertEqual("TOPLEFT", panel.points[1][3])

        -- A member whose note is up to date: nothing shows.
        detail:DisplayMember(1, { name = "Toolbox" })
        test.assertFalse(panel.shown)
        -- Closing the detail panel hides it too.
        detail:DisplayMember(1, { name = "Hammer" })
        detail.hooks.OnHide()
        test.assertFalse(panel.shown)
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
        end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end
