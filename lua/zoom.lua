-- A viewport over the existing page coordinates. Stroke widths stay in page
-- units; only the on-screen renderer scales them.
local Zoom = {}

function Zoom.clamp(origin, start, length, scale)
    return math.max(start, math.min(start + length - length / scale, origin))
end

function Zoom.toPage(x, y, area, scale, ox, oy)
    return ox + (x - area.x) / scale, oy + (y - area.y) / scale
end

function Zoom.toView(x, y, area, scale, ox, oy)
    return area.x + (x - ox) * scale, area.y + (y - oy) * scale
end

return Zoom
