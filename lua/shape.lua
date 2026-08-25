--[[--
Geometric shape recognizer for handwriting strokes.

Analyzes raw stroke point streams and classifies them into:
- "line": straight line between endpoints
- "circle": circle centered on stroke centroid
- "ellipse": axis-aligned or rotated ellipse
- "triangle": closed 3-vertex polygon
- "rectangle": closed 4-vertex quadrilateral (or square)

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

--- Computes polygon area using Shoelace formula.
local function polygonArea(points)
    local area = 0
    local n = #points
    for i = 1, n do
        local j = (i % n) + 1
        area = area + (points[i].x * points[j].y - points[j].x * points[i].y)
    end
    return math.abs(area) / 2
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

--- Tests if a stroke forms a circle or ellipse.
local function detectCircleOrEllipse(points, total_len)
    if #points < 6 then return nil end
    local first = points[1]
    local last = points[#points]
    local close_dist = math.sqrt((last.x - first.x)^2 + (last.y - first.y)^2)

    -- Must be closed or near-closed (gap <= 35% of path length)
    if close_dist > total_len * 0.35 then return nil end

    -- Compute centroid
    local cx, cy = 0, 0
    for _, pt in ipairs(points) do
        cx = cx + pt.x
        cy = cy + pt.y
    end
    cx = cx / #points
    cy = cy / #points

    -- Compute radii from centroid
    local radii = {}
    local r_mean = 0
    local r_min, r_max = math.huge, 0
    for _, pt in ipairs(points) do
        local r = math.sqrt((pt.x - cx)^2 + (pt.y - cy)^2)
        table.insert(radii, r)
        r_mean = r_mean + r
        if r < r_min then r_min = r end
        if r > r_max then r_max = r end
    end
    r_mean = r_mean / #points
    if r_mean < 10 then return nil end

    -- Radial standard deviation
    local var = 0
    for _, r in ipairs(radii) do
        var = var + (r - r_mean)^2
    end
    local std = math.sqrt(var / #points)

    -- A single closed loop has length roughly equal to its circumference ~ 2*pi*r_mean.
    -- Multi-turn spirals have path length much greater than one circumference.
    local expected_circumference = 2 * math.pi * r_mean
    if total_len > 1.45 * expected_circumference then return nil end

    -- Bounding box
    local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
    for _, pt in ipairs(points) do
        if pt.x < min_x then min_x = pt.x end
        if pt.y < min_y then min_y = pt.y end
        if pt.x > max_x then max_x = pt.x end
        if pt.y > max_y then max_y = pt.y end
    end
    local w = max_x - min_x
    local h = max_y - min_y
    local aspect = (w > 0 and h > 0) and (math.min(w, h) / math.max(w, h)) or 1

    -- Circle check: tight radial variance and radius range
    if std / r_mean <= 0.18 and (r_max - r_min) / r_mean <= 0.30 and aspect >= 0.75 then
        local circle_pts = {}
        local num_segs = 36
        for i = 0, num_segs do
            local theta = (i / num_segs) * 2 * math.pi
            table.insert(circle_pts, {
                x = math.floor(cx + r_mean * math.cos(theta) + 0.5),
                y = math.floor(cy + r_mean * math.sin(theta) + 0.5),
                p = 1
            })
        end
        return "circle", circle_pts
    end

    -- Ellipse check
    local rx = w / 2
    local ry = h / 2
    if rx >= 10 and ry >= 10 then
        local ell_var = 0
        for _, pt in ipairs(points) do
            local norm_dist = ((pt.x - cx)/rx)^2 + ((pt.y - cy)/ry)^2
            ell_var = ell_var + (norm_dist - 1)^2
        end
        if math.sqrt(ell_var / #points) <= 0.35 then
            local ell_pts = {}
            local num_segs = 36
            for i = 0, num_segs do
                local theta = (i / num_segs) * 2 * math.pi
                table.insert(ell_pts, {
                    x = math.floor(cx + rx * math.cos(theta) + 0.5),
                    y = math.floor(cy + ry * math.sin(theta) + 0.5),
                    p = 1
                })
            end
            return "ellipse", ell_pts
        end
    end

    return nil
end

--- Tests if a stroke forms a polygon (triangle, rectangle, square).
local function detectPolygon(points, total_len)
    if #points < 6 then return nil end
    local first = points[1]
    local last = points[#points]
    local close_dist = math.sqrt((last.x - first.x)^2 + (last.y - first.y)^2)

    -- Must be closed or near-closed
    if close_dist > total_len * 0.35 then return nil end

    -- Try simplification with epsilon
    local eps = total_len * 0.08
    local simp = simplifyRDP(points, eps)

    -- Ensure total stroke length is consistent with the simplified polygon perimeter (rejects spirals/scribbles)
    local simp_len = 0
    for i = 1, #simp - 1 do
        local pA, pB = simp[i], simp[i + 1]
        simp_len = simp_len + math.sqrt((pB.x - pA.x)^2 + (pB.y - pA.y)^2)
    end
    if total_len > 1.35 * simp_len then return nil end

    local n_verts = #simp - 1
    if n_verts == 3 then
        local p1, p2, p3 = simp[1], simp[2], simp[3]
        -- Centroid
        local cx = (p1.x + p2.x + p3.x) / 3
        local cy = (p1.y + p2.y + p3.y) / 3

        -- Distances of vertices from centroid
        local r1 = math.sqrt((p1.x - cx)^2 + (p1.y - cy)^2)
        local r2 = math.sqrt((p2.x - cx)^2 + (p2.y - cy)^2)
        local r3 = math.sqrt((p3.x - cx)^2 + (p3.y - cy)^2)
        local r_avg = (r1 + r2 + r3) / 3

        -- Find the vertex furthest from centroid (or apex) as primary orientation
        local apex = p1
        local max_r = r1
        if r2 > max_r then apex = p2; max_r = r2 end
        if r3 > max_r then apex = p3; max_r = r3 end

        local theta0 = math.atan2(apex.y - cy, apex.x - cx)
        -- Snap theta to nearest vertical / horizontal if within 12 degrees
        local deg = math.deg(theta0) % 360
        local cardinals = { -90, 0, 90, 180, 270 }
        for _, c in ipairs(cardinals) do
            if math.abs(deg - (c % 360)) < 12 or math.abs(deg - (c % 360) - 360) < 12 then
                theta0 = math.rad(c)
                break
            end
        end

        local tri_pts = {}
        for i = 0, 2 do
            local angle = theta0 + i * (2 * math.pi / 3)
            table.insert(tri_pts, {
                x = math.floor(cx + r_avg * math.cos(angle) + 0.5),
                y = math.floor(cy + r_avg * math.sin(angle) + 0.5),
                p = 1
            })
        end
        table.insert(tri_pts, { x = tri_pts[1].x, y = tri_pts[1].y, p = 1 })
        return "triangle", tri_pts

    elseif n_verts == 4 then
        local p1, p2 = simp[1], simp[2]
        -- Calculate rotation angle along first edge
        local theta = math.atan2(p2.y - p1.y, p2.x - p1.x)
        -- Snap to 0 / 90 / 180 / 270 if close (axis-aligned)
        local deg = (math.deg(theta) % 90)
        if deg < 10 then
            theta = theta - math.rad(deg)
        elseif deg > 80 then
            theta = theta + math.rad(90 - deg)
        end

        local cos_t = math.cos(theta)
        local sin_t = math.sin(theta)

        -- Project all points onto rotated coordinate system
        local min_u, max_u = math.huge, -math.huge
        local min_v, max_v = math.huge, -math.huge
        for _, pt in ipairs(points) do
            local u = pt.x * cos_t + pt.y * sin_t
            local v = -pt.x * sin_t + pt.y * cos_t
            if u < min_u then min_u = u end
            if u > max_u then max_u = u end
            if v < min_v then min_v = v end
            if v > max_v then max_v = v end
        end

        local w = max_u - min_u
        local h = max_v - min_v
        local is_square = math.abs(w - h) / math.max(w, h) < 0.20

        if is_square then
            local side = (w + h) / 2
            local mid_u = (min_u + max_u) / 2
            local mid_v = (min_v + max_v) / 2
            min_u, max_u = mid_u - side/2, mid_u + side/2
            min_v, max_v = mid_v - side/2, mid_v + side/2
        end

        -- Unproject corners back to screen coordinates
        local function unproject(u, v)
            return {
                x = math.floor(u * cos_t - v * sin_t + 0.5),
                y = math.floor(u * sin_t + v * cos_t + 0.5),
                p = 1
            }
        end

        local c1 = unproject(min_u, min_v)
        local c2 = unproject(max_u, min_v)
        local c3 = unproject(max_u, max_v)
        local c4 = unproject(min_u, max_v)

        local rect_pts = { c1, c2, c3, c4, { x = c1.x, y = c1.y, p = 1 } }
        return is_square and "square" or "rectangle", rect_pts
    end

    return nil
end

--- Recognizes a geometric shape from a raw stroke.
-- Returns new_stroke, shape_type or nil if not a recognized shape.
function Shape.recognize(raw_stroke)
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

    -- 1. Try Line
    local shape_type, pts = detectLine(points, total_len)

    -- 2. Try Circle / Ellipse
    if not shape_type then
        shape_type, pts = detectCircleOrEllipse(points, total_len)
    end

    -- 3. Try Polygon (Triangle, Rectangle, Square)
    if not shape_type then
        shape_type, pts = detectPolygon(points, total_len)
    end

    if shape_type and pts then
        local clean_stroke = Stroke:new{
            tool = raw_stroke.tool,
            width = raw_stroke.width,
            color = raw_stroke.color,
        }
        for _, pt in ipairs(pts) do
            clean_stroke:addPoint(pt.x, pt.y, pt.p or 1)
        end
        return clean_stroke, shape_type
    end

    return nil
end

return Shape
