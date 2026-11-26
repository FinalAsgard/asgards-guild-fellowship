local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local fakeFrames = require("tests.fake_frames")

local contains = fakeFrames.contains

-- The theme and widgets ------------------------------------------------------

local function loadUi()
    return test.newAddon("Adapters/Theme.lua", "Adapters/Widgets.lua", "Adapters/AgfWindow.lua")
end

test.test("agf window: the bundled fonts are registered with LibSharedMedia, from the add-on's own folder", function()
    local addon = loadUi()
    local registered = {}
    local media = {
        Register = function(_, kind, name, path)
            registered[name] = { kind = kind, path = path }
        end,
    }

    test.assertTrue(addon.Theme.Register(media))

    test.assertEqual("font", registered.Inter.kind)
    test.assertEqual("Interface\\AddOns\\AsgardsGuildFellowship\\Media\\Fonts\\Inter-Regular.ttf",
        registered.Inter.path)
    test.assertTrue(registered["Inter SemiBold"] ~= nil)
    -- No library, or one without Register: nothing to do, and no error.
    test.assertFalse(addon.Theme.Register(nil))
    test.assertFalse(addon.Theme.Register({}))
end)

test.test("agf window: every font and texture the theme names ships in Media", function()
    local addon = loadUi()
    local function shipped(path, extension)
        local relative = string.gsub(string.gsub(path, "^Interface\\AddOns\\AsgardsGuildFellowship\\", ""), "\\", "/")
        local handle = io.open(relative .. (extension or ""), "rb")
        if handle ~= nil then
            handle:close()
        end
        return handle ~= nil
    end
    local style, path
    for style, path in pairs(addon.Theme.FONTS) do
        test.assertTrue(shipped(path), style .. " font is in Media")
    end
    for style, path in pairs(addon.Theme.TEXTURES) do
        if string.find(path, "^Interface\\AddOns\\") then
            test.assertTrue(shipped(path, ".tga"), style .. " texture is in Media")
        end
    end
end)

test.test("agf window: widgets draw on fake frames and keep their state", function()
    local addon = loadUi()
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local page = environment.CreateFrame("Frame")

    local picked
    local segmented = ui:Segmented(page, { { id = "dungeon", label = "Dungeon" }, { id = "raid", label = "Raid" } },
        200, function(id)
            picked = id
        end)
    test.assertEqual("dungeon", segmented:Selected())
    segmented.buttons[2].scripts.OnClick(segmented.buttons[2])
    test.assertEqual("raid", picked)
    test.assertEqual("raid", segmented:Selected())

    local tabs = ui:Tabs(page, { { id = "relevant", label = "Relevant Parties" }, { id = "other", label = "Other" } })
    tabs:SetLabel("relevant", "Relevant Parties · 3")
    test.assertTrue(contains(page.texts, "Relevant Parties · 3"))
    tabs.tabs[2].scripts.OnClick(tabs.tabs[2])
    test.assertEqual("other", tabs:Selected())
    -- Tabs are buttons: the selected one green, the others the surface.
    test.assertEqual("green", tabs.tabs[2].fillColor)
    test.assertEqual("surface", tabs.tabs[1].fillColor)
    tabs.tabs[1].scripts.OnEnter(tabs.tabs[1])
    test.assertEqual("hover", tabs.tabs[1].fillColor)
    tabs.tabs[2].scripts.OnEnter(tabs.tabs[2])
    test.assertEqual("green", tabs.tabs[2].fillColor)

    local wanted
    local switch = ui:Toggle(page, function(on)
        wanted = on
    end)
    switch.scripts.OnClick(switch)
    test.assertTrue(wanted)
    -- The owner decides what's saved; the switch shows only that.
    test.assertFalse(switch:IsOn())
    switch:SetOn(true)
    test.assertTrue(switch:IsOn())

    local note = ui:TextInput(page, 300, 60)
    test.assertTrue(contains(page.texts, "0/60"))
    note.box:SetText("3 bosses down")
    note.box.scripts.OnTextChanged(note.box, true)
    test.assertTrue(contains(page.texts, "13/60"))

    local badge = ui:CountBadge(page)
    test.assertFalse(badge.shown)
    badge:SetCount(2)
    test.assertTrue(badge.shown)
    test.assertEqual("2", badge.text.text)

    local clicked = 0
    local primary = ui:Button(page, "Start a group", "primary", function()
        clicked = clicked + 1
    end)
    primary.scripts.OnClick(primary)
    primary:SetActive(false)
    primary.scripts.OnClick(primary)
    test.assertEqual(1, clicked)

    local tile = ui:RoleTile(page, "healer", 40)
    tile:SetFilled(true)
    test.assertTrue(tile.filled)
    -- The role's name, until a small tile shows its icon instead.
    test.assertEqual("Healer", tile.label.text)
    test.assertFalse(tile.icon.shown)
    tile:ShowIcon()
    test.assertEqual("", tile.label.text)
    test.assertTrue(tile.icon.shown)
    test.assertTrue(ui:RoleTile(page, "any", 12).icon.shown)

    local glow = ui:Glow(page)
    glow:SetGlow("gold")
    test.assertTrue(glow.texture.shown)
    glow:Pulse()
    glow:SetGlow(nil)
    test.assertFalse(glow.texture.shown)

    local chosen
    local menu = ui:ContextMenu(page)
    menu:Open(page, { { label = "Open Guild LFG Board", onClick = function() chosen = "open" end },
        { label = "Hide LFG button", onClick = function() chosen = "hide" end } })
    test.assertTrue(menu:IsOpen())
    test.assertFalse(menu.title.shown)
    test.assertFalse(menu.divider.shown)
    menu.rows[2].scripts.OnClick(menu.rows[2])
    test.assertEqual("hide", chosen)
    test.assertFalse(menu:IsOpen())
    -- A title heads the items, with a line under it.
    menu:Open(page, { { label = "Whisper", onClick = function() chosen = "whisper" end } }, "Hammer")
    test.assertTrue(menu.title.shown)
    test.assertEqual("Hammer", menu.title.text)
    test.assertTrue(menu.divider.shown)
    test.assertFalse(menu.rows[2].shown)
    menu.rows[1].scripts.OnClick(menu.rows[1])
    test.assertEqual("whisper", chosen)
    -- Hidden with its window rather than closed: its catcher goes too, so
    -- it never eats the next click.
    menu:Open(page, { { label = "Whisper", onClick = function() end } }, "Hammer")
    test.assertTrue(menu.catcher.shown)
    menu.scripts.OnHide(menu)
    test.assertFalse(menu:IsOpen())
    test.assertFalse(menu.catcher.shown)
end)

test.test("agf window: a UTF-8 note counts characters, not bytes", function()
    local addon = loadUi()

    test.assertEqual(5, addon.Widgets.Length("Hello"))
    test.assertEqual(4, addon.Widgets.Length("Æsir"))
    test.assertEqual(0, addon.Widgets.Length(nil))
end)

-- The window -----------------------------------------------------------------

-- A window over fake frames with an LFG module and one Chat tags switch on a
-- settings model whose value lives in `state.tags`.
local function newWindow()
    local addon = test.newAddon("Core/SettingsModel.lua", "Adapters/Theme.lua", "Adapters/Widgets.lua",
        "Adapters/AgfWindow.lua")
    local environment = fakeFrames.install({ UISpecialFrames = {} })
    local state = { tags = true, saved = nil, printed = {} }
    local settings = addon.SettingsModel.Create()
    settings:AddSection("chatTags", "Chat Tags")
    settings:Add("chatTags", { id = "chatTags", kind = "toggle", label = "Tag guild chat speakers",
        get = function() return state.tags end,
        set = function(enabled)
            state.tags = enabled
            return true
        end })
    state.aliasColor = "4a90ff"
    settings:Add("chatTags", { id = "chatTagColor:alias", kind = "color", label = "Alias tag color",
        sample = "[TheTool]", swatches = { { label = "Blue", color = "4a90ff" }, { label = "Gold", color = "ffd100" } },
        get = function() return state.aliasColor end,
        set = function(color)
            state.aliasColor = color
            return true
        end })
    local client = {
        environment = environment,
        Print = function(_, message)
            table.insert(state.printed, message)
        end,
    }
    local window = addon.AgfWindow.Create(client, {
        frameName = "AgfTestWindow",
        modules = { { id = "lfg", label = "LFG", title = "Guild LFG Board" } },
        settings = settings,
        settingsTabs = { { id = "chat", label = "Chat",
            rows = { { id = "chatTags", label = "Chat tags", info = "Tag speakers." },
                { id = "chatTagColor:alias", label = "Alias tag color", info = "The alias tag's color." } } } },
        character = function()
            return { name = "Hammer", level = 24, className = "Paladin", classColor = "fff58cba" }
        end,
        version = "1.2.3",
        loadPosition = function()
            return state.position
        end,
        savePosition = function(position)
            state.saved = position
        end,
    })
    return addon, window, environment, settings, state
end

test.test("agf window: opens on the LFG page, titled Guild LFG Board, with the sidebar filled in", function()
    local _, window, environment = newWindow()

    test.assertTrue(window:Open("lfg"))

    test.assertTrue(window:IsOpen())
    test.assertEqual("lfg", window:Page())
    local texts = environment.pages[1].texts
    test.assertTrue(contains(texts, "Guild LFG Board"))
    test.assertTrue(contains(texts, "Asgard's Guild Fellowship"))
    test.assertTrue(contains(texts, "LFG"))
    test.assertTrue(contains(texts, "Settings"))
    test.assertTrue(contains(texts, "|cfff58cbaHammer|r"))
    test.assertTrue(contains(texts, "Level 24 Paladin"))
    test.assertTrue(contains(texts, "Version 1.2.3"))
    test.assertTrue(window.pages.lfg.shown)
    test.assertFalse(window.pages.settings.shown)
    -- Each sidebar button is its own fill, so nothing draws over its label.
    local index
    for index = 1, #window.moduleButtons do
        test.assertTrue(rawget(window.moduleButtons[index], "fillShape") ~= nil)
    end
    -- Escape closes it.
    test.assertEqual("AgfTestWindow", environment.UISpecialFrames[1])

    window.close.scripts.OnClick(window.close)
    test.assertFalse(window:IsOpen())
end)

test.test("agf window: the gear toggles the module's popup; a click elsewhere closes it", function()
    local _, window = newWindow()
    window:Open("lfg")

    window.gear.scripts.OnClick(window.gear)
    test.assertTrue(window:SettingsPopupOpen())
    test.assertEqual("LFG", window:SettingsPopupTitle())
    test.assertTrue(window.popup.shown)

    window.gear.scripts.OnClick(window.gear)
    test.assertFalse(window:SettingsPopupOpen())
    test.assertFalse(window.popup.shown)

    -- A click anywhere else in the window lands on the catcher.
    window.gear.scripts.OnClick(window.gear)
    window.catcher.scripts.OnClick(window.catcher)
    test.assertFalse(window:SettingsPopupOpen())

    -- Closing the window closes it too.
    window.gear.scripts.OnClick(window.gear)
    window:Close()
    test.assertFalse(window:SettingsPopupOpen())
end)

test.test("agf window: switching modules keeps the popup open and retitled; Settings closes it", function()
    local addon = test.newAddon("Core/SettingsModel.lua", "Adapters/Theme.lua", "Adapters/Widgets.lua",
        "Adapters/AgfWindow.lua")
    local environment = fakeFrames.install({})
    local window = addon.AgfWindow.Create({ environment = environment }, {
        modules = { { id = "lfg", label = "LFG", title = "Guild LFG Board" },
            { id = "roster", label = "Roster", title = "Roster" } },
        settings = addon.SettingsModel.Create(),
        settingsTabs = {},
    })
    window:Open("lfg")
    window:ToggleSettingsPopup()

    window.moduleButtons[2].scripts.OnClick(window.moduleButtons[2])
    test.assertEqual("roster", window:Page())
    test.assertTrue(window:SettingsPopupOpen())
    test.assertEqual("Roster", window:SettingsPopupTitle())

    local settingsButton = window.moduleButtons[#window.moduleButtons]
    settingsButton.scripts.OnClick(settingsButton)
    test.assertEqual("settings", window:Page())
    test.assertFalse(window:SettingsPopupOpen())
    test.assertFalse(window.gear.shown)
end)

test.test("agf window: the Settings page's Chat tags switch round-trips the shared setting", function()
    local _, window, environment, settings, state = newWindow()
    window:Open("settings")
    local switch = window:Switches("chatTags")[1]

    test.assertTrue(contains(environment.pages[1].texts, "Chat"))
    test.assertTrue(contains(environment.pages[1].texts, "Chat tags"))
    test.assertTrue(switch:IsOn())

    switch.scripts.OnClick(switch)
    test.assertFalse(state.tags)
    test.assertFalse(switch:IsOn())

    -- Changed elsewhere (/agf tags or the old window): the switch follows.
    settings:Toggle("chatTags")
    test.assertTrue(state.tags)
    test.assertTrue(switch:IsOn())
end)

test.test("agf window: the Settings page's Chat tab sets a tag's color from its swatches", function()
    local _, window, environment, settings, state = newWindow()
    window:Open("settings")
    local card = window.colorRows["chatTagColor:alias"][1]

    test.assertTrue(contains(environment.pages[1].texts, "Alias tag color"))
    -- The sample in the saved color, that swatch outlined.
    test.assertEqual("|cff4a90ff[TheTool]|r", card.sample.text)
    test.assertTrue(card.swatches[1].selected)
    test.assertFalse(card.swatches[2].selected)

    card.swatches[2].scripts.OnClick(card.swatches[2])
    test.assertEqual("ffd100", state.aliasColor)
    test.assertEqual("|cffffd100[TheTool]|r", card.sample.text)
    test.assertTrue(card.swatches[2].selected)
    test.assertFalse(card.swatches[1].selected)

    -- Changed elsewhere (the old window): the row follows.
    settings:Set("chatTagColor:alias", "4a90ff")
    test.assertTrue(card.swatches[1].selected)
    -- Without the game's color picker there's no Custom... button.
    test.assertEqual(nil, rawget(card, "custom"))
end)

test.test("agf window: Custom... picks any color with the game's color picker, and cancel puts it back", function()
    local _, window, environment, _, state = newWindow()
    local picker = { rgb = { 0, 0, 0 } }
    function picker.SetupColorPickerAndShow(_, info)
        picker.info = info
    end
    function picker.GetColorRGB()
        return picker.rgb[1], picker.rgb[2], picker.rgb[3]
    end
    environment.ColorPickerFrame = picker
    window:Open("settings")
    local card = window.colorRows["chatTagColor:alias"][1]
    test.assertTrue(card.custom ~= nil)

    card.custom.scripts.OnClick(card.custom)
    -- It opens on the saved color.
    test.assertEqual(0x4a / 255, picker.info.r)
    test.assertEqual(0xff / 255, picker.info.b)
    -- A color picked is saved as it changes, none of the swatches outlined.
    picker.rgb = { 1, 0.5, 0 }
    picker.info.swatchFunc()
    test.assertEqual("ff8000", state.aliasColor)
    test.assertEqual("|cffff8000[TheTool]|r", card.sample.text)
    test.assertFalse(card.swatches[1].selected)
    -- Cancelled: the color it started with comes back.
    picker.info.cancelFunc()
    test.assertEqual("4a90ff", state.aliasColor)
    test.assertTrue(card.swatches[1].selected)
end)

test.test("agf window: it's moved and saved, and opens where it was left", function()
    local _, window, _, _, state = newWindow()
    state.position = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = 100, y = 700 }
    window:Open("lfg")

    -- It's placed where it was saved.
    local placed = {}
    window.frame.SetPoint = function(_, point, _, relativePoint, x, y)
        table.insert(placed, { point = point, relativePoint = relativePoint, x = x, y = y })
    end
    window:place()
    test.assertEqual(1, #placed)
    test.assertEqual("TOPLEFT", placed[1].point)
    test.assertEqual("BOTTOMLEFT", placed[1].relativePoint)
    test.assertEqual(100, placed[1].x)
    test.assertEqual(700, placed[1].y)

    window.frame.GetPoint = function()
        return "TOPLEFT", nil, "BOTTOMLEFT", 120, 680
    end
    window.frame.scripts.OnDragStop(window.frame)

    test.assertEqual("TOPLEFT", state.saved.point)
    test.assertEqual("BOTTOMLEFT", state.saved.relativePoint)
    test.assertEqual(120, state.saved.x)
    test.assertEqual(680, state.saved.y)
end)

test.test("agf window: a window that fails to build reports why instead of raising", function()
    local addon = loadUi()
    local window = addon.AgfWindow.Create({ environment = { CreateFrame = function() error("no frames") end } },
        { modules = { { id = "lfg", label = "LFG" } } })

    local opened, failure = window:Open("lfg")

    test.assertFalse(opened)
    test.assertContains(failure, "no frames")
    test.assertFalse(window:IsOpen())
end)

-- Saved per character ---------------------------------------------------------

test.test("agf window: its position is saved per character, and an unusable one is ignored", function()
    local addon = test.newAddon("Core/NameNormalizer.lua", "Core/FellowshipStore.lua")
    local database = {}
    local store = addon.FellowshipStore.Create(database)
    local position = { point = "CENTER", relativePoint = "CENTER", x = 10, y = -20 }

    test.assertEqual(nil, store:WindowPosition("Hammer-Camelot"))
    test.assertTrue(store:SetWindowPosition("Hammer-Camelot", position))
    test.assertEqual(10, store:WindowPosition("Hammer-Camelot").x)
    test.assertEqual(nil, store:WindowPosition("Anvil-Camelot"))
    test.assertFalse(store:SetWindowPosition("Hammer-Camelot", { point = "CENTER" }))

    database.characterLayout["Anvil-Camelot"] = { window = { point = 3 } }
    test.assertEqual(nil, store:WindowPosition("Anvil-Camelot"))
end)

-- The composed add-on ----------------------------------------------------------

local function registerProfileTests(profile)
    test.test(profile .. " /agf lfg opens the new window on the Guild LFG Board, and help lists it", function()
        local world = fixtures.newEnvironment(profile)
        local addon = fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fakeFrames.install(world.environment)

        fixtures.slash(world, "help")
        local help = table.concat(world.messages, "\n")
        test.assertContains(help, "/agf lfg - show the LFG button and open the Guild LFG Board")
        test.assertContains(help, "/agf dnd - turn Do Not Disturb on or off")
        -- The Group Finder and its command are gone.
        test.assertFalse(string.find(help, "/agf group", 1, true) ~= nil)
        fixtures.slash(world, "group")
        test.assertContains(world.messages[#world.messages], "Unknown command 'group'")

        fixtures.slash(world, "lfg")
        test.assertTrue(addon.agfWindow:IsOpen())
        test.assertEqual("lfg", addon.agfWindow:Page())
        test.assertTrue(contains(world.environment.pages[1].texts, "Guild LFG Board"))
    end)

    test.test(profile .. " the new window's Chat tags switch agrees with /agf tags", function()
        local world = fixtures.newEnvironment(profile)
        local addon = fixtures.loadAddon(world)
        fixtures.fire(world, "ADDON_LOADED", world.addonName)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")
        fakeFrames.install(world.environment)
        addon.agfWindow:Open("settings")
        local switch = addon.agfWindow:Switches("chatTags")[1]
        local before = addon.settings:Get("chatTags")
        test.assertEqual(before, switch:IsOn())

        fixtures.slash(world, "tags")
        test.assertEqual(not before, switch:IsOn())

        switch.scripts.OnClick(switch)
        test.assertEqual(before, addon.settings:Get("chatTags"))
        test.assertEqual(before, switch:IsOn())
    end)
end

local index
for index = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[index])
end

test.test("agf window: a module's header switch agrees with its setting, and shows only on that module", function()
    local addon = test.newAddon("Core/SettingsModel.lua", "Adapters/Theme.lua", "Adapters/Widgets.lua",
        "Adapters/AgfWindow.lua")
    local environment = fakeFrames.install({})
    local state = { on = true }
    local settings = addon.SettingsModel.Create()
    settings:AddSection("guildGreet", "Guild Greet")
    settings:Add("guildGreet", { id = "guildGreet", kind = "toggle", label = "Show greet prompts",
        get = function() return state.on end,
        set = function(enabled)
            state.on = enabled
            return true
        end })
    local window = addon.AgfWindow.Create({ environment = environment }, {
        modules = { { id = "lfg", label = "LFG", title = "Guild LFG Board" },
            { id = "greetings", label = "Greetings", title = "Greetings",
                headerSwitch = { id = "guildGreet", label = "Greet prompts", on = "Greet prompts on",
                    off = "Greet prompts off" } } },
        settings = settings,
        settingsTabs = {},
    })
    window:Open("lfg")
    local header = window:HeaderSwitch("greetings")

    test.assertEqual(nil, window:HeaderSwitch("lfg"))
    test.assertFalse(header.frame.shown)
    window:ShowPage("greetings")
    test.assertTrue(header.frame.shown)
    test.assertTrue(header.switch:IsOn())
    test.assertEqual("Greet prompts on", header.label.text)

    header.switch.scripts.OnClick(header.switch)
    test.assertFalse(state.on)
    test.assertFalse(header.switch:IsOn())
    test.assertEqual("Greet prompts off", header.label.text)

    -- Changed elsewhere (the AddOns options or a slash command): it follows.
    settings:Set("guildGreet", true)
    test.assertTrue(header.switch:IsOn())
    test.assertEqual("Greet prompts on", header.label.text)

    window:ShowPage("settings")
    test.assertFalse(header.frame.shown)
end)

test.test("agf window: a multiline input folds line breaks, caps bytes at a whole letter, and grows to its most lines", function()
    local addon = loadUi()
    local environment = fakeFrames.install({})
    local ui = addon.Widgets.Create(environment)
    local page = environment.CreateFrame("Frame")
    local typed, entered, escaped = {}, 0, 0
    local input = ui:TextInput(page, 300, 255, function(text)
        table.insert(typed, text)
    end, { multiline = true, maxBytes = 10, onEnter = function()
        entered = entered + 1
    end, onEscape = function()
        escaped = escaped + 1
    end })
    local box = input.box
    local function typeText(text)
        box:SetText(text)
        box.scripts.OnTextChanged(box, true)
        -- A real box runs OnTextChanged again after the add-on's SetText.
        if box:GetText() ~= text then
            box.scripts.OnTextChanged(box, false)
        end
    end

    test.assertTrue(rawget(box, "multiLine"))
    test.assertEqual("0/255", input.counter.text)
    typeText("Hi\nthere")
    test.assertEqual("Hi there", box:GetText())
    -- What's handed on is the folded text.
    test.assertEqual("Hi there", typed[#typed])
    test.assertEqual("8/255", input.counter.text)
    -- é is two bytes: the cap stops before a letter that won't fit whole.
    typeText("Héllo wörld")
    test.assertEqual("Héllo wö", box:GetText())
    test.assertEqual("8/255", input.counter.text)

    box.scripts.OnEnterPressed(box)
    box.scripts.OnEscapePressed(box)
    test.assertEqual(1, entered)
    test.assertEqual(1, escaped)

    test.assertEqual(1, addon.Widgets.LinesFor(nil, 16, 4))
    test.assertEqual(1, addon.Widgets.LinesFor(15, 16, 4))
    test.assertEqual(2, addon.Widgets.LinesFor(32, 16, 4))
    test.assertEqual(4, addon.Widgets.LinesFor(200, 16, 4))
    test.assertEqual("ab", addon.Widgets.CutBytes("abé", 3))
end)
