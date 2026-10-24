-- Repeated nearby marker strokes, measured offscreen with production controllers.
-- Run from a disposable KOReader runtime; args: plugin directory, temp directory.
require('setupkoenv')
local plugin,tmp=assert(arg[1]),assert(arg[2])
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(tmp..'/settings.lua')
local Device=require('device')
for _,name in ipairs({'refreshUI','refreshFast','refreshFull','refreshPartial','refreshNoMerge','refreshA2'}) do
 Device.screen[name]=function() end
end
require('document/canvascontext'):init(Device)
local load=dofile(plugin..'/loader.lua')(plugin)
local Canvas,Document=load('canvas'),load('document')
local BB,ffi=require('ffi/blitbuffer'),require('ffi')
local function wall()
 local t=ffi.new('struct timeval');ffi.C.gettimeofday(t,nil)
 return tonumber(t.tv_sec)+tonumber(t.tv_usec)/1e6
end
local results={}
local screen=Device.screen
local original=screen.bb
for _,zoom in ipairs({1,2}) do
 for _,width in ipairs({48,120}) do
  for _,samples in ipairs({10,400}) do
  local w,h=1860,2480
  screen.bb=BB.new(w,h,BB.TYPE_BB8);screen.bb:fill(BB.COLOR_WHITE)
  local doc=Document:new(nil)
  local c=Canvas:new{document=doc,content={x=0,y=40,w=w,h=h-40},dimen={x=0,y=0,w=w,h=h}}
  c.highlighter_width=width;c.highlighter_color=160;c:setZoom(zoom)
  local starts,lifts,total=0,0,0
  for line=1,12 do
   local y=500+line*16
   local started=wall()
   if zoom==1 then c:_beginStroke('highlighter',100,y,1)
   else c:_zoomStylus({id=1,x=100,y=y,pressure=4095},'highlighter') end
   starts=starts+wall()-started
   for i=1,samples do
    local x=100+i*4
    if zoom==1 then c:_extendStroke(x,y+math.sin(i/30)*2,1)
    else c:_zoomStylus({id=1,x=x,y=y+math.sin(i/30)*2,pressure=4095},'highlighter') end
   end
   local lifted=wall()
   if zoom==1 then c:_endStroke() else c:_zoomStylus({id=-1},'highlighter') end
   lifts=lifts+wall()-lifted;total=total+wall()-started
  end
  assert(not load('safe').failed and #doc:getPage().strokes==12,'repeated marker input failed')
  results[#results+1]={zoom=zoom,width=width,strokes=12,samples_per_stroke=samples+1,
   start_ms=starts*1000/12,lift_ms=lifts*1000/12,total_ms=total*1000/12}
  local pixels=ffi.string(screen.bb.data,tonumber(screen.bb.stride)*screen.bb:getHeight())
  c:paintTo(screen.bb,0,0)
  assert(pixels==ffi.string(screen.bb.data,tonumber(screen.bb.stride)*screen.bb:getHeight()),
   'rapid marker contacts differ from an authoritative repaint')
  c:stop();screen.bb:free()
  end
 end
end
screen.bb=original
if Device.input and Device.input.teardown then Device.input:teardown() end
print('MARKER_BENCH_JSON='..require('json').encode(results))
