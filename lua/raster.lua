-- KOReader's full-row fill may use the parent's stride on a narrow viewport.
-- Split only those fills, retaining native scanline speed and clip boundaries.
local Raster = {}
local function pixel(bb,x,y,color) bb:setPixel(x,y,color) end
function Raster.rect(bb,x,y,w,h,color,rgb)
    local paint = rgb and bb.paintRectRGB32 or bb.paintRect
    if bb.getPhysicalRect and bb.pixel_stride > bb.w then
        local bx,by,bw,bh = bb:getBoundedRect(x,y,w,h)
        if bw<=0 or bh<=0 then return end
        local px,_,pw = bb:getPhysicalRect(bx,by,bw,bh)
        if px==0 and pw==bb.w then
            -- Rotation swaps the logical axis that spans a physical row.
            if bb:getRotation()%2==0 and bw>1 then
                paint(bb,bx,by,bw-1,bh,color)
                return paint(bb,bx+bw-1,by,1,bh,color)
            elseif bb:getRotation()%2==1 and bh>1 then
                paint(bb,bx,by,bw,bh-1,color)
                return paint(bb,bx,by+bh-1,bw,1,color)
            end
            -- One physical pixel wide: a custom setter bypasses the shortcut.
            return paint(bb,bx,by,bw,bh,color,pixel)
        end
    end
    return paint(bb,x,y,w,h,color)
end
return Raster
