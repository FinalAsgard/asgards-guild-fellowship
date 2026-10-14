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
        "Core/SyncFacts.lua",
        "Core/SuggestionBundles.lua",
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
    local world = { model = model, roles = {}, dnd = {}, addon = addon }
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


test.test("profile view model: lists the player's Discord, location and bio, newest across its characters", function()
    local world = setup()
    world.partition:SetProfileText("hammer-area52", "discord", "hammer#1", START, "hammer-area52")
    world.partition:SetProfileText("toolbox-area52", "bio", "Hi", START, "toolbox-area52")

    local about = world.build().about

    test.assertEqual("discord,location,bio", about[1].kind .. "," .. about[2].kind .. "," .. about[3].kind)
    test.assertEqual("Discord", about[1].label)
    test.assertEqual("hammer#1", about[1].text)
    test.assertEqual(32, about[1].max)
    test.assertEqual("", about[2].text)
    test.assertEqual(40, about[2].max)
    test.assertEqual("Hi", about[3].text)
    test.assertEqual(500, about[3].max)
end)

test.test("profile tab: About me fields show the player's text with a count, and save on Enter", function()
    local model = {}
    local key, value
    for key, value in pairs(PLAYER) do
        model[key] = value
    end
    model.about = {
        { kind = "discord", label = "Discord", text = "hammer#1", max = 32 },
        { kind = "location", label = "Location", text = "", max = 40 },
        { kind = "bio", label = "Bio", text = "", max = 500 },
    }
    local world = newPage(model)
    world.texts = {}
    world.page.setText = function(kind, text)
        table.insert(world.texts, kind .. "=" .. text)
    end
    local page = world.page
    page.panel.hooks.OnShow()

    local discord, location = page.aboutRows[2], page.aboutRows[3]
    -- The short fields share one width; the bio is a taller box on several
    -- lines; the characters follow under their own heading.
    local width = world.addon.ProfilePage.SHORT_BOX_WIDTH
    test.assertEqual(width, page.aboutRows[1].box.width)
    test.assertEqual(width, discord.box.width)
    test.assertEqual(width, location.box.width)
    test.assertTrue(page.aboutRows[4].box.multiLine)
    test.assertEqual(nil, rawget(discord.box, "multiLine"))
    test.assertEqual(world.addon.ProfilePage.BIO_HEIGHT, page.aboutRows[4].box.height)
    test.assertEqual("Characters", page.charactersHeading.text)
    test.assertTrue(page.charactersHeading.shown)
    test.assertEqual("Discord", discord.label.text)
    test.assertEqual("hammer#1", discord.box.text)
    test.assertEqual("8/32", discord.counter.text)
    test.assertEqual("0/40", location.counter.text)

    -- Typed and saved with Enter, trimmed.
    location.box:SetText("  Ohio, evenings ")
    location.box.scripts.OnTextChanged(location.box)
    test.assertEqual("17/40", location.counter.text)
    location.box.scripts.OnEnterPressed(location.box)
    test.assertEqual("location=Ohio, evenings", table.concat(world.texts, ","))
    -- Leaving the box again with nothing new saves nothing more.
    location.box.scripts.OnEditFocusLost(location.box)
    test.assertEqual(1, #world.texts)

    -- Escape puts the saved text back.
    discord.box:SetText("oops")
    discord.box.scripts.OnEscapePressed(discord.box)
    test.assertEqual("hammer#1", discord.box.text)
    test.assertEqual(1, #world.texts)
end)

test.test("profile view model: alts can be made main or removed; the main can't", function()
    local world = setup()

    local main, alt = world.build().characters[1], world.build().characters[2]

    test.assertFalse(main.canMakeMain)
    test.assertFalse(main.canRemove)
    test.assertTrue(alt.canMakeMain)
    test.assertTrue(alt.canRemove)
    local model = world.build()
    test.assertEqual("toolbox-area52", model.main)
    test.assertEqual(48, model.aliasMax)
end)

test.test("profile view model: alt candidates are the guild's other characters, with a warning for another player's", function()
    local world = setup()
    local addon = world.addon
    local normalizer = addon.NameNormalizer.Create(RULES)
    local partition = world.partition
    -- Bolt and Spark are Thunderer's; Visitor is on its own; Wrench left.
    partition:RecordCharacter("bolt-area52", { name = "Bolt-Area52", classToken = "SHAMAN", level = 40 })
    partition:RecordCharacter("spark-area52", { name = "Spark-Area52", classToken = "MAGE", level = 30 })
    partition:RecordCharacter("visitor-stormrage", { name = "Visitor-Stormrage", classToken = "MAGE", level = 80 })
    partition:JoinPlayerOf("spark-area52", "bolt-area52", "manual")
    partition:SetAlias(partition:GetCharacter("bolt-area52").player, "Thunderer", "manual")
    local function candidates(query)
        local found = addon.ProfileViewModel.AltCandidates({
            partition = partition, selfKey = "toolbox-area52", normalizer = normalizer,
        }, query)
        local names = {}
        local index
        for index = 1, #found do
            names[index] = found[index].name .. (found[index].owner and ("<" .. found[index].owner .. ">") or "")
        end
        return table.concat(names, ","), found
    end

    -- Toolbox already has an alt: Thunderer's characters can't be taken
    -- from them, so only characters on their own are offered.
    test.assertEqual("Visitor-Stormrage", (candidates("")))
    test.assertEqual("Visitor-Stormrage", (candidates("VIS")))
    test.assertEqual("", (candidates("thunder")))
    local _, found = candidates("visitor")
    test.assertEqual(nil, found[1].warning)
    test.assertEqual(nil, found[1].joins)
    -- No logged-in character known: nothing to add to.
    test.assertEqual(0, #addon.ProfileViewModel.AltCandidates({ partition = partition, normalizer = normalizer }, ""))

    -- Visitor is on its own: it's offered every player's characters, by
    -- name or by the player's alias, and picking one joins that player.
    local function fromVisitor(query)
        return addon.ProfileViewModel.AltCandidates({
            partition = partition, selfKey = "visitor-stormrage", normalizer = normalizer,
        }, query)
    end
    found = fromVisitor("THUNDER")
    test.assertEqual(2, #found)
    test.assertEqual("Bolt", found[1].name)
    test.assertTrue(found[1].joins)
    test.assertEqual("Bolt belongs to Thunderer. Picking it adds Visitor-Stormrage to Thunderer's characters.",
        found[1].warning)
    test.assertEqual(4, #fromVisitor(""))
end)

test.test("profile tab: Make main and Remove on alts, and Add alt picks with a warning", function()
    local world = newPage(PLAYER)
    world.actions = {}
    local page = world.page
    page.makeMain = function(key) table.insert(world.actions, "main " .. key) end
    page.removeAlt = function(key) table.insert(world.actions, "remove " .. key) end
    page.addAlt = function(key) table.insert(world.actions, "add " .. key) end
    PLAYER.characters[2].canMakeMain = true
    PLAYER.characters[2].canRemove = true
    page.candidates = function(query)
        local all = {
            { key = "bolt", name = "Bolt", coloredName = "Bolt", level = 40, owner = "Thunderer", joins = true,
                warning = "Bolt belongs to Thunderer. Picking it adds Toolbox to Thunderer's characters." },
            { key = "visitor", name = "Visitor", coloredName = "Visitor", level = 80 },
        }
        if query == "vis" then
            return { all[2] }
        end
        return all
    end
    page.panel.hooks.OnShow()

    test.assertFalse(page.rows[1].makeMain.shown)
    test.assertFalse(page.rows[1].remove.shown)
    test.assertTrue(page.rows[2].makeMain.shown)
    page.rows[2].makeMain.scripts.OnClick()
    page.rows[2].remove.scripts.OnClick()
    test.assertEqual("main hammer,remove hammer", table.concat(world.actions, ","))

    page.addAltButton.scripts.OnClick()
    test.assertTrue(page.picker.frame.shown)
    test.assertEqual("Bolt  |cff9d9d9d40|r  |cff9d9d9d(Thunderer)|r", page.picker.results[1].text.text)
    test.assertEqual("Pick a character to add.", page.picker.warning.text)
    page.picker.results[1].button.scripts.OnClick()
    test.assertContains(page.picker.warning.text, "Bolt belongs to Thunderer")
    test.assertEqual("Join", page.picker.add.text)
    page.picker.search:SetText("vis")
    page.picker.search.scripts.OnTextChanged(page.picker.search)
    test.assertFalse(page.picker.results[2].button.shown)
    page.picker.results[1].button.scripts.OnClick()
    test.assertEqual("Add Visitor as an alt.", page.picker.warning.text)
    test.assertEqual("Add", page.picker.add.text)
    page.picker.add.scripts.OnClick()

    test.assertEqual("add visitor", world.actions[3])
    test.assertFalse(page.picker.frame.shown)

    -- Picking another player's character joins that player instead.
    page.join = function(key) table.insert(world.actions, "join " .. key) end
    page.addAltButton.scripts.OnClick()
    page.picker.results[1].button.scripts.OnClick()
    page.picker.add.scripts.OnClick()
    test.assertEqual("join bolt", world.actions[4])
    PLAYER.characters[2].canMakeMain = nil
    PLAYER.characters[2].canRemove = nil
end)

test.test("own characters store: logins are kept per guild, dismissals for good, unreadable entries skipped", function()
    local world = setup()
    local partition = world.partition

    test.assertEqual(0, #partition:OwnCharacters())
    test.assertTrue(partition:RecordOwnCharacter("wrench-area52", START))
    test.assertTrue(partition:RecordOwnCharacter("hammer-area52", START + 5))
    test.assertTrue(partition:RecordOwnCharacter("hammer-area52", START + 9))
    test.assertFalse(partition:RecordOwnCharacter("", START))
    partition.data.ownCharacters["bad-area52"] = "yesterday"
    test.assertEqual("hammer-area52,wrench-area52", table.concat(partition:OwnCharacters(), ","))

    test.assertFalse(partition:IsOwnCharacterDismissed("wrench-area52"))
    test.assertTrue(partition:DismissOwnCharacter("wrench-area52"))
    test.assertTrue(partition:IsOwnCharacterDismissed("wrench-area52"))
end)

test.test("profile view model: suggests this install's other characters that aren't on the player yet", function()
    local world = setup()
    local partition = world.partition
    partition:RecordCharacter("visitor-stormrage", { name = "Visitor-Stormrage", classToken = "MAGE", level = 80 })
    partition:RecordCharacter("bolt-area52", { name = "Bolt-Area52", classToken = "SHAMAN", level = 40 })
    partition:RecordCharacter("spark-area52", { name = "Spark-Area52", classToken = "MAGE", level = 30 })
    partition:JoinPlayerOf("spark-area52", "bolt-area52", "manual")
    -- Toolbox and Hammer are this player's; Wrench left the guild.
    local keys = { "toolbox-area52", "hammer-area52", "wrench-area52", "visitor-stormrage", "spark-area52",
        "bolt-area52" }
    local index
    for index = 1, #keys do
        partition:RecordOwnCharacter(keys[index], START)
    end
    partition:DismissOwnCharacter("bolt-area52")

    local suggested = world.build().suggested

    test.assertEqual(2, #suggested)
    test.assertEqual("spark-area52", suggested[1].key)
    test.assertEqual("Bolt", suggested[1].owner)
    test.assertContains(suggested[1].warning, "Spark belongs to Bolt")
    test.assertEqual("visitor-stormrage", suggested[2].key)
    test.assertEqual("Visitor-Stormrage", suggested[2].name)
    test.assertEqual(nil, suggested[2].owner)
    -- Nothing is linked by suggesting it.
    test.assertTrue(partition:GetCharacter("visitor-stormrage").player
        ~= partition:GetCharacter("toolbox-area52").player)
end)

test.test("profile tab: lists suggested own characters with Add as alt and Dismiss", function()
    local model = {}
    local key, value
    for key, value in pairs(PLAYER) do
        model[key] = value
    end
    model.suggested = {
        { key = "visitor", name = "Visitor", coloredName = "Visitor", level = 80 },
        { key = "spark", name = "Spark", coloredName = "Spark", level = 30, owner = "Bolt" },
    }
    local world = newPage(model)
    world.actions = {}
    local page = world.page
    page.addAlt = function(target) table.insert(world.actions, "add " .. target) end
    page.dismiss = function(target) table.insert(world.actions, "dismiss " .. target) end
    page.panel.hooks.OnShow()

    test.assertEqual("Your other characters on this computer", page.suggestHeading.text)
    test.assertTrue(page.suggestHeading.shown)
    test.assertEqual("Visitor  |cff9d9d9d80|r", page.suggestRows[1].text.text)
    test.assertContains(page.suggestRows[2].text.text, "(belongs to Bolt)")
    page.suggestRows[1].add.scripts.OnClick()
    page.suggestRows[2].dismiss.scripts.OnClick()
    test.assertEqual("add visitor,dismiss spark", table.concat(world.actions, ","))

    -- None left: the section goes away.
    world.model = PLAYER
    page:Refresh()
    test.assertFalse(page.suggestHeading.shown)
    test.assertFalse(page.suggestRows[1].frame.shown)
end)

-- /agf profile in the composed add-on ------------------------------------------

-- The add-on logged in, with a master frame recording its page. On its
-- first build My Profile is drawn on a fake tab: `world.profileTab`, with
-- the page drawn on it in `world.profilePage`.
local function loggedIn(profile, playerName, database)
    local world = fixtures.newEnvironment(profile, { playerName = playerName, database = database })
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

    test.test(profile .. " My Profile's About me saves to the player and goes to the guild", function()
        local world, addon = loggedIn(profile)
        local page = openProfile(world)
        local selfKey = addon.rosterController:SelfKey()
        world.sentMessages = {}

        local bio = page.aboutRows[4]
        bio.box:SetText("Raids on Fridays")
        bio.box.scripts.OnEnterPressed(bio.box)

        local _, partition = addon.rosterController:QuietContext()
        test.assertEqual("Raids on Fridays", partition:GetProfileText(selfKey, "bio"))
        test.assertEqual("Raids on Fridays", page.aboutRows[4].box.text)
        local sent = world.sentMessages[#world.sentMessages]
        local _, message = world.environment.LibStub.libs["AceSerializer-3.0"]:Deserialize(sent.text)
        test.assertEqual("bio", message.facts[1].kind)
        test.assertEqual(selfKey, message.facts[1].by)
    end)

    test.test(profile .. " an officer's identity edits on My Profile are official at once", function()
        local world, addon = loggedIn(profile)
        local page = openProfile(world)
        local selfKey = addon.rosterController:SelfKey()
        local _, partition = addon.rosterController:QuietContext()
        local alt = page.rows[2].key
        local function playerOf(key)
            return partition:GetPlayer(partition:GetCharacter(key).player)
        end

        page.rows[2].makeMain.scripts.OnClick()
        test.assertEqual(alt, playerOf(selfKey).main)
        -- The page shows it at once: the alt is now first.
        test.assertEqual(alt, page.rows[1].key)

        local alias = page.aboutRows[1]
        alias.box:SetText("Tools")
        alias.box.scripts.OnEnterPressed(alias.box)
        test.assertEqual("Tools", playerOf(selfKey).alias)
        test.assertContains(page.heading.text, "Tools (")

        -- The third guild member joins, then the first alt is removed.
        page.addAltButton.scripts.OnClick()
        page.picker.results[1].button.scripts.OnClick()
        local added = page.picker.results[1].candidate.key
        page.picker.add.scripts.OnClick()
        test.assertEqual(playerOf(selfKey), playerOf(added))
        test.assertEqual(3, #partition:CharactersOf(partition:GetCharacter(selfKey).player))

        -- An alt other than the logged-in character.
        local row
        local index
        for index = 2, #page.rows do
            if page.rows[index].frame.shown and page.rows[index].key ~= selfKey then
                row = page.rows[index]
            end
        end
        local removed = row.key
        row.remove.scripts.OnClick()
        test.assertTrue(playerOf(removed) ~= playerOf(selfKey))
        -- None of it waits for anyone.
        test.assertEqual(0, #addon.syncSession:Suggestions(partition):Pending())
    end)

    test.test(profile .. " a member's identity edits on My Profile apply here and wait as suggestions", function()
        local member = profile == "Forever" and "Hammer Smith" or "Hammer-Area52"
        local world, addon = loggedIn(profile, member)
        local page = openProfile(world)
        local selfKey = addon.rosterController:SelfKey()
        local _, partition = addon.rosterController:QuietContext()

        -- Hammer is Toolbox's alt: it makes itself the main.
        test.assertTrue(page.rows[1].key ~= selfKey)
        local self
        local index
        for index = 1, #page.rows do
            if page.rows[index].key == selfKey then
                self = page.rows[index]
            end
        end
        self.makeMain.scripts.OnClick()

        test.assertEqual(selfKey, partition:GetPlayer(partition:GetCharacter(selfKey).player).main)
        test.assertTrue(#addon.syncSession:Suggestions(partition):Pending() > 0)
    end)

    test.test(profile .. " My Profile suggests another character this install logged in on, linked only when asked", function()
        local loner = profile == "Forever" and "Zélie Rune" or "Visitor-Stormrage"
        local first = loggedIn(profile, loner)
        -- The same game install (saved data), now on the first member.
        local world, addon = loggedIn(profile, nil, first.database)
        local page = openProfile(world)
        local _, partition = addon.rosterController:QuietContext()
        local selfKey = addon.rosterController:SelfKey()
        local lonerKey = page.suggestRows[1].key

        test.assertEqual("Your other characters on this computer", page.suggestHeading.text)
        test.assertTrue(partition:GetCharacter(lonerKey).player ~= partition:GetCharacter(selfKey).player)
        -- Logins are never synced.
        local sent = table.concat((function()
            local texts = {}
            local index
            for index = 1, #world.sentMessages do
                texts[index] = world.sentMessages[index].text
            end
            return texts
        end)(), "\n")
        test.assertEqual(nil, string.find(sent, "ownCharacters", 1, true))

        page.suggestRows[1].add.scripts.OnClick()
        test.assertEqual(partition:GetCharacter(selfKey).player, partition:GetCharacter(lonerKey).player)
        -- Linked now, so no longer suggested.
        test.assertFalse(page.suggestRows[1].frame.shown)
    end)

    test.test(profile .. " a second login on this install is recorded even when no scan runs", function()
        local alt = profile == "Forever" and "Hammer Smith" or "Hammer-Area52"
        local first = loggedIn(profile)
        -- Same install, soon after: the daily scan doesn't run again, and
        -- the roster has nobody new, so no scan finishes.
        local _, addon = loggedIn(profile, alt, first.database)
        local _, partition = addon.rosterController:QuietContext()

        test.assertContains(table.concat(partition:OwnCharacters(), ","), addon.rosterController:SelfKey())
        test.assertEqual(2, #partition:OwnCharacters())
    end)

    test.test(profile .. " a dismissed own character stays hidden on this install", function()
        local loner = profile == "Forever" and "Zélie Rune" or "Visitor-Stormrage"
        local first = loggedIn(profile, loner)
        local world = loggedIn(profile, nil, first.database)
        local page = openProfile(world)

        page.suggestRows[1].dismiss.scripts.OnClick()
        test.assertFalse(page.suggestHeading.shown)

        local again = loggedIn(profile, nil, world.database)
        test.assertFalse(openProfile(again).suggestHeading.shown)
    end)

    test.test(profile .. " Declare as my main declares the player's main and then goes away", function()
        local world, addon = loggedIn(profile)
        local page = openProfile(world)
        local _, partition = addon.rosterController:QuietContext()
        local main = page.rows[1].key
        test.assertTrue(page.declareButton.shown)

        page.declareButton.scripts.OnClick()

        test.assertTrue(partition:IsDeclared(main))
        test.assertFalse(page.declareButton.shown)
        test.assertContains(page.rows[1].name.text, "declared main")
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
