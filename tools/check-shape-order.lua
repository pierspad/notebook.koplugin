-- Native shape-order menu, paint order and undo at both zoom levels.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/shape-order-settings.lua')
G_reader_settings:saveSetting('language','it')
local Device=require('device');require('document/canvascontext'):init(Device)
local dir=assert(arg[1]);local load=dofile(dir..'/loader.lua')(dir)
local Icon=require('ui/widget/iconwidget');local iconinit=Icon.init
Icon.init=function(self)
 if self.icon and self.icon:match('^notebook%.') then self.file=dir..'/icons/'..self.icon..'.svg' end
 return iconinit(self)
end
local Screen=Device.screen
Screen.refreshFast=function() end;Screen.refreshUI=function() end
local Canvas,Document,Shape,Stroke=load('canvas'),load('document'),load('shape'),load('stroke')
local UI=require('ui/uimanager');local shown
UI.show=function(_,widget) shown=widget end
for _,zoom in ipairs({1,2}) do
 local doc=Document:new('/tmp/shape-order.scribe');doc:setTemplate('blank')
 local c=Canvas:new{document=doc,content={x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}}
 local shape=Shape.create('rectangle',40,100,200,220,3,160,true)
 local ink=Stroke:new{tool='pen',width=5,color=0};ink:addPoint(100,160,1)
 doc:addStroke(shape);doc:addStroke(ink)
 c:setZoom(zoom);c:paintTo(Screen.bb,0,0)
 local x,y=c:_viewPoint(100,160)
 assert(Screen.bb:getPixel(x,y):getColor8().a==0,'initial ink not above shape')
 c:_showLassoMenu({shape})
 assert(c.lasso_menu.on_order,'shape has no order action')
 local menu=shown
 local row=menu.content_frame[1]
 local switch=row[1]
 assert(switch[1].icon=='notebook.above-text' and switch[2].icon=='notebook.below-text','layer icons missing')
 assert(switch[1].dimen.h==row[3].dimen.h and switch[2].dimen.h==row[3].dimen.h,'layer button heights differ')
 assert(switch[2].active and not switch[1].active,'back state not indicated')
 assert(menu==c.lasso_menu and menu.order_front==false,'direct order control state missing')
 menu:paintTo(Screen.bb,0,0)
 if arg[2] then Screen.bb:writePNG(arg[2]..'/shape-order-'..zoom..'.png') end
 assert(switch[1].dimen.x>=menu.dimen.x and switch[1].dimen.y==menu.dimen.y,'button tap area not placed')
 assert(menu:handleEvent(require('ui/event'):new('Gesture',{ges='tap',pos={x=switch[1].dimen.x+10,y=switch[1].dimen.y+10,w=0,h=0}})),'native layer tap not consumed')
 assert(c.lasso_menu.order_front==true,'front state not updated')
 c:_deselectLasso();c:paintTo(Screen.bb,0,0)
 assert(doc:getPage().strokes[2]==shape,'shape not moved forward')
 assert(Screen.bb:getPixel(x,y):getColor8().a==160,'front shape did not cover ink')
 doc:undo();c:_clearZoomCache();c:paintTo(Screen.bb,0,0)
 assert(Screen.bb:getPixel(x,y):getColor8().a==0,'undo did not restore ink')
 doc:redo();c:_clearZoomCache();c:paintTo(Screen.bb,0,0)
 c:_showLassoMenu({shape});c.lasso_menu.content_frame[1][1][2]:onTap();c:_deselectLasso();c:paintTo(Screen.bb,0,0)
 assert(Screen.bb:getPixel(x,y):getColor8().a==0,'back shape hid ink')
end
print('native direct shape-order controls, rendering and undo passed at 1x/2x')
