package.path = "./?.lua;./spec/?.lua;" .. package.path
local support = require("support")
support.installStubs()
require("uistubs").install({})
local Device = require("device")
local Screen = Device.screen
Screen.scaleBySize = function(_,n) return n end
Screen.getWidth = function() return 160 end
Screen.getHeight = function() return 200 end
Screen.bb = support.FakeBB.new(160,200)
G_reader_settings = {readSetting=function() end,saveSetting=function() end}
local Document, Canvas, Stroke = require("document"), require("canvas"), require("stroke")
local Renderer = require("renderer")
local doc = Document:new("/tmp/notebook-performance.scribe")
local function ink(x)
    local stroke=Stroke:new{width=3}
    stroke:addPoint(x,70,1); stroke:addPoint(x+20,95,1)
    return stroke
end
for i=1,4 do
    if i>1 then doc:addPage() end
    for j=1,20 do doc:addStroke(ink(j*4)) end
end
local c=Canvas:new{document=doc,content={x=0,y=30,w=160,h=170}}
local draw=Renderer.drawStroke
local calls=0
Renderer.drawStroke=function(...) calls=calls+1; return draw(...) end
local function paint() c:paintTo(Screen.bb,0,0) end
paint(); local first=calls
assert(first==20,"initial render missing ink")
local blit = Screen.bb.blitFrom
local blits = 0
Screen.bb.blitFrom = function(self, ...)
    blits = blits + 1
    return blit(self, ...)
end
paint(); assert(calls==first,"unchanged page rerasterized")
assert(blits==1,"cached page copied the full framebuffer more than once")
Screen.bb.blitFrom = blit
local function exact()
    local expected=support.FakeBB.new(160,200)
    c:_drawTemplate(expected)
    for _,s in ipairs(doc:getPage().strokes) do draw(expected,s) end
    for y=30,199 do for x=0,159 do
        assert(expected:get(x,y)==Screen.bb:get(x,y),"stale cached pixels")
    end end
end
exact()
doc:setPageTemplate(3,"dots")
doc:goToPage(3); paint(); exact()
doc:goToPage(4); local before=calls; paint()
assert(calls==before,"adjacent page cache missed")
c:_repaintRegion(0,30,160,170,true); exact()
doc:addStroke(ink(100)); paint(); exact()
doc:undo(); paint(); exact(); doc:redo(); paint(); exact()
doc:beginBatch(); doc:addStroke(ink(110)); paint(); exact()
doc:commitBatch(); paint(); exact()
doc:setPageTemplate(4,"blank"); paint(); exact()
for i=1,4 do doc:goToPage(i); paint() end
assert(#c.page_render_cache==2,"page cache grows with notebook length")
local entries=c.page_render_cache
c:stop()
for _,entry in ipairs(entries) do assert(entry.bb.freed,"page bitmap leaked on close") end
Renderer.drawStroke=draw
-- Only edited pages rebuild their serialized stroke tables.
assert(doc:save())
local clean=doc.pages[1]._serialized
local edited=doc.pages[4]._serialized
doc:goToPage(4); doc:addStroke(ink(120)); assert(doc:save())
assert(doc.pages[1]._serialized==clean,"clean page serialization was rebuilt")
assert(doc.pages[4]._serialized~=edited,"edited serialization was reused")
local n=#doc:getPage().strokes
doc:undo(); assert(doc:save()); assert(#doc.pages[4]._serialized==n-1)
doc:redo(); assert(doc:save()); assert(#doc.pages[4]._serialized==n)
-- Large erase redo preserves order in one pass.
local original={}; for i,s in ipairs(doc:getPage().strokes) do original[i]=s end
local victims={original[2],original[7],original[12]}
doc:removeStrokes(victims); doc:undo(); doc:redo()
local out=1
for i,s in ipairs(original) do
    if i~=2 and i~=7 and i~=12 then
        assert(doc:getPage().strokes[out]==s,"erase redo changed paint order");out=out+1
    end
end
-- Two two-finger taps = exactly one undo, with expiry and palm protection.
local clock=0
require("ui/time").now=function() return clock end
require("ui/time").to_ms=function(v) return v end
local undos=0
c.owner={_undo=function() undos=undos+1 end}
c.draw_with_finger=false; c.pen_down=false; c.pen_left_at=nil
c:onHistoryTap(nil,{pos={x=80,y=100}})
clock=300; c:onHistoryTap(nil,{pos={x=80,y=100}}); assert(undos==1)
clock=600; c:onHistoryTap(nil,{pos={x=80,y=100}}); assert(undos==1,"triple tap repeated undo")
clock=1200; c:onHistoryTap(nil,{pos={x=80,y=100}}); assert(undos==1,"expired taps undid")
c.pen_down=true; clock=1300;c:onHistoryTap(nil,{pos={x=80,y=100}})
c.pen_down=false;clock=1400;c:onHistoryTap(nil,{pos={x=80,y=100}});assert(undos==1,"palm armed undo")
c.draw_with_finger=true;clock=1500;c:onHistoryTap(nil,{pos={x=80,y=100}});assert(undos==1)
c.draw_with_finger=false; c.two_finger_tap_at=nil
clock=2000;c:onHistoryTap(nil,{pos={x=20,y=60}})
clock=2200;c:onHistoryTap(nil,{pos={x=140,y=160}});assert(undos==1,"distant taps undid")
c.suspended=true;clock=2300;c:onHistoryTap(nil,{pos={x=140,y=160}})
c.suspended=false;clock=2400;c:onHistoryTap(nil,{pos={x=140,y=160}})
assert(undos==1,"suspended gesture armed undo")
c.selected_strokes={};clock=2500;c:onHistoryTap(nil,{pos={x=140,y=160}})
assert(undos==1 and not c.two_finger_tap_at,"selection armed undo")
print("performance: four-page cache pixels/invalidation/eviction/free, save reuse, erase redo and two-finger undo passed")
