-- A PDF page is immutable paper. Two recent rasters are cached with a byte budget; erasing
-- annotations restores it without rerendering the PDF on every pen sample.
local PDF = {}
local lfs = require("libs/libkoreader-lfs")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local Raster = require("raster")
local entries, cache_bytes = {}, 0
local MAX_BYTES, MAX_ENTRIES = 12 * 1024 * 1024, 2
local preview_warnings = {}
local preview_warning_order = {}
local MAX_PREVIEW_WARNINGS = 32
local function evict(index)
    local entry = table.remove(entries, index)
    cache_bytes = cache_bytes - entry.bytes
    entry.bb:free()
end

function PDF.clear()
    while #entries > 0 do evict(#entries) end
    preview_warnings = {}
    preview_warning_order = {}
end

function PDF.count(path)
    local count=PDF.inspect(path)
    return count
end

-- Always release metadata handles, including native exceptions from malformed PDFs.
local function withDocument(path,read)
    local doc=require("ffi/mupdf").openDocument(path)
    local ok,a,b=pcall(function()
        if doc:needsPassword() then error("Password-protected PDF") end
        return read(doc)
    end)
    local closed,close_err=pcall(doc.close,doc)
    if not ok then error(a,0) end
    if not closed then error(close_err,0) end
    return a,b
end
local function pageSize(doc,number)
    local page=doc:openPage(number)
    local ok,w,h=pcall(function()
        local width,height=page:getSize(require("ffi/drawcontext").new())
        assert(type(width)=="number" and type(height)=="number"
            and width>0 and height>0 and width<math.huge and height<math.huge,"Invalid PDF page dimensions")
        return width,height
    end)
    local closed,close_err=pcall(page.close,page)
    if not ok then error(w,0) end
    if not closed then error(close_err,0) end
    return w,h
end

-- Opens the PDF once for its count and all native page dimensions.
function PDF.inspect(path)
    return withDocument(path,function(doc)
        local count=doc:getPages()
        local sizes={}
        for i=1,count do
            local w,h=pageSize(doc,i)
            sizes[i]={w=w,h=h}
        end
        return count,sizes
    end)
end
function PDF.size(path,page_number)
    return withDocument(path,function(doc) return pageSize(doc,page_number) end)
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
        local doc,page,result
        local rendered,render_error=pcall(function()
            doc=require("ffi/mupdf").openDocument(background.file)
            page=doc:openPage(background.page)
            local dc=require("ffi/drawcontext").new()
            local pw,ph=page:getSize(dc)
            assert(type(pw)=="number" and type(ph)=="number"
                and pw>0 and ph>0 and pw<math.huge and ph<math.huge,"Invalid PDF page dimensions")
            local zoom=math.min(w/pw,h/ph)
            dc:setZoom(zoom)
            result=page:draw_new(dc,w,h,-math.floor((w-pw*zoom)/2),-math.floor((h-ph*zoom)/2))
        end)
        local page_closed,page_error=true,nil
        if page then page_closed,page_error=pcall(page.close,page) end
        local doc_closed,doc_error=true,nil
        if doc then doc_closed,doc_error=pcall(doc.close,doc) end
        if not rendered or not page_closed or not doc_closed then
            if result and result.free then pcall(result.free,result) end
            if not rendered then error(render_error,0) end
            if not page_closed then error(page_error,0) end
            error(doc_error,0)
        end

        local cached,cached_or_error=pcall(function()
            assert(result,"MuPDF returned no PDF raster")
            local stride=tonumber(result.stride)
            local height=result:getHeight()
            assert(stride and stride>0 and height and height>0,"Invalid PDF raster dimensions")
            local bytes=stride*height
            while #entries > 0 and cache_bytes + bytes > MAX_BYTES do evict(#entries) end
            local entry={file=background.file,page=background.page,stamp=stamp,
                w=w,h=h,bb=result,bytes=bytes}
            table.insert(entries,1,entry)
            cache_bytes=cache_bytes+bytes
            return entry
        end)
        if not cached then
            if result and result.free then pcall(result.free,result) end
            error(cached_or_error,0)
        end
        cache=cached_or_error
    end
    local x,y=math.floor(area.x),math.floor(area.y)
    local bounds=clip or {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()}
    local x0,y0=math.max(0,x,bounds.x),math.max(0,y,bounds.y)
    local x1,y1=math.min(bb:getWidth(),x+w,bounds.x+bounds.w),math.min(bb:getHeight(),y+h,bounds.y+bounds.h)
    if x1>x0 and y1>y0 then bb:blitFrom(cache.bb,x0,y0,x0-x,y0-y,x1-x0,y1-y0) end
end

local function drawErrorPaper(bb,area,clip)
    local x,y,w,h=math.floor(area.x),math.floor(area.y),math.floor(area.w),math.floor(area.h)
    if w<=0 or h<=0 then return end
    local bounds=clip or {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()}
    local x0,y0=math.max(0,x,bounds.x),math.max(0,y,bounds.y)
    local x1,y1=math.min(bb:getWidth(),x+w,bounds.x+bounds.w),math.min(bb:getHeight(),y+h,bounds.y+bounds.h)
    if x1<=x0 or y1<=y0 then return end
    Raster.rect(bb,x0,y0,x1-x0,y1-y0,Blitbuffer.COLOR_WHITE)

    local cx,cy=x+math.floor(w/2),y+math.floor(h/2)
    local radius=math.max(1,math.min(5,math.floor(math.min(w,h)/8)))
    local function crossPixel(px,py)
        if px>=x0 and px<x1 and py>=y0 and py<y1 then
            Raster.rect(bb,px,py,1,1,Blitbuffer.COLOR_BLACK)
        end
    end
    for offset=-radius,radius do
        crossPixel(cx+offset,cy+offset)
        crossPixel(cx+offset,cy-offset)
    end
end

local function removePreviewWarning(key)
    preview_warnings[key] = nil
    for i = #preview_warning_order, 1, -1 do
        if preview_warning_order[i] == key then table.remove(preview_warning_order, i) end
    end
end

local function addPreviewWarning(key)
    if preview_warnings[key] then return false end
    if #preview_warning_order >= MAX_PREVIEW_WARNINGS then
        local oldest = table.remove(preview_warning_order, 1)
        preview_warnings[oldest] = nil
    end
    preview_warnings[key] = true
    preview_warning_order[#preview_warning_order + 1] = key
    return true
end

--- Draws a PDF background for a live preview without propagating PDF faults.
--- Returns true on success, or false and the error after painting clean paper
--- with a small cross in the affected area.
function PDF.drawPreview(bb,background,area,clip)
    local ok,err=pcall(PDF.draw,bb,background,area,clip)
    local key=tostring(background and background.file)..":"..tostring(background and background.page)
    if ok then
        removePreviewWarning(key)
        return true
    end
    if addPreviewWarning(key) then
        pcall(logger.warn,"Notebook: PDF preview failed:",background and background.file,err)
    end
    pcall(drawErrorPaper,bb,area,clip)
    return false,tostring(err)
end

return PDF
