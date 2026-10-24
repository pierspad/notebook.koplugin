package.path = "./?.lua;./spec/?.lua;" .. package.path
local opens, rasters, closed_docs, closed_pages = 0, {}, 0, 0
local generation, size = 100, 200
local render_fault = false
local close_fault
local warnings = 0
package.loaded.logger = { warn = function() warnings = warnings + 1 end }
package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 255, COLOR_BLACK = 0 }
package.loaded["libs/libkoreader-lfs"]={attributes=function()
    return {size=size,modification=generation,change=generation,ino=generation,dev=1}
end}
package.loaded["ffi/drawcontext"]={new=function() return {setZoom=function() end} end}
package.loaded["ffi/mupdf"]={openDocument=function()
    opens=opens+1
    return {openPage=function(_,number)
        return {getSize=function() return 600,800 end,close=function()
                closed_pages=closed_pages+1
                if close_fault=="page" then error("MuPDF page close failure") end
            end,
            draw_new=function(_,_,w,h)
                if render_fault then error("MuPDF render failure") end
                local bb={w=w,h=h,stride=w,page=number,generation=generation}
                function bb:getHeight() return self.h end
                function bb:free() assert(not self.freed,"double free");self.freed=true end
                rasters[#rasters+1]=bb
                return bb
            end}
    end,close=function()
        closed_docs=closed_docs+1
        if close_fault=="document" then error("MuPDF document close failure") end
    end}
end}
local PDF=require("pdfbackground")
local target={getWidth=function() return 1860 end,getHeight=function() return 2480 end,
    blitFrom=function(self,source,dx,dy,sx,sy,w,h)
        assert(not source.freed,"blit from freed raster")
        self.source=source;self.rect={dx,dy,sx,sy,w,h}
    end}
local full={x=0,y=0,w=1860,h=2480}
local small={x=4,y=8,w=186,h=248}
local background={file="/fixture.pdf",page=1}
PDF.draw(target,background,full);local first=target.source
PDF.draw(target,background,small)
PDF.draw(target,background,full)
assert(opens==2 and target.source==first,"thumbnail evicted the full-size background")
PDF.draw(target,{file=background.file,page=2},full)
PDF.draw(target,background,full)
assert(opens==3,"two neighboring full pages do not fit in the bounded cache")
PDF.draw(target,background,full,{x=7,y=11,w=20,h=30})
assert(table.concat(target.rect,",")=="7,11,7,11,20,30","warm clipping changed")
generation=generation+1
PDF.draw(target,background,full)
assert(target.source~=first and target.source.generation==generation,"replaced PDF stayed stale")
local before=opens
-- A single 2x raster is bigger than the budget; it is kept alone, as before.
local large={x=0,y=0,w=3720,h=4960}
PDF.draw(target,background,large)
PDF.draw(target,background,large)
assert(opens==before+1,"oversize current raster was rendered repeatedly")
local alive=0
for _,bb in ipairs(rasters) do if not bb.freed then alive=alive+1 end end
assert(alive==1,"oversize raster retained other entries")
render_fault=true
local ok=pcall(function() PDF.draw(target,{file=background.file,page=9},full) end)
assert(not ok,"render failure was swallowed")
render_fault=false
PDF.draw(target,background,full)
assert(target.source.page==1,"cache failed to recover after a rendering error")

-- A close error must still attempt the other close and free any raster already
-- returned by MuPDF. These exercise the production strict draw API.
local doc_before, page_before = closed_docs, closed_pages
close_fault="page"
local strict_ok=pcall(PDF.draw,target,{file="/page-close.pdf",page=1},full)
assert(not strict_ok,"strict PDF draw swallowed a page-close error")
assert(closed_docs==doc_before+1,"page-close failure skipped document close")
assert(closed_pages==page_before+1,"failed page close was not attempted")
assert(rasters[#rasters].freed,"raster leaked after a page-close failure")

doc_before, page_before=closed_docs,closed_pages
close_fault="document"
strict_ok=pcall(PDF.draw,target,{file="/document-close.pdf",page=1},full)
assert(not strict_ok,"strict PDF draw swallowed a document-close error")
assert(closed_docs==doc_before+1 and closed_pages==page_before+1,
    "document-close failure skipped a native close")
assert(rasters[#rasters].freed,"raster leaked after a document-close failure")
close_fault=nil

-- Preview failures are contained and replace stale pixels with a white page
-- and a small error cross rather than propagating into the event loop.
local preview={w=30,h=30,pixels={},getWidth=function(self) return self.w end,
    getHeight=function(self) return self.h end,
    paintRect=function(self,x,y,w,h,color)
        self.paints=self.paints or {};self.paints[#self.paints+1]={x,y,w,h,color}
        for py=y,y+h-1 do for px=x,x+w-1 do
            if px>=0 and py>=0 and px<self.w and py<self.h then self.pixels[py*self.w+px]=color end
        end end
    end,
    blitFrom=function() error("failed PDF preview must not blit stale cache pixels") end}
for i=0,preview.w*preview.h-1 do preview.pixels[i]=77 end
render_fault=true
local preview_ok,preview_error=PDF.drawPreview(preview,{file="/preview-render.pdf",page=7},
    {x=2,y=3,w=20,h=18})
render_fault=false
assert(preview_ok==false and tostring(preview_error):find("MuPDF render failure",1,true),
    "preview failure did not return a useful error")
assert(warnings>0,"preview failure was not logged")
assert(preview.pixels[3*preview.w+2]==255,"preview retained stale framebuffer pixels")
local black=0
for _,pixel in pairs(preview.pixels) do if pixel==0 then black=black+1 end end
assert(black>0,"preview failure did not draw the visible error cross")
-- A dirty clip may contain only the edge of a page. The fallback paints only
-- that intersection, and it must not draw a cross whose center is outside it.
for i=0,preview.w*preview.h-1 do preview.pixels[i]=77 end
render_fault=true
local clipped_ok=PDF.drawPreview(preview,{file="/preview-clipped.pdf",page=1},
    {x=2,y=3,w=20,h=18},{x=2,y=3,w=5,h=5})
render_fault=false
assert(clipped_ok==false,"clipped preview failure was swallowed")
for py=0,preview.h-1 do for px=0,preview.w-1 do
    local pixel=preview.pixels[py*preview.w+px]
    if px>=2 and px<7 and py>=3 and py<8 then
        assert(pixel==255,"fallback cross escaped its clipped intersection")
    else
        assert(pixel==77,"fallback repainted pixels outside its clipped intersection")
    end
end end
for _,fault in ipairs({"page","document"}) do
    close_fault=fault
    local before_docs,before_pages=closed_docs,closed_pages
    local preview_ok=PDF.drawPreview(preview,{file="/preview-close-"..fault..".pdf",page=1},
        {x=2,y=3,w=20,h=18})
    assert(preview_ok==false,"preview swallowed a "..fault.." close failure")
    assert(closed_docs==before_docs+1 and closed_pages==before_pages+1,
        "preview close failure stranded a native handle")
    assert(rasters[#rasters].freed,"preview leaked a raster after "..fault.." close failure")
end
close_fault=nil
assert(closed_docs==opens and closed_pages==opens,"MuPDF handles leaked after close failures")

-- Export keeps the strict PDF path: a close fault fails the export, preserves
-- the destination, and removes its partial file.
local support=require("support")
package.loaded["ffi/blitbuffer"].TYPE_BB8=1
package.loaded["ffi/blitbuffer"].new=function(w,h) return support.FakeBB.new(w,h) end
package.loaded.template={draw=function() end}
package.loaded.renderer={drawPage=function() end}
local Export=require("export")
local output=os.tmpname()
local original=assert(io.open(output,"wb"));original:write("existing PDF");original:close()
local export_doc={pages={{strokes={},background={file="/export-close.pdf",page=1}}},
    pageCount=function() return 1 end,templateFor=function() return "blank" end,
    contentOrigin=function() return 0,0 end}
close_fault="document"
local export_ok,export_error=Export.toPDF(export_doc,output,{width=2,height=2})
close_fault=nil
assert(not export_ok and tostring(export_error):find("document close failure",1,true),
    "export silently omitted a failed PDF background")
local saved=assert(io.open(output,"rb"));local contents=saved:read("*a");saved:close()
assert(contents=="existing PDF","failed background export replaced its destination")
assert(not io.open(output..".tmp","rb"),"failed background export left a partial output")
os.remove(output)

PDF.draw(target,background,{x=0,y=0,w=0,h=20})
PDF.clear();PDF.clear()
for _,bb in ipairs(rasters) do assert(bb.freed,"cache clear leaked a raster") end
assert(closed_docs==opens and closed_pages==opens,"MuPDF handles leaked")
print("pdfcache: size alternation, neighboring pages, clipping, replacement, bounded eviction and cleanup passed")
-- Metadata failures during import/export must release every native handle too.
for _,method in ipairs({'inspect','size'}) do
    for _,fault in ipairs({'password','page count','open page','page size','invalid dimensions','none'}) do
        local documents,pages,doc_closes,page_closes=0,0,0,0
        package.loaded['ffi/mupdf'].openDocument=function()
            documents=documents+1
            return {
                needsPassword=function() return fault=='password' end,
                getPages=function() if fault=='page count' then error('count failed') end;return 2 end,
                openPage=function()
                    if fault=='open page' then error('open failed') end
                    pages=pages+1
                    return {
                        getSize=function()
                            if fault=='page size' then error('size failed') end
                            if fault=='invalid dimensions' then return 0,800 end
                            return 600,800
                        end,
                        close=function() page_closes=page_closes+1 end,
                    }
                end,
                close=function() doc_closes=doc_closes+1 end,
            }
        end
        local ok=pcall(PDF[method],'/bad.pdf',1)
        local expected=fault=='none' or method=='size' and fault=='page count'
        assert(ok==expected,'metadata failure/success changed: '..method..'/'..fault)
        assert(documents==doc_closes and pages==page_closes,'metadata leaked handles: '..method..'/'..fault)
    end
end
print('pdf metadata: import/size failures and invalid dimensions release all native handles')
