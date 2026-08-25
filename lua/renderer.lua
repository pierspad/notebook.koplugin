--[[--
Stroke rasterizer.

KOReader's blitbuffer offers rectangles and circles but no line primitive, so
stroke rendering is implemented here. This module is deliberately the only place
in the plugin that knows how a stroke becomes pixels: it is the latency-critical
hot spot, and keeping it behind a narrow interface means it can be rewritten
(spans, C, SIMD) without any other module noticing.

The interface is: give me a blitbuffer and a segment, I paint it and hand back
the rectangle I dirtied. Callers use that rectangle to drive a partial refresh.

@module notebook.renderer
--]]--

local Blitbuffer = require("ffi/blitbuffer")

local Renderer = {}

-- Pressure below this is treated as a resting touch rather than intent, and
-- still produces a visible line. Without a floor, the start of every stroke
-- fades in and handwriting looks ragged.
local MIN_PRESSURE_FACTOR = 0.35

-- Default highlighter tint: the gray blank paper is taken down to. Ink already
-- darker than this is left alone.
local HIGHLIGHT_TINT = 160

local COLOR_BLACK = Blitbuffer.Color8(0)
local COLOR_HIGHLIGHT_DEFAULT = Blitbuffer.Color8(HIGHLIGHT_TINT)

--- Returns the half-width, in pixels, a stroke should have at a given pressure.
function Renderer.radiusFor(stroke, pressure)
    local p = pressure or 1
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    local factor = MIN_PRESSURE_FACTOR + (1 - MIN_PRESSURE_FACTOR) * p
    return (stroke.width * factor) / 2
end

--- Paints a single round stamp. Small radii bypass paintCircle, which bails out
-- entirely at r == 0 and is needlessly expensive for a dot.
local function stamp(bb, x, y, r, color)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if r < 1 then
        bb:paintRect(x, y, 1, 1, color)
    else
        -- w defaults to r, which gives a filled disc.
        bb:paintCircle(x, y, math.floor(r + 0.5), color)
    end
end

--[[--
Paints a chisel stamp for the highlighter.

The blend is a minimum, not a multiply: a pixel is darkened *to* the tint, never
past it. That makes highlighting idempotent -- over blank paper it gives gray,
over black ink it leaves the ink alone, and over an existing highlight it changes
nothing at all.
--]]
local function stampHighlight(bb, x, y, r, color)
    local x0 = math.floor(x - r + 0.5)
    local y0 = math.floor(y - r + 0.5)
    local s = math.floor(r * 2 + 0.5)
    if s < 1 then s = 1 end
    local x1, y1 = x0 + s - 1, y0 + s - 1

    --[[
    A Color8 is FFI cdata on a device, and a plain number only in the tests.

    `type()` on cdata answers neither "table" nor "number", so asking it those
    two questions and defaulting to zero meant the threshold was zero
    everywhere it mattered: the blend stopped being "darken towards the tint"
    and became "repaint everything that is not already pure black". Pen ink
    survived that, being black, and the dots of dot grid paper did not -- they
    are darker than the tint, they are meant to be left alone, and highlighting
    over them washed them out.
    --]]
    local tint
    if type(color) == "number" then
        tint = color
    else
        tint = color.getColor8 and color:getColor8().a or color.a or 0
    end

    --[[
    Clipped to the buffer, because getPixel and setPixel are not.

    Every other primitive here goes through blitbuffer's own painting calls,
    which clip. These two index straight into the row pointer with the
    coordinate they are given, so a stamp that overhangs the edge reads and
    writes past the end of the allocation. Nothing on the drawing path can
    reach that -- the canvas keeps the nib a full stroke width inside the page
    -- but an export renders into a buffer of its own chosen size, and a page
    written on a wider panel would hang over the side of it.
    --]]
    local w = bb.getWidth and bb:getWidth() or bb.w
    local h = bb.getHeight and bb:getHeight() or bb.h
    if w and h then
        if x0 < 0 then x0 = 0 end
        if y0 < 0 then y0 = 0 end
        if x1 > w - 1 then x1 = w - 1 end
        if y1 > h - 1 then y1 = h - 1 end
    end

    for j = y0, y1 do
        for i = x0, x1 do
            local px = bb:getPixel(i, j)
            if px then
                local gray = px.getColor8 and px:getColor8().a or px.a
                -- Only ever darken *towards* the tint, never past it.
                if gray and gray > tint then
                    bb:setPixel(i, j, color)
                end
            end
        end
    end
end

--[[--
Paints the segment between two points and returns the dirtied rectangle.

@tparam blitbuffer bb target buffer
@tparam table stroke the stroke being drawn (supplies tool, width, color)
@tparam number x0,y0,p0 start point and its pressure
@tparam number x1,y1,p1 end point and its pressure
@treturn number,number,number,number x, y, w, h of the dirtied area
--]]
function Renderer.drawSegment(bb, stroke, x0, y0, p0, x1, y1, p1)
    local r0 = Renderer.radiusFor(stroke, p0)
    local r1 = Renderer.radiusFor(stroke, p1)

    local dx, dy = x1 - x0, y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)

    local is_highlight = stroke.tool == "highlighter"
    local color = COLOR_BLACK
    if is_highlight then
        color = stroke.tint and Blitbuffer.Color8(stroke.tint) or COLOR_HIGHLIGHT_DEFAULT
    elseif stroke.color and stroke.color ~= 0 then
        color = Blitbuffer.Color8(stroke.color)
    end

    local is_lasso = stroke.tool == "lasso"
    if is_lasso then
        local dash_len = 8
        local gap_len = 6
        local cycle = dash_len + gap_len
        local steps = math.max(1, math.ceil(dist))
        local cur_len = stroke.accum_len or 0
        for i = 0, steps do
            local phase = (cur_len + dist * (i / steps)) % cycle
            if phase < dash_len then
                local t = i / steps
                local x = x0 + dx * t
                local y = y0 + dy * t
                stamp(bb, x, y, 1.2, COLOR_BLACK)
            end
        end
        stroke.accum_len = cur_len + dist
    else
        local step_dist = is_highlight and math.max(2, math.floor(math.min(r0, r1) * 0.4)) or 1.0
        local steps = math.max(1, math.ceil(dist / step_dist))

        for i = 0, steps do
            local t = i / steps
            local x = x0 + dx * t
            local y = y0 + dy * t
            local r = r0 + (r1 - r0) * t
            if is_highlight then
                stampHighlight(bb, x, y, r, color)
            else
                stamp(bb, x, y, r, color)
            end
        end
    end

    -- The dirty rect must cover both endpoint discs in full.
    local r_max = math.max(r0, r1)
    local pad = math.ceil(r_max) + 2
    local rx = math.floor(math.min(x0, x1) - pad)
    local ry = math.floor(math.min(y0, y1) - pad)
    local rw = math.ceil(math.max(x0, x1) + pad) - rx
    local rh = math.ceil(math.max(y0, y1) + pad) - ry
    return rx, ry, rw, rh
end

--- Draws a dashed rectangle for selection outlines.
function Renderer.drawDashedRect(bb, x, y, w, h, color)
    color = color or COLOR_BLACK
    local dash = 8
    local cycle = 14

    for i = 0, w do
        if (i % cycle) < dash then
            bb:setPixel(x + i, y, color)
            bb:setPixel(x + i, y + h, color)
        end
    end
    for j = 0, h do
        if (j % cycle) < dash then
            bb:setPixel(x, y + j, color)
            bb:setPixel(x + w, y + j, color)
        end
    end
end

--[[--
Paints a complete stroke. Used when repainting a page from the vector model,
never on the live drawing path.

With `clip`, only the parts of the stroke that fall inside that rectangle are
drawn. The eraser repaints a small region and everything crossing it has to be
put back -- but a line crossing a corner of that region does not need its whole
length rasterised, and stamping is expensive enough that the difference is the
difference between a rub that keeps up with the hand and one that does not.
--]]
function Renderer.drawStroke(bb, stroke, clip)
    local n = stroke:count()
    if n == 0 then return end

    -- Short strokes have no index and are drawn whole: their bounding box has
    -- already said they are near the region, and there is nothing left to skip.
    local chunks = clip and n > 1 and stroke.chunkIndex and stroke:chunkIndex()
    if chunks then
        local pad = math.ceil(stroke.width / 2) + 1
        local cx0, cy0 = clip.x - pad, clip.y - pad
        local cx1, cy1 = clip.x + clip.w + pad, clip.y + clip.h + pad
        for _, c in ipairs(chunks) do
            if cx1 >= c[3] and cx0 <= c[5] and cy1 >= c[4] and cy0 <= c[6] then
                local px, py, pp = stroke:getPoint(c[1])
                for i = c[1] + 1, c[2] do
                    local x, y, p = stroke:getPoint(i)
                    Renderer.drawSegment(bb, stroke, px, py, pp, x, y, p)
                    px, py, pp = x, y, p
                end
            end
        end
        return
    end

    if n == 1 then
        local x, y, p = stroke:getPoint(1)
        local r = Renderer.radiusFor(stroke, p)
        if stroke.tool == "highlighter" then
            stampHighlight(bb, x, y, r,
                Blitbuffer.Color8(stroke.tint or HIGHLIGHT_TINT))
        else
            stamp(bb, x, y, r, Blitbuffer.Color8(stroke.color))
        end
        return
    end

    local px, py, pp = stroke:getPoint(1)
    for i = 2, n do
        local x, y, p = stroke:getPoint(i)
        Renderer.drawSegment(bb, stroke, px, py, pp, x, y, p)
        px, py, pp = x, y, p
    end
end

--[[--
Paints every stroke of a page, in creation order.

`scale` shrinks the page for thumbnails. Drawing small directly, rather than
rendering the full page and scaling the bitmap down, is the difference between
touching a few thousand pixels and four and a half million -- which matters when
a gallery has to produce one of these per notebook.
--]]
function Renderer.drawPage(bb, page, scale, ox, oy)
    ox, oy = ox or 0, oy or 0
    if (not scale or scale == 1) and ox == 0 and oy == 0 then
        for _, stroke in ipairs(page.strokes) do
            Renderer.drawStroke(bb, stroke)
        end
        return
    end
    scale = scale or 1

    for _, stroke in ipairs(page.strokes) do
        local n = stroke:count()
        if n > 0 then
            -- A stand-in carrying the scaled width; the real stroke is untouched.
            local scaled = {
                tool = stroke.tool,
                color = stroke.color,
                tint = stroke.tint,
                width = math.max(1, stroke.width * scale),
            }
            local px, py, pp = stroke:getPoint(1)
            if n == 1 then
                Renderer.drawSegment(bb, scaled, px * scale + ox, py * scale + oy, pp,
                    px * scale + ox, py * scale + oy, pp)
            else
                for i = 2, n do
                    local x, y, p = stroke:getPoint(i)
                    Renderer.drawSegment(bb, scaled,
                        px * scale + ox, py * scale + oy, pp,
                        x * scale + ox, y * scale + oy, p)
                    px, py, pp = x, y, p
                end
            end
        end
    end
end

return Renderer
