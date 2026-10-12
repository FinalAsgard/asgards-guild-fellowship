local _, addon = ...

-- The master frame's tabs and which one is showing. Pages register in order
-- with an id, a label, and an icon; the first one registered is the home
-- page, where the general entry points (the minimap button, the add-on
-- compartment, the guild window's button, and `/agf`) open. It holds no
-- frames, so specs drive it directly.
local PageNavigator = {}
addon.PageNavigator = PageNavigator

local Navigator = {}
Navigator.__index = Navigator

function PageNavigator.Create()
    return setmetatable({ pages = {}, byId = {} }, Navigator)
end

-- Adds a page after the ones already registered. Returns false for a
-- missing or repeated id.
function Navigator:Add(id, label, icon)
    if type(id) ~= "string" or self.byId[id] ~= nil then
        return false
    end
    local page = { id = id, label = label, icon = icon }
    table.insert(self.pages, page)
    self.byId[id] = page
    if self.current == nil then
        self.current = id
    end
    return true
end

-- The pages to show as tabs, in order: { id, label, icon, selected }.
function Navigator:Tabs()
    local tabs = {}
    local index
    for index = 1, #self.pages do
        local page = self.pages[index]
        table.insert(tabs, {
            id = page.id,
            label = page.label,
            icon = page.icon,
            selected = page.id == self.current,
        })
    end
    return tabs
end

-- The id of the page showing, or nil before any page is registered.
function Navigator:Current()
    return self.current
end

-- Shows the page `id`. An unknown id leaves the current page as it is and
-- returns false.
function Navigator:Select(id)
    if self.byId[id] == nil then
        return false
    end
    self.current = id
    return true
end

-- The page an entry point opens: a command that names a registered page
-- opens that page; every other entry point opens the home page.
function Navigator:PageFor(entry)
    if entry ~= nil and self.byId[entry] ~= nil then
        return entry
    end
    local home = self.pages[1]
    return home and home.id or nil
end
