-- Convex marker footprints and geometric area subtraction. Fragments use the
-- existing filled-stroke representation: storage, cloning and undo need no
-- raster masks or new file format. Coordinates remain in page space.
local Area = {}

local function cross(a,b,c)
    return (b[1]-a[1])*(c[2]-a[2])-(b[2]-a[2])*(c[1]-a[1])
end

local function hull(points)
    table.sort(points,function(a,b) return a[1]<b[1] or (a[1]==b[1] and a[2]<b[2]) end)
    local out={}
    for _,p in ipairs(points) do
        while #out>=2 and cross(out[#out-1],out[#out],p)<=0 do out[#out]=nil end
        out[#out+1]=p
    end
    local lower=#out
    for i=#points-1,1,-1 do
        local p=points[i]
        while #out>lower and cross(out[#out-1],out[#out],p)<=0 do out[#out]=nil end
        out[#out+1]=p
    end
    out[#out]=nil
    return out
end

function Area.sweep(x0,y0,r0,x1,y1,r1)
    local points={}
    for _,v in ipairs({{x0,y0,r0},{x1,y1,r1}}) do
        for _,dx in ipairs({-1,1}) do for _,dy in ipairs({-1,1}) do
            points[#points+1]={v[1]+dx*v[3],v[2]+dy*v[3]}
        end end
    end
    return hull(points)
end

local function bounds(points)
    local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
    for _,p in ipairs(points) do
        x0,y0=math.min(x0,p[1]),math.min(y0,p[2])
        x1,y1=math.max(x1,p[1]),math.max(y1,p[2])
    end
    return x0,y0,x1,y1
end

local function clip(points,a,b,inside)
    local result={}
    local prev=points[#points]
    if not prev then return result end
    local pd=cross(a,b,prev)
    for _,p in ipairs(points) do
        local d=cross(a,b,p)
        local pin=inside and pd>=0 or (not inside and pd<=0)
        local cin=inside and d>=0 or (not inside and d<=0)
        if pin~=cin then
            local t=pd/(pd-d)
            result[#result+1]={prev[1]+(p[1]-prev[1])*t,prev[2]+(p[2]-prev[2])*t}
        end
        if cin then result[#result+1]=p end
        prev,pd=p,d
    end
    return result
end

local function nonempty(points)
    if #points<3 then return false end
    local area=0
    local prev=points[#points]
    for _,p in ipairs(points) do
        area=area+prev[1]*p[2]-p[1]*prev[2];prev=p
    end
    return math.abs(area)>1e-7
end

local function subtract(points,cutter)
    local x0,y0,x1,y1=bounds(points)
    local a0,b0,a1,b1=bounds(cutter)
    if x1<a0 or x0>a1 or y1<b0 or y0>b1 then return {points},false end
    -- Test actual intersection before splitting: a bounding-box overlap alone
    -- must never fragment a missed stroke or create an undo record.
    local intersection=points
    local prev=cutter[#cutter]
    for _,p in ipairs(cutter) do
        intersection=clip(intersection,prev,p,true);prev=p
        if not nonempty(intersection) then return {points},false end
    end
    local result,remaining={},points
    prev=cutter[#cutter]
    for _,p in ipairs(cutter) do
        local outside=clip(remaining,prev,p,false)
        if nonempty(outside) then result[#result+1]=outside end
        remaining=clip(remaining,prev,p,true);prev=p
        if not nonempty(remaining) then break end
    end
    return result,true
end

local function capsule(x0,y0,x1,y1,r)
    local points={}
    -- Circumscribed 24-gon: no un-erased slivers inside the circular nib.
    -- Maximum overcut is r*(sec(pi/24)-1), under 0.35 px at r=40.
    local radius=r/math.cos(math.pi/24)
    for _,v in ipairs({{x0,y0},{x1,y1}}) do
        for i=0,23 do
            local a=(i+.5)*math.pi/12
            points[#points+1]={v[1]+radius*math.cos(a),v[2]+radius*math.sin(a)}
        end
    end
    return hull(points)
end

-- End indices of independent convex contours in one marker-area stroke.
-- Keeping them in one flat point array avoids thousands of document objects
-- after cutting a densely sampled curve; no bridge edges are ever drawn.
function Area.parts(stroke)
    local parts=stroke.marker_parts
    local index,first=0,1
    return function()
        index=index+1
        local last=parts and parts[index] or (index==1 and stroke:count())
        if not last then return nil end
        local start=first;first=last+1
        return start,last
    end
end

function Area.erase(stroke,path,r,context)
    if #path<2 or r<=0 or stroke.n==0 then return nil end
    local x0,y0,x1,y1=stroke:getBounds()
    x1,y1=x0+x1,y0+y1
    local px0,py0,px1,py1=math.huge,math.huge,-math.huge,-math.huge
    for i=1,#path-1,2 do
        px0,py0=math.min(px0,path[i]-r),math.min(py0,path[i+1]-r)
        px1,py1=math.max(px1,path[i]+r),math.max(py1,path[i+1]+r)
    end
    if px1<x0 or px0>x1 or py1<y0 or py0>y1 then return nil end
    local extra=r*(1/math.cos(math.pi/24)-1)
    -- Cutters are immutable during clipping. All markers in this display
    -- batch share them, instead of rebuilding the same 24-gon per stroke.
    local cutters=context and context.cutters
    if not cutters then
        cutters={}
        for i=1,math.max(1,#path-3),2 do
            cutters[#cutters+1]=capsule(path[i],path[i+1],path[i+2] or path[i],path[i+3] or path[i+1],r)
        end
        if context then context.cutters=cutters end
    end
    local Stroke=require("stroke")
    local Renderer=require("renderer")
    local changed=false
    local fragments={}
    local untouched,area_fragment
    local function keep(first,last)
        if not untouched then
            area_fragment=nil
            untouched=Stroke:new{tool=stroke.tool,width=stroke.width,color=stroke.color,tint=stroke.tint}
            untouched:appendRange(stroke,first,first)
            fragments[#fragments+1]=untouched
        end
        if last>first then untouched:appendRange(stroke,first+1,last) end
    end
    local function cut(points,first,last)
        local polygons={points}
        local hit=false
        for _,cutter in ipairs(cutters) do
            local next_polygons={}
            for _,polygon in ipairs(polygons) do
                local pieces,touched=subtract(polygon,cutter)
                hit=hit or touched
                for _,piece in ipairs(pieces) do next_polygons[#next_polygons+1]=piece end
            end
            polygons=next_polygons
        end
        if not hit and not stroke.filled then
            -- Preserve untouched runs as compact original centreline strokes.
            -- A small dab must not turn a thousand-point marker into a
            -- thousand independent polygon objects.
            keep(first,last)
            return
        end
        changed=changed or hit
        untouched=nil
        for _,polygon in ipairs(polygons) do
            if not area_fragment then
                area_fragment=Stroke:new{tool="highlighter",width=stroke.width,
                    color=stroke.color,tint=stroke.tint,filled=true,marker_parts={}}
                fragments[#fragments+1]=area_fragment
            end
            for _,p in ipairs(polygon) do area_fragment:addPoint(p[1],p[2],1) end
            area_fragment.marker_parts[#area_fragment.marker_parts+1]=area_fragment.n
        end
    end
    if stroke.filled then
        for first,last in Area.parts(stroke) do
            local points={}
            for i=first,last do local x,y=stroke:getPoint(i);points[#points+1]={x,y} end
            cut(points)
        end
    else
        local first=1
        while first<=stroke.n do
            local last=math.min(first+1,stroke.n)
            local ax,ay,ap=stroke:getPoint(first)
            local bx,by,bp=stroke:getPoint(last)
            if not stroke.pen_style and ap==bp then
                while last<stroke.n do
                    local cx,cy,cp=stroke:getPoint(last+1)
                    local dx,dy=bx-ax,by-ay
                    if cp~=ap or math.abs(dx*(cy-ay)-dy*(cx-ax))>1e-8
                        or dx*(cx-bx)+dy*(cy-by)<0 then break end
                    last=last+1;bx,by,bp=cx,cy,cp
                end
            end
            local ar=Renderer.radiusFor(stroke,ap,bx-ax,by-ay)
            local br=Renderer.radiusFor(stroke,bp,bx-ax,by-ay)
            -- Reject in scalar space before constructing a convex hull or
            -- allocating polygon pieces for every missed centreline segment.
            local radius=math.max(ar,br)
            -- The circumscribed cutter extends slightly beyond r. Include it
            -- here to preserve exactly the clipping geometry at nib edges.
            if math.max(ax,bx)+radius<px0-extra or math.min(ax,bx)-radius>px1+extra
                or math.max(ay,by)+radius<py0-extra or math.min(ay,by)-radius>py1+extra then
                keep(first,last)
            else
                cut(Area.sweep(ax,ay,ar,bx,by,br),first,last)
            end
            if last==stroke.n then break end
            first=last
        end
    end
    if not changed then return nil end
    -- Geometry changes only within the swept nib (plus polygon approximation).
    local pad=extra+2
    local left,top=math.max(x0,px0-pad),math.max(y0,py0-pad)
    local right,bottom=math.min(x1,px1+pad),math.min(y1,py1+pad)
    return fragments,left,top,right-left,bottom-top
end

return Area
