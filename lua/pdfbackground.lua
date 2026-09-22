-- A PDF page is immutable paper. Only the current raster is cached; erasing
-- annotations restores it without rerendering the PDF on every pen sample.
local PDF = {}
local cache

function PDF.clear()
    if cache then cache.bb:free(); cache=nil end
end

function PDF.count(path)
    local doc = require("ffi/mupdf").openDocument(path)
    if doc:needsPassword() then doc:close(); error("Password-protected PDF") end
    local count=doc:getPages()
    doc:close()
    return count
end

function PDF.draw(bb, background, area, clip)
    if not background then return end
    local w,h=math.floor(area.w),math.floor(area.h)
    local key=background.file..":"..background.page..":"..w..":"..h
    if not cache or cache.key~=key then
        PDF.clear()
        local doc,page
        local ok,result=pcall(function()
            doc=require("ffi/mupdf").openDocument(background.file)
            page=doc:openPage(background.page)
            local dc=require("ffi/drawcontext").new()
            local pw,ph=page:getSize(dc)
            local zoom=math.min(w/pw,h/ph)
            dc:setZoom(zoom)
            return page:draw_new(dc,w,h,-math.floor((w-pw*zoom)/2),-math.floor((h-ph*zoom)/2))
        end)
        if page then page:close() end
        if doc then doc:close() end
        if not ok then error(result) end
        cache={key=key,bb=result}
    end
    local x,y=math.floor(area.x),math.floor(area.y)
    local bounds=clip or {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()}
    local x0,y0=math.max(0,x,bounds.x),math.max(0,y,bounds.y)
    local x1,y1=math.min(bb:getWidth(),x+w,bounds.x+bounds.w),math.min(bb:getHeight(),y+h,bounds.y+bounds.h)
    if x1>x0 and y1>y0 then bb:blitFrom(cache.bb,x0,y0,x0-x,y0-y,x1-x0,y1-y0) end
end

return PDF
