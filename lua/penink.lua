local Raster = require("raster")
-- Rasterize the union of pressure-interpolated discs with one span per row.
-- A long sweep never stamps the same interior pixel hundreds of times.
local bit=require("bit")
local BB=require("ffi/blitbuffer")
local ok_ffi,ffi=pcall(require,"ffi")
local uint8pt=ok_ffi and ffi.typeof("uint8_t *") or nil
local TYPE_BB8=BB.TYPE_BB8
local PenInk={}
local function grain(x,y)
    local h=bit.tobit(x*374761393+bit.tobit(y*668265263))
    h=bit.bxor(h,bit.rshift(h,13))
    h=bit.tobit(h*1274126177)
    return bit.band(bit.bxor(h,bit.rshift(h,16)),65535)/65535
end

local function colorByte(color)
    if type(color)=="number" then return color end
    if color.a then return color.a end
    if color.getColor8 then return color:getColor8().a end
    return 0
end

local function edgeX(ax,ay,bx,by,y,left,right)
    if (ay<=y and by>y) or (by<=y and ay>y) then
        local x=ax+(y-ay)*(bx-ax)/(by-ay)
        if x<left then left=x end
        if x>right then right=x end
    elseif ay==y and by==y then
        if ax<left then left=ax end; if bx<left then left=bx end
        if ax>right then right=ax end; if bx>right then right=bx end
    end
    return left,right
end

local function drawPencil(bb,x0,y0,r0,x1,y1,r1,color,gx,gy)
    local h=bb:getHeight()
    local w=bb:getWidth()
    local first=math.max(0,math.ceil(math.min(y0-r0,y1-r1)))
    local last=math.min(h-1,math.floor(math.max(y0+r0,y1+r1)))
    if first>last then return end
    local dx,dy=x1-x0,y1-y0
    local length=math.sqrt(dx*dx+dy*dy)
    local p1x,p1y,p2x,p2y,p3x,p3y,p4x,p4y
    local has_quad=length>math.abs(r1-r0)
    if has_quad then
        local ux,uy=dx/length,dy/length
        local k=(r0-r1)/length
        local q=math.sqrt(1-k*k)
        local ax,ay=k*ux-q*uy,k*uy+q*ux
        local bx,by=k*ux+q*uy,k*uy-q*ux
        p1x,p1y=x0+r0*ax,y0+r0*ay
        p2x,p2y=x1+r1*ax,y1+r1*ay
        p3x,p3y=x1+r1*bx,y1+r1*by
        p4x,p4y=x0+r0*bx,y0+r0*by
    end
    local maxx=w-1
    local len2=length*length
    local r0_2,r1_2=r0*r0,r1*r1
    local dr=r1-r0
    local fast_bb8=uint8pt and type(bb)=="cdata" and bb:getType()==TYPE_BB8
    local data,stride,rot,bw,bh,cbyte
    if fast_bb8 then
        data=ffi.cast(uint8pt,bb.data)
        stride=tonumber(bb.stride)
        rot=bb:getRotation()
        bw,bh=bb.w,bb.h
        cbyte=colorByte(color)
        if bb:getInverse()==1 then cbyte=255-cbyte end
    end
    for y=first,last do
        local left,right=math.huge,-math.huge
        local dy0=y-y0
        if math.abs(dy0)<=r0 then
            local extent=math.sqrt(math.max(0,r0_2-dy0*dy0))
            left,right=x0-extent,x0+extent
        end
        local dy1=y-y1
        if math.abs(dy1)<=r1 then
            local extent=math.sqrt(math.max(0,r1_2-dy1*dy1))
            left,right=math.min(left,x1-extent),math.max(right,x1+extent)
        end
        if has_quad then
            left,right=edgeX(p1x,p1y,p2x,p2y,y,left,right)
            left,right=edgeX(p3x,p3y,p4x,p4y,y,left,right)
        end
        left,right=math.max(0,math.ceil(left)),math.min(maxx,math.floor(right))
        if left<=right then
            local y_dot=dy0*dy
            if fast_bb8 and rot==0 then
                local base=stride*y
                for x=left,right do
                    local t=length>0 and math.max(0,math.min(1,((x-x0)*dx+y_dot)/len2)) or 0
                    local r=r0+dr*t
                    local ox,oy=x-x0-dx*t,dy0-dy*t
                    if grain(x+gx,y+gy)<0.74*(1-0.4*math.min(1,(ox*ox+oy*oy)/(r*r))) then
                        data[base+x]=cbyte
                    end
                end
            elseif fast_bb8 then
                local idx,step
                if rot==1 then idx,step=stride*left+(bw-y-1),stride
                elseif rot==2 then idx,step=stride*(bh-y-1)+(bw-left-1),-1
                else idx,step=stride*(bh-left-1)+y,-stride end
                for x=left,right do
                    local t=length>0 and math.max(0,math.min(1,((x-x0)*dx+y_dot)/len2)) or 0
                    local r=r0+dr*t
                    local ox,oy=x-x0-dx*t,dy0-dy*t
                    if grain(x+gx,y+gy)<0.74*(1-0.4*math.min(1,(ox*ox+oy*oy)/(r*r))) then
                        data[idx]=cbyte
                    end
                    idx=idx+step
                end
            else
                for x=left,right do
                    local t=length>0 and math.max(0,math.min(1,((x-x0)*dx+y_dot)/len2)) or 0
                    local r=r0+dr*t
                    local ox,oy=x-x0-dx*t,dy0-dy*t
                    if grain(x+gx,y+gy)<0.74*(1-0.4*math.min(1,(ox*ox+oy*oy)/(r*r))) then
                        bb:setPixel(x,y,color)
                    end
                end
            end
        end
    end
end

function PenInk.draw(bb,x0,y0,r0,x1,y1,r1,color,rgb,pencil,gx,gy)
    r0,r1=math.max(0.5,r0),math.max(0.5,r1)
    if pencil then
        return drawPencil(bb,x0,y0,r0,x1,y1,r1,color,gx or 0,gy or 0)
    end
    local h=bb:getHeight()
    local w=bb:getWidth()
    local first=math.max(0,math.ceil(math.min(y0-r0,y1-r1)))
    local last=math.min(h-1,math.floor(math.max(y0+r0,y1+r1)))
    if first>last then return end
    local dx,dy=x1-x0,y1-y0
    local length=math.sqrt(dx*dx+dy*dy)
    if length==0 then x0=math.floor(x0+0.5);y0=math.floor(y0+0.5);x1,y1=x0,y0 end
    local has_quad=length>math.abs(r1-r0)
    local p1x,p1y,p2x,p2y,p3x,p3y,p4x,p4y
    if has_quad then
        local ux,uy=dx/length,dy/length
        local k=(r0-r1)/length
        local q=math.sqrt(1-k*k)
        local ax,ay=k*ux-q*uy,k*uy+q*ux
        local bx,by=k*ux+q*uy,k*uy-q*ux
        p1x,p1y=x0+r0*ax,y0+r0*ay
        p2x,p2y=x1+r1*ax,y1+r1*ay
        p3x,p3y=x1+r1*bx,y1+r1*by
        p4x,p4y=x0+r0*bx,y0+r0*by
    end
    local maxx=w-1
    local r0_2,r1_2=r0*r0,r1*r1
    local fast_rot0=uint8pt and type(bb)=="cdata" and not rgb and bb:getType()==TYPE_BB8 and bb:getRotation()==0
    local data,stride,cbyte
    if fast_rot0 then
        data=ffi.cast(uint8pt,bb.data)
        stride=tonumber(bb.stride)
        cbyte=colorByte(color)
        if bb:getInverse()==1 then cbyte=255-cbyte end
    end
    for y=first,last do
        local left,right=math.huge,-math.huge
        local dy0=y-y0
        if math.abs(dy0)<=r0 then
            local extent=math.sqrt(math.max(0,r0_2-dy0*dy0))
            left,right=x0-extent,x0+extent
        end
        local dy1=y-y1
        if math.abs(dy1)<=r1 then
            local extent=math.sqrt(math.max(0,r1_2-dy1*dy1))
            left,right=math.min(left,x1-extent),math.max(right,x1+extent)
        end
        if has_quad then
            left,right=edgeX(p1x,p1y,p2x,p2y,y,left,right)
            left,right=edgeX(p3x,p3y,p4x,p4y,y,left,right)
        end
        left,right=math.max(0,math.ceil(left)),math.min(maxx,math.floor(right))
        if left<=right then
            if fast_rot0 then
                ffi.fill(data+stride*y+left,right-left+1,cbyte)
            else
                Raster.rect(bb,left,y,right-left+1,1,color,rgb and bb.paintRectRGB32)
            end
        end
    end
end

return PenInk
