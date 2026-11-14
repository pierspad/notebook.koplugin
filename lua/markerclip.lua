-- Convex polygon subtraction. Coordinates and shared vertices are immutable.
local function bounds(points)
    if points.bounds then return unpack(points.bounds) end
    local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
    for _,p in ipairs(points) do
        x0,y0=math.min(x0,p[1]),math.min(y0,p[2])
        x1,y1=math.max(x1,p[1]),math.max(y1,p[2])
    end
    points.bounds={x0,y0,x1,y1}
    return x0,y0,x1,y1
end

-- Split both half-planes in one traversal. Shared vertices are immutable.
local function split(points,a,b)
    local ax,ay=a[1],a[2]
    local dx,dy=b[1]-ax,b[2]-ay
    local low,high=math.huge,-math.huge
    for i=1,#points do
        local point=points[i]
        local d=dx*(point[2]-ay)-dy*(point[1]-ax)
        if d<low then low=d end
        if d>high then high=d end
        if low<0 and high>0 then break end
    end
    -- Most cutter edges contain the whole remaining polygon on one side.
    -- Reuse its immutable vertices and return nil for the empty side.
    if low>=0 then return points,nil end
    if high<=0 then return nil,points end
    local inside,outside={},{}
    local np=#points
    local prev=points[np]
    if not prev then return inside,outside end
    local pd=dx*(prev[2]-ay)-dy*(prev[1]-ax)
    for i=1,np do
        local p=points[i]
        local d=dx*(p[2]-ay)-dy*(p[1]-ax)
        if (pd>=0)~=(d>=0) or (pd<=0)~=(d<=0) then
            local t=pd/(pd-d)
            local q={prev[1]+(p[1]-prev[1])*t,prev[2]+(p[2]-prev[2])*t}
            if (pd>=0)~=(d>=0) then inside[#inside+1]=q end
            if (pd<=0)~=(d<=0) then outside[#outside+1]=q end
        end
        if d>=0 then inside[#inside+1]=p end
        if d<=0 then outside[#outside+1]=p end
        prev,pd=p,d
    end
    return inside,outside
end

local function nonempty(points)
    if not points then return false end
    local np=#points
    if np<3 then return false end
    local area=0
    local prev=points[np]
    for i=1,np do
        local p=points[i]
        area=area+prev[1]*p[2]-p[1]*prev[2];prev=p
    end
    return math.abs(area)>1e-7
end

local function subtract(points,cutter)
    local x0,y0,x1,y1=bounds(points)
    local a0,b0,a1,b1=bounds(cutter)
    if x1<a0 or x0>a1 or y1<b0 or y0>b1 then return {points},false end
    -- Keep the original polygon on a miss. Computing both pieces together
    -- avoids clipping the intersection once, then clipping it twice again.
    local result,remaining={},points
    local nc=#cutter
    local prev=cutter[nc]
    for i=1,nc do
        local p=cutter[i]
        local inside,outside=split(remaining,prev,p)
        if outside and nonempty(outside) then result[#result+1]=outside end
        remaining=inside;prev=p
        if not nonempty(remaining) then return {points},false end
    end
    return result,true
end

return {subtract=subtract}
