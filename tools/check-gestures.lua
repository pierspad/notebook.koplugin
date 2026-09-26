-- Run from KOReader's disposable SDL runtime, with plugin Lua and output directories as arguments.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
local directory=assert(arg[1]);local output=assert(arg[2])
local load=dofile(directory..'/loader.lua')(directory)
local Icon=require('ui/widget/iconwidget');local iconinit=Icon.init
Icon.init=function(self) if self.icon and self.icon:match('^notebook%.') then self.file=directory..'/icons/'..self.icon..'.svg' end;return iconinit(self) end
local Screen=Device.screen;Screen.refreshFast=function() end;Screen.refreshUI=function() end
local full=0;Screen.refreshFull=function() full=full+1 end
local UI=require('ui/uimanager');UI.show=function() end
local Document=load('document');local doc=Document:new('/tmp/native.scribe');doc:setTemplate('blank')
local nb=load('notebook'):new{document=doc};nb:paintTo(Screen.bb,0,0)
local c=nb.canvas
local Shape=load('shape');local Renderer=load('renderer')
local s=Shape.create('rectangle',120,350,380,600,5,0,true);doc:addStroke(s)
nb:paintTo(Screen.bb,0,0);c:_showLassoMenu({s});c.lasso_menu:paintTo(Screen.bb,0,0)
local menu=c.lasso_menu;local m={x=menu.dimen.x,y=menu.dimen.y,w=menu.dimen.w,h=menu.dimen.h}
c:_beginShapeTransform(s,'rotate',430,475)
assert(not load('safe').failed,'menu close failed')
for y=math.max(c.content.y,m.y),math.min(Screen:getHeight()-1,m.y+m.h-1) do
 for x=math.max(c.content.x,m.x),math.min(Screen:getWidth()-1,m.x+m.w-1) do
  assert(Screen.bb:getPixel(x,y):getColor8().a==255,'old menu pixels captured in rotation snapshot')
 end
end
c:_extendShapeTransform(350,600);c:_endShapeTransform()
c.lasso_menu:paintTo(Screen.bb,0,0)
Screen.bb:writePNG(output..'/rotation.png')
c.pen_down=false;c:_runReconcile();assert(full==1,'idle cleanup did not happen')
-- Use actual tool selection and raw stylus entry point in a panned viewport.
c:_deselectLasso();c:setZoom(2);c.zoom_x=40;c.zoom_y=c.content.y+30
c:_renderZoom(Screen.bb);nb:_selectTool(5);c.shape_kind='triangle';c.shape_fill=true
UI.getTopmostVisibleWidget=function() return nb end
Device.input.pen_slot=15
local function pen(x,y,release)
 c:onStylusEvent{slot=15,tool=Device.input.TOOL_TYPE_PEN,id=release and -1 or 1,x=x,y=y}
 assert(not load('safe').failed,'raw zoom shape input faulted')
end
pen(100,250);pen(320,450);pen(320,450,true)
assert(c.zoom==2 and doc:getPage().strokes[2].shape_kind=='triangle','zoom shape gesture failed')
c.lasso_menu:paintTo(Screen.bb,0,0)
Screen.bb:writePNG(output..'/zoom-shape.png')
nb:_selectTool(1);assert(c.zoom==2 and c.tool=='pen')
pen(80,220);pen(400,500);pen(400,500,true)
assert(#doc:getPage().strokes==3,'zoom pen tool transition lost ink')
print('native rotation snapshot, idle cleanup, zoom shapes and raw tool switch passed')
