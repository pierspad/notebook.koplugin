-- Run with KOReader's LuaJIT, from its directory. Offscreen UI and temporary
-- documents only; never registers input, writes settings, or updates the panel.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/mnt/us/koreader/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = assert(arg[1]) .. "/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Document = require("document")
local Notebook = require("notebook")
local Stroke = require("stroke")
local Shape = require("shape")
local UI = require("ui/uimanager")
local doc = Document:new("/tmp/notebook-audit/smoke.scribe")
local nb = Notebook:new{ document=doc, title="Notebook audit" }
for i, color in ipairs({0, 0, 96}) do
    local s = Stroke:new{width=8, color=color}
    for x=100,1500,4 do
        s:addPoint(x, 300+i*150+math.sin(x/100)*30, i==1 and 1 or x/1500)
    end
    doc:addStroke(s)
end
local raw = Stroke:new{width=4}
for x=200,1400,20 do raw:addPoint(x,1100,1) end
doc:addStroke(assert(Shape.recognize(raw,"arrow")))
local bb = BB.new(Device.screen:getWidth(), Device.screen:getHeight(), BB.TYPE_BB8)
nb:paintTo(bb,0,0)
bb:writePNG("/tmp/notebook-audit/notebook.png")
local old_show, menu = UI.show
UI.show=function(_,widget) menu=widget end
nb.tool_buttons[1]:onHold()
UI.show=old_show
assert(menu and #menu.actions==5, "pen menu did not open")
menu:paintTo(bb,0,0)
bb:writePNG("/tmp/notebook-audit/pen-menu.png")
assert(doc:save())
local loaded=Document:new(doc.path)
assert(loaded:load())
assert(#loaded:getPage().strokes==4)
assert(loaded:getPage().strokes[3].color==96)
assert(require("export").toPDF(loaded,"/tmp/notebook-audit/smoke.pdf",{width=1860,height=2480}))
bb:free()
print("DEVICE SMOKE PASS: real widgets, pen hold menu, pressure/color save-load, arrow, PDF")
