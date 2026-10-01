package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
local Stroke,Document,Renderer=require('stroke'),require('document'),require('renderer')
local FakeBB=support.FakeBB
local function paint(doc,scale)
 local bb=FakeBB.new(180,160);Renderer.drawPage(bb,doc:getPage(),scale);return bb
end
math.randomseed(1952)
for i=1,80 do
 local doc=Document:new('/tmp/marker-area.scribe')
 local under=Stroke:new{width=2,color=0};under:addPoint(0,75);under:addPoint(170,75);doc:addStroke(under)
 local marker=Stroke:new{tool='highlighter',width=math.random(12,35),tint=160}
 marker:addPoint(20,math.random(40,100),.6)
 marker:addPoint(150,math.random(40,100),1);doc:addStroke(marker)
 local before=paint(doc)
 local x,y,r=math.random(30,140),math.random(35,105),math.random(3,12)
 local hit=doc:eraseAreaAlongPath({x,y,x,y},r)
 local after=paint(doc)
 for py=0,159 do for px=0,179 do
  local d=math.sqrt((px-x)^2+(py-y)^2)
  if d>r+.6 then assert(before:get(px,py)==after:get(px,py),'erase changed distant ink') end
  if d<r-.6 and before:get(px,py)==160 then
   assert(after:get(px,py)==255,'area eraser left interior marker ink')
  end
  if before:get(px,py)==0 then assert(after:get(px,py)==0,'marker erase destroyed underlying ink') end
 end end
 if hit then
  doc:undo();local undone=paint(doc)
  for py=0,159 do for px=0,179 do assert(before:get(px,py)==undone:get(px,py),'undo changed pixels') end end
  doc:redo()
  assert(doc:save());local loaded=Document:new(doc.path);assert(loaded:load())
  for _,scale in ipairs({.5,1,2}) do
   local actual,want=paint(loaded,scale),paint(doc,scale)
   for py=0,159 do for px=0,179 do assert(actual:get(px,py)==want:get(px,py),'save/load changed scaled ink') end end
  end
 end
 local clipped=FakeBB.new(180,160)
 for _,s in ipairs(doc:getPage().strokes) do Renderer.drawStroke(clipped,s,{x=55.2,y=48.4,w=25.1,h=30.2}) end
 for py=49,77 do for px=56,79 do assert(clipped:get(px,py)==after:get(px,py),'partial area repaint differs') end end
end
-- Sparse crossings, contacts at the nib edge, repeated erases and interior
-- hit testing must work even when no recorded centre point is near the tip.
local doc=Document:new('/tmp/marker-repeat.scribe')
local s=Stroke:new{tool='highlighter',width=30,tint=160}
for x=10,160,.15 do s:addPoint(x,80) end
doc:addStroke(s)
assert(doc:eraseAreaAlongPath({70,65,70,95},5))
assert(#doc:getPage().strokes<30,'straight marker expanded into per-sample polygons')
assert(not doc:eraseAreaAlongPath({70,70,70,90},3),'empty area generated another undo action')
assert(doc:eraseAreaAlongPath({95,62,95,69},3),'second edge erase missed fragments')
local bb=paint(doc)
assert(bb:get(95,66)==255 and bb:get(95,80)==160,'second erase lost untouched marker')
for _,fragment in ipairs(doc:getPage().strokes) do
 if fragment.filled then
  local x,y=fragment:getPoint(1)
  assert(fragment:hitTest(x,y,1),'filled marker boundary is not selectable')
 end
end
local filled=Stroke:new{tool='highlighter',filled=true,width=30,tint=160}
filled:addPoint(20,20);filled:addPoint(80,20);filled:addPoint(80,80);filled:addPoint(20,80)
assert(filled:hitTestPath({50,50,52,52},1),'whole-stroke eraser misses polygon interior')
assert(require('lasso').isStrokeSelected(filled,{{x=45,y=45},{x=55,y=45},{x=55,y=55},{x=45,y=55}}),
    'lasso wholly inside marker fragment misses its filled surface')
local moved=filled:clone();moved:translate(10,12)
assert(moved:hitTest(85,85,0) and not filled:hitTest(85,85,0),'clone/translate shares geometry')
print('marker area: 80 independent circular cuts, dirty clips, underlying ink, scaled save/load, undo/redo, sparse and repeated erases passed')
local multipart=Stroke:new{tool='highlighter',width=30,tint=160,filled=true,marker_parts={4,8}}
for _,point in ipairs({{10,10},{30,10},{30,30},{10,30},{80,80},{100,80},{100,100},{80,100}}) do
 multipart:addPoint(point[1],point[2])
end
assert(multipart:hitTest(20,20,0) and multipart:hitTest(90,90,0) and not multipart:hitTest(55,55,0),
 'multipart hit test draws a bridge through the gap')
local cloned=multipart:clone()
assert(cloned.marker_parts and cloned.marker_parts~=multipart.marker_parts,'clone lost or shared contour boundaries')
local d=Document:new('/tmp/multipart.scribe');d:addStroke(multipart)
assert(not d:eraseAreaAlongPath({50,50,60,60},3),'gap between contours generates an erase')
assert(d:eraseAreaAlongPath({20,20,20,20},3),'first contour was not erased')
local bb=paint(d)
assert(bb:get(20,20)==255 and bb:get(90,90)==160 and bb:get(55,55)==255,'erase joined disjoint contours')
assert(d:save());local loaded=Document:new(d.path);assert(loaded:load())
local persisted=paint(loaded)
for y=0,159 do for x=0,179 do assert(bb:get(x,y)==persisted:get(x,y),'multipart persistence changed coverage') end end
assert(not require('lasso').isStrokeSelected(multipart,{{x=50,y=50},{x=60,y=50},{x=60,y=60},{x=50,y=60}}),
 'lasso selected a nonexistent bridge between contours')
print('multipart markers: independent contours, cloned indices, geometric gaps and persistence passed')
-- An independent distance-to-polyline oracle exercises fast diagonal sweeps
-- and paths that turn back, rather than just stationary circular contacts.
local function distance(x,y,ax,ay,bx,by)
 local dx,dy=bx-ax,by-ay
 local den=dx*dx+dy*dy
 local t=den>0 and math.max(0,math.min(1,((x-ax)*dx+(y-ay)*dy)/den)) or 0
 return math.sqrt((x-ax-t*dx)^2+(y-ay-t*dy)^2)
end
for _,path in ipairs({{40,50,120,100},{30,65,120,70,55,90},{70,30,80,120,90,30}}) do
 local doc=Document:new('/tmp/marker-sweeps.scribe')
 local marker=Stroke:new{tool='highlighter',width=35,tint=160}
 marker:addPoint(10,80,.7);marker:addPoint(165,80,1);doc:addStroke(marker)
 local before=paint(doc);assert(doc:eraseAreaAlongPath(path,6))
 local after=paint(doc)
 for y=0,159 do for x=0,179 do
  local best=math.huge
  for i=1,#path-3,2 do best=math.min(best,distance(x,y,path[i],path[i+1],path[i+2],path[i+3])) end
  if best>6.6 then assert(after:get(x,y)==before:get(x,y),'swept eraser overcut distant surface') end
  if best<5.4 and before:get(x,y)==160 then assert(after:get(x,y)==255,'swept eraser left marker slivers') end
 end end
end
print('marker polylines: fast diagonal sweeps and reversing paths match independent segment distances')
