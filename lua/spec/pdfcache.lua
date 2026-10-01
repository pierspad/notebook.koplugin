package.path = "./?.lua;./spec/?.lua;" .. package.path
local opens, rasters, closed_docs, closed_pages = 0, {}, 0, 0
local generation, size = 100, 200
local render_fault = false
package.loaded["libs/libkoreader-lfs"]={attributes=function()
    return {size=size,modification=generation,change=generation,ino=generation,dev=1}
end}
package.loaded["ffi/drawcontext"]={new=function() return {setZoom=function() end} end}
package.loaded["ffi/mupdf"]={openDocument=function()
    opens=opens+1
    return {openPage=function(_,number)
        return {getSize=function() return 600,800 end,close=function() closed_pages=closed_pages+1 end,
            draw_new=function(_,_,w,h)
                if render_fault then error("MuPDF render failure") end
                local bb={w=w,h=h,stride=w,page=number,generation=generation}
                function bb:getHeight() return self.h end
                function bb:free() assert(not self.freed,"double free");self.freed=true end
                rasters[#rasters+1]=bb
                return bb
            end}
    end,close=function() closed_docs=closed_docs+1 end}
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
PDF.draw(target,background,{x=0,y=0,w=0,h=20})
PDF.clear();PDF.clear()
for _,bb in ipairs(rasters) do assert(bb.freed,"cache clear leaked a raster") end
assert(closed_docs==opens and closed_pages==opens,"MuPDF handles leaked")
print("pdfcache: size alternation, neighboring pages, clipping, replacement, bounded eviction and cleanup passed")
