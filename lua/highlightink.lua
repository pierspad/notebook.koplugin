-- Continuous chisel sweeps and filled marker fragments share the same
-- idempotent darken blend. Pixel work scales with visible area, not samples.
local HighlightInk = {}
local BB = require("ffi/blitbuffer")
local ok_ffi, ffi = pcall(require, "ffi")
local uint8pt = ok_ffi and ffi.typeof("uint8_t *") or nil
local TYPE_BB8 = BB.TYPE_BB8
local TYPE_BBRGB32 = BB.TYPE_BBRGB32
local TYPE_BBRGB24 = BB.TYPE_BBRGB24
local TYPE_BBRGB16 = BB.TYPE_BBRGB16
local BLACK = BB.COLOR_BLACK

local function paintRowSlow(bb, py, left, right, color, tint, preview)
    if preview then
        for px = left + (-(left+py) % 4), right, 4 do
            bb:setPixel(px, py, BLACK)
        end
    elseif type(color) ~= "number" and color.getR and bb.getType then
        local bbtype = bb:getType()
        if bbtype == TYPE_BBRGB32 or bbtype == TYPE_BBRGB24 or bbtype == TYPE_BBRGB16 then
            local r,g,b = color:getR(),color:getG(),color:getB()
            if bbtype == TYPE_BBRGB32 and uint8pt and type(bb) == "cdata"
                and bb:getRotation() == 0 and bb:getInverse() == 0 then
                local data = ffi.cast(uint8pt, bb.data)
                local base = tonumber(bb.stride) * py
                for idx = base + left * 4, base + right * 4, 4 do
                    local cr, cg, cb = data[idx], data[idx + 1], data[idx + 2]
                    if cr > r or cg > g or cb > b then
                        if cr > r then data[idx] = r end
                        if cg > g then data[idx + 1] = g end
                        if cb > b then data[idx + 2] = b end
                        data[idx + 3] = 255
                    end
                end
                return
            end
            for px = left, right do
                local pixel = bb:getPixel(px, py)
                local pr,pg,pb = pixel:getR(),pixel:getG(),pixel:getB()
                if pr > r or pg > g or pb > b then
                    bb:setPixel(px, py, BB.ColorRGB32(math.min(pr,r),math.min(pg,g),math.min(pb,b),0xFF))
                end
            end
            return
        end
        for px = left, right do
            local pixel = bb:getPixel(px, py)
            if pixel then
                local gray = pixel.getColor8 and pixel:getColor8().a or pixel.a
                if gray and gray > tint then bb:setPixel(px, py, color) end
            end
        end
    else
        for px = left, right do
            local pixel = bb:getPixel(px, py)
            if pixel then
                local gray = pixel.getColor8 and pixel:getColor8().a or pixel.a
                if gray and gray > tint then bb:setPixel(px, py, color) end
            end
        end
    end
end

local function paintRowBB8(data, stride, rot, bw, bh, inv, tint, inv_tint, py, left, right)
    if rot == 0 then
        local base = stride * py
        if inv == 0 then
            for idx = base + left, base + right do
                if data[idx] > tint then data[idx] = tint end
            end
        else
            for idx = base + left, base + right do
                if data[idx] < inv_tint then data[idx] = inv_tint end
            end
        end
        return
    end
    local idx, step
    if rot == 1 then
        idx, step = stride * left + (bw - py - 1), stride
    elseif rot == 2 then
        idx, step = stride * (bh - py - 1) + (bw - left - 1), -1
    else
        idx, step = stride * (bh - left - 1) + py, -stride
    end
    local count = right - left
    if inv == 0 then
        for _ = 0, count do
            if data[idx] > tint then data[idx] = tint end
            idx = idx + step
        end
    else
        for _ = 0, count do
            if data[idx] < inv_tint then data[idx] = inv_tint end
            idx = idx + step
        end
    end
end

local function paintRowBB8Rot0(data, stride, tint, py, left, right)
    local base = stride * py
    for idx = base + left, base + right do
        if data[idx] > tint then data[idx] = tint end
    end
end

local function paintRowSegmentSlow(bb, py, left, right, color, tint, preview)
    if not preview and uint8pt and type(bb) == "cdata" and bb:getType() == TYPE_BB8 then
        return paintRowBB8(ffi.cast(uint8pt, bb.data), tonumber(bb.stride),
            bb:getRotation(), bb.w, bb.h, bb:getInverse(), tint, 255 - tint, py, left, right)
    end
    return paintRowSlow(bb, py, left, right, color, tint, preview)
end

-- Rasterize continuous marker polygons without repainting their borders as
-- opaque pen ink. Inclusive scanlines give adjacent fragments identical seams.
function HighlightInk.polygon(bb, points, color, preview, clip, exclude)
    local np = #points
    if np == 0 then return end
    local tint = type(color) == "number" and color
        or (color.getColor8 and color:getColor8().a or color.a or 0)
    local top,bottom=math.huge,-math.huge
    local x0,x1=math.huge,-math.huge
    for i=1,np do
        local p=points[i]
        local px,py=p[1],p[2]
        if px<x0 then x0=px end; if px>x1 then x1=px end
        if py<top then top=py end; if py>bottom then bottom=py end
    end
    top=math.max(0,math.ceil(top-1e-8),clip and math.ceil(clip.y) or 0)
    bottom=math.min(bb:getHeight()-1,math.floor(bottom+1e-8),clip and math.ceil(clip.y+clip.h)-1 or math.huge)
    local minx=math.max(0,clip and math.ceil(clip.x) or 0)
    local maxx=math.min(bb:getWidth()-1,clip and math.ceil(clip.x+clip.w)-1 or math.huge)
    -- Multipart fragments often overlap the dirty rectangle in Y only.
    -- Reject before traversing every edge on every scanline of an invisible
    -- contour, preserving the rasterizer's inclusive subpixel tolerance.
    if top>bottom or x1+1e-8<minx or x0-1e-8>maxx then return end
    local fast_bb8 = not preview and uint8pt and type(bb) == "cdata" and bb:getType() == TYPE_BB8
    local data, stride, rot, bw, bh, inv, inv_tint
    if fast_bb8 then
        data = ffi.cast(uint8pt, bb.data)
        stride = tonumber(bb.stride)
        rot = bb:getRotation()
        bw, bh = bb.w, bb.h
        inv = bb:getInverse()
        inv_tint = 255 - tint
    end
    for y=top,bottom do
        local left,right=math.huge,-math.huge
        local prev=points[np]
        local px0, py0 = prev[1], prev[2]
        for i=1,np do
            local p=points[i]
            local px1, py1 = p[1], p[2]
            local lo = py0 < py1 and py0 or py1
            local hi = py0 > py1 and py0 or py1
            if y>=lo-1e-8 and y<=hi+1e-8 then
                if py0==py1 then
                    if px0<left then left=px0 end; if px1<left then left=px1 end
                    if px0>right then right=px0 end; if px1>right then right=px1 end
                else
                    local x=px0+(y-py0)*(px1-px0)/(py1-py0)
                    if x<left then left=x end
                    if x>right then right=x end
                end
            end
            px0, py0 = px1, py1
        end
        left,right=math.max(minx,math.ceil(left-1e-8)),math.min(maxx,math.floor(right+1e-8))
        if left<=right then
            if exclude and y>=exclude[2] and y<=exclude[4] then
                local a,b=math.min(right,exclude[1]-1),math.max(left,exclude[3]+1)
                if left<=a then
                    if fast_bb8 then paintRowBB8(data,stride,rot,bw,bh,inv,tint,inv_tint,y,left,a)
                    else paintRowSlow(bb,y,left,a,color,tint,preview) end
                end
                if b<=right then
                    if fast_bb8 then paintRowBB8(data,stride,rot,bw,bh,inv,tint,inv_tint,y,b,right)
                    else paintRowSlow(bb,y,b,right,color,tint,preview) end
                end
            else
                if fast_bb8 then paintRowBB8(data,stride,rot,bw,bh,inv,tint,inv_tint,y,left,right)
                else paintRowSlow(bb,y,left,right,color,tint,preview) end
            end
        end
    end
end

function HighlightInk.drawSegment(bb,x0,y0,r0,x1,y1,r1,color,first,last,steps,preview,exclude_start)
    if first>last then return end
    local tint=type(color)=="number" and color
        or (color.getColor8 and color:getColor8().a or color.a or 0)
    local dx,dy,dr=x1-x0,y1-y0,r1-r0
    local a,b=first/steps,last/steps
    local ymin=math.max(0,math.ceil(math.min(y0+(dy-dr)*a-r0,y0+(dy-dr)*b-r0)-1e-8))
    local ymax=math.min(bb:getHeight()-1,math.floor(math.max(y0+(dy+dr)*a+r0,y0+(dy+dr)*b+r0)+1e-8))
    if ymin>ymax then return end
    local maxx=bb:getWidth()-1
    local ex0,ex1=math.ceil(x0-r0-1e-8),math.floor(x0+r0+1e-8)
    local ey0,ey1=math.ceil(y0-r0-1e-8),math.floor(y0+r0+1e-8)
    local fast_rot0 = not preview and uint8pt and type(bb) == "cdata"
        and bb:getType() == TYPE_BB8 and bb:getRotation() == 0 and bb:getInverse() == 0
    local data, stride
    if fast_rot0 then
        data = ffi.cast(uint8pt, bb.data)
        stride = tonumber(bb.stride)
    end
    local d0,d1=-dy-dr,dy-dr
    -- Solve the two vertical square-side inequalities for t, then evaluate
    -- both horizontal sides at the endpoints of that interval. This is the
    -- exact continuous sweep, including pressure changes, without constructing
    -- a polygon or sampling a series of stamps for each digitizer event.
    for y=ymin,ymax do
        local low,high=a,b
        local c0,c1=y-y0-r0,y0-y-r0
        local valid=true
        if d0==0 then valid=c0<=1e-8
        elseif d0>0 then high=math.min(high,-c0/d0)
        else low=math.max(low,-c0/d0) end
        if d1==0 then valid=valid and c1<=1e-8
        elseif d1>0 then high=math.min(high,-c1/d1)
        else low=math.max(low,-c1/d1) end
        if valid and low<=high+1e-8 then
            local left=math.max(0,math.ceil(math.min(x0+(dx-dr)*low-r0,x0+(dx-dr)*high-r0)-1e-8))
            local right=math.min(maxx,math.floor(math.max(x0+(dx+dr)*low+r0,x0+(dx+dr)*high+r0)+1e-8))
            if left<=right then
                if exclude_start and y>=ey0 and y<=ey1 then
                    local lright,rleft=math.min(right,ex0-1),math.max(left,ex1+1)
                    if left<=lright then
                        if fast_rot0 then paintRowBB8Rot0(data,stride,tint,y,left,lright)
                        else paintRowSegmentSlow(bb,y,left,lright,color,tint,preview) end
                    end
                    if rleft<=right then
                        if fast_rot0 then paintRowBB8Rot0(data,stride,tint,y,rleft,right)
                        else paintRowSegmentSlow(bb,y,rleft,right,color,tint,preview) end
                    end
                else
                    if fast_rot0 then paintRowBB8Rot0(data,stride,tint,y,left,right)
                    else paintRowSegmentSlow(bb,y,left,right,color,tint,preview) end
                end
            end
        end
    end
end

function HighlightInk.stamp(bb,x,y,r,color)
    HighlightInk.drawSegment(bb,x,y,r,x,y,r,color,0,1,1)
end

return HighlightInk
