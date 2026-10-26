-- luacheck: globals G_defaults
-- Whole-stroke miss/hit test through model and the production Canvas controller.
-- Run from KOReader: ./luajit THIS PLUGIN_LUA
require("setupkoenv")
G_defaults=require("luadefaults"):open()
local settings_path=os.tmpname();os.remove(settings_path)
G_reader_settings=require("luasettings"):open(settings_path)
local Device=require("device")
require("document/canvascontext"):init(Device)
local Screen=Device.screen
local original_bb=Screen.bb
local BB=require("ffi/blitbuffer")
for _,name in ipairs({"refreshUI","refreshFast","refreshFull","refreshPartial","refreshNoMerge","refreshA2"}) do
    Screen[name]=function() end
end
local load=dofile(assert(arg[1]).."/loader.lua")(arg[1])
local Canvas,Document,Stroke,Renderer=load("canvas"),load("document"),load("stroke"),load("renderer")
local timing=require("ui/time");local clock=0
local original_now,original_ms=timing.now,timing.to_ms
timing.now=function() return clock end
timing.to_ms=function(t) return t end
local UI=require("ui/uimanager");local pending={}
UI.scheduleIn=function(_,seconds,fn) pending[fn]=clock+seconds*1000 end
UI.unschedule=function(_,fn) pending[fn]=nil end
local w,h=Screen:getWidth(),Screen:getHeight()
Screen.bb=BB.new(w,h,BB.TYPE_BB8)

local function makeDoc(with_hit)
    local doc=Document:new(nil)
    local stroke=Stroke:new{width=3,pen_style="fineliner"}
    local rows,per_row=200,1000
    for row=0,rows-1 do
        local y=row%2==0 and h*.125 or h*.375
        for j=0,per_row-1 do
            local forward=(row%2==0) and j or (per_row-1-j)
            local x=forward*(w-1)/(per_row-1)
            stroke:addPoint(x,y,1)
        end
    end
    doc.pages[1].strokes={stroke}
    local crossing
    if with_hit then
        crossing=Stroke:new{width=3,pen_style="fineliner"}
        crossing:addPoint(w*.5-4,h*.25,1);crossing:addPoint(w*.5+4,h*.25,1)
        doc.pages[1].strokes[2]=crossing
    end
    return doc,stroke,crossing
end
local function makeCrowdedDoc()
    local doc=Document:new(nil)
    local count=3000
    for i=1,count do
        local row=math.floor((i-1)/50)
        local col=(i-1)%50
        local y=row%2==0 and h*.125 or h*.375
        local x=col*(w-8)/49
        local stroke=Stroke:new{width=3,pen_style="fineliner"}
        stroke:addPoint(x,y,1);stroke:addPoint(x+4,y+2,1)
        doc.pages[1].strokes[i]=stroke
    end
    return doc,count
end
local function makeSnake(point_count)
    local stroke=Stroke:new{width=3,pen_style="fineliner"}
    local half=math.floor(point_count/2)
    for i=0,point_count-1 do
        local row=i<half and 0 or 1
        local j=i<half and i or i-half
        local count=row==0 and half or point_count-half
        local forward=row==0 and j or count-1-j
        stroke:addPoint(forward*(w-1)/(count-1),row==0 and 100 or 300,1)
    end
    return stroke
end
local function signature(doc)
    local bb=BB.new(w,h,BB.TYPE_BB8);bb:fill(BB.COLOR_WHITE)
    Renderer.drawPage(bb,doc:getPage())
    local ffi=require("ffi")
    local pixels=ffi.string(bb.data,tonumber(bb.stride)*bb:getHeight())
    bb:free();return pixels
end
local doc,long=makeDoc(false)
local miss={w*.5-2,h*.25,w*.5+2,h*.25}
assert(not long:hitTestPath(miss,4),"miss fixture touches long stroke")
long:chunkIndex()
collectgarbage("collect")
local mem_before_queries=collectgarbage("count")
local samples={}
for sample=1,9 do
    collectgarbage("collect")
    local started=os.clock()
    for _=1,160 do assert(not long:hitTestPath(miss,4)) end
    samples[sample]=(os.clock()-started)*1000/160
end
table.sort(samples)
print(string.format("warm long-stroke hitTestPath miss: median %.4f ms/query (160 calls x 9), points=%d chunks=%d",
    samples[5],long.n,#long:chunkIndex()))
collectgarbage("collect")
print(string.format("long-stroke query index retained: %.1f KiB; groups=%s",
    collectgarbage("count")-mem_before_queries,tostring(long.chunk_groups~=nil)))
local cold=long:clone()
collectgarbage("collect")
local cold_before=collectgarbage("count")
local cold_start=os.clock()
assert(not cold:hitTestPath(miss,4),"cold miss fixture touches long stroke")
local cold_ms=(os.clock()-cold_start)*1000
collectgarbage("collect")
local cold_first_kib=collectgarbage("count")-cold_before
local group_start=os.clock()
assert(not cold:hitTestPath(miss,4),"repeated cold miss fixture touches long stroke")
local group_ms=(os.clock()-group_start)*1000
collectgarbage("collect")
print(string.format("cold 200k-point path miss: %.3f ms; first-query cache %.1f KiB; second query %.3f ms; groups=%s",
    cold_ms,cold_first_kib,group_ms,tostring(cold.chunk_groups~=nil)))
for _,point_count in ipairs({200,2000}) do
    local sample=makeSnake(point_count)
    collectgarbage("collect")
    local started=os.clock()
    assert(not sample:hitTestPath(miss,4),"medium cold miss fixture touches stroke")
    local cold_elapsed=(os.clock()-started)*1000
    local misses={}
    for round=1,7 do
        local at=os.clock()
        for _=1,300 do assert(not sample:hitTestPath(miss,4)) end
        misses[round]=(os.clock()-at)*1000/300
    end
    table.sort(misses)
    print(string.format("%d-point miss: cold %.4f ms; warm median %.4f ms/query; groups=%s",
        point_count,cold_elapsed,misses[4],tostring(sample.chunk_groups~=nil)))
end
local model_samples={}
for sample=1,7 do
    local started=os.clock()
    for _=1,80 do assert(doc:eraseAlongPath(miss,4)==nil) end
    model_samples[sample]=(os.clock()-started)*1000/80
end
table.sort(model_samples)
print(string.format("Document:eraseAlongPath miss: median %.4f ms/query (80 calls x 7)",model_samples[4]))

local crowded,crowded_count=makeCrowdedDoc()
local crowded_samples={}
for sample=1,7 do
    local started=os.clock()
    for _=1,80 do assert(crowded:eraseAlongPath(miss,4)==nil) end
    crowded_samples[sample]=(os.clock()-started)*1000/80
end
table.sort(crowded_samples)
print(string.format("Document page miss: median %.4f ms/query (%d strokes)",
    crowded_samples[4],crowded_count))

local function controller(with_hit,crowded_page,count_tests)
    local d,stroke,crossing
    local page_strokes
    if crowded_page then d,page_strokes=makeCrowdedDoc();stroke=d:getPage().strokes[1]
    else d,stroke,crossing=makeDoc(with_hit);page_strokes=#d:getPage().strokes end
    local before=signature(d)
    local c=Canvas:new{document=d,content={x=0,y=0,w=w,h=h}}
    c.eraser_mode="stroke";c.eraser_size=8
    local old_hit_test=Stroke.hitTestPath
    local detailed_tests=0
    if count_tests then
        Stroke.hitTestPath=function(self,...)
            detailed_tests=detailed_tests+1
            return old_hit_test(self,...)
        end
    end
    local erase=d.eraseAlongPath
    local model_calls,model_ms,model_peak=0,0,0
    d.eraseAlongPath=function(self,...)
        local started=os.clock();local result={erase(self,...)}
        local ms=(os.clock()-started)*1000
        model_calls=model_calls+1;model_ms=model_ms+ms;model_peak=math.max(model_peak,ms)
        return unpack(result)
    end
    local start=os.clock()
    for i=0,120 do
        clock=i*8
        local ready={};for fn,deadline in pairs(pending) do if deadline<=clock then ready[#ready+1]=fn end end
        for _,fn in ipairs(ready) do pending[fn]=nil;fn() end
        local x=w*.35+i*w*.3/120
        c.sample_time=clock
        c:_eraseAlong(x,h*.25)
    end
    c:_endErase()
    if count_tests then Stroke.hitTestPath=old_hit_test end
    local elapsed=(os.clock()-start)*1000
    local after=signature(d)
    if with_hit then
        assert(#d:getPage().strokes==1 and d:getPage().strokes[1]==stroke,"controller did not erase intended crossing stroke")
        assert(d:canUndo(),"hit was not recorded for undo")
        d:undo();assert(#d:getPage().strokes==2 and d:getPage().strokes[2]==crossing,"undo failed to restore crossing stroke")
        assert(signature(d)==before,"undo pixels differ from original")
        d:redo();assert(#d:getPage().strokes==1,"redo failed")
    else
        assert(#d:getPage().strokes==page_strokes and d:getPage().strokes[1]==stroke,"miss changed model")
        assert(not d:canUndo(),"miss created undo history")
        assert(after==before,"miss changed rendered pixels")
    end
    c.stopping=true;c:stop()
    return elapsed,detailed_tests,model_calls,model_ms,model_peak,stroke.chunk_groups~=nil
end
local miss_ms,_,miss_calls,miss_model,miss_peak,miss_tree=controller(false)
print(string.format("production Canvas controller miss (121 samples): %.3f ms; model=%d calls %.3fms peak=%.3fms groups=%s",
    miss_ms,miss_calls,miss_model,miss_peak,tostring(miss_tree)))
local crowded_ms,_,crowded_calls,crowded_model,crowded_peak,crowded_tree=controller(false,true)
print(string.format("production Canvas controller crowded-page miss (121 samples): %.3f ms; 3000 strokes, model=%d calls %.3fms peak=%.3fms groups=%s",
    crowded_ms,crowded_calls,crowded_model,crowded_peak,tostring(crowded_tree)))
print(string.format("production Canvas controller hit (121 samples; undo checked separately): %.3f ms",controller(true)))
-- Count calls in a separate replay: the instrumentation would otherwise
-- disproportionately penalize the baseline that enters detailed testing.
local _,counted_tests=controller(false,true,true)
print(string.format("untimed crowded-controller detailed tests: %d",counted_tests))
timing.now,timing.to_ms=original_now,original_ms
Screen.bb:free();Screen.bb=original_bb;os.remove(settings_path)
if Device.input and Device.input.teardown then Device.input:teardown() end
