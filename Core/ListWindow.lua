local _, addon = ...

-- A pooled list's arithmetic: which rows of a long list are in view and
-- where each one sits, so the list only needs frames for those. Rows are
-- laid out top to bottom with no gaps; each is `height` tall, a number for
-- every row or a function(index) -> height for mixed heights (section
-- labels between cards, say). Offsets are pixels scrolled down from the
-- top.
--
-- Pure: it knows nothing about frames.
local ListWindow = {}
addon.ListWindow = ListWindow

local function heightOf(height, index)
    if type(height) == "function" then
        return math.max(0, height(index) or 0)
    end
    return math.max(0, height or 0)
end

-- Each row's top and the list's total height: { tops = { [index] = top },
-- total }. Fixed heights need no table, so it's built only for mixed ones.
function ListWindow.Layout(count, height)
    if type(height) ~= "function" then
        return { total = count * heightOf(height) }
    end
    local tops, top = {}, 0
    local index
    for index = 1, count do
        tops[index] = top
        top = top + heightOf(height, index)
    end
    return { tops = tops, total = top }
end

-- Row `index`'s top in `layout` (from Layout, for `height`).
local function topOf(layout, height, index)
    if layout.tops ~= nil then
        return layout.tops[index]
    end
    return (index - 1) * heightOf(height)
end

-- `offset` held between the top and the furthest the list scrolls, where
-- its last row's bottom meets the viewport's.
function ListWindow.Clamp(offset, total, viewport)
    local most = math.max(0, (total or 0) - math.max(0, viewport or 0))
    return math.max(0, math.min(most, offset or 0))
end

-- What a list of `count` rows shows in a `viewport`-tall window scrolled
-- `offset` down: { first, last, tops = { [index] = top within the
-- viewport }, offset (clamped), total }. A row partly in view counts.
-- first and last are nil when nothing shows.
function ListWindow.Visible(count, height, viewport, offset)
    local layout = ListWindow.Layout(count, height)
    offset = ListWindow.Clamp(offset, layout.total, viewport)
    local window = { tops = {}, offset = offset, total = layout.total }
    local bottom = offset + math.max(0, viewport or 0)
    local first = 1
    if layout.tops == nil then
        local step = heightOf(height)
        if step <= 0 then
            return window
        end
        first = math.floor(offset / step) + 1
    end
    local index
    for index = first, count do
        local top = topOf(layout, height, index)
        if top >= bottom then
            break
        end
        if top + heightOf(height, index) > offset then
            window.first = window.first or index
            window.last = index
            window.tops[index] = top - offset
        end
    end
    return window
end

-- The offset that shows row `index` whole, moving `offset` as little as it
-- can: unchanged when the row is already in view, else just far enough
-- that it sits at the top (scrolling up) or the bottom (scrolling down).
-- Clamped; `offset` clamped when `index` isn't a row.
function ListWindow.KeepInView(index, count, height, viewport, offset)
    local layout = ListWindow.Layout(count, height)
    if type(index) ~= "number" or index < 1 or index > count then
        return ListWindow.Clamp(offset, layout.total, viewport)
    end
    local top = topOf(layout, height, index)
    local bottom = top + heightOf(height, index)
    offset = offset or 0
    if top < offset then
        offset = top
    elseif bottom > offset + (viewport or 0) then
        offset = bottom - (viewport or 0)
    end
    return ListWindow.Clamp(offset, layout.total, viewport)
end
