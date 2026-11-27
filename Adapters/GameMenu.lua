local _, addon = ...

-- Adds "Open in Guild Fellowship" to the game's own right-click menus on a
-- player: chat names, the target, party and raid frames, and the guild
-- roster. It shows only when the clicked name is a known in-guild
-- character, and opens the AGF window on that player.
--
-- Best guess (to confirm in game with /agf probe menu): both clients build
-- these menus with the Menu system, where Menu.ModifyMenu(tag, callback)
-- runs `callback(owner, rootDescription, contextData)` each time the menu
-- with that tag opens, and rootDescription:CreateButton(text, onClick) adds
-- an entry. contextData carries the clicked `name` and `server`, or a
-- `unit`. The tags below are the unit menus' names. A client without
-- Menu.ModifyMenu gets nothing added, quietly.
local GameMenu = {
    LABEL = "Open in Guild Fellowship",
    TAGS = {
        "MENU_UNIT_PLAYER",
        "MENU_UNIT_TARGET",
        "MENU_UNIT_FRIEND",
        "MENU_UNIT_PARTY",
        "MENU_UNIT_RAID",
        "MENU_UNIT_RAID_PLAYER",
        "MENU_UNIT_GUILD",
        "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    },
}
addon.GameMenu = GameMenu

local Menus = {}
Menus.__index = Menus

-- options:
--   resolve  function(name) -> the character key when `name` ("Name" or
--            "Name-Realm") is a known in-guild character, else nil
--   onOpen   function(key): the entry was chosen for that character
function GameMenu.Create(environment, options)
    return setmetatable({ environment = environment, options = options, extended = {} }, Menus)
end

-- The clicked player's name, "Name-Realm" when the menu names a realm.
function GameMenu.NameOf(environment, contextData)
    if type(contextData) ~= "table" then
        return nil
    end
    local name, server = contextData.name, contextData.server
    if (type(name) ~= "string" or name == "") and type(contextData.unit) == "string"
        and type(environment.UnitName) == "function"
    then
        local ok, unitName, unitServer = pcall(environment.UnitName, contextData.unit)
        if ok then
            name, server = unitName, unitServer
        end
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if type(server) == "string" and server ~= "" and string.find(name, "-", 1, true) == nil then
        return name .. "-" .. server
    end
    return name
end

-- Adds the entry to every menu the client has. Returns the tags extended
-- (none without the Menu system); a second call adds nothing more.
function Menus:Install()
    if self.installed then
        return self.extended
    end
    self.installed = true
    local menu = self.environment.Menu
    if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then
        return self.extended
    end
    local owner = self
    local index
    for index = 1, #GameMenu.TAGS do
        local tag = GameMenu.TAGS[index]
        local ok = pcall(menu.ModifyMenu, tag, function(_, rootDescription, contextData)
            owner:extend(rootDescription, contextData)
        end)
        if ok then
            table.insert(self.extended, tag)
        end
    end
    return self.extended
end

-- Adds the entry to one opening menu, for a guildmate only.
function Menus:extend(rootDescription, contextData)
    pcall(function()
        local name = GameMenu.NameOf(self.environment, contextData)
        local key = name and self.options.resolve(name) or nil
        if key == nil or type(rootDescription) ~= "table" or type(rootDescription.CreateButton) ~= "function" then
            return
        end
        if type(rootDescription.CreateDivider) == "function" then
            rootDescription:CreateDivider()
        end
        rootDescription:CreateButton(GameMenu.LABEL, function()
            self.options.onOpen(key)
        end)
    end)
end

-- What /agf probe menu prints: whether the client has the Menu system and
-- which menus got the entry.
function Menus:ProbeLines()
    local menu = self.environment.Menu
    local lines = {}
    table.insert(lines, "Menu system: " .. ((type(menu) == "table" and type(menu.ModifyMenu) == "function")
        and "yes" or "no (nothing is added to the game's right-click menus)"))
    table.insert(lines, "Menus with " .. GameMenu.LABEL .. ": " ..
        (self.extended[1] ~= nil and table.concat(self.extended, ", ") or "none"))
    return lines
end
