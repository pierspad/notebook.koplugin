-- Embedded PNG/JPEG objects share stroke history and never depend on source paths.
local _=require("i18n")
local Codec=require("imagecodec")
local Image={MAX_BYTES=Codec.MAX_BYTES,MAX_PIXELS=Codec.MAX_PIXELS,info=Codec.info,base64=Codec.base64}
local entries,bytes={},0
local BUDGET=32*1024*1024
local function evict(i)
    local entry=table.remove(entries,i);bytes=bytes-entry.bytes;entry.bb:free()
end
function Image.clear() while #entries>0 do evict(#entries) end end
function Image.create(data,x,y,w,h)
    for _,value in ipairs({x,y,w,h}) do
        if type(value)~="number" or value~=value or math.abs(value)==math.huge then return nil end
    end
    if not x or not y or not w or not h or w<=0 or h<=0 then return nil end
    local sw,_,mime=Image.info(data)
    if not sw then return nil end
    local stroke=require("stroke"):new{tool="image",shape_kind="image",width=1,image_data=data,image_mime=mime}
    stroke:addPoint(x,y);stroke:addPoint(x+w,y+h)
    return stroke
end
local function raster(data,w,h)
    for i,entry in ipairs(entries) do
        if entry.data==data and entry.w==w and entry.h==h then
            table.remove(entries,i);table.insert(entries,1,entry);return entry.bb
        end
    end
    local estimate=w*h*4
    if w<1 or h<1 or estimate>BUDGET then return nil end
    while #entries>0 and (#entries>=2 or bytes+estimate>BUDGET) do evict(#entries) end
    local RenderImage=require("ui/renderimage")
    local ok,bb=pcall(RenderImage.renderImageData,RenderImage,data,#data,false,w,h)
    if not ok or not bb then return nil end
    local scaled,result=pcall(RenderImage.scaleBlitBuffer,RenderImage,bb,w,h,false)
    if not scaled or not result then bb:free();return nil end
    if result~=bb then bb:free() end
    bb=result
    local size=tonumber(bb.stride) and tonumber(bb.stride)*bb:getHeight() or estimate
    if size>BUDGET then bb:free();return nil end
    while #entries>0 and bytes+size>BUDGET do evict(#entries) end
    table.insert(entries,1,{data=data,w=w,h=h,bb=bb,bytes=size});bytes=bytes+size
    return bb
end
function Image.import(path,area)
    local file,err=io.open(path,"rb")
    if not file then return nil,err end
    local data=file:read(Image.MAX_BYTES+1);file:close()
    local w,h=Image.info(data)
    if not w then return nil,_("Choose a PNG or JPEG image up to 4 MB and 8 megapixels.") end
    local scale=math.min(area.w*0.65/w,area.h*0.65/h,1)
    w,h=math.max(1,math.floor(w*scale)),math.max(1,math.floor(h*scale))
    -- Decode before changing the document; malformed images never become edits.
    if not raster(data,w,h) then return nil,_("Could not open this image.") end
    return Image.create(data,area.x+(area.w-w)/2,area.y+(area.h-h)/2,w,h)
end
function Image.draw(bb,stroke,scale,ox,oy,clip)
    scale,ox,oy=scale or 1,ox or 0,oy or 0
    local x,y=math.floor(stroke.x_min*scale+ox),math.floor(stroke.y_min*scale+oy)
    local w,h=math.max(1,math.floor((stroke.x_max-stroke.x_min)*scale)),math.max(1,math.floor((stroke.y_max-stroke.y_min)*scale))
    local bounds=clip or {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()}
    local l,t=math.max(0,x,bounds.x),math.max(0,y,bounds.y)
    local r,b=math.min(bb:getWidth(),x+w,bounds.x+bounds.w),math.min(bb:getHeight(),y+h,bounds.y+bounds.h)
    if r<=l or b<=t then return end
    local image=raster(stroke.image_data,w,h)
    if image then
        local blit=bb.alphablitFrom or bb.blitFrom
        blit(bb,image,l,t,l-x,t-y,r-l,b-t)
    else
        -- Leave a visible bounded placeholder for a failed decoder/allocation.
        bb:paintRect(l,t,r-l,1,require("ffi/blitbuffer").COLOR_BLACK)
    end
end
return Image
