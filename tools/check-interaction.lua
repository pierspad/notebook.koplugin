-- Run from a KOReader runtime: ./luajit /path/check-interaction.lua /path/plugin /tmp/output
-- Offscreen SDL only; no input registration, settings writes or device refresh.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/notebook-settings.lua')
local Device=require('device')
require('document/canvascontext'):init(Device)
local directory=assert(arg[1], 'plugin Lua directory required')
local output=assert(arg[2], 'existing output directory required')
local load=dofile(directory..'/loader.lua')(directory)
local Icon=require('ui/widget/iconwidget');local init=Icon.init
Icon.init=function(self)
 if self.icon and self.icon:match('^notebook%.') then self.file=directory..'/icons/'..self.icon..'.svg' end
 return init(self)
end
local BB=require('ffi/blitbuffer');local screen=Device.screen
screen.refreshUI=function() end;screen.refreshFast=function() end
local Document=load('document');local nb=load('notebook'):new{document=Document:new('/tmp/qa.scribe')}
nb:paintTo(screen.bb,0,0)
local UI=require('ui/uimanager');local dialog
UI.show=function(_,widget) dialog=widget end
nb:_editText(nil,30,170)
assert(dialog and dialog.button_table)
local height
for _,row in ipairs(dialog.button_table.buttons_layout) do
 for _,button in ipairs(row) do
  local size=button:getSize();print('button',button.text or button.icon,size.w,size.h)
  height=height or size.h;assert(size.h==height,'button height mismatch')
 end
end
local rows=dialog.button_table.container
assert(#rows==2,'toolbar rows are separated')
local bg=dialog.button_table.button_by_id.bg_toggle
bg.callback()
assert(bg:getSize().h==height,'toggle changed button height')
dialog._input_widget:addChars('testo à 日本語')
assert(nb.canvas.text_preview.text=='testo à 日本語','native input preview mismatch')
local Text=load('textobject');local label=Text.create('testo à 日本語',30,300,400,28,{})
label.cursor_pos=6
local render=load('renderer');render.drawStroke(screen.bb,label)
screen.bb:writePNG(output..'/cursor.png')
dialog:paintTo(screen.bb,0,0)
screen.bb:writePNG(output..'/text-controls.png')
dialog.buttons[2][5].callback()
assert(nb.document:getPage().strokes[1].text=='testo à 日本語','native text commit failed')
local original=nb.document:getPage().strokes[1]
nb:_editText(original)
dialog:setInputText(' \n\t')
dialog.buttons[2][5].callback()
assert(#nb.document:getPage().strokes==0,'native blank edit was not removed')
nb.document:undo()
assert(nb.document:getPage().strokes[1]==original,'native blank edit cannot be undone')
nb:_editText(original)
UI:close(dialog)
assert(not nb.canvas.text_preview and not nb.canvas.hidden_stroke,'framework dismissal leaked preview')
local Shape=load('shape');local shape=Shape.create('rectangle',100,150,1450,1950,14,0,false)
shape=Shape.transform(shape,'rotate',1600,1800,1450,1050)
local bb=BB.new(1860,2480,BB.TYPE_BB8)
local function bench()
 local t=os.clock();for _=1,10 do render.drawStroke(bb,shape) end
 return (os.clock()-t)*100
end
local optimized=bench()
local geo=load('geometryink');local draw=geo.draw;geo.draw=function() return false end
local fallback=bench();geo.draw=draw
print(string.format('rotated rectangle: polygon %.3f ms, brush fallback %.3f ms',optimized,fallback))
bb:free();print('real KOReader runtime checks passed')
