local addonName, addon = ...

-- The new UI's look, in one place: colors, corner radii, spacing, the
-- bundled Inter font and the textures shipped in Media/. The new window and
-- every widget read from here, so later features moved into the window look
-- the same. It uses no framework: the old window keeps the Details!
-- Framework until each of its features moves over.
local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

local Theme = {
    COLORS = {
        -- The window's gray, under the green sweep.
        background = { 0.10, 0.11, 0.11, 0.97 },
        -- Panels and cards: slightly lighter rounded surfaces.
        surface = { 0.14, 0.15, 0.15, 1 },
        raised = { 0.18, 0.19, 0.19, 1 },
        hover = { 0.23, 0.24, 0.24, 1 },
        -- The faint 1px edge around panels and cards.
        border = { 0.24, 0.26, 0.25, 1 },
        text = { 0.93, 0.94, 0.93, 1 },
        muted = { 0.62, 0.64, 0.63, 1 },
        -- Small uppercase section labels.
        label = { 0.52, 0.55, 0.54, 1 },
        disabled = { 0.38, 0.40, 0.39, 1 },
        -- Selection and primary buttons.
        green = { 0.27, 0.62, 0.38, 1 },
        greenHover = { 0.32, 0.70, 0.44, 1 },
        -- "For you": the button glow, the count and relevant cards' border.
        gold = { 0.85, 0.69, 0.22, 1 },
        -- "A slot opened in your party".
        orange = { 0.95, 0.55, 0.18, 1 },
        -- Errors, e.g. a greeting that can't be saved.
        red = { 0.92, 0.36, 0.33, 1 },
        -- Roles: an open role in full color, a filled one in grey.
        tank = { 0.27, 0.52, 0.92, 1 },
        healer = { 0.30, 0.74, 0.40, 1 },
        dps = { 0.86, 0.29, 0.27, 1 },
        filled = { 0.34, 0.36, 0.35, 1 },
    },
    RADIUS = {
        window = 12,
        card = 10,
        button = 6,
        small = 4,
    },
    SPACING = {
        xs = 4,
        s = 8,
        m = 12,
        l = 16,
        xl = 24,
    },
    FONT_SIZE = {
        small = 10,
        body = 12,
        title = 15,
        heading = 20,
    },
    -- Registered with LibSharedMedia under these names, so other add-ons
    -- can use the bundled font too.
    FONT_NAMES = {
        regular = "Inter",
        semibold = "Inter SemiBold",
        italic = "Inter Italic",
    },
    FONTS = {
        regular = MEDIA .. "Fonts\\Inter-Regular.ttf",
        semibold = MEDIA .. "Fonts\\Inter-SemiBold.ttf",
        italic = MEDIA .. "Fonts\\Inter-Italic.ttf",
    },
    TEXTURES = {
        -- A white disc: its quarters are every rounded corner.
        rounded = MEDIA .. "Textures\\Rounded",
        -- The window's diagonal green sweep, drawn for its fixed size.
        sweep = MEDIA .. "Textures\\Sweep",
        -- Placeholder add-on icon until final art.
        tree = MEDIA .. "Textures\\Tree",
        gear = MEDIA .. "Textures\\Gear",
        close = MEDIA .. "Textures\\Close",
        glow = MEDIA .. "Textures\\Glow",
        -- The party's leader, and top group friends (Top 5).
        crown = MEDIA .. "Textures\\Crown",
        star = MEDIA .. "Textures\\Star",
        -- A role tile where any role will do.
        person = MEDIA .. "Textures\\Person",
        -- Role tiles too small for the role's name: Tank, Healer, DPS.
        shield = MEDIA .. "Textures\\Shield",
        cross = MEDIA .. "Textures\\Cross",
        sword = MEDIA .. "Textures\\Sword",
        -- For a dungeon the game gives no icon for.
        dungeon = MEDIA .. "Textures\\Dungeon",
        -- Edit and delete, e.g. on a greeting's row.
        pencil = MEDIA .. "Textures\\Pencil",
        trash = MEDIA .. "Textures\\Trash",
        -- A plain white square for flat, tinted fills; on every client.
        white = "Interface\\Buttons\\WHITE8X8",
    },
}
addon.Theme = Theme

-- Registers the bundled fonts with LibSharedMedia (`media`, the library),
-- if it's there. True when they were registered.
function Theme.Register(media)
    if type(media) ~= "table" or type(media.Register) ~= "function" then
        return false
    end
    local style
    for style, name in pairs(Theme.FONT_NAMES) do
        if not pcall(media.Register, media, "font", name, Theme.FONTS[style]) then
            return false
        end
    end
    return true
end

-- The color `name` as r, g, b, a.
function Theme.Color(name)
    local color = Theme.COLORS[name] or Theme.COLORS.text
    return color[1], color[2], color[3], color[4]
end

-- A saved "rrggbb" color as r, g, b, a (0 to 1); white for anything else.
function Theme.Hex(hex)
    if type(hex) ~= "string" or string.find(hex, "^%x%x%x%x%x%x$") == nil then
        return 1, 1, 1, 1
    end
    return tonumber(string.sub(hex, 1, 2), 16) / 255, tonumber(string.sub(hex, 3, 4), 16) / 255,
        tonumber(string.sub(hex, 5, 6), 16) / 255, 1
end

-- Sets font string `text` in Inter (`style`: "regular", "semibold" or
-- "italic"; `size`: a FONT_SIZE name or a number), colored `color` (a
-- COLORS name). A client that can't load the font keeps the game's.
function Theme.Font(text, style, size, color)
    local height = Theme.FONT_SIZE[size] or size or Theme.FONT_SIZE.body
    local path = Theme.FONTS[style] or Theme.FONTS.regular
    -- SetFont can fail by raising or by returning false.
    local ok, set = pcall(text.SetFont, text, path, height, "")
    if not ok or set == false then
        pcall(text.SetFontObject, text, "GameFontHighlight")
    end
    if color ~= nil then
        text:SetTextColor(Theme.Color(color))
    end
    return text
end

-- A small uppercase grey section label's text.
function Theme.Label(text)
    return string.upper(text or "")
end
