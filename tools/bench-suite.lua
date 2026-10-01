-- Native offscreen benchmark, driven by tools/benchmark.py. Never accesses user notebooks.
require("setupkoenv")
local plugin,tmp,jit_mode,scale=assert(arg[1]),assert(arg[2]),arg[3],tonumber(arg[4]) or 1
tmp=assert(require("ffi/util").realpath(tmp))
if jit_mode=="off" then jit.off() else jit.on() end
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open(tmp.."/settings.lua")
local Device=require("device")
-- Never ask the physical e-ink driver to refresh, including during stop/flush.
for _,name in ipairs({"refreshUI","refreshFast","refreshFull","refreshPartial","refreshNoMerge","refreshA2"}) do
    Device.screen[name]=function() end
end
require("document/canvascontext"):init(Device)
local load=dofile(plugin.."/loader.lua")(plugin)
local Document,Stroke,Renderer=load("document"),load("stroke"),load("renderer")
local Canvas,Lasso,Export,Xopp=load("canvas"),load("lasso"),load("export"),load("xopp")
local BB=require("ffi/blitbuffer")
local ffi=require("ffi")
local json=require("json")
local lfs=require("libs/libkoreader-lfs")
local function wall() local t=ffi.new("struct timeval");ffi.C.gettimeofday(t,nil);return tonumber(t.tv_sec)+tonumber(t.tv_usec)/1e6 end
local function rss()
    local f=io.open("/proc/self/status","r");if not f then return 0 end
    local s=f:read("*a");f:close();return tonumber(s:match("VmRSS:%s+(%d+)")) or 0
end
local results={}
local extended=arg[5]=="extended"
local function measure(name,fn,iterations,counters)
    if arg[6] and not name:find(arg[6],1,true) then return end
    io.stderr:write("NOTEBOOK_BENCH_CASE="..name.."\n");io.stderr:flush()
    local jit_before=jit.status()
    fn() -- explicit warm-up; cold scenarios reset their own state.
    local cpu,elapsed,heap,retained,resident,gc={},{},{},{},{},{}
    local frequency={}
    for i=1,9 do
        collectgarbage("collect")
        local mem=collectgarbage("count")
        local r=rss()
        local c,t=os.clock(),wall()
        for _=1,iterations or 1 do fn() end
        cpu[i]=(os.clock()-c)*1000/(iterations or 1)
        elapsed[i]=(wall()-t)*1000/(iterations or 1)
        heap[i]=collectgarbage("count")-mem
        resident[i]=rss()-r
        local gc_start=os.clock()
        collectgarbage("collect");retained[i]=collectgarbage("count")-mem
        gc[i]=(os.clock()-gc_start)*1000
        local freq=io.open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq","r")
        if freq then frequency[i]=tonumber(freq:read("*a"));freq:close() end
    end
    local function summary(values)
        local sorted={};for i,value in ipairs(values) do sorted[i]=value end
        table.sort(sorted)
        return {median=sorted[5],p95=sorted[9],min=sorted[1],max=sorted[9],raw=values}
    end
    results[#results+1]={name=name,iterations=iterations or 1,warmups=1,cpu_ms=summary(cpu),wall_ms=summary(elapsed),
        heap_delta_kib=summary(heap),retained_kib=summary(retained),rss_delta_kib=summary(resident),explicit_gc_ms=summary(gc),cpu_frequency_khz=frequency,
        jit_active_before=jit_before,jit_active_after=jit.status(),counters=counters and counters() or {}}
end
local function ink(i,tool,points)
    local s=Stroke:new{tool=tool or "pen",width=tool=="highlighter" and 24 or 3,
        pen_style=i%3==0 and "pencil" or "fineliner",tint=160}
    for k=1,points or 48 do
        s:addPoint(40+i%18*90+k,100+math.floor(i/18)%36*60+math.sin(k/6)*8,0.7)
    end
    return s
end
local count=400*scale
local doc=Document:new(tmp.."/fixture.scribe")
for p=1,4 do
    if p>1 then doc:addPage() end
    for i=1,count do doc:addStroke(ink(i,i%8==0 and "highlighter" or "pen")) end
end
assert(doc:save())
local function ioCounts() return {file_bytes=lfs.attributes(doc.path,"size"),pages=4,strokes_per_page=count} end
measure("save/unchanged",function() assert(doc:save()) end,1,ioCounts)
measure("save/one-page-edit",function() doc:addStroke(ink(1));assert(doc:save());doc:undo() end,1,ioCounts)
measure("load/full-notebook",function() local d=Document:new(doc.path);assert(d:load());assert(d:pageCount()==4) end,1,ioCounts)
measure("load/thumbnail-preview",function()
    local d=Document:new(doc.path)
    if d.loadPreview then assert(d:loadPreview()) else assert(d:load()) end
end,1,function() return {materialized_pages=Document.loadPreview and 1 or 4,strokes_per_page=count} end)
local polygon={}
for i=1,200 do local a=i*2*math.pi/200;polygon[i]={x=900+200*math.cos(a),y=1200+200*math.sin(a)} end
measure("lasso/200-vertices",function() Lasso.findSelectedStrokes(doc:getPage().strokes,polygon) end,10)
local bb=BB.new(1860,2480,BB.TYPE_BB8)
local draw=Renderer.drawStroke
local calls=0
Renderer.drawStroke=function(...) calls=calls+1;return draw(...) end
local function pixels() local out={draw_calls_total=calls,buffer_bytes=1860*2480};calls=0;return out end
measure("render/full-mixed-page",function() bb:fill(BB.COLOR_WHITE);Renderer.drawPage(bb,doc:getPage()) end,1,pixels)
measure("render/dirty-64x64",function()
    local clip={x=700,y=700,w=64,h=64};bb:paintRect(700,700,64,64,BB.COLOR_WHITE)
    for _,s in ipairs(doc:getPage().strokes) do Renderer.drawStroke(bb,s,clip) end
end,5,pixels)
local screen=Device.screen
local original=screen.bb;screen.bb=bb
local canvas=Canvas:new{document=doc,content={x=0,y=40,w=1860,h=2440},dimen={x=0,y=0,w=1860,h=2480}}
measure("repaint/production-64x64",function() canvas:_repaintRegion(700,700,64,64,true) end,5,pixels)
measure("cache/page-cold",function()
    for _,e in ipairs(canvas.page_render_cache or {}) do e.bb:free() end
    canvas.page_render_cache={};canvas:paintTo(bb,0,0)
end,1,pixels)
local blits=0
local blit=BB.blitFrom
BB.blitFrom=function(...) blits=blits+1;return blit(...) end
measure("cache/page-warm",function() canvas:paintTo(bb,0,0) end,10,function()
    local counts=pixels();counts.blit_calls=blits;return counts
end)
BB.blitFrom=blit
canvas.zoom=2;canvas.zoom_x=0;canvas.zoom_y=40
measure("zoom/2x-cold",function() canvas:_clearZoomCache();canvas:_renderZoom(bb) end,1,
 function() return {zoom_buffer_bytes=1860*2440*4} end)
measure("zoom/2x-pan-warm",function() canvas.zoom_x=canvas.zoom_x==0 and 100 or 0;canvas:_renderZoom(bb) end,10)
canvas:stop();screen.bb=original
measure("render/thumbnail-page",function() local small=BB.new(186,248,BB.TYPE_BB8);Renderer.drawPage(small,doc:getPage(),0.1);small:free() end,1)
for _,kind in ipairs({"pen","highlighter"}) do
    measure("eraser/area-"..kind,function()
        local d=Document:new(tmp.."/unused.scribe")
        local s=Stroke:new{tool=kind,width=kind=="highlighter" and 48 or 3,tint=160}
        for i=0,1000 do s:addPoint(100+i*1.6,500+12*math.sin(i/30),1) end
        d:addStroke(s);d:beginBatch()
        for i=1,12 do d:eraseAreaAlongPath({150+i*115,474,150+i*115,550},8,{}) end
        d:commitBatch();d:undo();d:redo()
    end,1)
end
-- Wide nibs, repeated fragment cuts and near misses reveal costs hidden by
-- narrow centreline-only fixtures. Baselines run exactly the same workloads.
for _,width in ipairs({48,120,300}) do
    local marker=Stroke:new{tool="highlighter",width=width,tint=160}
    for i=0,1000 do marker:addPoint(100+i*1.6,500+12*math.sin(i/30),1) end
    local hits=0
    measure("eraser/marker-edge-"..width,function()
        hits=0
        for i=1,60 do
            if marker:hitTestPath({100+i*24,500+width*.4,100+i*24+8,500+width*.4},3) then hits=hits+1 end
        end
    end,5,function() return {hits=hits,queries=60,points=1001,width=width} end)
    local fragment_counts={}
    measure("eraser/marker-cuts-"..width,function()
        local d=Document:new(nil);d:addStroke(marker:clone());d:beginBatch()
        for i=1,12 do d:eraseAreaAlongPath({150+i*115,500-width*.4,150+i*115,500+width*.4},8,{}) end
        d:commitBatch();d:undo();d:redo()
        local points,contours=0,0
        for _,stroke in ipairs(d:getPage().strokes) do
            points=points+stroke.n
            contours=contours+(stroke.marker_parts and #stroke.marker_parts or 1)
        end
        fragment_counts={strokes=#d:getPage().strokes,points=points,contours=contours,width=width,cuts=12}
    end,1,function() return fragment_counts end)
end
-- A crossing that deletes thousands of separate objects used to shift the
-- surviving tail once per hit. Keep sparse/no-hit cases alongside the dense case.
local object_strokes={}
for i=1,4000*scale do
    local stroke=Stroke:new{width=3}
    stroke:addPoint(i%2==0 and 300 or 100,100+i*.2,1);stroke:addPoint(i%2==0 and 350 or 150,100+i*.2,1);stroke:addPoint(i%2==0 and 400 or 200,100+i*.2,1)
    object_strokes[i]=stroke
end
for _,density in ipairs({"miss","sparse","dense"}) do
    local remaining,removed_count=0,0
    measure("eraser/object-"..density,function()
        local d=Document:new(nil)
        for i,stroke in ipairs(object_strokes) do d.pages[1].strokes[i]=stroke end
        local path=density=="miss" and {1000,100,1000,1000*scale}
            or density=="sparse" and {150,100,150,105} or {150,90,150,110+800*scale}
        local removed=d:eraseAlongPath(path,3)
        removed_count=removed and #removed or 0
        remaining=#d:getPage().strokes
        d:undo();assert(#d:getPage().strokes==#object_strokes)
        d:redo();assert(#d:getPage().strokes==remaining)
    end,1,function() return {strokes=remaining,hits=removed_count,initial_strokes=#object_strokes} end)
end
-- Production Safe.widget uses a watchdog on ordinary event handlers. Measure
-- actual wrappers as well as direct model work; these calls restore JIT state.
local Safe=load("safe")
local guarded=Document:new(nil)
for i=1,count do guarded:addStroke(ink(i)) end
local guarded_victims={}
for i=1,count,2 do guarded_victims[#guarded_victims+1]=guarded:getPage().strokes[i] end
guarded:removeStrokes(guarded_victims)
local function history_callback() guarded:undo();guarded:redo();return true end
local widget={handleEvent=history_callback}
Safe.widget(widget,"benchmark-history")
local unguarded={handleEvent=history_callback}
Safe.widget(unguarded,"benchmark-history-unwatched",false)
for _,entry in ipairs({{"direct",history_callback},{"watched",function() assert(widget:handleEvent()) end},
    {"protected",function() assert(unguarded:handleEvent()) end}}) do
    measure("callbacks/history-"..entry[1],entry[2],20,function()
        assert(not Safe.failed);return {strokes=#guarded:getPage().strokes}
    end)
end
local victims={};for i=1,count,2 do victims[#victims+1]=doc:getPage().strokes[i] end
doc:removeStrokes(victims)
measure("history/bulk-undo-redo",function() doc:undo();doc:redo() end,20)
doc:undo()
measure("export/xopp",function() assert(Xopp.toXOPP(doc,tmp.."/out.xopp")) end,1)
measure("export/pdf-4-pages",function() assert(Export.toPDF(doc,tmp.."/out.pdf",{width=930,height=1240})) end,1,
 function() return {file_bytes=lfs.attributes(tmp.."/out.pdf","size"),width=930,height=1240} end)
local noise={};for i=0,255 do noise[#noise+1]=string.char(i) end
for _,entry in ipairs({{"paper",string.rep("\255",1860*2480)},
    {"dense",string.rep(table.concat(noise),18019):sub(1,1860*2480)}}) do
 local name,data=entry[1],entry[2]
 measure("export/rle-"..name,function() assert(#Export.encodeRLE(data)>0) end,1,
  function() return {input_bytes=#data,output_bytes=#Export.encodeRLE(data)} end)
end

if extended then
    -- A complete repeated session exposes cache coexistence and invalidation,
    -- unlike isolated warm calls. RSS sampled at phase boundaries is a lower
    -- bound on the peak, not a continuous native allocation measurement.
    local workflow_counts={}
    measure("workflow/edit-page-zoom-save",function()
        local d=Document:new(tmp.."/workflow.scribe")
        for p=1,4 do
            if p>1 then d:addPage() end
            for i,stroke in ipairs(doc.pages[p].strokes) do d:getPage().strokes[i]=stroke end
        end
        local c=Canvas:new{document=d,content={x=0,y=40,w=1860,h=2440},dimen={x=0,y=0,w=1860,h=2480}}
        screen.bb=bb
        local start_rss,peak=rss(),rss()
        local function observe() peak=math.max(peak,rss()) end
        for p=1,4 do
            d:goToPage(p);c:paintTo(bb,0,0);observe()
            local before=#d:getPage().strokes
            local added=ink(1);d:addStroke(added)
            c:paintTo(bb,0,0);observe()
            d:undo();assert(#d:getPage().strokes==before);c:paintTo(bb,0,0)
            d:redo();assert(d:getPage().strokes[before+1]==added)
            c.zoom=2;c.zoom_x=0;c.zoom_y=40;c:_renderZoom(bb);observe()
            c.zoom_x=100;c:_renderZoom(bb);observe()
            c:_clearZoomCache();c.zoom=1
        end
        assert(d:save());observe()
        local restored=Document:new(d.path);assert(restored:load());observe()
        assert(restored:pageCount()==4 and restored.current_page==4)
        local total=0
        for p=1,4 do
            assert(#restored.pages[p].strokes==#doc.pages[p].strokes+1)
            total=total+#restored.pages[p].strokes
        end
        local cache_bytes=0
        for _,entry in ipairs(c.page_render_cache or {}) do
            cache_bytes=cache_bytes+entry.bb:getWidth()*entry.bb:getHeight()
        end
        c:stop();assert(not c.zoom_cache and not c.page_render_cache)
        screen.bb=original
        workflow_counts={pages=4,strokes=total,saves=1,zoom_renders=8,
            sampled_rss_peak_delta_kib=peak-start_rss,page_cache_bytes_at_close=cache_bytes}
    end,1,function() return workflow_counts end)
    local Selection=load("pageselection")
    local selected=assert(Selection.view(doc,{2,4}))
    measure("export/pdf-selected-2-pages",function()
        assert(Export.toPDF(selected,tmp.."/selected.pdf",{width=930,height=1240}))
    end,1,function() return {selected_pages=2,source_pages=4,file_bytes=lfs.attributes(tmp.."/selected.pdf","size")} end)
    local Svg=load("svg")
    measure("export/svg-full",function() assert(Svg.toSVG(doc,tmp.."/out.svg")) end,1,
        function() return {pages=doc:pageCount(),file_bytes=lfs.attributes(tmp.."/out.svg","size")} end)
    measure("export/svg-selected",function() assert(Svg.toSVG(selected,tmp.."/selected.svg")) end,1,
        function() return {selected_pages=2,source_pages=4,file_bytes=lfs.attributes(tmp.."/selected.svg","size")} end)
    measure("export/xopp-selected",function() assert(Xopp.toXOPP(selected,tmp.."/selected.xopp")) end,1,
        function() return {selected_pages=2,source_pages=4,file_bytes=lfs.attributes(tmp.."/selected.xopp","size")} end)
    local pages_doc=Document:new(nil)
    for i,stroke in ipairs(doc:getPage().strokes) do pages_doc.pages[1].strokes[i]=stroke end
    measure("history/page-duplicate-undo-redo",function()
        assert(pages_doc:duplicatePage(1)==2)
        assert(pages_doc.pages[2].strokes[1]~=pages_doc.pages[1].strokes[1])
        pages_doc:undo();assert(pages_doc:pageCount()==1)
        pages_doc:redo();assert(pages_doc:pageCount()==2)
        pages_doc:undo();pages_doc:goToPage(1)
    end,1,function() return {pages=pages_doc:pageCount(),strokes=#pages_doc.pages[1].strokes} end)
    local Text,Shape=load("textobject"),load("shape")
    local rich={strokes={}}
    for i=1,40 do
        rich.strokes[#rich.strokes+1]=Text.create("Caffè Ελληνικά 日本語 line "..i,40,40+i*45,700,24,{font_family="sans"})
        rich.strokes[#rich.strokes+1]=Shape.create(i%2==0 and "circle" or "rectangle",900,40+i*45,1200,70+i*45,4,0,true)
    end
    measure("render/text-and-filled-shapes",function() bb:fill(BB.COLOR_WHITE);Renderer.drawPage(bb,rich) end,1)
    for _,paper in ipairs({"blank","lined","grid","dots"}) do
        measure("paper/"..paper,function() load("template").draw(bb,paper,{x=0,y=0,w=1860,h=2480},1) end,5)
    end
    local PDF=load("pdfbackground")
    if not lfs.attributes(tmp.."/out.pdf") then
        assert(Export.toPDF(doc,tmp.."/out.pdf",{width=930,height=1240}))
    end
    local background={file=tmp.."/out.pdf",page=1}
    measure("background/pdf-cold",function() PDF.clear();PDF.draw(bb,background,{x=0,y=0,w=1860,h=2480}) end,1)
    PDF.draw(bb,background,{x=0,y=0,w=1860,h=2480})
    measure("background/pdf-warm",function() PDF.draw(bb,background,{x=0,y=0,w=1860,h=2480}) end,10)
    local small_pdf=BB.new(186,248,BB.TYPE_BB8)
    measure("background/pdf-alternating-size",function()
        PDF.draw(bb,background,{x=0,y=0,w=1860,h=2480})
        PDF.draw(small_pdf,background,{x=0,y=0,w=186,h=248})
    end,3,function() return {full_pixels=1860*2480,thumbnail_pixels=186*248} end)
    measure("background/pdf-alternating-page",function()
        PDF.draw(bb,background,{x=0,y=0,w=1860,h=2480})
        PDF.draw(bb,{file=background.file,page=2},{x=0,y=0,w=1860,h=2480})
    end,3)
    small_pdf:free()
    PDF.clear()
    local Library,Thumbnail=load("library"),load("thumbnail")
    assert(lfs.mkdir(tmp.."/library"));Library.root=function() return tmp.."/library" end
    local Share=load("share")
    local DS=require("datastorage")
    local oldDataDir=DS.getDataDir
    DS.getDataDir=function() return tmp end
    assert(lfs.mkdir(tmp.."/cache"))
    measure("share/cache-key-full-file",function() assert(Share.cachedExport(doc.path,"fixture","pdf")) end,1,
        function() return {input_bytes=lfs.attributes(doc.path,"size")} end)
    DS.getDataDir=oldDataDir
    measure("history/200-batches",function()
        local d=Document:new(tmp.."/history-unused.scribe")
        for i,stroke in ipairs(doc:getPage().strokes) do d.pages[1].strokes[i]=stroke end
        for i=1,200 do d:beginBatch();d:addStroke(ink(i));d:commitBatch() end
        assert(#d.undo_stack==200)
    end,1,function() return {history_operations=200,initial_strokes=count} end)
    local copy=assert(io.open(doc.path,"rb"));local bytes=copy:read("*a");copy:close()
    local source=tmp.."/library/fixture.scribe"
    local file=assert(io.open(source,"wb"));assert(file:write(bytes));assert(file:close())
    measure("thumbnail/disk-cold",function() Thumbnail.forget(source);assert(Thumbnail.get(source,186,248,1860,2480)) end,1)
    assert(Thumbnail.get(source,186,248,1860,2480))
    measure("thumbnail/disk-warm",function() assert(Thumbnail.cached(source)) end,100)
    for i=1,1000 do local f=assert(io.open(tmp.."/library/note-"..i..".scribe","wb"));f:close() end
    measure("library/list-1001",function() assert(#Library.list("","recent")==1001) end,1)
end

-- Page selection has a UI cost beyond parsing ranges: opening and toggling
-- can rebuild and repaint every visible thumbnail. Use device-sized fixtures.
if not arg[6] or arg[6]=="" or ("ui/page-grid"):find(arg[6],1,true) then
    local Icon=require("ui/widget/iconwidget")
    local icon_init=Icon.init
    Icon.init=function(self)
        if self.icon and self.icon:match("^notebook%.") then self.file=plugin.."/icons/"..self.icon..".svg" end
        return icon_init(self)
    end
    local ui_doc=Document:new(nil)
    local width,height=Device.screen:getWidth(),Device.screen:getHeight()
    for page=1,100 do
        if page>1 then ui_doc:addPage() end
        for i=1,40 do
            local stroke=Stroke:new{width=3}
            for point=1,24 do stroke:addPoint(width*.1+point*width*.02,height*.1+i*height*.014,1) end
            ui_doc:addStroke(stroke)
        end
    end
    ui_doc:goToPage(1)
    local UI=require("ui/uimanager")
    local dirty=UI.setDirty
    UI.setDirty=function() end
    local function counters() return {pages=100,strokes_per_page=40,points_per_stroke=24,screen_width=width,screen_height=height} end
    local PagePanel=load("pagepanel")
    measure("ui/page-grid-navigation-open",function()
        local panel=PagePanel:new{document=ui_doc}
        panel:paintTo(bb,0,0);assert(not load("safe").failed);panel:onCloseWidget()
    end,1,counters)
    local ChoosePages=load("exportpagesdialog")
    if ChoosePages.new then
        measure("ui/page-grid-export-open",function()
            local panel=ChoosePages.new(ui_doc,function() end)
            panel:paintTo(bb,0,0);assert(not load("safe").failed);panel:onCloseWidget()
        end,1,counters)
        local panel=ChoosePages.new(ui_doc,function() end)
        measure("ui/page-grid-export-toggle",function()
            panel:_goToPage(1);panel:paintTo(bb,0,0)
        end,1,counters)
        panel:onCloseWidget()
    end
    UI.setDirty=dirty;Icon.init=icon_init
end

Renderer.drawStroke=draw;bb:free()
if Device.input and Device.input.teardown then Device.input:teardown() end
print("NOTEBOOK_BENCH_JSON="..json.encode({schema=1,jit=jit_mode,arch=jit.arch,scale=scale,
    runtime=jit.version,screen={width=1860,height=2480,bpp=8},samples=9,results=results}))
