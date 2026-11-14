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
        if kind == "circle" then
            local cx,cy=(x0+x1)/2,(y0+y1)/2
            local outer=(x1-x0)/2+r
            local y_start=math.max(top,math.ceil(cy-outer))
            local y_end=math.min(bottom,math.floor(cy+outer))
            if stroke.filled then
                for y=y_start,y_end do
                    local dy=y-cy
                    local dx=math.sqrt(math.max(0,outer*outer-dy*dy))
                    local a,b=math.max(left,math.ceil(cx-dx)),math.min(right,math.floor(cx+dx))
                    if b>=a then
                        if rgb then Raster.rect(bb,a,y,b-a+1,1,color,true)
                        else Raster.rect(bb,a,y,b-a+1,1,color) end
                    end
                end
            else
                local inner=math.max(0,(x1-x0)/2-r)
                for y=y_start,y_end do
                    local dy=y-cy
                    local dx=math.sqrt(math.max(0,outer*outer-dy*dy))
                    if math.abs(dy)<inner then
                        local hole=math.sqrt(inner*inner-dy*dy)
                        local a1,b1=math.max(left,math.ceil(cx-dx)),math.min(right,math.floor(cx-hole))
                        if b1>=a1 then
                            if rgb then Raster.rect(bb,a1,y,b1-a1+1,1,color,true)
                            else Raster.rect(bb,a1,y,b1-a1+1,1,color) end
                        end
                        local a2,b2=math.max(left,math.ceil(cx+hole)),math.min(right,math.floor(cx+dx))
                        if b2>=a2 then
                            if rgb then Raster.rect(bb,a2,y,b2-a2+1,1,color,true)
                            else Raster.rect(bb,a2,y,b2-a2+1,1,color) end
                        end
                    else
                        local a,b=math.max(left,math.ceil(cx-dx)),math.min(right,math.floor(cx+dx))
                        if b>=a then
                            if rgb then Raster.rect(bb,a,y,b-a+1,1,color,true)
                            else Raster.rect(bb,a,y,b-a+1,1,color) end
                        end
                    end
                end
            end
        else
            local first, last = math.ceil(y0-r), math.floor(y1+r)
            if stroke.filled then
                local a, b = math.max(left, math.ceil(x0-r)), math.min(right, math.floor(x1+r))
                local f, l = math.max(top, first), math.min(bottom, last)
                if a <= b and f <= l then
                    if rgb then Raster.rect(bb,a, f, b-a+1, l-f+1, color,true)
                    else Raster.rect(bb,a, f, b-a+1, l-f+1, color) end
                end
            else
                local top_end = math.min(last, math.floor(y0+r))
                local bottom_start = math.max(top_end+1, math.ceil(y1-r))
                local bx0, bx1 = math.max(left, math.ceil(x0-r)), math.min(right, math.floor(x1+r))
                local bf1, bl1 = math.max(top, first), math.min(bottom, top_end)
                if bx0 <= bx1 and bf1 <= bl1 then
                    if rgb then Raster.rect(bb, bx0, bf1, bx1-bx0+1, bl1-bf1+1, color, true)
                    else Raster.rect(bb, bx0, bf1, bx1-bx0+1, bl1-bf1+1, color) end
                end
                local bf2, bl2 = math.max(top, bottom_start), math.min(bottom, last)
                if bx0 <= bx1 and bf2 <= bl2 then
                    if rgb then Raster.rect(bb, bx0, bf2, bx1-bx0+1, bl2-bf2+1, color, true)
                    else Raster.rect(bb, bx0, bf2, bx1-bx0+1, bl2-bf2+1, color) end
                end
                local bf3, bl3 = math.max(top, top_end+1), math.min(bottom, bottom_start-1)
                if bf3 <= bl3 then
                    local lx1 = math.min(right, math.floor(x0+r))
                    if bx0 <= lx1 then
                        if rgb then Raster.rect(bb, bx0, bf3, lx1-bx0+1, bl3-bf3+1, color, true)
                        else Raster.rect(bb, bx0, bf3, lx1-bx0+1, bl3-bf3+1, color) end
                    end
                    local rx0 = math.max(left, math.ceil(x1-r))
                    if rx0 <= bx1 then
                        if rgb then Raster.rect(bb, rx0, bf3, bx1-rx0+1, bl3-bf3+1, color, true)
                        else Raster.rect(bb, rx0, bf3, bx1-rx0+1, bl3-bf3+1, color) end
                    end
                end
            end
        end
        return true
    end
    return false
end

return GeometryInk
