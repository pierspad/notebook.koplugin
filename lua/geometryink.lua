local Raster = require("raster")
-- Fast rasterization of axis-aligned geometric figures. A normal stroke
-- renderer keeps the fallback for rotated or irregular figures.
local GeometryInk = {}

function GeometryInk.draw(bb, stroke, clip, color, color_enabled)
    -- A recognized marker shape still blends with paper and existing ink.
    -- Opaque geometric fills would turn it into a pen stroke.
    if stroke.tool == "highlighter" or stroke.pen_style == "pencil"
        or stroke.pen_style == "fountain" then return false end
    -- Regular geometry is a primitive, not thousands of overlapping round
    -- pen stamps. Scan each circle row once; rectangles need only four spans.
    local kind = stroke.shape_kind
    local axis_aligned = true
    if kind == "rectangle" or kind == "square" then
        local ax, ay = stroke:getPoint(1)
        local bx, by = stroke:getPoint(2)
        axis_aligned = math.abs(ay-by) < 0.01 and math.abs(bx-ax) > 0.01
    elseif kind == "circle" then
        axis_aligned = math.abs((stroke.x_max-stroke.x_min)-(stroke.y_max-stroke.y_min)) < 0.01
    end
    if kind == "triangle" or (not axis_aligned and
        (kind == "rectangle" or kind == "square" or kind == "circle")) then
        return require("polygonink").draw(bb, stroke, clip, color, color_enabled)
    end
    if axis_aligned and (kind == "circle" or kind == "rectangle" or kind == "square") then
        local x0,y0 = stroke.x_min,stroke.y_min
        local x1,y1 = stroke.x_max,stroke.y_max
        local left = clip and math.max(0, math.floor(clip.x)) or 0
        local top = clip and math.max(0, math.floor(clip.y)) or 0
        local right = clip and math.min(bb:getWidth()-1, math.ceil(clip.x+clip.w)-1)
            or bb:getWidth()-1
        local bottom = clip and math.min(bb:getHeight()-1, math.ceil(clip.y+clip.h)-1)
            or bb:getHeight()-1
        if right < left or bottom < top then return true end
        local r = stroke.width/2
        local rgb = color_enabled and type(stroke.color) == "number"
            and stroke.color >= 0x1000000 and stroke.color <= 0x1FFFFFF
            and bb.paintRectRGB32
        local function span(y,a,b)
            a,b=math.max(left,math.ceil(a)),math.min(right,math.floor(b))
            if b>=a and y>=top and y<=bottom then
                if rgb then Raster.rect(bb,a,y,b-a+1,1,color,true)
                else Raster.rect(bb,a,y,b-a+1,1,color) end
            end
        end
        if kind == "circle" then
            local cx,cy=(x0+x1)/2,(y0+y1)/2
            local outer=(x1-x0)/2+r
            if stroke.filled then
                for y=math.max(top,math.ceil(cy-outer)),math.min(bottom,math.floor(cy+outer)) do
                    local dy=y-cy
                    local dx=math.sqrt(math.max(0,outer*outer-dy*dy))
                    span(y,cx-dx,cx+dx)
                end
            else
                local inner=math.max(0,(x1-x0)/2-r)
                for y=math.max(top,math.ceil(cy-outer)),math.min(bottom,math.floor(cy+outer)) do
                    local dy=y-cy
                    local dx=math.sqrt(math.max(0,outer*outer-dy*dy))
                    if math.abs(dy)<inner then
                        local hole=math.sqrt(inner*inner-dy*dy)
                        span(y,cx-dx,cx-hole); span(y,cx+hole,cx+dx)
                    else span(y,cx-dx,cx+dx) end
                end
            end
        else
            local function block(a, b, first, last)
                a, b = math.max(left, math.ceil(a)), math.min(right, math.floor(b))
                first, last = math.max(top, first), math.min(bottom, last)
                if a > b or first > last then return end
                if rgb then Raster.rect(bb,a, first, b-a+1, last-first+1, color,true)
                else Raster.rect(bb,a, first, b-a+1, last-first+1, color) end
            end
            local first, last = math.ceil(y0-r), math.floor(y1+r)
            if stroke.filled then
                block(x0-r, x1+r, first, last)
            else
                local top_end = math.min(last, math.floor(y0+r))
                local bottom_start = math.max(top_end+1, math.ceil(y1-r))
                block(x0-r, x1+r, first, top_end)
                block(x0-r, x1+r, bottom_start, last)
                block(x0-r, x0+r, top_end+1, bottom_start-1)
                block(x1-r, x1+r, top_end+1, bottom_start-1)
            end
        end
        return true
    end
    return false
end

return GeometryInk
