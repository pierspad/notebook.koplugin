-- Real BB8/RGB32 integration; run from KOReader with /plugin/lua as argument.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/live-ink-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local load=dofile(arg[1]..'/loader.lua')(arg[1])
local BB=require('ffi/blitbuffer');local Screen=Device.screen
local Canvas,Document,Stroke=load('canvas'),load('document'),load('stroke')
local ui,fast=0,0
Screen.refreshUI=function() ui=ui+1 end
Screen.refreshFast=function() fast=fast+1 end
Screen.refreshFull=function() error('unexpected full refresh') end
local original=Screen.bb
local w,h=Screen:getWidth(),Screen:getHeight()
for _,rgb in ipairs({false,true}) do
 Screen.isColorEnabled=function() return rgb end
 for _,zoom in ipairs({1,2}) do
  for _,style in ipairs({'fineliner','fountain','pencil','highlighter'}) do
    Screen.bb=BB.new(w,h,rgb and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
    local doc=Document:new('/tmp/live-ink-native.scribe');doc:setTemplate('blank')
    local c=Canvas:new{document=doc,content={x=0,y=0,w=w,h=h}}
    c.pen_style=style;c.pen_color=0x1E53935;c.pen_width=7;c.highlighter_width=24
    c.highlighter_color=0x1FDD835
    local text=Stroke:new{tool='pen',width=3,color=0}
    text:addPoint(10,160,1);text:addPoint(w-20,160,1);doc:addStroke(text)
    c:setZoom(zoom);if zoom==2 then c.zoom_x=23;c.zoom_y=31 end
    c:paintTo(Screen.bb,0,0)
    local tool=style=='highlighter' and style or 'pen'
    local n=ui
    if zoom==1 then c:_beginStroke(tool,100,140,1);c:_extendStroke(230,185,1)
    else c:_zoomStylus({id=1,x=100,y=140,pressure=4095},tool)
        c:_zoomStylus({id=1,x=230,y=185,pressure=4095},tool) end
    assert(c.live_ink,'preview not started')
    if arg[2] and style=='highlighter' then
        Screen.bb:writePNG(arg[2]..'/marker-preview-'..zoom..'-'..tostring(rgb)..'.png')
    end
    if zoom==1 then c:_endStroke() else c:_zoomStylus({id=-1},tool) end
    assert(not c.live_ink and ui==n,'preview leaked or gray update queued')
    local actual=Screen.bb:copy();c:paintTo(Screen.bb,0,0)
    for y=0,h-1 do for x=0,w-1 do
        local a,b=actual:getPixel(x,y),Screen.bb:getPixel(x,y)
        assert(a:getR()==b:getR() and a:getG()==b:getG() and a:getB()==b:getB(),
            string.format('residue %s zoom=%d RGB=%s at %d,%d',style,zoom,tostring(rgb),x,y))
    end end
    if arg[2] and style=='highlighter' then
        Screen.bb:writePNG(arg[2]..'/marker-final-'..zoom..'-'..tostring(rgb)..'.png')
    end
    c:_clearZoomCache();if c.background_cache then c.background_cache:free() end
    actual:free();Screen.bb:free()
  end
 end
end
Screen.bb=original
assert(fast>0,'no fast feedback')
print('native BB8/RGB32: colored pen/pencil/fountain/marker at 1x/2x match complete page exactly')
