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
        table.sort(values);return {median=values[5],p95=values[9],min=values[1]}
    end
    results[#results+1]={name=name,cpu_ms=summary(cpu),wall_ms=summary(elapsed),
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
local victims={};for i=1,count,2 do victims[#victims+1]=doc:getPage().strokes[i] end
doc:removeStrokes(victims)
measure("history/bulk-undo-redo",function() doc:undo();doc:redo() end,20)
doc:undo()
measure("export/xopp",function() assert(Xopp.toXOPP(doc,tmp.."/out.xopp")) end,1)
measure("export/pdf-4-pages",function() assert(Export.toPDF(doc,tmp.."/out.pdf",{width=930,height=1240})) end,1,
 function() return {file_bytes=lfs.attributes(tmp.."/out.pdf","size"),width=930,height=1240} end)
local noise={};for i=0,255 do noise[#noise+1]=string.char(i) end
for name,data in pairs({paper=string.rep("\255",1860*2480),dense=string.rep(table.concat(noise),18019):sub(1,1860*2480)}) do
 measure("export/rle-"..name,function() assert(#Export.encodeRLE(data)>0) end,1,
  function() return {input_bytes=#data,output_bytes=#Export.encodeRLE(data)} end)
end

if extended then
    local Selection=load("pageselection")
    local selected=assert(Selection.view(doc,{2,4}))
    measure("export/pdf-selected-2-pages",function()
        assert(Export.toPDF(selected,tmp.."/selected.pdf",{width=930,height=1240}))
    end,1,function() return {selected_pages=2,source_pages=4,file_bytes=lfs.attributes(tmp.."/selected.pdf","size")} end)
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

Renderer.drawStroke=draw;bb:free()
if Device.input and Device.input.teardown then Device.input:teardown() end
print("NOTEBOOK_BENCH_JSON="..json.encode({schema=1,jit=jit_mode,arch=jit.arch,scale=scale,
    runtime=jit.version,screen={width=1860,height=2480,bpp=8},samples=9,results=results}))
