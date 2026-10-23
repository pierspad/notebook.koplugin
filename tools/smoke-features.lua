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
local gallery=load("gallery"):new{}
gallery.items={}
for i=1,30 do gallery.items[i]={name="Folder "..i,path="folder-"..i,is_folder=true} end
gallery:_layout()
paint("gallery-layout",gallery)
assert(gallery.content:getSize().h<=h-2*require("ui/size").padding.large,string.format("gallery exceeds its height: %s footer %s reserved %s",gallery.content:getSize().h,gallery.footer:getSize().h,gallery:_footerHeight()))
assert(gallery.footer:getSize().w<=w-2*require("ui/size").padding.large,"gallery footer overflows")
local counter_width=gallery.page_counter:getSize().w
for i=31,594 do gallery.items[i]={name="Folder "..i,path="folder-"..i,is_folder=true} end
gallery.page=12
gallery:_layout()
paint("gallery-two-digits",gallery)
if gallery.page_count<100 then assert(gallery.page_counter:getSize().w==counter_width,"two-digit pagination shifts arrows") end
gallery.items={}
for i,path in ipairs({"ab/ac/ad/ae", "ab/ac/ad/"..string.rep("Cartella日本語",30),
    string.rep("folder/",30).."current"}) do
    gallery:_goTo(path)
    assert(gallery.header_row[1]:getSize().w<=w,"gallery header overflows")
    paint("gallery-path-"..i,gallery)
end
gallery:free()
nb:paintTo(screen.bb,0,0)
nb:_showNotebookMenu()
assert(nb.settings_button.selected and not nb.tool_buttons[1].selected)
paint("notebook-menu",captured)
nb:paintTo(screen.bb,0,0);captured:paintTo(screen.bb,0,0)
screen.bb:writePNG(tmp.."/notebook-settings.png")
captured:onCloseWidget()
assert(not nb.settings_button.selected and nb.tool_buttons[1].selected)
nb:_selectTool(6);nb:_showNotebookMenu()
assert(nb.settings_button.selected and not nb.tool_buttons[6].selected)
captured:onCloseWidget()
assert(not nb.settings_button.selected and nb.tool_buttons[6].selected)
nb:_selectTool(1)
load("updater").showMenu(nb);paint("updates",captured)
assert(not captured.actions[2].selected(),"prerelease updates default to enabled")
captured:onCloseWidget()
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
-- A desktop notebook must fill its card using its recorded page geometry.
local thumbdoc=Document:new(load("library").pathFor("thumbnail-size"))
thumbdoc:setTemplate("grid")
thumbdoc.page_size={w=w,h=h-50};thumbdoc:setContentOrigin(0,50)
local line=load("stroke"):new{tool="pen",width=12}
line:addPoint(w*0.75,h*0.75);line:addPoint(w*0.85,h*0.75)
thumbdoc:addStroke(line);assert(thumbdoc:save())
local thumb=assert(load("thumbnail").get(thumbdoc.path,140,180,1860,2480))
local decoded=BB.new(140,180,BB.TYPE_BB8)
local image_widget=require("ui/widget/imagewidget"):new{file=thumb,width=140,height=180}
image_widget:paintTo(decoded,0,0)
local scale=math.min(140/w,180/h)
assert(decoded:getPixel(math.floor(w*0.8*scale),math.floor(h*0.75*scale)):getColor8().a<128,
    "thumbnail ignored the recorded page dimensions")
image_widget:free();decoded:free()
local Safe=load("safe");local later=Safe.later;local pending={}
Safe.later=function(_,fn) pending[#pending+1]=fn end
load("recents").remember(thumbdoc.path)
nb:_showRecentNotebooks();local recent=captured
while #pending>0 do table.remove(pending,1)() end
assert(recent.actions[1].preview and recent.action_rows[1].row.preview,
    "recent notebook thumbnail was not displayed")
paint("recent-notebooks",recent)
recent:onCloseWidget();Safe.later=later

nb.canvas:stop();Image.clear();UI.show=show
print("native features: menus fit, pen icons switch, PNG/JPEG decode/clip, images persist and PDF/SVG/XOPP export")
