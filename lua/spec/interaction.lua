package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
require('uistubs').install({})
local Device=require('device');local Screen=Device.screen
Screen.bb=support.FakeBB.new(600,800)
local fast,full,ui=0,0,0
Screen.refreshFast=function() fast=fast+1 end
Screen.refreshUI=function() ui=ui+1 end
Screen.refreshFull=function() full=full+1 end
local UI=require('ui/uimanager');local clock=0;local scheduled={}
local time=require('ui/time');time.now=function() return clock end;time.to_ms=function(v) return v end
UI.scheduleIn=function(_,delay,fn) scheduled[fn]=delay end
UI.unschedule=function(_,fn) scheduled[fn]=nil end
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local Document,Canvas,Renderer=require('document'),require('canvas'),require('renderer')
local doc=Document:new('/tmp/interactions.scribe')
local nb=require('notebook'):new{document=doc}
local c=nb.canvas;c.content={x=0,y=0,w=600,h=800}
c:setZoom(2);c.zoom_x=50;c.zoom_y=60
nb:_selectTool(5)
assert(c.zoom==2 and c.tool=='shape','selecting shape left zoom')
c.shape_kind='triangle';c.shape_fill=true
c:_zoomStylus({id=1,x=100,y=200},'shape')
c:_zoomStylus({id=1,x=300,y=400},'shape')
c:_zoomStylus({id=-1},'shape')
local s=doc:getPage().strokes[1]
assert(s and s.shape_kind=='triangle' and s.filled and s.x_min==100 and s.y_min==160,
    'zoom shape stored screen rather than page coordinates')
local hx,hy
for _,h in ipairs(c:shapeHandles(s)) do if h[1]=='rotate' then hx,hy=c:_viewPoint(h[2],h[3]) end end
-- The floating toolbar is above/below the shape, not over its rotation handle.
c:_zoomStylus({id=1,x=hx,y=hy},'shape')
assert(c.transform_gesture,'zoom rotation handle missed the selected shape')
c:_zoomStylus({id=1,x=hx-20,y=hy+70},'shape')
c:_zoomStylus({id=-1},'shape')
assert(#doc:getPage().strokes==1 and doc:getPage().strokes[1]~=s,'zoom rotation did not replace shape')
nb:_selectTool(1);assert(c.zoom==2 and c.tool=='pen','pen selection reset zoom')
-- No full vector replay when toolbar undo state changes.
local old=c.paintTo;c.paintTo=function() error('toolbar rerendered canvas') end
nb:_refreshToolbar();c.paintTo=old
-- A deferred cleanup never flashes during ink, then runs once at rest.
c:_scheduleCleanScreen();c.pen_down=true;c:_runReconcile()
assert(full==0 and c.reconcile_full,'full refresh interrupted pen contact')
c.pen_down=false;c:_runReconcile();c:_runReconcile()
assert(full==1 and not c.reconcile,'cleanup was lost or duplicated')
-- Cached pen lift does not rasterize the entire completed stroke again.
Screen.bb.getType=function() return 1 end
require('ffi/blitbuffer').new=function(w,h) return support.FakeBB.new(w,h) end
c:_renderZoom(Screen.bb)
c:_zoomStylus({id=1,x=70,y=100},'pen')
c:_zoomStylus({id=1,x=170,y=180},'pen')
local draw=Renderer.drawPage
Renderer.drawPage=function() error('pen lift replayed vector ink') end
c:_zoomStylus({id=-1},'pen')
Renderer.drawPage=draw
assert(c.zoom_cache_pending and #c.zoom_cache_pending==1,'cache delta lost')
c:_flushZoomCacheInk();assert(not c.zoom_cache_pending,'cache delta not applied on demand')
-- The kernel timing survives queued delivery at the same UI clock tick.
local plain=Canvas:new{document=Document:new('/tmp/timed.scribe')}
plain.sample_time=100;plain:_beginStroke('pen',100,300,1)
plain.sample_time=120;plain:_extendStroke(plain.last_x+plain.jump_base+50,300,1)
assert(plain.stroke:count()==2,'queued valid fast motion was rejected using processing time')
plain.sample_time=121;plain:_extendStroke(1700,300,1)
assert(plain.stroke:count()==2,'timestamp handling disabled palm jump rejection')
-- Independent analytic membership in a union of linearly varying discs.
local PenInk=require('penink')
for _,line in ipairs({{10,10,3,80,10,3},{10,10,2,10,80,7},{10,15,7,75,80,2},
    {80,20,4,12,75,8},{35,35,1,36,36,8}}) do
    local x0,y0,r0,x1,y1,r1=unpack(line)
    local bb=support.FakeBB.new(100,100)
    PenInk.draw(bb,x0,y0,r0,x1,y1,r1,0,false,false)
    local dx,dy,dr=x1-x0,y1-y0,r1-r0
    local denom=dx*dx+dy*dy-dr*dr
    for y=0,99 do for x=0,99 do
        local function inside(t)
            return (x-x0-dx*t)^2+(y-y0-dy*t)^2-(r0+dr*t)^2
        end
        local v=math.min(inside(0),inside(1))
        if denom>0 then
            local t=math.max(0,math.min(1,((x-x0)*dx+(y-y0)*dy+r0*dr)/denom))
            v=math.min(v,inside(t))
        end
        if math.abs(v)>1e-7 then
            assert((bb:get(x,y)==0)==(v<0),'scanline pen coverage differs from swept discs')
        end
    end end
end
print('interaction: zoom shape/rotation/tool switch, cleanup, pen lift and input timestamps passed')
-- Shape contact must use a visible binary outline, including colored fills.
for _,zoom in ipairs({1,2}) do
 Screen.bb=support.FakeBB.new(180,220)
 local shapes=Canvas:new{document=Document:new('/tmp/shape-preview.scribe'),
     content={x=0,y=0,w=180,h=220}}
 shapes.zoom=zoom;shapes.zoom_x=0;shapes.zoom_y=0
 shapes.shape_kind='rectangle';shapes.shape_color=160;shapes.shape_fill=true
 shapes.pen_width=2
 shapes:_beginShape(20,30);shapes:_extendShape(70,80)
 local x,y=shapes:_viewPoint(20,50)
 assert(Screen.bb:get(x,y)==0,'gray figure sent to binary waveform')
 x,y=shapes:_viewPoint(45,55)
 assert(Screen.bb:get(x,y)==255,'filled preview hides the underlying page')
 shapes.stopping=true;shapes:_endShape()
 assert(Screen.bb:get(x,y)==160,'pen lift failed to restore authoritative fill')
end
-- Event coalescing must retain the newest endpoint and finish it on pen-up.
Screen.bb=support.FakeBB.new(180,220)
local shapes=Canvas:new{document=Document:new('/tmp/shape-cadence.scribe'),
 content={x=0,y=0,w=180,h=220}}
shapes.stopping=true;shapes.shape_color=160;shapes.pen_width=2
clock=1000;shapes:_beginShape(20,30);shapes:_extendShape(70,80)
local preview=shapes.stroke;local paints=fast
shapes:_extendShape(70,80)
assert(shapes.stroke==preview and fast==paints,'stationary sample re-rasterized the figure')
clock=1010;shapes:_extendShape(90,100)
clock=1020;shapes:_extendShape(110,120)
assert(shapes.stroke==preview and scheduled[shapes.shape_preview_cb],'preview throttle failed')
local snapshot=shapes.shape_gesture.background
shapes:_endShape()
local final=shapes.document:getPage().strokes[1]
assert(final.x_max==110 and final.y_max==120,'pen-up lost latest throttled endpoint')
assert(snapshot.freed and not scheduled[shapes.shape_preview_cb],'shape left a snapshot or callback alive')
-- Resizing and rotating recognized markers retain the actual brush metadata.
local original=require('shape').create('rectangle',20,30,70,80,12,0,false)
original.tool='highlighter';original.tint=160
shapes.document:addStroke(original)
clock=2000;shapes:_beginShape(20,30,original);shapes:_extendShape(110,120)
local x,y=shapes:_viewPoint(20,50)
assert(Screen.bb:get(x,y)==0,'marker figure preview is not black')
shapes:_endShape()
local resized=shapes.document:getPage().strokes[2]
assert(resized.tool=='highlighter' and resized.tint==160,'shape resize changed the marker brush')
local rotated=require('shape').transform(resized,'rotate',120,150,120,80)
assert(rotated.tint==160 and rotated.tool=='highlighter','shape rotation lost marker tint')
print('shape previews: binary outlines, final fills, 1x/2x, coalesced release, stationary input, brush metadata and snapshot cleanup passed')

-- Direct layer controls must repaint immediately and retain shape selection.
for _,zoom in ipairs({1,2}) do
 Screen.bb=support.FakeBB.new(180,220)
 local d=Document:new('/tmp/direct-order.scribe')
 local shape=require('shape').create('rectangle',20,30,70,80,2,160,true)
 local ink=require('stroke'):new{width=3};ink:addPoint(40,50);ink:addPoint(50,60)
 d:addStroke(shape);d:addStroke(ink)
 local canvas=Canvas:new{document=d,content={x=0,y=0,w=180,h=220}}
 canvas.zoom=zoom;canvas.zoom_x=0;canvas.zoom_y=0
 canvas:_showLassoMenu({shape})
 assert(canvas.lasso_menu.on_order,'missing direct layer action')
 canvas.lasso_menu.on_order(true)
 assert(d:getPage().strokes[2]==shape,'direct front action failed')
 assert(canvas.selected_strokes[1]==shape and canvas.lasso_menu,'layer action lost selection')
 local depth=#d.undo_stack
 canvas.lasso_menu.on_order(true)
 assert(#d.undo_stack==depth,'unchanged layer action added undo')
 canvas.lasso_menu.on_order(false)
 assert(d:getPage().strokes[1]==shape,'direct back action failed')
 d:undo();assert(d:getPage().strokes[2]==shape,'layer undo failed')
 d:redo();assert(d:getPage().strokes[1]==shape,'layer redo failed')
end
print('direct shape layer controls: selection, no-op, undo/redo at 1x/2x passed')
-- A preview already painted before pen-up is still the committed endpoint.
Screen.bb=support.FakeBB.new(180,220)
local transform_doc=Document:new('/tmp/transform-release.scribe')
local original_shape=require('shape').create('rectangle',20,30,70,80,2,0,false)
transform_doc:addStroke(original_shape)
local transform_canvas=Canvas:new{document=transform_doc,content={x=0,y=0,w=180,h=220}}
transform_canvas:_beginShapeTransform(original_shape,'se',70,80)
clock=4000;transform_canvas:_extendShapeTransform(100,110)
assert(transform_canvas.transform_gesture.preview,'fixture did not paint preview')
transform_canvas:_endShapeTransform()
assert(transform_doc:getPage().strokes[1].x_max==100,'painted transform endpoint lost at release')
transform_doc:undo();assert(transform_doc:getPage().strokes[1]==original_shape,'transform undo lost original')
print('shape transform release: painted endpoint commits once and undo restores original')
