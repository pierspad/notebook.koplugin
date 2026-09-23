-- Run with KOReader's LuaJIT, from its directory. Offscreen UI and temporary
-- documents only; never registers input, writes settings, or updates the panel.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/mnt/us/koreader/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local directory = assert(arg[1])
local require = assert(loadfile(directory .. "/loader.lua"))()(directory)
-- Resolve staged plugin icons without installing or changing the live UI.
local IconWidget = require("ui/widget/iconwidget")
local icon_init = IconWidget.init
IconWidget.init = function(self)
    if self.icon and self.icon:match("^notebook%.") then
        self.file = directory .. "/icons/" .. self.icon .. ".svg"
    end
    return icon_init(self)
end
local BB = require("ffi/blitbuffer")
local Document = require("document")
local Notebook = require("notebook")
local Renderer = require("renderer")
local Stroke = require("stroke")
local Shape = require("shape")
local TextObject = require("textobject")
local Xopp = require("xopp")
local pressure = require("pressure")
for _=1,2 do
    local sensor = assert(pressure.open(), "physical pressure unavailable")
    assert(type(sensor:read())=="number")
    sensor:close()
    assert(sensor:read()==nil, "closed sensor still usable")
end
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
assert(menu.panel.dimen.y >= nb.tool_buttons[1].dimen.y + nb.tool_buttons[1].dimen.h)
assert(menu.panel.dimen.x == nb.tool_buttons[1].dimen.x)
for _, index in ipairs({2, 3, 5}) do
    nb:paintTo(bb,0,0)
    UI.show=function(_,widget) menu=widget end
    nb:_showToolOptions(index)
    UI.show=old_show
    menu:paintTo(bb,0,0)
    assert(menu.panel.dimen.x >= 0 and menu.panel.dimen.x+menu.panel.dimen.w <= bb:getWidth())
    bb:writePNG("/tmp/notebook-audit/tool-" .. index .. ".png")
end
for i, kind in ipairs({"square", "rectangle", "circle"}) do
    doc:addStroke(Shape.create(kind,100+(i-1)*550,1400,500+(i-1)*550,1750,5,0))
end
nb:paintTo(bb,0,0)
bb:writePNG("/tmp/notebook-audit/shapes.png")
assert(doc:save())
local loaded=Document:new(doc.path)
assert(loaded:load())
assert(#loaded:getPage().strokes==7)
assert(loaded:getPage().strokes[7].shape_kind=="circle")
assert(loaded:getPage().strokes[3].color==96)
assert(require("export").toPDF(loaded,"/tmp/notebook-audit/smoke.pdf",{width=1860,height=2480}))
local text=TextObject.create("Testo modificabile",180,1850,700,28,
    {font_family="serif",text_bold=true,text_italic=true,text_underline=true})
doc:addStroke(text)
Renderer.drawStroke(bb,text)
local restored_text=Stroke:deserialize(text:serialize())
assert(restored_text.text=="Testo modificabile" and restored_text.font_family=="serif"
    and restored_text.text_bold and restored_text.text_italic and restored_text.text_underline)
assert(Xopp.toXOPP(doc,"/tmp/notebook-audit/smoke.xopp"))
local pdfdoc=Document:new("/tmp/notebook-audit/pdf-background.scribe")
pdfdoc.pages={{strokes={},background={file="/tmp/notebook-audit/smoke.pdf",page=1}}}
pdfdoc.page_size={w=1860,h=2400}
require("pdfbackground").draw(bb,pdfdoc.pages[1].background,{x=0,y=80,w=1860,h=2400})
pdfdoc:addPage()
assert(pdfdoc.pages[1].background and not pdfdoc.pages[2].background,"PDF and inserted blank page differ")
-- Exercise real blitbuffer snapshots without writing to the physical panel.
local screen = Device.screen
local screen_bb, fast, refresh = screen.bb, screen.refreshFast, screen.refreshUI
screen.bb, screen.refreshFast, screen.refreshUI = bb, function() end, function() end
local canvas = nb.canvas
nb:paintTo(bb,0,0)
assert(canvas.background_cache,"page background was not cached")
nb:_editText(nil,900,1850)
local editor=UI._window_stack and UI._window_stack[#UI._window_stack]
editor=editor and editor.widget
assert(editor and editor.getInputText and canvas.text_preview,"live text editor did not open")
UI:close(editor)
canvas.text_preview,canvas.hidden_stroke=nil,nil
local cached_started=os.clock()
for i=1,20 do canvas:_repaintRegion(200+i*5,300+i*5,500,400,true) end
local cached_ms=(os.clock()-cached_started)*1000/20
canvas.shape_kind="circle"
canvas.pen_width=12
local strokes_before_shape = #doc:getPage().strokes
canvas:_beginShape(120,200)
local started = os.clock()
for i=1,20 do
    canvas.shape_gesture.next_x, canvas.shape_gesture.next_y = 600+i*35,700+i*40
    canvas:_paintShape()
end
local preview_ms = (os.clock()-started)*1000/20
local cache = canvas.shape_gesture.background
assert(cache, "preview has no background cache")
canvas.stopping = true
canvas:_endShape()
assert(not canvas.shape_gesture and #doc:getPage().strokes==strokes_before_shape+1)
-- Compare the old vector repaint cost for the same dirty rectangles.
started = os.clock()
for i=1,20 do canvas:_repaintRegion(120,200,480+i*35,500+i*40,true) end
local repaint_ms = (os.clock()-started)*1000/20
print(string.format("PREVIEW CPU: %.2f ms/frame; vector background repaint alone: %.2f ms/frame",preview_ms,repaint_ms))
print(string.format("CACHED REDRAW CPU: %.2f ms/region",cached_ms))
screen.bb, screen.refreshFast, screen.refreshUI = screen_bb, fast, refresh
bb:free()
print("DEVICE SMOKE PASS: real widgets, pen hold menu, pressure/color save-load, arrow, PDF")
