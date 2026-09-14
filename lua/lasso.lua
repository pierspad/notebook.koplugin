--[[--
Lasso selection and geometric containment helpers for strokes.

@module notebook.lasso
--]]--

local Rect = require("rect")
local Tuning = require("tuning")

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

    --[[
    Nothing whose box misses the loop's box can be inside it.

    Free, and worth having now rather than before: what follows walks the ink
    itself rather than hopping from one recorded point to the next, so a page of
    long strokes costs more of it than it used to. This answers for all the
    strokes the loop is nowhere near, which on a written page is nearly all of
    them, without measuring anything.
    ]]
    local lx0, ly0 = math.huge, math.huge
    local lx1, ly1 = -math.huge, -math.huge
    for _, p in ipairs(poly_pts) do
        if p.x < lx0 then lx0 = p.x end
        if p.y < ly0 then ly0 = p.y end
        if p.x > lx1 then lx1 = p.x end
        if p.y > ly1 then ly1 = p.y end
    end
    local bx, by, bw, bh = stroke:getBounds()
    if lx1 < bx or lx0 > bx + bw or ly1 < by or ly0 > by + bh then
        return false
    end

    local spacing = Tuning.lasso_sample_spacing
    local count = stroke:count()
    local px, py = stroke:getPoint(1)
    if Lasso.pointInPolygon(px, py, poly_pts) then return true end

    --[[
    Walked along the ink, not from one recorded point to the next.

    The two are the same thing for handwriting, whose points are a few pixels
    apart, and they are not the same thing at all for a straight line: a line is
    stored as its two ends, and the shape recogniser reduces one to exactly
    that. Testing only the points meant testing only the two ends, so a loop
    drawn round the middle of a line selected nothing -- and the same line drawn
    by the same hand was selectable before it was straightened and not after,
    which is the kind of difference nobody can be expected to guess at.

    Sampling by distance travelled is what keeps the resolution a property of
    the lasso rather than of what happens to be under it, so `since` carries
    across the join: a step does not restart at every recorded point.
    ]]
    local since = 0
    for i = 2, count do
        local x, y = stroke:getPoint(i)
        local dx, dy = x - px, y - py
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then
            local at = spacing - since
            while at <= len do
                local t = at / len
                if Lasso.pointInPolygon(px + dx * t, py + dy * t, poly_pts) then
                    return true
                end
                at = at + spacing
            end
            since = (since + len) % spacing
        end
        px, py = x, y
    end

    -- The far end always counts, however short the last step to it was.
    return Lasso.pointInPolygon(px, py, poly_pts)
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
    local clones = {}
    for i, stroke in ipairs(strokes) do
        clones[i] = stroke:clone()
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
