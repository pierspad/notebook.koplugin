-- Verify held-arrow replacement pixels immediately, before any full refresh.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/text-menu-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
G_reader_settings:saveSetting('language',arg[3] or 'en')
local dir=assert(arg[1]);local load=dofile(dir..'/loader.lua')(dir)
local Icon=require('ui/widget/iconwidget');local iconinit=Icon.init
Icon.init=function(self)
 if self.icon and self.icon:match('^notebook%.') then self.file=dir..'/icons/'..self.icon..'.svg' end
 return iconinit(self)
end
local Screen=Device.screen;Screen.refreshFast=function() end;Screen.refreshUI=function() end
local UI=require('ui/uimanager');UI.show=function() end
local Renderer=load('renderer');local Shape=load('shape')
local full,fast,ui=0,0,0
Screen.refreshFull=function() full=full+1 end
Screen.refreshFast=function() fast=fast+1 end
Screen.refreshUI=function() ui=ui+1 end
for _,case in ipairs({{1,true},{2,true},{2,false}}) do
 local zoom,cached=case[1],case[2]
 for _,style in ipairs({'fineliner','fountain','pencil','highlighter'}) do
  for _,color in ipairs({0,128}) do
   local nb=load('notebook'):new{document=load('document'):new('/tmp/snap-qa.scribe')}
   local c=nb.canvas;c.zoom=zoom;c.zoom_x=c.content.x;c.zoom_y=c.content.y
   c.pen_style=style;c.pen_color=color;c.line_style='arrow'
   local tool=style=='highlighter' and 'highlighter' or 'pen'
   nb:paintTo(Screen.bb,0,0)
   local base=Screen.bb:copy()
   for i=0,20 do
    local x,y=80+i*12,180+i*2+math.sin(i/3)*8
    if zoom==1 then
     if i==0 then c:_beginStroke(tool,x,y,0.7) else c:_extendStroke(x,y,0.7) end
    else c:_zoomStylus({id=1,x=x,y=y,pressure=0.7},tool) end
   end
   local raw=c.stroke or c.zoom_stroke
   local clean=assert(Shape.recognize(raw,'arrow'))
   if not cached then c:_clearZoomCache() end
   local before=ui;c:_applyShapeSnap(clean,raw)
   assert(ui==before+1 and full==0,'snap did not use a single local UI refresh')
   local actual=Screen.bb
   if zoom==1 then Renderer.drawStroke(base,clean,c.content)
   else
    local area=c.content
    Renderer.drawPage(base:viewport(area.x,area.y,area.w,area.h),{strokes={clean}},zoom,
      -c.zoom_x*zoom,-c.zoom_y*zoom,false)
   end
   for y=0,Screen:getHeight()-1 do for x=0,Screen:getWidth()-1 do
    assert(actual:getPixel(x,y):getColor8().a==base:getPixel(x,y):getColor8().a,
     string.format('snap pixels differ zoom=%d style=%s color=%d at %d,%d',zoom,style,color,x,y))
   end end
   base:free();c:_clearZoomCache()
   if c.background_cache then c.background_cache:free() end
  end
 end
end
print('native arrow replacements match authoritative pixels for all pen styles, gray/black and zoom')
-- A zoom repair must not clear neighboring rows/ink through a viewport stride.
local nb=load('notebook'):new{document=load('document'):new('/tmp/zoom-clip-qa.scribe')}
local c=nb.canvas;c.zoom=2;c.zoom_x=c.content.x;c.zoom_y=c.content.y
local BB=require('ffi/blitbuffer')
local x,y,w,h=40,c.content.y+30,3,20
Screen.bb:fill(BB.COLOR_BLACK)
c:_repaintScreenRegion(x,y,w,h,true)
for py=0,Screen:getHeight()-1 do for px=0,Screen:getWidth()-1 do
 if not (px>=x and px<x+w and py>=y and py<y+h) then
  assert(Screen.bb:getPixel(px,py):getColor8().a==0,'zoom repair cleared pixels outside dirty region')
 end
end end
c:_renderZoom(Screen.bb)
local original=c.zoom_cache:copy()
c.zoom_erase_region={x=40,y=c.content.y+30,w=3,h=20}
c:_flushZoomErase()
for py=0,c.zoom_cache:getHeight()-1 do for px=0,c.zoom_cache:getWidth()-1 do
 assert(c.zoom_cache:getPixel(px,py):getColor8().a==original:getPixel(px,py):getColor8().a,
  'zoom cache repair differs from full page')
end end
original:free();c:_clearZoomCache()
print('native zoom repair stays inside dirty bounds and matches the enlarged page cache')
