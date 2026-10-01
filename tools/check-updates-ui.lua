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
UI.show=function(_,widget) shown=widget end
local Gallery=load("gallery")
local gallery=Gallery:new{}
assert(not load("safe").failed)
gallery:paintTo(bb,0,0)
local top=gallery.header_row[1]
local version_x
for i,widget in ipairs(top) do if widget==gallery.version_text then version_x=top._offsets[i].x end end
local updates=gallery.updates_button.dimen
assert(version_x and updates.x>=version_x+gallery.version_text:getSize().w,"Updates button precedes or overlaps version")
assert(updates.x+updates.w<=screen:getWidth(),"Updates button outside screen")
bb:writePNG(tmp.."/updates-gallery.png")
load("updater").showMenu(gallery,updates)
assert(shown.actions[1].selected() and shown.actions[1].text)
shown:paintTo(bb,0,0)
assert(shown.panel.dimen.x>=0 and shown.panel.dimen.x+shown.panel.dimen.w<=screen:getWidth())
bb:writePNG(tmp.."/updates-menu.png")
assert(shown.action_rows[1].row.icon_widget.text=="☑","checked option lacks checkbox")
shown.actions[1].callback();assert(not shown.actions[1].selected())
shown:_refreshRows();assert(shown.action_rows[1].row.icon_widget.text=="☐")
shown.actions[1].callback();assert(shown.actions[1].selected())
load("exportpagesdialog").show(100,function() end)
shown:paintTo(bb,0,0)
bb:writePNG(tmp.."/export-pages.png")
gallery:_freeWidgets();bb:free()
if Device.input and Device.input.teardown then Device.input:teardown() end
print("Native UI: Updates right of version, menu within screen, default weekly/toggle and page range dialog passed")
