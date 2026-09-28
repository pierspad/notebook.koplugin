package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
require('uistubs').install({})
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local Device=require('device');local Screen=Device.screen
Screen.getWidth=function() return 160 end;Screen.getHeight=function() return 200 end
Screen.bb=support.FakeBB.new(160,200);Screen.bb.getType=function() return 1 end
require('ffi/blitbuffer').new=function(w,h) return support.FakeBB.new(w,h) end
Screen.refreshFast=function() end;Screen.refreshUI=function() end
local Canvas,Document,Stroke,Renderer=require('canvas'),require('document'),require('stroke'),require('renderer')
local doc=Document:new('/tmp/zoom-history.scribe');doc:setTemplate('blank')
local c=Canvas:new{document=doc,content={x=0,y=10,w=160,h=190}}
c:setZoom(2);c.zoom_x,c.zoom_y=27,35
local function ink(x,y)
 local s=Stroke:new{tool='pen',width=4,color=0};s:addPoint(x,y,1);s:addPoint(x+40,y+20,1)
 return s
end
local a,b=ink(40,50),ink(100,120)
doc:addStroke(a);doc:addStroke(b)
c:paintTo(Screen.bb,0,0)
local cache=c.zoom_cache
local function sameAsDirect()
 local actual=Screen.bb:copy()
 c:_renderZoom(Screen.bb,true)
 for y=10,199 do for x=0,159 do
  assert(actual:get(x,y)==Screen.bb:get(x,y),'stale zoom history pixels at '..x..','..y)
 end end
 actual:free()
end
local function repaintHistory(redo)
 local page,x,y,w,h
 if redo then page,x,y,w,h=doc:redo() else page,x,y,w,h=doc:undo() end
 assert(page==1)
 c:_repaintRegion(x,y,w,h)
 assert(c.zoom_cache==cache,'local history replaced the full enlarged cache')
 c:paintTo(Screen.bb,0,0);sameAsDirect()
end
repaintHistory(false);repaintHistory(true)
-- Erased geometry may be outside the viewport; update the whole dirty area,
-- then pan there and compare against an independent vector render.
doc:removeStrokes({b});c:_repaintRegion(b:getBounds())
c.zoom_x,c.zoom_y=70,105;c:paintTo(Screen.bb,0,0);sameAsDirect()
repaintHistory(false);repaintHistory(true)
-- A direct document edit (without UI history callback) must also invalidate
-- the enlarged raster on the next render.
doc:undo();c:paintTo(Screen.bb,0,0);sameAsDirect()
assert(c.zoom_cache~=cache,'document revision did not invalidate stale cache')
cache=c.zoom_cache
-- Add/lift followed by undo before a pending cache append is flushed.
c:_zoomStylus({id=1,x=45,y=70},'pen');c:_zoomStylus({id=1,x=80,y=100},'pen')
c:_zoomStylus({id=-1},'pen')
assert(c.zoom_cache_pending,'new stroke not queued into zoom cache')
repaintHistory(false);repaintHistory(true)
-- Changing paper with the same page identity must repaint the cache too.
doc:setPageTemplate(1,'dots');c:paintTo(Screen.bb,0,0);sameAsDirect()
c:stop()
assert(not c.zoom_cache and not c.page_render_cache,'cache survived close')
print('zoom history: local repairs, offscreen erases, queued ink, revision/paper invalidation and cache cleanup passed')
