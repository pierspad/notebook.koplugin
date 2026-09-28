-- Native KOReader renderer, offscreen only. Run from the emulator runtime:
-- SDL_VIDEODRIVER=dummy ./luajit /path/tools/bench-notebook.lua /path/lua
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/tmp/notebook-bench-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
local load=dofile(assert(arg[1]).."/loader.lua")(arg[1])
local Document,Canvas,Stroke=load("document"),load("canvas"),load("stroke")
local BB=require("ffi/blitbuffer")
local screen=Device.screen
screen.bb=BB.new(screen:getWidth(),screen:getHeight(),BB.TYPE_BB8)
screen.refreshUI=function() end;screen.refreshFast=function() end
local doc=Document:new("/tmp/notebook-bench.scribe")
for p=1,4 do
    if p>1 then doc:addPage() end
    for j=1,400 do
        local s=Stroke:new{width=3}
        for k=1,64 do s:addPoint(30+(j%18)*45+k/3,60+math.floor(j/18)*40+math.sin(k/6)*8,0.7) end
        doc:addStroke(s)
    end
end
local canvas=Canvas:new{document=doc,content={x=0,y=40,w=screen:getWidth(),h=screen:getHeight()-40}}
local function measure(name,n,fn)
    collectgarbage("collect")
    local start=os.clock()
    for i=1,n do fn(i) end
    print(string.format("%s: %.3f ms/op",name,(os.clock()-start)*1000/n))
end
canvas:paintTo(screen.bb,0,0)
measure("four-page notebook adjacent page repaint",20,function(i)
    doc:goToPage(i%2==0 and 4 or 3);canvas:paintTo(screen.bb,0,0)
end)
assert(doc:save())
measure("four-page atomic save",8,function() assert(doc:save()) end)
local victims={}
for i=1,400,2 do victims[#victims+1]=doc:getPage().strokes[i] end
doc:removeStrokes(victims)
measure("undo + redo 200-stroke erase",100,function() doc:undo();doc:redo() end)
canvas:stop();screen.bb:free();os.remove(doc.path)
