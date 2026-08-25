--[[--
Page backgrounds: ruled lines, grids, dot grids.

A background is not ink. It is not in the stroke list, it cannot be selected,
and above all it cannot be erased -- rubbing out a word written across a ruled
line must leave the line. That falls out of drawing it here rather than storing
it as strokes: everything that reconstructs pixels from the model draws the
background first and the ink on top, so the background is restored by the same
pass that restores the strokes around it.

Drawn procedurally rather than loaded from images. On e-ink a line is one or two
pixels and a scaled bitmap of one is a smear; procedural lines are exact at page
size, at thumbnail size and in the PDF export, and there is nothing to install
next to the plugin.

Geometry is expressed in page pixels at 300 dpi -- roughly 11.8 px to the
millimetre -- and multiplied by the caller's scale. That is what keeps a 7 mm
ruled line 7 mm apart whether it is being drawn onto the panel or into a card.

@module notebook.template
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("i18n")

local Template = {}

Template.DEFAULT = "blank"

-- Pixels per millimetre on the panel this is designed for.
local MM = 11.8

--[[--
The available backgrounds, in the order they are offered.

Deliberately only the kinds of paper you would buy a pad of. Dated layouts --
planners, calendars, habit trackers -- are not backgrounds: they carry content
that has to be generated per page and per date, which is a different feature
with a different data model, and pretending otherwise would give a notebook
twelve identical "January" pages.
--]]
local TYPES = {
    { id = "blank",     name = _("Blank") },
    { id = "lined",     name = _("Lined") },
    { id = "narrow",    name = _("Narrow lined") },
    { id = "grid",      name = _("Grid") },
    { id = "dots",      name = _("Dot grid") },
    { id = "checklist", name = _("Checklist") },
}

local BY_ID = {}
for i, t in ipairs(TYPES) do BY_ID[t.id] = i end

--- The backgrounds, in order, as a list of `{ id, name }`.
function Template.list()
    return TYPES
end

--- True if `id` names a background this version knows how to draw.
function Template.isKnown(id)
    return id ~= nil and BY_ID[id] ~= nil
end

--- The display name of a background, or nil.
function Template.nameOf(id)
    local i = BY_ID[id]
    return i and TYPES[i].name or nil
end

-- Drawing ------------------------------------------------------------------------

-- Ruled lines are lighter than handwriting so they stay underneath it, but only
-- just: at the first attempt they were pale enough to be invisible on the panel
-- unless you went looking. E-ink has no backlight and a light grey hairline
-- disappears into the paper, so both the tone and the width below are the point
-- at which the ruling reads as ruling under normal light. Dots have to carry a
-- whole line's worth of guidance in a few pixels, so they are darker again.
local LINE_INK = Blitbuffer.COLOR_GRAY
local DOT_INK = Blitbuffer.COLOR_GRAY_5

-- Ruling width in page pixels. One pixel is a hairline at 300 dpi.
local LINE_PX = 2

-- Nominal spacings, in millimetres.
local SPACING = {
    lined     = 8,
    narrow    = 5.5,
    grid      = 5,
    dots      = 5,
    checklist = 11,
}

--[[--
The ruling runs to the edge of the page.

It used to stop short of it, on the reasoning that lines against the edge look
cropped. On paper that is true, because paper has an edge. A screen does not:
the margin read as the ruling being a square patch sitting on a white page
rather than as the page itself, and squared paper in particular looked like a
block of graph paper glued to a sheet. Running it to the edge is what makes it
read as the paper going on past the screen.
--]]
local INSET_MM = 0

--[[--
Paints a rectangle, clipped to the region the caller is repainting.

Clipping in both directions, not just along the band, is what keeps a background
inside the area it was asked for. A grid's vertical rules span the whole page:
drawn unclipped while the eraser was restoring a few hundred pixels, they would
be laid down the full height of the page -- over the toolbar, and over parts of
the screen nobody had asked to be repainted.
--]]
local function paint(bb, x, y, w, h, clip, ink)
    if clip then
        local x1 = math.min(x + w, clip.x + clip.w)
        local y1 = math.min(y + h, clip.y + clip.h)
        x = math.max(x, clip.x)
        y = math.max(y, clip.y)
        w, h = x1 - x, y1 - y
        if w <= 0 or h <= 0 then return end
    end
    bb:paintRect(x, y, w, h, ink)
end

--- A hollow box, clipped, as four sides.
local function paintBox(bb, x, y, size, thickness, clip, ink)
    paint(bb, x, y, size, thickness, clip, ink)
    paint(bb, x, y + size - thickness, size, thickness, clip, ink)
    paint(bb, x, y, thickness, size, clip, ink)
    paint(bb, x + size - thickness, y, thickness, size, clip, ink)
end

--[[--
Draws a background into `area`, optionally restricted to `clip`.

`area` is the rectangle the page occupies on the target buffer; `scale` shrinks
the spacings to match a page that is being drawn smaller than life, as in a
thumbnail or an export. `clip` is the region the caller is actually repainting:
the eraser restores a few hundred pixels at a time, and walking the whole page's
worth of ruling for each of those would make a sweep crawl.

Redrawing is idempotent -- the same pixels land in the same places -- so a caller
that draws a little more than it strictly needs is correct, only slower.
--]]
function Template.draw(bb, id, area, scale, clip)
    if not id or id == "blank" or not BY_ID[id] then return end
    scale = scale or 1

    local step = SPACING[id] * MM * scale
    if step < 3 then
        -- Below this the ruling closes up into a solid tone that reads as a
        -- grubby page rather than as lines. A very small thumbnail is better
        -- off blank.
        return
    end

    local thickness = math.max(1, math.floor(LINE_PX * scale + 0.5))
    local inset = math.floor(INSET_MM * MM * scale)
    local x0 = area.x + inset
    local y0 = area.y + inset
    local w = area.w - 2 * inset
    local h = area.h - 2 * inset
    if w <= 0 or h <= 0 then return end

    if id == "dots" then
        -- A dot has to say in a few pixels what a ruled line says across the
        -- page, so it is both darker and fatter than the ruling. At the width
        -- the lines use it was there but not visible, which is the same as not
        -- being there.
        local r = math.max(3, math.floor(4 * scale + 0.5))
        local y = y0
        while y <= y0 + h do
            local x = x0
            while x <= x0 + w do
                paint(bb, math.floor(x - r / 2), math.floor(y - r / 2),
                    r, r, clip, DOT_INK)
                x = x + step
            end
            y = y + step
        end
        return
    end

    -- Everything else is ruled, and the ruled kinds differ only in what else
    -- they put on each line.
    local y = y0
    while y <= y0 + h do
        paint(bb, x0, math.floor(y), w, thickness, clip, LINE_INK)
        if id == "checklist" then
            -- A box sitting on the line, at its left end: the thing that turns
            -- ruled paper into a list you tick off.
            local box = math.floor(step * 0.45)
            if box >= 4 then
                -- Set in from the edge by a fraction of the ruling. Flush left
                -- it looked stuck to the border of whatever was drawing it, and
                -- on paper a checkbox has a margin in front of it too.
                paintBox(bb, x0 + math.floor(box * 0.4),
                    math.floor(y - box - thickness), box, thickness, clip, LINE_INK)
            end
        end
        y = y + step
    end

    if id == "grid" then
        local x = x0
        while x <= x0 + w do
            paint(bb, math.floor(x), y0, thickness, h, clip, LINE_INK)
            x = x + step
        end
    end
end

return Template
