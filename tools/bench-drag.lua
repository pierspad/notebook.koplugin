-- KOReader runtime, offscreen selection benchmark. No event-loop/UI registration.
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open("/mnt/us/koreader/settings.reader.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
package.path=assert(arg[1]).."/?.lua;"..package.path
local BB=require("ffi/blitbuffer")
local Doc=require("document")
local Stroke=require("stroke")
local Canvas=require("canvas")
local Lasso=require("lasso")
local Tuning=require("tuning")
Tuning.drag_repaint_ms=60
local screen=Device.screen
screen.bb=BB.new(1860,2480,BB.TYPE_BB8)
local frames=0
screen.refreshFast=function() frames=frames+1 end
screen.refreshUI=function() end
local doc=Doc:new("/tmp/notebook-audit/unsaved-benchmark.scribe")
-- 18 long crossing lines; a compact selected mark touches their bounding boxes.
for i=1,18 do
    local s=Stroke:new{width=3}
    s:addPoint(50,50+i*20,1)
    s:addPoint(1700,2200-i*20,1)
    doc:addStroke(s)
end
local selected=Stroke:new{width=3}
selected:addPoint(600,700,1)
selected:addPoint(680,780,1)
doc:addStroke(selected)
local canvas=Canvas:new{document=doc}
canvas.selected_strokes={selected}
canvas.selection_bbox=Lasso.getSelectionBounds(canvas.selected_strokes)
canvas.dragging_selection=true
canvas.drag_last_x,canvas.drag_last_y=600,700
canvas._showLassoMenu=function() end
local started=os.clock()
for i=1,100 do canvas:_extendStroke(600+i,700+i,1) end
canvas:_endStroke()
print(string.format("100 queued drag samples: %.2f ms CPU, %d fast refreshes, final x=%.0f",
    (os.clock()-started)*1000,frames,selected.x_min))
assert(selected.x_min==700,"final displacement lost")
assert(doc:canUndo())
doc:undo()
assert(selected.x_min==600,"drag undo failed")
screen.bb:free()
