local _, addon = ...

-- The master frame's tabs and which one is showing. Pages register in order
-- with an id, a label, and an icon; the first one registered is the home
-- page, where the general entry points (the minimap button, the add-on
-- compartment, the guild window's button, and `/agf`) open. A page can
-- have a visibility rule (an officers-only tab): a hidden page has no tab
-- and can't be shown, and the home page takes over when the showing page
-- becomes hidden. It holds no frames, so specs drive it directly.
local PageNavigator = {}
addon.PageNavigator = PageNavigator

local Navigator = {}
Navigator.__index = Navigator

function PageNavigator.Create()
    return setmetatable({ pages = {}, byId = {} }, Navigator)
end

-- Adds a page after the ones already registered. `visible()`, when given,
-- says whether the page shows now (the home page always does). Returns
-- false for a missing or repeated id.
function Navigator:Add(id, label, icon, visible)
    if type(id) ~= "string" or self.byId[id] ~= nil then
        return false
    end
    local page = { id = id, label = label, icon = icon, visible = visible }
    table.insert(self.pages, page)
    self.byId[id] = page
    if self.current == nil then
        self.current = id
    end
    return true
end

-- Whether page `id` is registered and its rule (if any) lets it show. A
-- rule that fails hides the page.
function Navigator:IsVisible(id)
    local page = self.byId[id]
    if page == nil then
        return false
    end
    if page == self.pages[1] or type(page.visible) ~= "function" then
        return true
    end
    local ok, visible = pcall(page.visible)
    return ok and visible == true
end

-- Every registered page, shown or not, in order: { id, label, icon }.
function Navigator:Pages()
    local pages = {}
    local index
    for index = 1, #self.pages do
        local page = self.pages[index]
        table.insert(pages, { id = page.id, label = page.label, icon = page.icon })
    end
    return pages
end

-- The pages to show as tabs, in order: { id, label, icon, selected }. Only
-- visible pages have a tab.
function Navigator:Tabs()
    self:Revisit()
    local tabs = {}
    local index
    for index = 1, #self.pages do
        local page = self.pages[index]
        if self:IsVisible(page.id) then
            table.insert(tabs, {
                id = page.id,
                label = page.label,
                icon = page.icon,
                selected = page.id == self.current,
            })
        end
    end
    return tabs
end

-- Falls back to the home page when the page showing is hidden now. True
-- when that changed the current page.
function Navigator:Revisit()
    if self.current ~= nil and not self:IsVisible(self.current) then
        self.current = self.pages[1].id
        return true
    end
    return false
end

-- The id of the page showing, or nil before any page is registered.
function Navigator:Current()
    self:Revisit()
    return self.current
end

-- Shows the page `id`. An unknown or hidden id leaves the current page as
-- it is and returns false.
function Navigator:Select(id)
    if not self:IsVisible(id) then
        return false
    end
    self.current = id
    return true
end

-- The page an entry point opens: a command that names a visible page opens
-- that page; every other entry point opens the home page.
function Navigator:PageFor(entry)
    if entry ~= nil and self:IsVisible(entry) then
        return entry
    end
    local home = self.pages[1]
    return home and home.id or nil
end
