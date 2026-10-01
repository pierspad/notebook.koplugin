-- Native offscreen dirty repaint: ./luajit THIS CURRENT_LUA BASELINE_LUA
require('setupkoenv')
local current=dofile(arg[1]..'/loader.lua')(arg[1])
local before=dofile(arg[2]..'/loader.lua')(arg[2])
local Stroke,Document,Renderer=current('stroke'),current('document'),current('renderer')
local OldRenderer=before('renderer')
local BB=require('ffi/blitbuffer')
local doc=Document:new('/tmp/marker-repaint-bench.scribe')
local marker=Stroke:new{tool='highlighter',width=48,tint=160}
for i=0,1000 do marker:addPoint(100+i*1.6,500+12*math.sin(i/30)) end
doc:addStroke(marker)
for i=1,12 do assert(doc:eraseAreaAlongPath({150+i*115,474,150+i*115,500},8)) end
local a,b=BB.new(1860,2480,BB.TYPE_BB8),BB.new(1860,2480,BB.TYPE_BB8)
local clip={x=830,y=474,w=45,h=55}
local function paint(renderer,bb)
 bb:paintRect(clip.x,clip.y,clip.w,clip.h,BB.COLOR_WHITE)
 for _,s in ipairs(doc:getPage().strokes) do renderer.drawStroke(bb,s,clip) end
end
a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE)
paint(OldRenderer,a);paint(Renderer,b)
for y=0,2479 do for x=0,1859 do
 assert(a:getPixel(x,y):getColor8().a==b:getPixel(x,y):getColor8().a,'dirty pixels differ')
end end
local samples={{},{}}
for n=1,7 do
 for index=1,2 do
  collectgarbage('collect')
  local t=os.clock()
  for _=1,100 do paint(index==1 and OldRenderer or Renderer,index==1 and a or b) end
  if n>2 then samples[index][#samples[index]+1]=(os.clock()-t)*10 end
 end
end
table.sort(samples[1]);table.sort(samples[2])
local old,new=samples[1][3],samples[2][3]
print(string.format('native BB8 dirty repaint 45x55, 1001-point cut marker: before %.3f ms; after %.3f ms; %.2fx; identical pixels',old,new,old/new))
a:free();b:free()
