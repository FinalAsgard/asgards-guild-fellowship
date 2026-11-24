-- Draws the new window's textures into Media/Textures as uncompressed
-- 32-bit TGA files, which every supported client loads. Run from the repo
-- root after changing a shape or a color here:
--
--   luajit tools/make-textures.lua
--
-- Each texture is drawn by a function of the pixel's center that gives its
-- color and coverage (0 to 1), sampled 4x4 per pixel so edges are smooth.
-- White textures are tinted in game (SetVertexColor), so one shape serves
-- every color.

local OUT = "Media/Textures/"
local SAMPLES = 4

local function clamp(value)
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end
    return value
end

-- Writes a width x height TGA, drawing each pixel with `shade(x, y)` (x and y
-- in pixels from the top-left) -> r, g, b, coverage, all 0 to 1.
local function write(name, width, height, shade)
    local rows = {}
    local y
    -- TGA rows run bottom to top unless the descriptor says otherwise; the
    -- descriptor below sets top-left origin, so rows go top to bottom.
    for y = 0, height - 1 do
        local row = {}
        local x
        for x = 0, width - 1 do
            local r, g, b, a = 0, 0, 0, 0
            local sy, sx
            for sy = 0, SAMPLES - 1 do
                for sx = 0, SAMPLES - 1 do
                    local pr, pg, pb, pa = shade(x + (sx + 0.5) / SAMPLES, y + (sy + 0.5) / SAMPLES)
                    pa = clamp(pa)
                    r, g, b, a = r + pr * pa, g + pg * pa, b + pb * pa, a + pa
                end
            end
            local count = SAMPLES * SAMPLES
            -- Color is averaged over the covered samples (straight alpha).
            if a > 0 then
                r, g, b = r / a, g / a, b / a
            end
            a = a / count
            row[#row + 1] = string.char(
                math.floor(clamp(b) * 255 + 0.5),
                math.floor(clamp(g) * 255 + 0.5),
                math.floor(clamp(r) * 255 + 0.5),
                math.floor(clamp(a) * 255 + 0.5)
            )
        end
        rows[#rows + 1] = table.concat(row)
    end
    local header = string.char(
        0, 0, 2, -- no id, no color map, uncompressed true color
        0, 0, 0, 0, 0, -- color map spec
        0, 0, 0, 0, -- x and y origin
        width % 256, math.floor(width / 256),
        height % 256, math.floor(height / 256),
        32, -- bits per pixel
        8 + 32 -- 8 alpha bits, top-left origin
    )
    local handle = assert(io.open(OUT .. name, "wb"))
    handle:write(header, table.concat(rows))
    handle:close()
    print("wrote " .. OUT .. name)
end

local function inside(value)
    return value and 1 or 0
end

-- Whether (x, y) is within the rounded rectangle 0..width x 0..height with
-- corner `radius`.
local function inRoundedRect(x, y, width, height, radius)
    local cx = math.min(math.max(x, radius), width - radius)
    local cy = math.min(math.max(y, radius), height - radius)
    local dx, dy = x - cx, y - cy
    return x >= 0 and y >= 0 and x <= width and y <= height and dx * dx + dy * dy <= radius * radius
end

-- A white disc filling the texture. Its four quarters are the corners of
-- every rounded shape, and the whole of it is a round knob or dot.
write("Rounded.tga", 64, 64, function(x, y)
    local dx, dy = x - 32, y - 32
    return 1, 1, 1, inside(dx * dx + dy * dy <= 32 * 32)
end)

-- The window's diagonal sweep: dark green at the top-left corner, fading to
-- nothing by three quarters of the way across, laid over the window's gray.
-- The window is one fixed size, so the texture is drawn in window pixels
-- (960x600) and its rounded corners stay round once stretched over it.
local WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_RADIUS = 960, 600, 12
local SWEEP_SIZE = 512
write("Sweep.tga", SWEEP_SIZE, SWEEP_SIZE, function(x, y)
    local wx, wy = x / SWEEP_SIZE * WINDOW_WIDTH, y / SWEEP_SIZE * WINDOW_HEIGHT
    -- How far along the top-left to bottom-right diagonal, 0 to 1.
    local along = (wx * WINDOW_WIDTH + wy * WINDOW_HEIGHT) / (WINDOW_WIDTH * WINDOW_WIDTH + WINDOW_HEIGHT * WINDOW_HEIGHT)
    local fade = clamp(1 - along / 0.75)
    -- Eased, so the green lingers near the corner and thins out smoothly.
    fade = fade * fade * (3 - 2 * fade)
    local covered = inRoundedRect(wx, wy, WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_RADIUS)
    return 0.06, 0.22, 0.13, inside(covered) * fade * 0.85
end)

-- The placeholder tree: three stacked green tiers and a brown trunk, until
-- final art is made.
write("Tree.tga", 64, 64, function(x, y)
    if x >= 28 and x <= 36 and y >= 46 and y <= 58 then
        return 0.42, 0.29, 0.17, 1
    end
    local tiers = { { top = 4, bottom = 24, half = 14 }, { top = 14, bottom = 36, half = 20 },
        { top = 24, bottom = 48, half = 26 } }
    local index
    for index = 1, #tiers do
        local tier = tiers[index]
        if y >= tier.top and y <= tier.bottom then
            local half = (y - tier.top) / (tier.bottom - tier.top) * tier.half
            if math.abs(x - 32) <= half then
                return 0.28, 0.66, 0.38, 1
            end
        end
    end
    return 0, 0, 0, 0
end)

-- A white gear: a ring with eight teeth and a hole in the middle.
write("Gear.tga", 32, 32, function(x, y)
    local dx, dy = x - 16, y - 16
    local distance = math.sqrt(dx * dx + dy * dy)
    local angle = math.atan2(dy, dx)
    -- Teeth: where the angle is near one of eight spokes.
    local spoke = math.abs(((angle / (2 * math.pi) * 8) % 1) - 0.5)
    local outer = spoke > 0.25 and 14 or 11
    return 1, 1, 1, inside(distance <= outer and distance >= 4.5)
end)

-- A white X: two thick strokes corner to corner.
write("Close.tga", 32, 32, function(x, y)
    local function nearLine(px, py, ax, ay, bx, by)
        local vx, vy = bx - ax, by - ay
        local t = clamp(((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy))
        local cx, cy = ax + t * vx - px, ay + t * vy - py
        return cx * cx + cy * cy <= 2.2 * 2.2
    end
    return 1, 1, 1, inside(nearLine(x, y, 8, 8, 24, 24) or nearLine(x, y, 24, 8, 8, 24))
end)

-- A soft white glow, brightest in the middle, for highlights.
write("Glow.tga", 64, 64, function(x, y)
    local dx, dy = (x - 32) / 32, (y - 32) / 32
    local fade = clamp(1 - math.sqrt(dx * dx + dy * dy))
    return 1, 1, 1, fade * fade
end)

-- A white heart, for group friends: the classic heart curve, point down.
write("Heart.tga", 32, 32, function(x, y)
    local hx, hy = (x - 16) / 12, (16 - y) / 12 + 0.25
    local shape = (hx * hx + hy * hy - 1) ^ 3 - hx * hx * hy * hy * hy
    return 1, 1, 1, inside(shape <= 0)
end)

-- A white crown, for the party's leader: a band with three points above it.
write("Crown.tga", 32, 32, function(x, y)
    if x >= 5 and x <= 27 and y >= 20 and y <= 26 then
        return 1, 1, 1, 1
    end
    local points = { 6, 16, 26 }
    local index
    for index = 1, #points do
        -- Each point narrows from its base on the band to a tip at y = 7.
        local half = (y - 7) / 13 * 5.5
        if y >= 7 and y < 21 and math.abs(x - points[index]) <= half then
            return 1, 1, 1, 1
        end
    end
    return 0, 0, 0, 0
end)

-- A white person, for role tiles where any role will do: a round head over
-- rounded shoulders.
write("Person.tga", 32, 32, function(x, y)
    local hx, hy = x - 16, y - 10
    if hx * hx + hy * hy <= 5.5 * 5.5 then
        return 1, 1, 1, 1
    end
    local sx, sy = (x - 16) / 11, (y - 29) / 11
    return 1, 1, 1, inside(y <= 28 and sx * sx + sy * sy <= 1)
end)

-- A white dungeon gate, for dungeons the game gives no icon for: an arched
-- doorway in a square of stone.
write("Dungeon.tga", 64, 64, function(x, y)
    local inWall = x >= 6 and x <= 58 and y >= 8 and y <= 58
    local ax, ay = (x - 32) / 14, (y - 30) / 14
    local inDoor = x >= 18 and x <= 46 and y >= 30 and y <= 58 or (y < 30 and ax * ax + ay * ay <= 1)
    return 1, 1, 1, inside(inWall and not inDoor)
end)
