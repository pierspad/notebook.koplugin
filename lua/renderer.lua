local Raster = require("raster")
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
local HighlightInk = require("highlightink")
local GeometryInk = require("geometryink")

local Renderer = {}

-- Pressure below this is treated as a resting touch rather than intent, and
-- still produces a visible line. Without a floor, the start of every stroke
-- fades in and handwriting looks ragged.
local MIN_PRESSURE_FACTOR = 0.35

-- Default highlighter tint: the gray blank paper is taken down to. Ink already
-- darker than this is left alone.
local HIGHLIGHT_TINT = 160

local COLOR_BLACK = Blitbuffer.Color8(0)
local COLOR_HIGHLIGHT_YELLOW = 0x1FFFF66

local function rgbColor(value)
    if type(value) ~= "number" or value < 0x1000000 or value > 0x1FFFFFF then return nil end
    return Blitbuffer.ColorRGB32(math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x100) % 0x100, value % 0x100, 0xFF)
end

local function grayOfRGB(color)
    return math.floor((4898 * color:getR() + 9618 * color:getG()
        + 1869 * color:getB()) / 16384 + 0.5)
end

local function displayColor(value, color_enabled)
    local color = rgbColor(value)
    if not color_enabled or not color then
        if type(value) == "number" and value > 0xFFFFFF then
            return Blitbuffer.Color8(grayOfRGB(color or rgbColor(value)))
        end
        return Blitbuffer.Color8(value or 0)
    end
    return color
end

local function highlightColor(stroke,color_enabled)
    return displayColor(stroke.tint or (color_enabled and COLOR_HIGHLIGHT_YELLOW) or HIGHLIGHT_TINT,color_enabled)
end

--- Returns the half-width, in pixels, a stroke should have at a given pressure.
function Renderer.radiusFor(stroke, pressure, dx, dy)
    local p = pressure or 1
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    local factor = MIN_PRESSURE_FACTOR + (1 - MIN_PRESSURE_FACTOR) * p
    local r = (stroke.width * factor) / 2
    if stroke.pen_style == "fountain" then
        local angle_factor = 0.70
        if dx and dy and (dx ~= 0 or dy ~= 0) then
            local theta = math.atan2(dy, dx)
            -- 45-degree nib angle creates calligraphic contrast between thick downstrokes and thin cross-strokes
            angle_factor = 0.35 + 0.65 * math.abs(math.sin(theta - math.pi / 4))
        end
        r = r * angle_factor
    end
    return r
end

--- Paints a single round stamp. Small radii bypass paintCircle, which bails out
-- entirely at r == 0 and is needlessly expensive for a dot.
local function stamp(bb, x, y, r, color, color_enabled)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if r < 1 then
        if color_enabled and bb.setPixelClamped then
            bb:setPixelClamped(x, y, color)
        else
            Raster.rect(bb,x, y, 1, 1, color)
        end
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

--[[--
Paints the segment between two points and returns the dirtied rectangle.

@tparam blitbuffer bb target buffer
@tparam table stroke the stroke being drawn (supplies tool, width, color)
@tparam number x0,y0,p0 start point and its pressure
@tparam number x1,y1,p1 end point and its pressure
@treturn number,number,number,number x, y, w, h of the dirtied area
--]]
function Renderer.drawSegment(bb, stroke, x0, y0, p0, x1, y1, p1, clip, color_enabled, grain_x, grain_y, exclude_start)
    local dx, dy = x1 - x0, y1 - y0
    local r0 = Renderer.radiusFor(stroke, p0, dx, dy)
    local r1 = Renderer.radiusFor(stroke, p1, dx, dy)

    local dist = math.sqrt(dx * dx + dy * dy)

    -- Restrict work to samples whose stamp can touch the viewport. Preserve
    -- the original step grid (and pressure interpolation) so partial and full
    -- rendering agree exactly, including at the clipping boundary.
    local first_t, last_t = 0, 1
    if clip then
        local pad = math.ceil(math.max(r0, r1)) + 2
        local function axis(origin, delta, low, high)
            if delta == 0 then return origin >= low and origin <= high end
            local a, b = (low - origin) / delta, (high - origin) / delta
            if a > b then a, b = b, a end
            first_t, last_t = math.max(first_t, a), math.min(last_t, b)
            return first_t <= last_t
        end
        if not axis(x0, dx, -pad, clip.w + pad)
            or not axis(y0, dy, -pad, clip.h + pad) then
            return
        end
    end

    local is_highlight = stroke.tool == "highlighter"
    local color = displayColor(stroke.color, color_enabled)
    local is_rgb_ink = color_enabled and type(stroke.color) == "number"
        and stroke.color >= 0x1000000 and stroke.color <= 0x1FFFFFF
    if is_highlight then
        color = highlightColor(stroke,color_enabled)
    elseif stroke.color and stroke.color ~= 0 then
        color = displayColor(stroke.color, color_enabled)
    end

    local is_lasso = stroke.tool == "lasso"
    if is_lasso then
        local dash_len = 8
        local gap_len = 6
        local cycle = dash_len + gap_len
        local steps = math.max(1, math.ceil(dist))
        local cur_len = stroke.accum_len or 0
        for i = math.max(0, math.floor(first_t * steps)), math.min(steps, math.ceil(last_t * steps)) do
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
        local is_pencil = stroke.pen_style == "pencil"
        if is_highlight then
            HighlightInk.drawSegment(bb,x0,y0,r0,x1,y1,r1,color,0,1,1,
                stroke.live_preview,exclude_start or (stroke.live_preview and dist>0))
        else
            require("penink").draw(bb,x0,y0,r0,x1,y1,r1,color,is_rgb_ink,is_pencil,grain_x,grain_y)
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

--[[--
Draws a dashed rectangle for selection outlines.

Clipped by hand, because setPixel is not: it indexes the row without checking,
so a pixel past the edge is not dropped but written into whatever lies next in
memory. A selection made against the edge of the page has its frame drawn a few
pixels outside it, which is exactly that case.
--]]
function Renderer.drawDashedRect(bb, x, y, w, h, color)
    color = color or COLOR_BLACK
    local dash = 8
    local cycle = 14

    local max_x = bb:getWidth() - 1
    local max_y = bb:getHeight() - 1
    local function span(px, py, width, height)
        if bb.paintRect then
            Raster.rect(bb,px, py, width, height, color)
        elseif width > 1 then
            for dx = 0, width - 1 do bb:setPixel(px+dx, py, color) end
        else
            for dy = 0, height - 1 do bb:setPixel(px, py+dy, color) end
        end
    end

    -- Paint one span per dash; per-pixel FFI writes dominate large selections.
    local function hline(py)
        if py < 0 or py > max_y then return end
        for i = 0, w, cycle do
            local a, b = math.max(0, x+i), math.min(max_x, x+math.min(w, i+dash-1))
            if b >= a then span(a, py, b-a+1, 1) end
        end
    end

    local function vline(px)
        if px < 0 or px > max_x then return end
        for j = 0, h, cycle do
            local a, b = math.max(0, y+j), math.min(max_y, y+math.min(h, j+dash-1))
            if b >= a then span(px, a, 1, b-a+1) end
        end
    end

    hline(y)
    hline(y + h)
    vline(x)
    vline(x + w)
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
function Renderer.drawStroke(bb, stroke, clip, color_enabled)
    if stroke.text then return require("textobject").draw(bb,stroke,1,0,0,clip) end
    local n = stroke:count()
    if n == 0 then return end

    if stroke.tool == "highlighter" and stroke.filled then
        local color=highlightColor(stroke,color_enabled)
        for _,contour in ipairs(require("markerarea").contours(stroke)) do
            local first,last,x0,y0,x1,y1=unpack(contour)
            if not clip or (x1+1e-8>=clip.x and y1+1e-8>=clip.y
                and x0-1e-8<clip.x+clip.w and y0-1e-8<clip.y+clip.h) then
                local points={}
                for i=first,last do local x,y=stroke:getPoint(i);points[#points+1]={x,y} end
                HighlightInk.polygon(bb,points,color,false,clip)
            end
        end
        return
    end
    if stroke.shape_kind and GeometryInk.draw(bb, stroke, clip,
        displayColor(stroke.color or 0, color_enabled), color_enabled) then return end
    local ox, oy = 0, 0
    local target = bb
    if clip then
        ox, oy = math.max(0, math.floor(clip.x)), math.max(0, math.floor(clip.y))
        local w = math.min(bb:getWidth(), math.ceil(clip.x + clip.w)) - ox
        local h = math.min(bb:getHeight(), math.ceil(clip.y + clip.h)) - oy
        if w <= 0 or h <= 0 then return end
        target = bb:viewport(ox, oy, w, h)
    end
    local bounds = clip and { w = target:getWidth(), h = target:getHeight() }
    local marker_started = false
    local function segment(x0, y0, p0, x1, y1, p1)
        Renderer.drawSegment(target, stroke, x0 - ox, y0 - oy, p0,
            x1 - ox, y1 - oy, p1, bounds, color_enabled, ox + (stroke.grain_x or 0), oy + (stroke.grain_y or 0), marker_started)
        marker_started = stroke.tool == "highlighter"
    end

    -- Short strokes have no index and are drawn whole: their bounding box has
    -- already said they are near the region, and there is nothing left to skip.
    local chunks = clip and n > 1 and stroke.chunkIndex and stroke:chunkIndex()
    if chunks then
        local pad = math.ceil(stroke.width / 2) + 1
        local cx0, cy0 = clip.x - pad, clip.y - pad
        local cx1, cy1 = clip.x + clip.w + pad, clip.y + clip.h + pad
        for _, c in ipairs(chunks) do
            if cx1 >= c[3] and cx0 <= c[5] and cy1 >= c[4] and cy0 <= c[6] then
                marker_started = false
                local px, py, pp = stroke:getPoint(c[1])
                for i = c[1] + 1, c[2] do
                    local x, y, p = stroke:getPoint(i)
                    segment(px, py, pp, x, y, p)
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
            HighlightInk.stamp(target,x-ox,y-oy,r,highlightColor(stroke,color_enabled))
        else
            require("penink").draw(target,x-ox,y-oy,r,x-ox,y-oy,r,
                displayColor(stroke.color,color_enabled),
                color_enabled and type(stroke.color)=="number" and stroke.color>=0x1000000,
                stroke.pen_style=="pencil",ox+(stroke.grain_x or 0),oy+(stroke.grain_y or 0))
        end
        return
    end

    local px, py, pp = stroke:getPoint(1)
    for i = 2, n do
        local x, y, p = stroke:getPoint(i)
        segment(px, py, pp, x, y, p)
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
function Renderer.drawPage(bb, page, scale, ox, oy, color_enabled)
    if #page.strokes == 0 then return end
    ox, oy = ox or 0, oy or 0
    if (not scale or scale == 1) and ox == 0 and oy == 0 then
        for _, stroke in ipairs(page.strokes) do
            Renderer.drawStroke(bb, stroke, nil, color_enabled)
        end
        return
    end
    scale = scale or 1

    local clip = {x=0, y=0, w=bb:getWidth(), h=bb:getHeight()}
    for _, stroke in ipairs(page.strokes) do
        local pad = math.ceil(stroke.width * scale) + 2
        if stroke.x_max*scale+ox+pad >= 0 and stroke.y_max*scale+oy+pad >= 0
            and stroke.x_min*scale+ox-pad < clip.w and stroke.y_min*scale+oy-pad < clip.h then
            if stroke.text then
                require("textobject").draw(bb, stroke, scale, ox, oy, clip)
            else
                local scaled = {
                    shape_kind=stroke.shape_kind, filled=stroke.filled, marker_parts=stroke.marker_parts,
                    pen_style=stroke.pen_style, tool=stroke.tool,
                    color=stroke.color, tint=stroke.tint,
                    grain_x=-ox, grain_y=-oy,
                    width=math.max(1, stroke.width*scale),
                    x_min=stroke.x_min*scale+ox, y_min=stroke.y_min*scale+oy,
                    x_max=stroke.x_max*scale+ox, y_max=stroke.y_max*scale+oy,
                    count=function() return stroke:count() end,
                    getPoint=function(_, i)
                        local x, y, p = stroke:getPoint(i)
                        return x*scale+ox, y*scale+oy, p
                    end,
                }
                -- A stroke wholly inside the target needs no translated viewport
                -- or per-segment clipping closures. Keep the conservative brush
                -- margin so edge strokes retain the original clipping path.
                local contained = scaled.x_min-pad >= 0 and scaled.y_min-pad >= 0
                    and scaled.x_max+pad < clip.w and scaled.y_max+pad < clip.h
                Renderer.drawStroke(bb, scaled, not contained and clip or nil, color_enabled)
            end
        end
    end
end

return Renderer
