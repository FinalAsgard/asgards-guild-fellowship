local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

-- ProfileViewModel -----------------------------------------------------------

local RULES = { twoPartNames = false, homeRealm = "Area52" }
local START = 1790000000

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/RoleCatalog.lua",
        "Core/ProfileViewModel.lua"
    )
end

-- TheTool: Toolbox (warrior, main) + Hammer (paladin) + Wrench (mage), and
-- Wrench then leaves the guild. Logged in on `selfKey` (Toolbox unless
-- given).
local function setup()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local function members(entries)
        local result = {}
        local index
        for index = 1, #entries do
            result[normalizer:Key(entries[index][1])] = {
                name = entries[index][1], note = entries[index][2], level = entries[index][3],
                classToken = entries[index][4],
            }
        end
        return result
    end
    local function scan(entries, mode, now)
        addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
            partition = partition, members = members(entries), normalizer = normalizer,
            rules = RULES, mode = mode or "full", now = now or START,
        }))
    end
    local guild = {
        { "Toolbox-Area52", "@TheTool", 80, "WARRIOR" },
        { "Hammer-Area52", ">Toolbox", 70, "PALADIN" },
        { "Wrench-Area52", ">Toolbox", 60, "MAGE" },
    }
    scan(guild, "initial")
    scan({ guild[1], guild[2] }, "full", START + 86400)
    local roles = addon.RoleCatalog.For("retail")
    return {
        addon = addon,
        partition = partition,
        build = function(overrides)
            local inputs = {
                inGuild = true,
                partition = partition,
                selfKey = "toolbox-area52",
                members = members({ guild[1], guild[2] }),
                normalizer = normalizer,
                roles = roles,
                classColor = function(classToken)
                    return classToken == "WARRIOR" and "ffc79c6e" or nil
                end,
                dnd = false,
            }
            local key, value
            for key, value in pairs(overrides or {}) do
                inputs[key] = value
            end
            return addon.ProfileViewModel.Build(inputs)
        end,
    }
end

local function roleList(character)
    local parts = {}
    local index
    for index = 1, #character.roles do
        local role = character.roles[index]
        table.insert(parts, role.label .. (role.checked and "+" or "-"))
    end
    return table.concat(parts, " ")
end

test.test("profile view model: shows the logged-in character's player, main first, in class color with level", function()
    local world = setup()

    local model = world.build()

    test.assertEqual(nil, model.message)
    test.assertEqual("TheTool (Toolbox)", model.label)
    test.assertEqual("TheTool", model.alias)
    test.assertEqual("Toolbox", model.mainName)
    -- Wrench left the guild, so only Toolbox and Hammer are listed.
    test.assertEqual(2, #model.characters)
    local main, alt = model.characters[1], model.characters[2]
    test.assertEqual("Toolbox", main.name)
    test.assertEqual("|cffc79c6eToolbox|r", main.coloredName)
    test.assertEqual(80, main.level)
    test.assertTrue(main.isMain)
    test.assertTrue(main.isSelf)
    test.assertEqual("Hammer", alt.name)
    test.assertEqual("Hammer", alt.coloredName)
    test.assertEqual(70, alt.level)
    test.assertFalse(alt.isMain)
    test.assertFalse(alt.isSelf)
end)

test.test("profile view model: only the logged-in character's roles are editable, offering only its class's roles", function()
    local world = setup()
    world.partition:SetRoles("toolbox-area52", { "dps" }, START, "toolbox-area52")

    local model = world.build()

    local main, alt = model.characters[1], model.characters[2]
    test.assertTrue(main.editable)
    test.assertEqual(nil, main.hint)
    -- A warrior can't heal, so it isn't offered.
    test.assertEqual("Tank- DPS+", roleList(main))
    test.assertFalse(alt.editable)
    -- Never set: every role the paladin's class can fill.
    test.assertEqual("Tank, Healer, DPS", alt.rolesText)
    test.assertEqual("Log in on Hammer to change its roles.", alt.hint)

    -- Logged in on Hammer instead, Hammer's are the editable ones.
    model = world.build({ selfKey = "hammer-area52" })
    test.assertFalse(model.characters[1].editable)
    test.assertEqual("DPS", model.characters[1].rolesText)
    test.assertEqual("Log in on Toolbox to change its roles.", model.characters[1].hint)
    test.assertTrue(model.characters[2].editable)
    test.assertEqual("Tank+ Healer+ DPS+", roleList(model.characters[2]))
end)

test.test("profile view model: carries Do Not Disturb", function()
    local world = setup()

    test.assertTrue(world.build({ dnd = true }).dnd)
    test.assertFalse(world.build({ dnd = false }).dnd)
    test.assertTrue(world.build({ inGuild = false, dnd = true }).dnd)
end)

test.test("profile view model: out of a guild, or before the roster knows the character, it says so", function()
    local world = setup()
    local ProfileViewModel = world.addon.ProfileViewModel

    local model = world.build({ inGuild = false, partition = nil })
    test.assertEqual(ProfileViewModel.NO_GUILD, model.message)
    test.assertContains(model.message, "needs a guild")
    test.assertEqual(nil, model.characters)

    test.assertEqual(ProfileViewModel.NOT_READY, world.build({ partition = false }).message)
    test.assertEqual(ProfileViewModel.NOT_IN_ROSTER, world.build({ selfKey = "stranger-area52" }).message)
    test.assertEqual(ProfileViewModel.NOT_IN_ROSTER, world.build({ selfKey = false }).message)
end)

-- The tab, drawn with fake frames ---------------------------------------------

local function newPage(model)
    local addon = test.newAddon("Core/RoleCatalog.lua", "Core/ProfileViewModel.lua", "Adapters/ProfilePage.lua")
    local environment = fakeFrames.install({})
    local world = { model = model, roles = {}, dnd = {} }
    world.page = addon.ProfilePage.Create({ environment = environment }, fakeFrames.host(environment), {
        model = function()
            return world.model
        end,
        setRole = function(role, enabled)
            table.insert(world.roles, role .. "=" .. tostring(enabled))
        end,
        setDnd = function(enabled)
            table.insert(world.dnd, enabled)
        end,
    })
    return world
end

local PLAYER = {
    label = "TheTool (Toolbox)",
    dnd = true,
    characters = {
        {
            key = "toolbox", name = "Toolbox", coloredName = "|cffc79c6eToolbox|r", level = 80,
            isMain = true, isSelf = true, editable = true, rolesText = "DPS",
            roles = {
                { role = "tank", label = "Tank", checked = false },
                { role = "dps", label = "DPS", checked = true },
            },
        },
        {
            key = "hammer", name = "Hammer", coloredName = "Hammer", level = 70,
            isMain = false, isSelf = false, editable = false, rolesText = "Tank, Healer, DPS",
            hint = "Log in on Hammer to change its roles.",
            roles = {},
        },
    },
}

test.test("profile tab: draws the player, check boxes for the logged-in character, and read-only roles for the rest", function()
    local world = newPage(PLAYER)
    local page = world.page

    page.panel.hooks.OnShow()

    test.assertEqual("TheTool (Toolbox)", page.heading.text)
    test.assertFalse(page.messageText.shown)
    test.assertTrue(page.dndButton:GetChecked())
    local main, alt = page.rows[1], page.rows[2]
    test.assertEqual("|cffc79c6eToolbox|r  |cff9d9d9d(80, main, logged in)|r", main.name.text)
    test.assertTrue(main.checks[1].button.shown)
    test.assertEqual("Tank", main.checks[1].label.text)
    test.assertFalse(main.checks[1].button:GetChecked())
    test.assertEqual("DPS", main.checks[2].label.text)
    test.assertTrue(main.checks[2].button:GetChecked())
    -- A warrior has no third role.
    test.assertFalse(main.checks[3].button.shown)
    test.assertFalse(main.rolesText.shown)
    test.assertEqual("Hammer  |cff9d9d9d(70)|r", alt.name.text)
    test.assertFalse(alt.checks[1].button.shown)
    test.assertTrue(alt.rolesText.shown)
    test.assertContains(alt.rolesText.text, "Tank, Healer, DPS")
    test.assertContains(alt.rolesText.text, "Log in on Hammer to change its roles.")
end)

test.test("profile tab: its check boxes change roles and Do Not Disturb", function()
    local world = newPage(PLAYER)
    local page = world.page
    page.panel.hooks.OnShow()

    local tank = page.rows[1].checks[1].button
    tank:SetChecked(true)
    tank.scripts.OnClick(tank)
    page.dndButton:SetChecked(false)
    page.dndButton.scripts.OnClick(page.dndButton)

    test.assertEqual("tank=true", table.concat(world.roles, ","))
    test.assertEqual(false, world.dnd[1])
end)

test.test("profile tab: shows the message instead of the list when there's no player, and hides rows no longer needed", function()
    local world = newPage(PLAYER)
    local page = world.page
    page.panel.hooks.OnShow()

    world.model = { message = "My Profile needs a guild: this character isn't in one.", dnd = false }
    page:Refresh()

    test.assertEqual("My Profile", page.heading.text)
    test.assertTrue(page.messageText.shown)
    test.assertContains(page.messageText.text, "needs a guild")
    test.assertFalse(page.scroll.shown)
    test.assertFalse(page.rows[1].frame.shown)
    test.assertFalse(page.dndButton:GetChecked())
end)

test.test("profile tab: a tab out of view isn't redrawn, and without a tab it isn't made", function()
    local world = newPage(PLAYER)
    local page = world.page
    page.panel:Hide()

    page:Refresh()
    test.assertEqual(nil, rawget(page.heading, "text"))

    local addon = test.newAddon("Core/RoleCatalog.lua", "Adapters/ProfilePage.lua")
    local none, reason = addon.ProfilePage.Create({ environment = {} }, nil, {})
    test.assertEqual(nil, none)
    test.assertContains(reason, "no tab")
end)


-- /agf profile in the composed add-on ------------------------------------------

-- The add-on logged in, with a master frame recording its page. On its
-- first build My Profile is drawn on a fake tab: `world.profileTab`, with
-- the page drawn on it in `world.profilePage`.
local function loggedIn(profile)
    local world = fixtures.newEnvironment(profile)
    local addon = fixtures.loadAddon(world)
    fakeFrames.install(world.environment)
    local frame = { shown = false }
    function frame:IsShown() return self.shown end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:ShowPage(id)
        self.page = id
        return true
    end
    function frame:SetTitle() end
    function frame:SetStatus() end
    function frame:SetRows() return true end
    function frame:SetConflicts() return true end
    function frame:SetRecruiters() return true end
    function frame:SetRecentAds() return true end
    local create = addon.ProfilePage.Create
    addon.ProfilePage.Create = function(client, host, options)
        world.profilePage = create(client, host, options)
        return world.profilePage
    end
    addon.RosterWindow.Create = function(_, options)
        world.profileTab = fakeFrames.host(world.environment)
        world.profileTab:Hide()
        options.drawPages.profile(world.profileTab)
        return frame
    end
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    world.frame = frame
    return world, addon
end

-- Opens My Profile and brings its tab into view, as the frame does.
local function openProfile(world)
    fixtures.slash(world, "profile")
    world.profileTab:Show()
    world.profileTab.hooks.OnShow()
    return world.profilePage
end

local function click(button, checked)
    button:SetChecked(checked)
    button.scripts.OnClick(button)
end

local function registerProfileTests(profile)
    test.test(profile .. " /agf profile opens the frame on My Profile, and again closes it", function()
        local world, addon = loggedIn(profile)

        fixtures.slash(world, "profile")
        test.assertTrue(world.frame.shown)
        test.assertEqual("profile", world.frame.page)
        fixtures.slash(world, "profile")
        test.assertFalse(world.frame.shown)

        -- Another tab showing: it switches to My Profile.
        fixtures.slash(world, "roster")
        fixtures.slash(world, "profile")
        test.assertTrue(world.frame.shown)
        test.assertEqual("profile", world.frame.page)

        local tabs = addon.pages:Tabs()
        test.assertEqual("group", tabs[2].id)
        test.assertEqual("profile", tabs[3].id)
        test.assertEqual("My Profile", tabs[3].label)
        test.assertEqual(addon.MasterFrame.ICONS.profile, tabs[3].icon)
    end)

    test.test(profile .. " /agf help lists /agf profile", function()
        local world = loggedIn(profile)

        fixtures.slash(world, "help")

        test.assertContains(table.concat(world.messages, "\n"), "/agf profile - open or close My Profile")
    end)

    test.test(profile .. " My Profile shows the logged-in character's player and its roles", function()
        local world = loggedIn(profile)

        local page = openProfile(world)

        test.assertContains(page.heading.text, "TheTool (")
        local main = page.rows[1]
        test.assertContains(main.name.text, "main, logged in")
        -- A warrior: Tank and DPS, no healing.
        test.assertEqual("Tank", main.checks[1].label.text)
        test.assertEqual("DPS", main.checks[2].label.text)
        test.assertFalse(main.checks[3].button.shown)
        test.assertContains(page.rows[2].rolesText.text, "to change its roles.")
    end)

    test.test(profile .. " My Profile's roles are the Settings' roles, both ways", function()
        local world, addon = loggedIn(profile)
        local page = openProfile(world)
        local selfKey = addon.rosterController:SelfKey()
        local _, partition = addon.rosterController:QuietContext()

        -- Ticked off on My Profile: Settings and the stored roles agree.
        click(page.rows[1].checks[1].button, false)
        test.assertFalse(addon.settings:Get("role_tank"))
        test.assertEqual("dps", table.concat(partition:GetRoles(selfKey), ","))

        -- Changed in Settings: My Profile shows it at once.
        test.assertTrue(addon.settings:Set("role_tank", true))
        test.assertTrue(page.rows[1].checks[1].button:GetChecked())
    end)

    test.test(profile .. " My Profile's Do Not Disturb is the Group Finder's, Settings' and /agf dnd's", function()
        local world, addon = loggedIn(profile)
        local page = openProfile(world)
        test.assertFalse(page.dndButton:GetChecked())

        click(page.dndButton, true)
        test.assertTrue(addon.settings:Get("dnd"))
        test.assertTrue(addon.rosterController:Store():GroupFinderDnd())

        fixtures.slash(world, "dnd")
        test.assertFalse(page.dndButton:GetChecked())
        test.assertTrue(addon.settings:Set("dnd", true))
        test.assertTrue(page.dndButton:GetChecked())
    end)

    test.test(profile .. " out of a guild, My Profile says it needs one", function()
        local world, addon = loggedIn(profile)
        local page = openProfile(world)

        world.guild = nil
        page:Refresh()

        test.assertTrue(page.messageText.shown)
        test.assertEqual(addon.ProfileViewModel.NO_GUILD, page.messageText.text)
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end
