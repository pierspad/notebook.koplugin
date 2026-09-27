-- Native menu bounds, size/style preview, cursor layout reuse and screenshots.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/text-menu-settings.lua')
local Device=require('device');require('document/canvascontext'):init(Device)
G_reader_settings:saveSetting('language',arg[3] or 'en')
local dir,out=assert(arg[1]),assert(arg[2]);local load=dofile(dir..'/loader.lua')(dir)
local Icon=require('ui/widget/iconwidget');local iconinit=Icon.init
Icon.init=function(self)
 if self.icon and self.icon:match('^notebook%.') then self.file=dir..'/icons/'..self.icon..'.svg' end
 return iconinit(self)
end
local Screen=Device.screen;Screen.refreshFast=function() end;Screen.refreshUI=function() end
local nb=load('notebook'):new{document=load('document'):new('/tmp/text-menu.scribe')}
nb:paintTo(Screen.bb,0,0)
local menu;local UI=require('ui/uimanager');UI.show=function(_,w) menu=w end
for _,index in ipairs({1,5,6}) do
 nb:paintTo(Screen.bb,0,0)
 nb:_showToolOptions(index)
 menu:paintTo(Screen.bb,0,0)
 local d=menu.panel.dimen
 assert(d.x>=0 and d.y>=0 and d.x+d.w<=Screen:getWidth() and d.y+d.h<=Screen:getHeight(),
    string.format('menu %d outside screen: %d,%d %dx%d',index,d.x,d.y,d.w,d.h))
 Screen.bb:writePNG(out..'/menu-'..index..'-'..Screen:getWidth()..'.png')
 if index==6 then
    local picker=menu.header
    local initial=picker.sample._text_widget
    picker:step(2)
    assert(nb.canvas.text_size==28 and picker.sample.font_size==28,'size step not reflected')
    assert(not initial._bb,'old preview buffer leaked')
    for _=1,60 do picker:step(2) end
    assert(nb.canvas.text_size==96 and not picker.plus.enabled_func(),'upper bound failed')
    for i=1,6 do menu.action_rows[i].row:onTap() end
    assert(picker.sample.font_family=='mono' and picker.sample.text_italic and picker.sample.text_bold
        and picker.sample.text_underline,'sample ignores selected typography')
    menu:paintTo(Screen.bb,0,0)
    Screen.bb:writePNG(out..'/menu-text-max-'..Screen:getWidth()..'.png')
    local glyphs=picker.sample._text_widget
    menu:onCloseWidget()
    assert(not glyphs._bb and not picker.sample,'closing menu leaked the sample')
 end
end
nb:paintTo(Screen.bb,0,0)
local paper=Screen.bb:copy()
nb:_editText(nil,20,180)
local dialog=menu;dialog._input_widget:addChars('Testo à 日本語')
local preview=nb.canvas.text_preview;local widget=preview._text_widget
-- Move the real input cursor; the preview must retain its native text layout.
dialog._input_widget.charpos=3;dialog.strike_callback()
assert(nb.canvas.text_preview==preview and preview._text_widget==widget,'cursor rebuilt the text layout')
local actual=Screen.bb:copy()
local reference=paper:copy()
load('renderer').drawStroke(reference,preview,nb.canvas.content)
for py=0,Screen:getHeight()-1 do for px=0,Screen:getWidth()-1 do
    assert(actual:getPixel(px,py):getColor8().a==reference:getPixel(px,py):getColor8().a,
        string.format('partial caret mismatch %d,%d',px,py))
end end
-- A one-pixel clip is the worst case for physical-stride fill shortcuts.
local narrow=paper:copy()
local cx,cy,cw,ch=load('textobject').caretBounds(preview)
load('renderer').drawStroke(narrow,preview,{x=cx,y=cy,w=cw,h=ch})
for py=0,Screen:getHeight()-1 do for px=0,Screen:getWidth()-1 do
    local inside=px>=cx and px<cx+cw and py>=cy and py<cy+ch
    local wanted=(inside and reference or paper):getPixel(px,py):getColor8().a
    assert(narrow:getPixel(px,py):getColor8().a==wanted,'narrow text clip painted outside its region')
end end
narrow:free();reference:free();paper:free();actual:free()
local underlined=preview.text_underline
dialog.buttons[1][5].callback()
assert(preview._text_widget==widget and preview.text_underline~=underlined,'underline rebuilt glyphs')
dialog.buttons[2][1].callback()
assert(preview._text_widget==widget,'background toggle rebuilt glyphs')
dialog.buttons[1][1].callback()
assert(not widget._bb,'editor layout not freed on cancel')
print('native text menus fit; size limits/styles update; cursor and decoration changes reuse glyph layout')
