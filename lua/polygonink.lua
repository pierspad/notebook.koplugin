-- Scanline rasterization for transformed figures. Work scales with edge height,
-- not edge length times brush area as it does for overlapping pen stamps.
local PolygonInk = {}

function PolygonInk.draw(bb, stroke, clip, color, color_enabled)
    local left = math.max(0, clip and math.floor(clip.x) or 0)
    local top = math.max(0, clip and math.floor(clip.y) or 0)
    local right = math.min(bb:getWidth()-1, clip and math.ceil(clip.x+clip.w)-1 or bb:getWidth()-1)
    local bottom = math.min(bb:getHeight()-1, clip and math.ceil(clip.y+clip.h)-1 or bb:getHeight()-1)
    local rgb = color_enabled and type(stroke.color) == "number"
        and stroke.color >= 0x1000000 and stroke.color <= 0x1FFFFFF and bb.paintRectRGB32
    local function span(y, a, b)
        a, b = math.max(left, math.ceil(a)), math.min(right, math.floor(b))
        if a <= b then
            if rgb then bb:paintRectRGB32(a,y,b-a+1,1,color)
            else bb:paintRect(a,y,b-a+1,1,color) end
        end
    end
    local function fill(points)
        local ymin, ymax = math.huge, -math.huge
        for _, p in ipairs(points) do ymin=math.min(ymin,p[2]); ymax=math.max(ymax,p[2]) end
        local intersections = {}
        for y=math.max(top,math.ceil(ymin)),math.min(bottom,math.floor(ymax)) do
            local count = 0
            local prev = points[#points]
            for _, p in ipairs(points) do
                if (prev[2] <= y and p[2] > y) or (p[2] <= y and prev[2] > y) then
                    count=count+1
                    intersections[count]=prev[1]+(y-prev[2])*(p[1]-prev[1])/(p[2]-prev[2])
                end
                prev=p
            end
            for i=#intersections,count+1,-1 do intersections[i]=nil end
            table.sort(intersections)
            for i=1,count-1,2 do span(y,intersections[i],intersections[i+1]) end
        end
    end
    local points = {}
    for i=1,stroke:count() do
        local x,y=stroke:getPoint(i)
        points[#points+1]={x,y}
    end
    if #points < 2 then return false end
    if stroke.filled then fill(points) end
    local r=math.max(0.5,stroke.width/2)
    if right<left or bottom<top then return true end
    local target=bb:viewport(left,top,right-left+1,bottom-top+1)
    local PenInk=require("penink")
    local previous=points[#points]
    for _,p in ipairs(points) do
        PenInk.draw(target,previous[1]-left,previous[2]-top,r,p[1]-left,p[2]-top,r,color,rgb,false)
        previous=p
    end
    return true
end

return PolygonInk
