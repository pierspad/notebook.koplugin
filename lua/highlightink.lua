-- Chisel highlighter rasterizer. Kept separate from the stroke and shape paths:
-- large markers are the dominant per-pixel cost at 2x zoom.
local HighlightInk = {}
local BLACK = require("ffi/blitbuffer").COLOR_BLACK
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
    if type(color) == "number" then tint = color
    else tint = color.getColor8 and color:getColor8().a or color.a or 0 end

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

HighlightInk.stamp = stampHighlight

-- Gather the union of overlapping square stamps by scanline, then blend each
-- pixel once. On a broad marker the previous loop visited most pixels in
-- several stamps; this preserves the same idempotent tint and clipping.
function HighlightInk.drawSegment(bb, x0, y0, r0, x1, y1, r1, color,
        first, last, steps, preview)
    if math.min(r0, r1) < 2 and not preview then
        for i = first, last do
            local t = i / steps
            stampHighlight(bb, x0 + (x1-x0)*t, y0 + (y1-y0)*t,
                r0 + (r1-r0)*t, color)
        end
        return
    end
    local width = bb.getWidth and bb:getWidth() or bb.w
    local height = bb.getHeight and bb:getHeight() or bb.h
    local rows = {}
    for i = first, last do
        local t = i / steps
        local x, y = x0 + (x1-x0)*t, y0 + (y1-y0)*t
        local r = r0 + (r1-r0)*t
        local left, top = math.floor(x-r+0.5), math.floor(y-r+0.5)
        local size = math.max(1, math.floor(r*2+0.5))
        local right, bottom = left+size-1, top+size-1
        left, right = math.max(0,left), math.min(width-1,right)
        top, bottom = math.max(0,top), math.min(height-1,bottom)
        if left <= right then
            for py = top, bottom do
                local row = rows[py]
                if row then
                    if left < row[1] then row[1] = left end
                    if right > row[2] then row[2] = right end
                else rows[py] = {left, right} end
            end
        end
    end
    local tint = type(color) == "number" and color
        or (color.getColor8 and color:getColor8().a or color.a or 0)
    for py, row in pairs(rows) do
        if preview then
            -- Black hatching is visible with DU and leaves most text/paper
            -- untouched. No per-pixel reads or gray waveform while moving.
            for px = row[1] + (-(row[1]+py) % 4), row[2], 4 do
                bb:setPixel(px, py, BLACK)
            end
        else
            for px = row[1], row[2] do
                local pixel = bb:getPixel(px, py)
                if pixel then
                    local gray = pixel.getColor8 and pixel:getColor8().a or pixel.a
                    if gray and gray > tint then bb:setPixel(px, py, color) end
                end
            end
        end
    end
end

return HighlightInk
