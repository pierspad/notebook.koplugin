-- Real BB8/RGB32 history rendering: cropped repair must match full vectors.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/zoom-history-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local dir=assert(arg[1]);local load=dofile(dir..'/loader.lua')(dir)
local BB=require('ffi/blitbuffer');local Screen=Device.screen
local Canvas,Document,Stroke,Shape,Text=load('canvas'),load('document'),load('stroke'),load('shape'),load('textobject')
Screen.refreshUI=function() end;Screen.refreshFast=function() end;Screen.refreshFull=function() end
local function rgb(p) return p:getR(),p:getG(),p:getB() end
local original=Screen.bb
for _,color in ipairs({false,true}) do
 Screen.isColorEnabled=function() return color end
 local doc=Document:new('/tmp/zoom-history-native.scribe');doc:setTemplate('dots')
 Screen.bb=BB.new(600,800,color and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
 local c=Canvas:new{document=doc,content={x=0,y=30,w=600,h=770}}
 local pen=Stroke:new{tool='pen',width=6,color=color and 0x1E53935 or 0}
 pen:addPoint(60,100,1);pen:addPoint(260,260,1);doc:addStroke(pen)
 local label=Text.create('Undo e redo',60,160,260,24,{});doc:addStroke(label)
 local shape=Shape.create('rectangle',50,110,210,235,4,160,true);doc:addStroke(shape)
 c:setZoom(2);c.zoom_x,c.zoom_y=21,73;c:paintTo(Screen.bb,0,0)
 local cache=c.zoom_cache
 local function compare()
  local actual=Screen.bb:copy();c:_renderZoom(Screen.bb,true)
  for y=30,799 do for x=0,599 do
   local ar,ag,ab=rgb(actual:getPixel(x,y));local br,bg,bb=rgb(Screen.bb:getPixel(x,y))
   assert(ar==br and ag==bg and ab==bb,'native zoom history mismatch at '..x..','..y)
  end end
  actual:free()
 end
 local function history(redo)
  local page,x,y,w,h
  if redo then page,x,y,w,h=doc:redo() else page,x,y,w,h=doc:undo() end
  assert(page==1 and x,'history must have a local dirty rectangle')
  c:_repaintRegion(x,y,w,h)
  assert(c.zoom_cache==cache,'local history rebuilt whole cache')
  c:paintTo(Screen.bb,0,0);compare()
 end
 history(false);history(true)
 doc:replaceStroke(shape,Shape.transform(shape,'se',240,255,shape.x_max,shape.y_max))
 c:_clearZoomCache();c:paintTo(Screen.bb,0,0);cache=c.zoom_cache
 history(false);history(true)
 doc:removeStrokes({pen,label});c:_repaintRegion(0,30,400,400);compare()
 history(false);history(true)
 c.zoom_x,c.zoom_y=80,120;c:paintTo(Screen.bb,0,0);compare()
 history(false);history(true)
 c:stop();Screen.bb:free()
end
Screen.bb=original
print('native BB8/RGB32 zoom history matches full vectors for ink, text, filled shapes, transforms, erases and pans')
