-- Native offscreen integration: real widgets, image decoding, storage and exports.
-- Run from a disposable KOReader runtime (tools/test-native-features.py).
require("setupkoenv")
local plugin,tmp=assert(arg[1]),assert(arg[2])
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open(tmp.."/settings.lua")
local Device=require("device")
for _,name in ipairs({"refreshUI","refreshFast","refreshFull","refreshPartial"}) do Device.screen[name]=function() end end
require("document/canvascontext"):init(Device)
local load=dofile(plugin.."/loader.lua")(plugin)
assert(load("library").ensureDir(""));load("pluginicons")()
local BB=require("ffi/blitbuffer")
local UI=require("ui/uimanager")
local Notebook,Document,Image=load("notebook"),load("document"),load("imageobject")
local screen=Device.screen;local w,h=screen:getWidth(),screen:getHeight()
local source=BB.new(32,16,BB.TYPE_BB8);source:fill(BB.COLOR_WHITE)
source:paintRect(8,4,16,8,BB.COLOR_BLACK);source:writePNG(tmp.."/source.png");source:free()
local doc=Document:new(load("library").pathFor("native"));doc:setTemplate("grid")
doc.paper_options={spacing=4,gray=112}
local nb=Notebook:new{document=doc,title="Native test"}
local captured
local show=UI.show
UI.show=function(_,widget) captured=widget end
local function paint(name,widget)
    local bb=BB.new(w,h,BB.TYPE_BB8);bb:fill(BB.COLOR_WHITE)
    widget:paintTo(bb,0,0)
    assert(not load("safe").failed,"native painter failed: "..name)
    local d=widget.panel and widget.panel.dimen or widget.dimen
    assert(d.x>=0 and d.y>=0 and d.x+d.w<=w and d.y+d.h<=h,"offscreen panel: "..name)
    bb:writePNG(tmp.."/"..name..".png");bb:free()
end
nb:_showNotebookMenu();paint("notebook-menu",captured)
nb:_showPaperOptions();paint("paper-options",captured)
nb:_showToolSettings();paint("tool-settings",captured)
nb:_setSetting("pen_style","pencil");assert(nb.tool_buttons[1].icon=="notebook.pencil")
nb:_setSetting("pen_style","fountain");assert(nb.tool_buttons[1].icon=="notebook.fountain")
local image=assert(Image.import(tmp.."/source.png",nb.canvas.content))
doc:addStroke(image)
local jpeg=assert(Image.import(plugin.."/../tools/fixtures/reference.jpg",nb.canvas.content))
assert(jpeg.image_mime=="image/jpeg");doc:addStroke(jpeg)
nb:paintTo(screen.bb,0,0)
assert(not load("safe").failed)
assert(doc:save());local reopened=Document:new(doc.path);assert(reopened:load())
assert(reopened:getPage().strokes[1].image_data==image.image_data)
assert(reopened:getPage().strokes[2].image_data==jpeg.image_data)
os.remove(tmp.."/source.png");Image.clear()
reopened.page_size={w=nb.canvas.content.w,h=nb.canvas.content.h}
assert(load("export").toPDF(reopened,tmp.."/image.pdf"))
assert(load("pdfbackground").count(tmp.."/image.pdf")==1,"exported PDF cannot be reopened")
assert(load("svg").toSVG(reopened,tmp.."/image.svg"))
assert(load("xopp").toXOPP(reopened,tmp.."/image.xopp"))
-- Native alpha compositing must preserve pixels outside the dirty rectangle.
local clipped=BB.new(160,120,BB.TYPE_BB8);clipped:fill(BB.Color8(155))
local placed=assert(Image.create(image.image_data,20,30,80,40))
Image.draw(clipped,placed,1,0,0,{x=40,y=45,w=12,h=12})
assert(clipped:getPixel(39,45):getColor8().a==155)
assert(clipped:getPixel(40,45):getColor8().a<155,"image not decoded/composited")
clipped:free()
nb.canvas:stop();Image.clear();UI.show=show
print("native features: menus fit, pen icons switch, PNG/JPEG decode/clip, images persist and PDF/SVG/XOPP export")
