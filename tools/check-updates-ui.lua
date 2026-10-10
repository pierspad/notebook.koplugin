-- Offscreen native layout checks; no physical refresh, user settings or notebooks.
require("setupkoenv")
G_defaults=require("luadefaults"):open()
local tmp=assert(require("ffi/util").realpath(assert(arg[2])))
G_reader_settings=require("luasettings"):open(tmp.."/ui-settings.lua")
local Device=require("device")
require("document/canvascontext"):init(Device)
local load=dofile(arg[1].."/loader.lua")(arg[1])
local BB=require("ffi/blitbuffer")
local screen=Device.screen
for _,name in ipairs({"refreshUI","refreshFast","refreshFull","refreshPartial","refreshNoMerge","refreshA2"}) do screen[name]=function() end end
local bb=BB.new(screen:getWidth(),screen:getHeight(),BB.TYPE_BB8)
screen.bb=bb
local icon=require("ui/widget/iconwidget")
local init=icon.init
icon.init=function(self)
    if self.icon and self.icon:match("^notebook%.") then self.file=arg[1].."/icons/"..self.icon..".svg" end
    return init(self)
end
local lfs=require("libs/libkoreader-lfs")
assert(lfs.attributes(tmp.."/library","mode")=="directory" or lfs.mkdir(tmp.."/library"))
load("library").root=function() return tmp.."/library" end
local UI=require("ui/uimanager")
local shown
local shown_history={}
UI.show=function(_,widget) shown=widget;shown_history[#shown_history+1]=widget end
local Gallery=load("gallery")
local gallery=Gallery:new{}
assert(not load("safe").failed)
gallery:paintTo(bb,0,0)
local updates=gallery.updates_button.dimen
local bottom=gallery.footer[3]
local version_x=bottom._offsets[2].x+require("ui/size").padding.large
assert(updates.x>=version_x+gallery.version_text:getSize().w,"Updates overlaps version")
assert(updates.x+updates.w<=screen:getWidth(),"Updates button outside screen")
bb:writePNG(tmp.."/updates-gallery.png")
gallery.updates_button:onTap()
assert(shown.actions[1].selected() and shown.actions[1].text)
shown:paintTo(bb,0,0)
assert(shown.panel.dimen.x>=0 and shown.panel.dimen.x+shown.panel.dimen.w<=screen:getWidth())
assert(shown.panel.dimen.y+shown.panel.dimen.h<updates.y,"Updates menu is not above its button")
assert(math.abs(shown.panel.dimen.x+shown.panel.dimen.w-updates.x-updates.w)<=1,"Updates menu is not right aligned")
assert(gallery.updates_button.frame.background==BB.COLOR_WHITE,"Updates button appears disabled")
bb:writePNG(tmp.."/updates-menu.png")
assert(shown.action_rows[1].row.icon_widget.text=="☑","checked option lacks checkbox")
shown.actions[1].callback();assert(not shown.actions[1].selected())
shown:_refreshRows();assert(shown.action_rows[1].row.icon_widget.text=="☐")
shown.actions[1].callback();assert(shown.actions[1].selected())
local document=load("document"):new(nil)
for i=1,100 do
    if i>1 then document:addPage() end
    document.pages[i].template=i%2==0 and "ruled" or "blank"
    local stroke=load("stroke"):new{width=4}
    stroke:addPoint(100,400+i%7*35);stroke:addPoint(screen:getWidth()-100,800+i%5*50)
    document:addStroke(stroke)
end
document:goToPage(1)
local panel=load("exportpagesdialog").show(document,function() end)
assert(panel:setRange("-3;5-"))
assert(panel:isSelected(3) and not panel:isSelected(4) and panel:isSelected(100))
panel:_goToPage(3);assert(not panel:isSelected(3))
panel:_editRange()
local dialog
for _,widget in ipairs(shown_history) do if widget.getInputText then dialog=widget end end
assert(dialog,"range bar did not open editable input")
dialog:setInputText("-3;5-")
dialog.buttons[1][2].callback()
assert(panel:isSelected(3) and not panel:isSelected(4) and panel:isSelected(100))
shown=panel
shown:paintTo(bb,0,0)
bb:writePNG(tmp.."/export-pages.png")
gallery:_freeWidgets();bb:free()
if Device.input and Device.input.teardown then Device.input:teardown() end
print("Native UI: Updates right of version, menu within screen, default weekly/toggle and page range dialog passed")
