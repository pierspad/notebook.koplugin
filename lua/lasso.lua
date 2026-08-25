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

--- Tests if a stroke is selected by a lasso polygon.
-- A stroke is selected if its center or any of its sample points are inside the polygon.
function Lasso.isStrokeSelected(stroke, poly_pts)
    if not stroke or stroke:count() == 0 then return false end

    local bx, by, bw, bh = stroke:getBounds()
    local cx = bx + bw / 2
    local cy = by + bh / 2
    if Lasso.pointInPolygon(cx, cy, poly_pts) then
        return true
    end

    local count = stroke:count()
    local step = math.max(1, math.floor(count / 10))
    for i = 1, count, step do
        local x, y = stroke:getPoint(i)
        if Lasso.pointInPolygon(x, y, poly_pts) then
            return true
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
