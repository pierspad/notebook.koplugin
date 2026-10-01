-- Native offscreen continuous eraser input. Run from KOReader: THIS LUA_DIR [off]
require('setupkoenv')
if arg[2]=='off' then jit.off() end
G_defaults=require('luadefaults'):open()
local settings_path=os.tmpname();os.remove(settings_path)
G_reader_settings=require('luasettings'):open(settings_path)
local Device=require('device')
require('document/canvascontext'):init(Device)
local Screen=Device.screen
local BB=require('ffi/blitbuffer')
local load=dofile(arg[1]..'/loader.lua')(arg[1])
local Canvas,Document,Stroke=load('canvas'),load('document'),load('stroke')
local timing=require('ui/time');local clock=0
local actualNow,actualMillis=timing.now,timing.to_ms
local UI=require('ui/uimanager');local pending={}
UI.scheduleIn=function(_,seconds,fn) pending[fn]=clock+seconds*1000 end
UI.unschedule=function(_,fn) pending[fn]=nil end
for _,name in ipairs({'refreshUI','refreshFast','refreshFull','refreshPartial','refreshNoMerge','refreshA2'}) do Screen[name]=function() end end
local w,h=Screen:getWidth(),Screen:getHeight()
Screen.bb=BB.new(w,h,BB.TYPE_BB8)
for _,zoom in ipairs({1,2}) do for _,width in ipairs({48,120}) do
 clock=0;pending={}
 local d=Document:new(nil);d:setTemplate('blank')
 local marker=Stroke:new{tool='highlighter',width=width,tint=160}
 for i=0,1000 do marker:addPoint(50+i*(w*.7/1000),h*.28+12*math.sin(i/30)) end
 d:addStroke(marker)
 local c=Canvas:new{document=d,content={x=0,y=0,w=w,h=h}}
 c.eraser_mode='area';c.eraser_size=8;c:setZoom(zoom)
 c:paintTo(Screen.bb,0,0)
 timing.now=function() return clock end;timing.to_ms=function(t) return t end
 local calls,model_ms,peak=0,0,0
 local erase=d.eraseAreaAlongPath
 d.eraseAreaAlongPath=function(self,...)
  local t=os.clock();local result={erase(self,...)}
  local ms=(os.clock()-t)*1000
  calls=calls+1;model_ms=model_ms+ms;peak=math.max(peak,ms)
  if arg[3]=='trace' then
   local pts=0;for _,s in ipairs(self:getPage().strokes) do pts=pts+s.n end
   io.stderr:write(string.format('call %d %.2fms points=%d\n',calls,ms,pts));io.stderr:flush()
  end
  return unpack(result)
 end
 collectgarbage('collect');local mem=collectgarbage('count');local start=os.clock()
 -- Same page-space rub at both zoom levels; a 125 Hz stream with gentle turns.
 for i=0,120 do
  clock=i*8
  local ready={};for fn,deadline in pairs(pending) do if deadline<=clock then ready[#ready+1]=fn end end
  for _,fn in ipairs(ready) do pending[fn]=nil;fn() end
  local x=w*.16+i*w*.23/120
  local y=h*.28+18*math.sin(i/12)
  c.sample_time=clock
  if zoom==1 then c:_eraseAlong(x,y) else c:_zoomStylus({id=1,x=x*zoom,y=y*zoom},'eraser') end
 end
 if zoom==1 then c:_endErase() else c:_zoomStylus({id=-1},'eraser') end
 local total=(os.clock()-start)*1000
 local points=0;for _,s in ipairs(d:getPage().strokes) do points=points+s.n end
 print(string.format('zoom=%d width=%d samples=121 model_calls=%d model=%.3fms peak=%.3fms total=%.3fms heap=%.1fKiB strokes=%d points=%d',
  zoom,width,calls,model_ms,peak,total,collectgarbage('count')-mem,#d:getPage().strokes,points))
 -- Final framebuffer must match the authoritative vector output.
 local expected=BB.new(w,h,BB.TYPE_BB8)
 expected:fill(BB.COLOR_WHITE)
 if zoom==2 then c:_renderZoom(expected,true)
 else load('renderer').drawPage(expected,d:getPage()) end
 for y=0,h-1 do for x=0,w-1 do
  assert(Screen.bb:getPixel(x,y):getColor8().a==expected:getPixel(x,y):getColor8().a,
   'dirty repaint differs from authoritative pixels')
 end end
 if arg[4] then expected:writePNG(arg[4]..'/zoom'..zoom..'-width'..width..'.png') end
 expected:free()
 timing.now, timing.to_ms=actualNow,actualMillis
 c.stopping=true;c:stop()
 io.stdout:flush()
end end
Screen.bb:free();os.remove(settings_path)
