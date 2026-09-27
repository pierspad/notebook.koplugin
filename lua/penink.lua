local Raster = require("raster")
-- Rasterize the union of pressure-interpolated discs with one span per row.
-- A long sweep never stamps the same interior pixel hundreds of times.
local bit=require("bit")
local PenInk={}
local function grain(x,y)
    local h=bit.tobit(x*374761393+bit.tobit(y*668265263))
    h=bit.bxor(h,bit.rshift(h,13))
    h=bit.tobit(h*1274126177)
    return bit.band(bit.bxor(h,bit.rshift(h,16)),65535)/65535
end

function PenInk.draw(bb,x0,y0,r0,x1,y1,r1,color,rgb,pencil,gx,gy)
    r0,r1=math.max(0.5,r0),math.max(0.5,r1)
    gx,gy=gx or 0,gy or 0
    local dx,dy=x1-x0,y1-y0
    local length=math.sqrt(dx*dx+dy*dy)
    if length==0 then x0=math.floor(x0+0.5);y0=math.floor(y0+0.5);x1,y1=x0,y0 end
    local points
    if length>math.abs(r1-r0) then
        local ux,uy=dx/length,dy/length
        local k=(r0-r1)/length
        local q=math.sqrt(1-k*k)
        local ax,ay=k*ux-q*uy,k*uy+q*ux
        local bx,by=k*ux+q*uy,k*uy-q*ux
        points={{x0+r0*ax,y0+r0*ay},{x1+r1*ax,y1+r1*ay},
            {x1+r1*bx,y1+r1*by},{x0+r0*bx,y0+r0*by}}
    end
    local first=math.max(0,math.ceil(math.min(y0-r0,y1-r1)))
    local last=math.min(bb:getHeight()-1,math.floor(math.max(y0+r0,y1+r1)))
    local maxx=bb:getWidth()-1
    for y=first,last do
        local left,right=math.huge,-math.huge
        if math.abs(y-y0)<=r0 then
            local extent=math.sqrt(math.max(0,r0*r0-(y-y0)^2))
            left,right=x0-extent,x0+extent
        end
        if math.abs(y-y1)<=r1 then
            local extent=math.sqrt(math.max(0,r1*r1-(y-y1)^2))
            left,right=math.min(left,x1-extent),math.max(right,x1+extent)
        end
        if points then
            local prev=points[4]
            for i=1,4 do
                local p=points[i]
                if prev[2]==y and p[2]==y then
                    left,right=math.min(left,prev[1],p[1]),math.max(right,prev[1],p[1])
                elseif (prev[2]<=y and p[2]>y) or (p[2]<=y and prev[2]>y) then
                    local x=prev[1]+(y-prev[2])*(p[1]-prev[1])/(p[2]-prev[2])
                    left,right=math.min(left,x),math.max(right,x)
                end
                prev=p
            end
        end
        left,right=math.max(0,math.ceil(left)),math.min(maxx,math.floor(right))
        if left<=right then
            if pencil then
                for x=left,right do
                    local t=length>0 and math.max(0,math.min(1,((x-x0)*dx+(y-y0)*dy)/(length*length))) or 0
                    local r=r0+(r1-r0)*t
                    local distance=((x-x0-dx*t)^2+(y-y0-dy*t)^2)/(r*r)
                    if grain(x+gx,y+gy)<0.74*(1-0.4*math.min(1,distance)) then
                        bb:setPixel(x,y,color)
                    end
                end
            elseif rgb and bb.paintRectRGB32 then
                Raster.rect(bb,left,y,right-left+1,1,color,true)
            else
                Raster.rect(bb,left,y,right-left+1,1,color)
            end
        end
    end
end

return PenInk
