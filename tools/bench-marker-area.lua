-- Real marker geometry/raster cost; run from the KOReader runtime, /plugin/lua as arg[1].
require('setupkoenv')
local load=dofile(arg[1]..'/loader.lua')(arg[1])
local Stroke,Document,Renderer=load('stroke'),load('document'),load('renderer')
local BB=require('ffi/blitbuffer')
local bb=BB.new(1860,2480,BB.TYPE_BB8)
for _,wavy in ipairs({false,true}) do
 local erase_ms,paint_ms,max_fragments=0,0,0
 for _=1,12 do
  local doc=Document:new('/tmp/marker-benchmark.scribe')
  local marker=Stroke:new{tool='highlighter',width=48,tint=160}
  for i=0,1000 do marker:addPoint(100+i*1.6,500+(wavy and 12*math.sin(i/30) or 0)) end
  doc:addStroke(marker)
  local started=os.clock()
  for i=1,12 do assert(doc:eraseAreaAlongPath({150+i*115,474,150+i*115,500},8)) end
  erase_ms=erase_ms+(os.clock()-started)*1000/12
  max_fragments=math.max(max_fragments,#doc:getPage().strokes)
  started=os.clock()
  bb:fill(BB.COLOR_WHITE);Renderer.drawPage(bb,doc:getPage())
  paint_ms=paint_ms+(os.clock()-started)*1000
 end
 print(string.format('1001-point %s, 12 cuts: mean %.3f ms/cut; %.3f ms/page render; %d final fragments',
  wavy and 'wavy marker' or 'straight marker',erase_ms/12,paint_ms/12,max_fragments))
end
bb:free()
