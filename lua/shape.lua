--[[--
Geometric shape recognizer for handwriting strokes.

Straightens lines and adds arrowheads to open strokes on endpoint hold.
Freehand geometric figures are never regularized. Explicit shapes use the
same vector stroke model for selection, erasing and persistence.

@module notebook.shape
--]]--

local Stroke = require("stroke")

local Shape = {}

--- Perpendicular distance from point (px, py) to line segment (x1, y1)-(x2, y2).
local function pointToSegmentDist(px, py, x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local len_sq = dx * dx + dy * dy
    if len_sq == 0 then
        local ex = px - x1
        local ey = py - y1
        return math.sqrt(ex * ex + ey * ey)
    end

    local t = ((px - x1) * dx + (py - y1) * dy) / len_sq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local proj_x = x1 + t * dx
    local proj_y = y1 + t * dy
    local ex = px - proj_x
    local ey = py - proj_y
    return math.sqrt(ex * ex + ey * ey)
end

--- Total path length of a point list.
local function strokeLength(points)
    local len = 0
    for i = 2, #points do
        local dx = points[i].x - points[i - 1].x
        local dy = points[i].y - points[i - 1].y
        len = len + math.sqrt(dx * dx + dy * dy)
    end
    return len
end

--- Ramer-Douglas-Peucker polyline simplification.
local function simplifyRDP(points, epsilon)
    if #points <= 2 then return points end

    local max_dist = 0
    local max_idx = 0
    local first = points[1]
    local last = points[#points]

    for i = 2, #points - 1 do
        local d = pointToSegmentDist(points[i].x, points[i].y, first.x, first.y, last.x, last.y)
        if d > max_dist then
            max_dist = d
            max_idx = i
        end
    end

    if max_dist > epsilon then
        local left_pts = {}
        for i = 1, max_idx do table.insert(left_pts, points[i]) end
        local right_pts = {}
        for i = max_idx, #points do table.insert(right_pts, points[i]) end

        local res_left = simplifyRDP(left_pts, epsilon)
        local res_right = simplifyRDP(right_pts, epsilon)

        local result = {}
        for i = 1, #res_left - 1 do table.insert(result, res_left[i]) end
        for i = 1, #res_right do table.insert(result, res_right[i]) end
        return result
    else
        return { first, last }
    end
end

--- Tests if a stroke represents a straight line.
local function detectLine(points, total_len)
    if #points < 2 then return nil end
    local first = points[1]
    local last = points[#points]
    local chord = math.sqrt((last.x - first.x)^2 + (last.y - first.y)^2)

    -- A line must not loop back on itself: chord should be >= 80% of path length
    if chord < total_len * 0.80 then return nil end

    local max_dev = 0
    for i = 2, #points - 1 do
        local d = pointToSegmentDist(points[i].x, points[i].y, first.x, first.y, last.x, last.y)
        if d > max_dev then max_dev = d end
    end

    -- Maximum deviation must be small relative to length (<= 8% of chord or <= 20px)
    local tol = math.max(20, chord * 0.08)
    if max_dev <= tol then
        return "line", { first, last }
    end
    return nil
end

--- Filters out redundant points and tail clusters from holding still.
local function filterClusters(points)
    if #points <= 2 then return points end
    local filtered = { points[1] }
    for i = 2, #points do
        local prev = filtered[#filtered]
        local dx = points[i].x - prev.x
        local dy = points[i].y - prev.y
        -- Keep point if moved >= 3px or if it is the very last point
        if dx * dx + dy * dy >= 9 or i == #points then
            table.insert(filtered, points[i])
        end
    end
    return filtered
end

--- Creates a regular, axis-aligned shape inside a dragged rectangle.
function Shape.create(kind, x0, y0, x1, y1, width, color, filled)
    if kind ~= "rectangle" and kind ~= "square" and kind ~= "circle" and kind ~= "triangle" then return nil end
    local w, h = math.abs(x1-x0), math.abs(y1-y0)
    if kind == "square" or kind == "circle" then
        local side = math.min(w, h)
        x1 = x0 + (x1 < x0 and -side or side)
        y1 = y0 + (y1 < y0 and -side or side)
    end
    local left, right = math.min(x0,x1), math.max(x0,x1)
    local top, bottom = math.min(y0,y1), math.max(y0,y1)
    local stroke = Stroke:new{tool="pen", width=width, color=color, shape_kind=kind, filled=filled == true}
    if kind == "triangle" then
        for _, point in ipairs({{left,bottom},{(left+right)/2,top},{right,bottom},{left,bottom}}) do
            stroke:addPoint(point[1],point[2],1)
        end
    elseif kind == "circle" then
        local radius = (right-left)/2
        local cx, cy = (left+right)/2, (top+bottom)/2
        for n = 0, 64 do
            local angle = n * math.pi / 32
            stroke:addPoint(cx + radius*math.cos(angle), cy + radius*math.sin(angle), 1)
        end
    else
        for _, point in ipairs({{left,top},{right,top},{right,bottom},{left,bottom},{left,top}}) do
            stroke:addPoint(point[1],point[2],1)
        end
    end
    return stroke
end

--- Transform one explicit figure from its original points, without accumulating rounding error.
function Shape.transform(original, handle, x, y, start_x, start_y)
    local left, top = original.x_min, original.y_min
    local right, bottom = original.x_max, original.y_max
    local cx, cy = (left + right) / 2, (top + bottom) / 2
    local angle = 0
    if handle == "rotate" then
        angle = math.atan2(y - cy, x - cx) - math.atan2(start_y - cy, start_x - cx)
    else
        if handle:find("w", 1, true) then left = math.min(x, right - 8) end
        if handle:find("e", 1, true) then right = math.max(x, left + 8) end
        if handle:find("n", 1, true) then top = math.min(y, bottom - 8) end
        if handle:find("s", 1, true) then bottom = math.max(y, top + 8) end
    end
    local result = Stroke:new{tool=original.tool, width=original.width,
        color=original.color, shape_kind=original.shape_kind,
        pen_style=original.pen_style, filled=original.filled}
    local old_w = math.max(1, original.x_max - original.x_min)
    local old_h = math.max(1, original.y_max - original.y_min)
    local c, s = math.cos(angle), math.sin(angle)
    for i = 1, original:count() do
        local px, py, pressure = original:getPoint(i)
        if handle == "rotate" then
            local dx, dy = px - cx, py - cy
            result:addPoint(cx + dx*c - dy*s, cy + dx*s + dy*c, pressure)
        else
            result:addPoint(left + (px - original.x_min) * (right-left) / old_w,
                top + (py - original.y_min) * (bottom-top) / old_h, pressure)
        end
    end
    return result
end

--- Straightens a raw line or adds an arrowhead to an open stroke.
-- Returns new_stroke, shape_type or nil if not a recognized shape.
function Shape.recognize(raw_stroke, line_style)
    if not raw_stroke or raw_stroke:count() < 3 then return nil end

    local raw_points = {}
    for i = 1, raw_stroke:count() do
        local x, y, p = raw_stroke:getPoint(i)
        table.insert(raw_points, { x = x, y = y, p = p })
    end

    local points = filterClusters(raw_points)
    if #points < 2 then return nil end

    local total_len = strokeLength(points)
    if total_len < 25 then return nil end
    local first, last = points[1], points[#points]
    local gap = math.sqrt((last.x-first.x)^2 + (last.y-first.y)^2)
    local open_arrow = line_style == "arrow" and gap > math.max(4,raw_stroke.width*1.5)

    -- 1. Try Line
    local shape_type, pts = detectLine(points, total_len)

    -- In arrow mode an open curved shaft keeps its route. RDP removes hand
    -- tremor; two corner-cutting passes soften it while preserving endpoints.
    if not shape_type and open_arrow then
            pts = simplifyRDP(points, math.max(2, total_len * 0.008))
            for _ = 1, 2 do
                local smooth = {pts[1]}
                for i = 1, #pts-1 do
                    local u, v = pts[i], pts[i+1]
                    smooth[#smooth+1] = {x=.75*u.x+.25*v.x, y=.75*u.y+.25*v.y}
                    smooth[#smooth+1] = {x=.25*u.x+.75*v.x, y=.25*u.y+.75*v.y}
                end
                smooth[#smooth+1] = pts[#pts]
                pts = smooth
            end
            shape_type = "line"
    end
    if shape_type == "line" and line_style == "arrow" then
        local a, b = pts[math.max(1, #pts-3)], pts[#pts]
        local dx, dy = b.x - a.x, b.y - a.y
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0 then
            local head = math.min(total_len * 0.3, math.max(14, raw_stroke.width * 4))
            local ux, uy = dx / length, dy / length
            local function wing(side)
                return { x = b.x - head * ux + side * head * 0.5 * uy,
                    y = b.y - head * uy - side * head * 0.5 * ux, p = 1 }
            end
            pts[#pts+1], pts[#pts+2], pts[#pts+3] = wing(1), b, wing(-1)
            shape_type = "arrow"
        end
    end

    if shape_type and pts then
        local clean_stroke = Stroke:new{
            shape_kind = shape_type,
            tool = raw_stroke.tool,
            pen_style = raw_stroke.pen_style,
            filled = raw_stroke.filled,
            width = raw_stroke.width,
            color = raw_stroke.color,
            -- Carried, so a shape snapped mid-stroke keeps being drawn in the
            -- shade the stroke was being drawn in rather than jumping tone.
            tint = raw_stroke.tint,
        }
        for _, pt in ipairs(pts) do
            clean_stroke:addPoint(pt.x, pt.y, pt.p or 1)
        end
        return clean_stroke, shape_type
    end

    return nil
end

return Shape
