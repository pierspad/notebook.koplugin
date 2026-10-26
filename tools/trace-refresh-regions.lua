-- luacheck: globals G_defaults
-- Synthetic 125 Hz pen input, regional-refresh submissions captured, no panel I/O.
require('setupkoenv')
local root,tmp=assert(arg[1]),assert(arg[2])
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(tmp..'/refresh-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local Screen=Device.screen
local original_bb=Screen.bb
local BB=require('ffi/blitbuffer');local UI=require('ui/uimanager');local time=require('ui/time')
local clock,pending=0,{}
local real_now,real_ms=time.now,time.to_ms
time.now=function() return clock end;time.to_ms=function(t) return t end
UI.scheduleIn=function(_,seconds,fn) pending[fn]=clock+seconds*1000 end
UI.unschedule=function(_,fn) pending[fn]=nil end
local load=dofile(root..'/loader.lua')(root)
local Canvas,Document=load('canvas'),load('document')
local results={}
local active,calls=false,{}
for _,name in ipairs({'refreshFast','refreshUI','refreshFull','refreshPartial','refreshNoMerge','refreshA2'}) do
 Screen[name]=function(_,x,y,w,h)
  assert(x>=80 and y>=0 and x+w<=1860 and y+h<=2480,'refresh escaped drawable content')
  calls[#calls+1]={mode=name,x=x,y=y,w=w,h=h,active=active,at=clock}
 end
end
-- Model REAGL capability for routing only; this is not a physical-driver test.
Screen.waveform_partial=4;Screen._isREAGLWaveFormMode=function(_,mode) return mode==4 end
local function advance(ms)
 clock=clock+ms
 for _=1,20 do
  local ready={};for fn,deadline in pairs(pending) do if deadline<=clock then ready[#ready+1]=fn end end
  if #ready==0 then return end
  for _,fn in ipairs(ready) do pending[fn]=nil;fn() end
 end
 error('task queue did not settle')
end
for _,pattern in ipairs({'nearby','distant'}) do
 clock,pending,calls=0,{},{}
 Screen.bb=BB.new(1860,2480,BB.TYPE_BB8);Screen.bb:fill(BB.COLOR_WHITE)
 local d=Document:new(nil)
 local c=Canvas:new{document=d,content={x=80,y=0,w=1780,h=2480}}
 c.highlighter_width=48;c.highlighter_color=160
 for line=1,12 do
  local x=pattern=='distant' and (line%2==0 and 1400 or 120) or 120
  local y=pattern=='distant' and (line%2==0 and 2200 or 300) or 300+line*16
  active=true;c.pen_down=true;c:_beginStroke('highlighter',x,y,1)
  for i=1,12 do advance(8);c:_extendStroke(x+i*4,y,1) end
  c:_endStroke();c.pen_down=false;active=false
  advance(16)
 end
 advance(1000)
 local counts,area={},{}
 for _,v in ipairs(calls) do
  counts[v.mode]=(counts[v.mode] or 0)+1
  area[v.mode]=(area[v.mode] or 0)+v.w*v.h
  assert(not v.active or v.mode=='refreshFast','slow refresh occurred during contact')
 end
 results[#results+1]={pattern=pattern,strokes=#d:getPage().strokes,counts=counts,submitted_pixel_area=area,calls=calls}
 c.stopping=true;c:stop();Screen.bb:free();Screen.bb=original_bb
end
time.now,time.to_ms=real_now,real_ms
if Device.input and Device.input.teardown then Device.input:teardown() end
print('REFRESH_TRACE_JSON='..require('json').encode(results))
