--[[--
Lasso selection and geometric containment helpers for strokes.

@module notebook.lasso
--]]--

local Rect = require("rect")

local Lasso = {}

--- Point-in-polygon ray-casting test.
function Lasso.pointInPolygon(px, py, poly_pts)
    local n = #poly_pts
    if n < 3 then return false end

    local inside = false
    local j = n
    for i = 1, n do
        local pi = poly_pts[i]
        local pj = poly_pts[j]
        if ((pi.y > py) ~= (pj.y > py)) and
           (px < (pj.x - pi.x) * (py - pi.y) / (pj.y - pi.y) + pi.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

--[[--
How far apart, in pixels, the points of a stroke are tested.

Fixed, rather than a fraction of the stroke's length. A fraction reads as ten
tests whatever the stroke is, which on a long one means testing it every
sixtieth of its length: a loop drawn round a word of a line that was written in
a single stroke tested no point inside the loop and selected nothing. Fixed
spacing makes the resolution of the test a property of the lasso -- roughly a
millimetre on a 300 dpi panel -- rather than of what happens to be under it.
--]]
local SAMPLE_SPACING = 12

--[[--
Tests if a stroke is selected by a lasso polygon.

A stroke is selected when part of the stroke itself is inside the loop.

The centre of its bounding box used to count as well, and that is not a point
of the stroke: it is a point of the rectangle around it, and for anything
concave -- an L, an arc, a large circle, a long diagonal -- it lies in the empty
space the stroke encloses rather than on the ink. A small loop drawn in the gap
inside an L therefore selected the L without ever having touched it.
--]]
function Lasso.isStrokeSelected(stroke, poly_pts)
    if not stroke or stroke:count() == 0 then return false end

    local count = stroke:count()
    local px, py = stroke:getPoint(1)
    if Lasso.pointInPolygon(px, py, poly_pts) then return true end

    -- Walked by distance travelled, so a densely sampled stroke is not tested
    -- more finely than a sparse one covering the same ground.
    local since = 0
    for i = 2, count do
        local x, y = stroke:getPoint(i)
        local dx, dy = x - px, y - py
        since = since + math.sqrt(dx * dx + dy * dy)
        px, py = x, y
        if since >= SAMPLE_SPACING or i == count then
            since = 0
            if Lasso.pointInPolygon(x, y, poly_pts) then
                return true
            end
        end
    end

    return false
end

--- Finds all strokes on a page selected by a lasso loop.
function Lasso.findSelectedStrokes(page_strokes, lasso_pts)
    local selected = {}
    for _, stroke in ipairs(page_strokes) do
        if Lasso.isStrokeSelected(stroke, lasso_pts) then
            table.insert(selected, stroke)
        end
    end
    return selected
end

--- Computes combined bounding box of a list of strokes.
function Lasso.getSelectionBounds(strokes)
    local bbox = nil
    for _, stroke in ipairs(strokes) do
        local x, y, w, h = stroke:getBounds()
        bbox = Rect.grow(bbox, x, y, w, h)
    end
    return bbox
end

--- Creates independent deep copies of a list of strokes.
function Lasso.cloneStrokes(strokes)
    local Stroke = require("stroke")
    local clones = {}
    for _, stroke in ipairs(strokes) do
        local copy = Stroke:new{
            tool = stroke.tool,
            width = stroke.width,
            color = stroke.color,
            tint = stroke.tint,
        }
        for i = 1, stroke:count() do
            local x, y, p = stroke:getPoint(i)
            copy:addPoint(x, y, p)
        end
        table.insert(clones, copy)
    end
    return clones
end

--- Translates a list of strokes by (dx, dy).
function Lasso.translateStrokes(strokes, dx, dy)
    for _, stroke in ipairs(strokes) do
        stroke:translate(dx, dy)
    end
end

return Lasso
