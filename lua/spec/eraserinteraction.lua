package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs();require('uistubs').install({})
local clock=0
local time=require('ui/time');time.now=function() return clock end;time.to_ms=function(t) return t end
local UI=require('ui/uimanager');local scheduled={}
UI.scheduleIn=function(_,delay,fn) scheduled[fn]=delay end
UI.unschedule=function(_,fn) scheduled[fn]=nil end
local Device=require('device');local Screen=Device.screen
Screen.bb=support.FakeBB.new(600,800)
Screen.refreshUI=function() end;Screen.refreshFast=function() end
Device.input.TOOL_TYPE_PEN=1;Device.input.TOOL_TYPE_ERASER=2
local Canvas,Document,Stroke=require('canvas'),require('document'),require('stroke')
local function new()
 clock=0
 local d=Document:new(nil)
 local c=Canvas:new{document=d,content={x=0,y=50,w=600,h=750}}
 c.tool='eraser';c.eraser_mode='area';c.eraser_size=3
 return c,d
end
local function stroke(d,x,y)
 local s=Stroke:new{};for px=x-5,x+5 do s:addPoint(px,y) end;d:addStroke(s);return s
end
-- A discontinuity recovered by the outlier filter is a new local contact,
-- not a straight wipe from the old point to the new one.
local c,d=new();local middle=stroke(d,300,180)
c:_eraseAlong(50,180)
for _=1,require('tuning').outlier_limit do c:_eraseAlong(550,180) end
c:_endErase()
assert(d:getPage().strokes[1]==middle,'outlier recovery erased a straight bridge across the page')
-- Crossing outside the canvas must break the path before returning inside.
c,d=new();middle=stroke(d,300,180)
c:onStylusEvent{tool=2,id=1,x=50,y=180}
c:onStylusEvent{tool=2,id=1,x=50,y=5}
clock=100
c:onStylusEvent{tool=2,id=1,x=550,y=180}
c:onStylusEvent{tool=2,id=-1}
assert(d:getPage().strokes[1]==middle,'canvas exit/reentry erased a bridge')
-- Sample timestamps, rather than processing time after a slow refresh, keep
-- actual fast motion valid. A repeated stationary dab needs no model pass.
c,d=new();local passes=0
local erase=d.eraseAreaAlongPath
d.eraseAreaAlongPath=function(self,...) passes=passes+1;return erase(self,...) end
c.sample_time=10;c:_eraseAlong(100,180)
assert(c.last_sample_at==10,'eraser did not retain the accepted input timestamp')
for _=1,80 do c:_eraseAlong(100,180) end
assert(passes==1,'stationary eraser repeatedly clipped the same area')
c:_endErase()
-- At 2x, raw kernel samples must be batched before geometry, not just refresh.
c,d=new();c:setZoom(2);passes=0
erase=d.eraseAreaAlongPath
d.eraseAreaAlongPath=function(self,...) passes=passes+1;return erase(self,...) end
for x=100,180 do c:_zoomStylus({tool=2,id=1,x=x,y=250},'eraser') end
assert(passes<=2,'zoom eraser applied geometry for every queued sample')
c:_zoomStylus({tool=2,id=-1},'eraser')
assert(passes<=3,'release did not flush the final coalesced eraser path')
assert(not d._batch and not c.erase_path,'erase contact leaked pending work')
-- The same continuity protection applies to whole-stroke mode, and a
-- recovered contact still groups both local removals into one undo operation.
for _,mode in ipairs({'area','stroke'}) do
 c,d=new();c.eraser_mode=mode;c.eraser_size=8
 local left=stroke(d,50,180);middle=stroke(d,300,180);local right=stroke(d,550,180)
 local history=#d.undo_stack
 c:_eraseAlong(50,180)
 for _=1,require('tuning').outlier_limit do c:_eraseAlong(550,180) end
 c:_endErase()
 assert(#d:getPage().strokes==1 and d:getPage().strokes[1]==middle,'gap joined in '..mode)
 assert(#d.undo_stack==history+1,'recovery split the sweep undo group')
 d:undo()
 assert(d:getPage().strokes[1]==left and d:getPage().strokes[2]==middle and d:getPage().strokes[3]==right)
 d:redo();assert(#d:getPage().strokes==1)
 assert(not scheduled[c.erase_flush_cb] and not c.erase_flush_scheduled,'released eraser left a timer')
end
-- A queued turn is preserved, while an exactly straight continuation is
-- compacted. This checks actual model input rather than a smoothing helper.
c,d=new();local paths={}
d.eraseAreaAlongPath=function(_,path) paths[#paths+1]=path end
c:_eraseAlong(50,180);c:_eraseAlong(60,180)
for x=61,80 do c:_eraseAlong(x,180) end
c:_eraseAlong(80,200);c:_endErase()
local tail=paths[#paths]
assert(#tail==6 and tail[3]==80 and tail[4]==180 and tail[5]==80 and tail[6]==200,'turn was replaced by a straight chord')
-- A modal interruption ends the contact before its next page position.
c,d=new();middle=stroke(d,300,180)
c:_eraseAlong(50,180)
c.owner={}
local top=UI.getTopmostVisibleWidget
UI.getTopmostVisibleWidget=function() return {} end
c:onStylusEvent{tool=2,id=1,x=550,y=180}
UI.getTopmostVisibleWidget=top;c.owner=nil
assert(not c.erase_path and not d._batch,'modal interruption left a connected path')
c:_eraseAlong(550,180);c:_endErase()
assert(d:getPage().strokes[1]==middle,'modal return joined separate contacts')
-- Finger/raw erasing also prevents synchronous saves during contact.
c,d=new();local saves=0
d.save=function() saves=saves+1;return true end
c:_eraseAlong(100,180);c.autosave_cb()
assert(saves==0 and scheduled[c.autosave_cb],'eraser contact allowed an idle save')
c:_endErase();c.autosave_cb();assert(saves==1,'idle save did not resume after erase release')
print('eraser interaction: discontinuity, canvas reentry, input clock, stationary nib and 2x coalescing passed')
