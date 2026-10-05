-- Continuous chisel sweeps and filled marker fragments share the same
-- idempotent darken blend. Pixel work scales with visible area, not samples.
local HighlightInk = {}
local BB = require("ffi/blitbuffer")
local BLACK = BB.COLOR_BLACK
local paintRow = function(bb, py, left, right, color, tint, preview)
    if preview then
        for px = left + (-(left+py) % 4), right, 4 do
            bb:setPixel(px, py, BLACK)
        end
    elseif type(color) ~= "number" and color.getR and bb.getType and
        (bb:getType() == BB.TYPE_BBRGB32 or bb:getType() == BB.TYPE_BBRGB24
            or bb:getType() == BB.TYPE_BBRGB16) then
        -- Per-channel darken preserves colored ink as well as black ink.
        -- Unlike luminance replacement it never brightens any channel and
        -- repeated passes with the same marker are idempotent.
        -- This is the composited framebuffer, not a transparent overlay.
        -- FFI defaults an omitted alpha to zero, which SDL displays as black.
        local r,g,b = color:getR(),color:getG(),color:getB()
        for px = left, right do
            local pixel = bb:getPixel(px, py)
            local pr,pg,pb = pixel:getR(),pixel:getG(),pixel:getB()
            if pr > r or pg > g or pb > b then
                bb:setPixel(px, py, BB.ColorRGB32(math.min(pr,r),math.min(pg,g),math.min(pb,b),0xFF))
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


-- Rasterize continuous marker polygons without repainting their borders as
-- opaque pen ink. Inclusive scanlines give adjacent fragments identical seams.
function HighlightInk.polygon(bb, points, color, preview, clip, exclude)
    local tint = type(color) == "number" and color
        or (color.getColor8 and color:getColor8().a or color.a or 0)
    local top,bottom=math.huge,-math.huge
    local x0,x1=math.huge,-math.huge
    for _,p in ipairs(points) do
        top=math.min(top,p[2]);bottom=math.max(bottom,p[2])
        x0=math.min(x0,p[1]);x1=math.max(x1,p[1])
    end
    top=math.max(0,math.ceil(top-1e-8),clip and math.ceil(clip.y) or 0)
    bottom=math.min(bb:getHeight()-1,math.floor(bottom+1e-8),clip and math.ceil(clip.y+clip.h)-1 or math.huge)
    local minx=math.max(0,clip and math.ceil(clip.x) or 0)
    local maxx=math.min(bb:getWidth()-1,clip and math.ceil(clip.x+clip.w)-1 or math.huge)
    -- Multipart fragments often overlap the dirty rectangle in Y only.
    -- Reject before traversing every edge on every scanline of an invisible
    -- contour, preserving the rasterizer's inclusive subpixel tolerance.
    if top>bottom or x1+1e-8<minx or x0-1e-8>maxx then return end
    for y=top,bottom do
        local left,right=math.huge,-math.huge
        local prev=points[#points]
        for _,p in ipairs(points) do
            if y>=math.min(prev[2],p[2])-1e-8 and y<=math.max(prev[2],p[2])+1e-8 then
                if prev[2]==p[2] then
                    left=math.min(left,prev[1],p[1]);right=math.max(right,prev[1],p[1])
                else
                    local x=prev[1]+(y-prev[2])*(p[1]-prev[1])/(p[2]-prev[2])
                    left=math.min(left,x);right=math.max(right,x)
                end
            end
            prev=p
        end
        left,right=math.max(minx,math.ceil(left-1e-8)),math.min(maxx,math.floor(right+1e-8))
        if left<=right then
            if exclude and y>=exclude[2] and y<=exclude[4] then
                local a,b=math.min(right,exclude[1]-1),math.max(left,exclude[3]+1)
                if left<=a then paintRow(bb,y,left,a,color,tint,preview) end
                if b<=right then paintRow(bb,y,b,right,color,tint,preview) end
            else paintRow(bb,y,left,right,color,tint,preview) end
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
    local maxx=bb:getWidth()-1
    local ex0,ex1=math.ceil(x0-r0-1e-8),math.floor(x0+r0+1e-8)
    local ey0,ey1=math.ceil(y0-r0-1e-8),math.floor(y0+r0+1e-8)
    -- Solve the two vertical square-side inequalities for t, then evaluate
    -- both horizontal sides at the endpoints of that interval. This is the
    -- exact continuous sweep, including pressure changes, without constructing
    -- a polygon or sampling a series of stamps for each digitizer event.
    for y=ymin,ymax do
        local low,high=a,b
        local c0,c1=y-y0-r0,y0-y-r0
        local d0,d1=-dy-dr,dy-dr
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
                    if left<=lright then paintRow(bb,y,left,lright,color,tint,preview) end
                    if rleft<=right then paintRow(bb,y,rleft,right,color,tint,preview) end
                else paintRow(bb,y,left,right,color,tint,preview) end
            end
        end
    end
end

function HighlightInk.stamp(bb,x,y,r,color)
    HighlightInk.drawSegment(bb,x,y,r,x,y,r,color,0,1,1)
end

return HighlightInk
