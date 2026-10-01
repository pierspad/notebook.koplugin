-- Whole-stroke erasing uses the painted square nib, including pressure and
-- disconnected fragments. No rasterization or fragment allocation is needed.
local Area=require("markerarea")
local Renderer=require("renderer")
local M={}
local function distance(px,py,ax,ay,bx,by)
    local dx,dy=bx-ax,by-ay
    local den=dx*dx+dy*dy
    local t=den>0 and math.max(0,math.min(1,((px-ax)*dx+(py-ay)*dy)/den)) or 0
    dx,dy=px-ax-t*dx,py-ay-t*dy
    return dx*dx+dy*dy
end
local function cross(ax,ay,bx,by,cx,cy)
    return (bx-ax)*(cy-ay)-(by-ay)*(cx-ax)
end
local function edgesNear(ax,ay,bx,by,cx,cy,dx,dy,r2)
    if math.max(ax,bx)>=math.min(cx,dx) and math.min(ax,bx)<=math.max(cx,dx)
        and math.max(ay,by)>=math.min(cy,dy) and math.min(ay,by)<=math.max(cy,dy)
        and cross(ax,ay,bx,by,cx,cy)*cross(ax,ay,bx,by,dx,dy)<=0
        and cross(cx,cy,dx,dy,ax,ay)*cross(cx,cy,dx,dy,bx,by)<=0 then return true end
    return distance(ax,ay,cx,cy,dx,dy)<=r2 or distance(bx,by,cx,cy,dx,dy)<=r2
        or distance(cx,cy,ax,ay,bx,by)<=r2 or distance(dx,dy,ax,ay,bx,by)<=r2
end
local function touches(poly,path,r)
    local r2=r*r
    for i=1,#path-1,2 do
        local px,py=path[i],path[i+1]
        local qx,qy=path[i+2] or px,path[i+3] or py
        local inside=false
        local a=poly[#poly]
        for _,b in ipairs(poly) do
            if (a[2]>py)~=(b[2]>py) and px<(b[1]-a[1])*(py-a[2])/(b[2]-a[2])+a[1] then inside=not inside end
            if edgesNear(px,py,qx,qy,a[1],a[2],b[1],b[2],r2) then return true end
            a=b
        end
        if inside then return true end
    end
    return false
end
function M.path(stroke,path,r)
    if stroke.n==0 or #path<2 then return false end
    local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
    for i=1,#path-1,2 do
        x0,y0=math.min(x0,path[i]-r),math.min(y0,path[i+1]-r)
        x1,y1=math.max(x1,path[i]+r),math.max(y1,path[i+1]+r)
    end
    local bx,by,bw,bh=stroke:getBounds()
    if bx>x1 or by>y1 or bx+bw<x0 or by+bh<y0 then return false end
    if stroke.filled then
        for first,last in Area.parts(stroke) do
            local poly={}
            for i=first,last do local x,y=stroke:getPoint(i);poly[#poly+1]={x,y} end
            if touches(poly,path,r) then return true end
        end
        return false
    end
    local function segment(first,last)
        local ax,ay,ap=stroke:getPoint(first)
        local cx,cy,cp=stroke:getPoint(last)
        local ar=Renderer.radiusFor(stroke,ap,cx-ax,cy-ay)
        local cr=Renderer.radiusFor(stroke,cp,cx-ax,cy-ay)
        if math.min(ax-ar,cx-cr)>x1 or math.max(ax+ar,cx+cr)<x0
            or math.min(ay-ar,cy-cr)>y1 or math.max(ay+ar,cy+cr)<y0 then return false end
        -- Contacts on either endpoint square need no hull or edge arrays.
        -- The squares are part of the painted sweep even at pressure changes.
        for i=1,#path-1,2 do
            local dx=math.max(0,math.abs(path[i]-ax)-ar)
            local dy=math.max(0,math.abs(path[i+1]-ay)-ar)
            if dx*dx+dy*dy<=r*r then return true end
            dx=math.max(0,math.abs(path[i]-cx)-cr)
            dy=math.max(0,math.abs(path[i+1]-cy)-cr)
            if dx*dx+dy*dy<=r*r then return true end
        end
        return touches(Area.sweep(ax,ay,ar,cx,cy,cr),path,r)
    end
    if stroke.n==1 then return segment(1,1) end
    local chunks=stroke:chunkIndex()
    if chunks then
        local pad=stroke.width/2
        for _,chunk in ipairs(chunks) do
            if chunk[3]-pad<=x1 and chunk[5]+pad>=x0 and chunk[4]-pad<=y1 and chunk[6]+pad>=y0 then
                for i=chunk[1],chunk[2]-1 do if segment(i,i+1) then return true end end
            end
        end
    else
        for i=1,stroke.n-1 do if segment(i,i+1) then return true end end
    end
    return false
end
return M
