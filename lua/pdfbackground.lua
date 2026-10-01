-- A PDF page is immutable paper. Two recent rasters are cached with a byte budget; erasing
-- annotations restores it without rerendering the PDF on every pen sample.
local PDF = {}
local lfs = require("libs/libkoreader-lfs")
local entries, cache_bytes = {}, 0
local MAX_BYTES, MAX_ENTRIES = 12 * 1024 * 1024, 2
local function evict(index)
    local entry = table.remove(entries, index)
    cache_bytes = cache_bytes - entry.bytes
    entry.bb:free()
end

function PDF.clear()
    while #entries > 0 do evict(#entries) end
end

function PDF.count(path)
    local count=PDF.inspect(path)
    return count
end

-- Opens a PDF once and returns both its page count and the dimensions of every
-- page in PDF points. Import used to open it once for the count and XOPP had
-- to guess every page was shaped like the Scribe panel.
function PDF.inspect(path)
    local doc = require("ffi/mupdf").openDocument(path)
    if doc:needsPassword() then doc:close(); error("Password-protected PDF") end
    local count=doc:getPages()
    local sizes={}
    local dc=require("ffi/drawcontext").new()
    for i=1,count do
        local page=doc:openPage(i)
        local w,h=page:getSize(dc)
        sizes[i]={w=w,h=h}
        page:close()
    end
    doc:close()
    return count,sizes
end

function PDF.size(path,page_number)
    local doc = require("ffi/mupdf").openDocument(path)
    if doc:needsPassword() then doc:close(); error("Password-protected PDF") end
    local page=doc:openPage(page_number)
    local dc=require("ffi/drawcontext").new()
    local w,h=page:getSize(dc)
    page:close(); doc:close()
    return w,h
end

function PDF.draw(bb, background, area, clip)
    if not background then return end
    local w,h=math.floor(area.w),math.floor(area.h)
    if w <= 0 or h <= 0 then return end
    local attr = lfs.attributes(background.file)
    local stamp = attr and table.concat({attr.size or 0, attr.modification or 0,
        attr.change or 0, attr.ino or 0, attr.dev or 0}, ":") or "missing"
    local cache
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if entry.file == background.file and entry.stamp ~= stamp then
            evict(i)
        elseif entry.file == background.file and entry.page == background.page and entry.w == w and entry.h == h then
            cache = table.remove(entries, i)
            table.insert(entries, 1, cache)
            break
        end
    end
    if not cache then
        -- Evict before allocating, so the miss does not temporarily double
        -- large zoom rasters. MuPDF uses its default grayscale raster (one byte/pixel).
        local estimate = w * h
        while #entries > 0 and (#entries >= MAX_ENTRIES or cache_bytes + estimate > MAX_BYTES) do evict(#entries) end
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
        local bytes = tonumber(result.stride) * result:getHeight()
        while #entries > 0 and cache_bytes + bytes > MAX_BYTES do evict(#entries) end
        cache = {file=background.file, page=background.page, stamp=stamp, w=w, h=h, bb=result, bytes=bytes}
        table.insert(entries, 1, cache)
        cache_bytes = cache_bytes + bytes
    end
    local x,y=math.floor(area.x),math.floor(area.y)
    local bounds=clip or {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()}
    local x0,y0=math.max(0,x,bounds.x),math.max(0,y,bounds.y)
    local x1,y1=math.min(bb:getWidth(),x+w,bounds.x+bounds.w),math.min(bb:getHeight(),y+h,bounds.y+bounds.h)
    if x1>x0 and y1>y0 then bb:blitFrom(cache.bb,x0,y0,x0-x,y0-y,x1-x0,y1-y0) end
end

return PDF
