local test = require("tests.test_helper")

-- A client's Menu system that keeps each tag's callback, and a menu
-- description that records what's added to it.
local function fakeMenu()
    local menu = { callbacks = {} }
    function menu.ModifyMenu(tag, callback)
        menu.callbacks[tag] = callback
    end
    return menu
end

local function description()
    local root = { buttons = {}, dividers = 0 }
    function root:CreateButton(text, onClick)
        table.insert(self.buttons, { text = text, onClick = onClick })
    end
    function root:CreateDivider()
        self.dividers = self.dividers + 1
    end
    return root
end

local function setup(environment)
    local addon = test.newAddon("Adapters/GameMenu.lua")
    local world = { opened = {} }
    world.menus = addon.GameMenu.Create(environment, {
        resolve = function(name)
            if name == "Bolt-Area52" or name == "Bolt" then
                return "bolt-area52"
            end
            return nil
        end,
        onOpen = function(key)
            table.insert(world.opened, key)
        end,
    })
    world.addon = addon
    return world
end

test.test("game menu: without the Menu system nothing is added and nothing is raised", function()
    local world = setup({})

    test.assertEqual(0, #world.menus:Install())
    test.assertEqual("Menu system: no (nothing is added to the game's right-click menus)",
        world.menus:ProbeLines()[1])
    test.assertEqual("Menus with Open in Guild Fellowship: none", world.menus:ProbeLines()[2])

    -- A Menu table without ModifyMenu is the same.
    world = setup({ Menu = {} })
    test.assertEqual(0, #world.menus:Install())
end)

test.test("game menu: the unit menus are extended once, and the probe names them", function()
    local menu = fakeMenu()
    local world = setup({ Menu = menu })

    local extended = world.menus:Install()
    test.assertEqual(#world.addon.GameMenu.TAGS, #extended)
    test.assertTrue(menu.callbacks.MENU_UNIT_PLAYER ~= nil)
    test.assertTrue(menu.callbacks.MENU_UNIT_GUILD ~= nil)
    test.assertEqual(#extended, #world.menus:Install())
    test.assertEqual("Menu system: yes", world.menus:ProbeLines()[1])
    test.assertTrue(string.find(world.menus:ProbeLines()[2], "MENU_UNIT_RAID_PLAYER", 1, true) ~= nil)
end)

test.test("game menu: only a guildmate's menu gets Open in Guild Fellowship, which opens their character", function()
    local menu = fakeMenu()
    local world = setup({ Menu = menu })
    world.menus:Install()

    local root = description()
    menu.callbacks.MENU_UNIT_FRIEND(nil, root, { name = "Bolt", server = "Area52" })
    test.assertEqual(1, #root.buttons)
    test.assertEqual("Open in Guild Fellowship", root.buttons[1].text)
    test.assertEqual(1, root.dividers)
    root.buttons[1].onClick()
    test.assertEqual("bolt-area52", world.opened[1])

    local stranger = description()
    menu.callbacks.MENU_UNIT_FRIEND(nil, stranger, { name = "Zed", server = "Area52" })
    test.assertEqual(0, #stranger.buttons)
    -- Nothing to go on: nothing added, nothing raised.
    local empty = description()
    menu.callbacks.MENU_UNIT_PLAYER(nil, empty, nil)
    menu.callbacks.MENU_UNIT_PLAYER(nil, nil, { name = "Bolt" })
    test.assertEqual(0, #empty.buttons)
end)

test.test("game menu: a unit's menu names the player through UnitName", function()
    local menu = fakeMenu()
    local world = setup({
        Menu = menu,
        UnitName = function(unit)
            if unit == "target" then
                return "Bolt", nil
            end
            return "Zed", "Elsewhere"
        end,
    })
    world.menus:Install()

    local root = description()
    menu.callbacks.MENU_UNIT_TARGET(nil, root, { unit = "target" })
    test.assertEqual(1, #root.buttons)
    local other = description()
    menu.callbacks.MENU_UNIT_PARTY(nil, other, { unit = "party1" })
    test.assertEqual(0, #other.buttons)

    test.assertEqual("Zed-Elsewhere", world.addon.GameMenu.NameOf({ UnitName = function()
        return "Zed", "Elsewhere"
    end }, { unit = "party1" }))
    test.assertEqual("Bolt-Area52", world.addon.GameMenu.NameOf({}, { name = "Bolt-Area52", server = "Other" }))
end)
