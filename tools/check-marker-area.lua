-- Run from the KOReader runtime: ./luajit /plugin/tools/check-marker-area.lua /plugin/lua [output-directory]
require('setupkoenv')
local load=dofile(arg[1]..'/loader.lua')(arg[1])
local BB=require('ffi/blitbuffer')
local Stroke,Document,Renderer=load('stroke'),load('document'),load('renderer')
for _,backend in ipairs({false,true}) do
 BB:setUseCBB(backend)
 for _,kind in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
  for rotation=0,3 do
   local doc=Document:new('/tmp/native-marker-area.scribe')
   local marker=Stroke:new{tool='highlighter',width=30,tint=0x1fdd835}
   marker:addPoint(20,50,.5);marker:addPoint(140,90,1);doc:addStroke(marker)
   local before=BB.new(170,170,kind);before:setRotation(rotation);before:fill(BB.COLOR_WHITE)
   Renderer.drawPage(before,doc:getPage(),nil,0,0,true)
   assert(doc:eraseAreaAlongPath({80,55,85,75},7))
   local after=BB.new(170,170,kind);after:setRotation(rotation);after:fill(BB.COLOR_WHITE)
   Renderer.drawPage(after,doc:getPage(),nil,0,0,true)
   local clipped=BB.new(170,170,kind);clipped:setRotation(rotation);clipped:fill(BB.COLOR_WHITE)
   for _,stroke in ipairs(doc:getPage().strokes) do
    Renderer.drawStroke(clipped,stroke,{x=60.2,y=40.3,w=35.6,h=55.1},true)
   end
   for y=0,169 do for x=0,169 do
    if x>=61 and x<95 and y>=41 and y<95 then
     assert(clipped:getPixel(x,y):getColor8().a==after:getPixel(x,y):getColor8().a,'native clip differs')
    elseif x<60 or x>=96 or y<40 or y>=96 then
     assert(clipped:getPixel(x,y):getColor8().a==255,'native clip escaped')
    end
    if x<70 or x>95 or y<45 or y>85 then
     assert(before:getPixel(x,y):getColor8().a==after:getPixel(x,y):getColor8().a,'native erase changes distant ink')
    end
   end end
   if backend and kind==BB.TYPE_BB8 and rotation==0 then
    assert(doc:save());local restored=Document:new(doc.path);assert(restored:load())
    clipped:fill(BB.COLOR_WHITE);Renderer.drawPage(clipped,restored:getPage(),nil,0,0,true)
    for y=0,169 do for x=0,169 do
     assert(clipped:getPixel(x,y):getColor8().a==after:getPixel(x,y):getColor8().a,'native bitser roundtrip differs')
    end end
    os.remove(doc.path)
    if arg[2] then before:writePNG(arg[2]..'/marker-before.png');after:writePNG(arg[2]..'/marker-after.png') end
   end
   before:free();after:free();clipped:free()
  end
 end
end
print('native marker: geometric cuts, partial clips and real bitser persistence passed in BB8/RGB32, four rotations and C/Lua backends')
