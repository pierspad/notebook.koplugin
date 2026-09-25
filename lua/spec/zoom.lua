package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()
require("uistubs").install({})

local Device = require("device")
Device.screen.bb = support.FakeBB.new(400, 600)
Device.screen.refreshFast = function() end
Device.screen.refreshUI = function() end
Device.input = {
    TOOL_TYPE_PEN = 1, TOOL_TYPE_ERASER = 2, TOOL_TYPE_HIGHLIGHTER = 3,
}

local Zoom = require("zoom")
local Canvas = require("canvas")
local Document = require("document")
G_reader_settings={readSetting=function() end, saveSetting=function() end}
package.loaded["ui/widget/button"].setText=function(self, text) self.text=text end
local doc = Document:new("/tmp/notebook-zoom.scribe")
local canvas = Canvas:new{document=doc, content={x=0,y=0,w=400,h=600}}

Device.input.stylus_eraser_active = true
assert(canvas:resolveTool(2)=="highlighter")
canvas.barrel_button_tool="eraser"
assert(canvas:resolveTool(2)=="eraser", "pen button setting did not select eraser")
Device.input.stylus_eraser_active = false
assert(canvas:resolveTool(2)=="eraser", "rubber tip no longer erases")

assert(Zoom.clamp(-10,0,400,2)==0)
assert(Zoom.clamp(999,0,400,2)==200)
canvas:setZoom(2)
canvas:_zoomStylus({id=1,x=100,y=120},"pen")
canvas:_zoomStylus({id=1,x=200,y=220},"pen")
canvas:_zoomStylus({id=-1},"pen")
local stroke=doc:getPage().strokes[1]
assert(stroke and stroke:count()==2)
local x,y=stroke:getPoint(1)
assert(x==50 and y==60,"zoomed pen stored screen rather than page coordinates")
canvas:_zoomPan(-200,-300)
assert(canvas.zoom_x==100 and canvas.zoom_y==150)
canvas:_zoomStylus({id=1,x=100,y=120},"pen")
canvas:_zoomStylus({id=-1},"pen")
x,y=doc:getPage().strokes[2]:getPoint(1)
assert(x==150 and y==210,"panned viewport did not map the pen to page space")
canvas:_zoomStylus({id=1,x=100,y=120},"eraser")
canvas:_zoomStylus({id=-1},"eraser")
assert(#doc:getPage().strokes==1,"zoomed eraser missed the mapped stroke")
doc:undo()
assert(#doc:getPage().strokes==2,"zoomed eraser did not make one undoable action")
canvas:_zoomStylus({id=1,x=300,y=300},"highlighter")
canvas:_zoomStylus({id=-1},"highlighter")
local highlight=doc:getPage().strokes[3]
assert(highlight.tool=="highlighter" and highlight.width==canvas.highlighter_width
    and highlight.tint==canvas.highlighter_color,
    "zoomed marker changed the stored tool, width or color")
canvas:setZoom(1)
assert(doc:getPage().strokes[1]==stroke and doc:getPage().strokes[2],
    "zoom toggle changed stored strokes")

local notebook=require("notebook"):new{document=Document:new("/tmp/notebook-zoom-button.scribe")}
notebook.canvas.content={x=0,y=0,w=400,h=600}
notebook.zoom_button.callback()
assert(notebook.canvas.zoom==2 and notebook.zoom_button.text=="1×")
notebook.zoom_button.callback()
assert(notebook.canvas.zoom==1 and notebook.zoom_button.text=="2×")

print("zoom viewport mapping and pen storage passed")
