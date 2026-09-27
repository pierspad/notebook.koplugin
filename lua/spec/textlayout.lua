package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
local rec=require('uistubs').install({})
local Text=require('textobject');local Screen=require('device').screen
Screen.bb=support.FakeBB.new(600,800)
Screen.refreshFast=function() end;Screen.refreshUI=function() end
local s=Text.create(string.rep('testo ',500),10,20,300,24,{font_family='serif'})
local widget=s._text_widget;local key=s._text_cache_key
assert(type(key)=='table' and key.text==s.text,'cache copies the label into a string key')
for _=1,10 do Text.draw(Screen.bb,s,1,0,0,{x=0,y=0,w=100,h=80}) end
assert(s._text_widget==widget and s._text_cache_key==key,'unchanged layout was reallocated')
s.text_background=true;s.text_underline=true;s.cursor_pos=2
Text.draw(Screen.bb,s)
assert(s._text_widget==widget,'decoration change invalidated glyphs')
for _,change in ipairs({function() s.font_size=28 end,function() s.text='changed' end,
    function() s.font_family='mono' end,function() s.text_bold=true end,
    function() s.text_italic=true end,function() s.x_max=s.x_max+10 end}) do
    local old=s._text_widget;change();Text.draw(Screen.bb,s)
    assert(s._text_widget~=old and old.freed,'layout input did not invalidate/free cache')
end
assert(not s:serialize()._text_cache_key,'cache metadata was serialized')
require('textcache').clear()

G_reader_settings={readSetting=function() end,saveSetting=function() end}
local nb=require('notebook'):new{document=require('document'):new('/tmp/textlayout.scribe')}
nb.canvas.content={x=0,y=0,w=600,h=800}
nb:_showToolOptions(1)
assert(rec.shown[#rec.shown].actions[4].section=='Stroke style','line/arrow section missing')
nb:_showToolOptions(5)
assert(rec.shown[#rec.shown].actions[5].section=='Fill','fill section missing')
nb:_showToolOptions(6)
local menu=rec.shown[#rec.shown];local picker=menu.header
assert(menu.actions[1].section=='Font family' and menu.actions[4].section=='Text style','text sections missing')
picker:step(2);assert(nb.canvas.text_size==28 and picker.sample.font_size==28,'text size not applied')
menu.action_rows[3].row:onTap();assert(picker.sample.font_family=='mono','font preview did not change')
for _=1,60 do picker:step(2) end
assert(nb.canvas.text_size==96 and not picker.plus.enabled_func(),'upper size bound failed')
for _=1,60 do picker:step(-2) end
assert(nb.canvas.text_size==10 and not picker.minus.enabled_func(),'lower size bound failed')
local sample=picker.sample;menu:onCloseWidget()
assert(not sample._text_widget and not picker.sample,'sample cache retained after menu close')
nb.canvas.text_size=26
nb:_editText(nil,30,100)
local editor=rec.shown[#rec.shown]
editor.input='Testo';editor._input_widget={charpos=1};editor.strike_callback()
local preview=nb.canvas.text_preview
preview._text_widget._getXYForCharPos=function(_,pos) return (pos-1)*8,0 end
local old_widget=preview._text_widget
local dirty
nb.canvas._refreshNow=function(_,x,y,w,h) dirty={x=x,y=y,w=w,h=h} end
editor._input_widget.charpos=2;editor.strike_callback()
assert(nb.canvas.text_preview==preview and preview._text_widget==old_widget,'cursor recreated layout')
assert(dirty and dirty.w==9 and dirty.h>0,'cursor repainted entire label')
dirty=nil;editor.strike_callback();assert(not dirty,'unchanged cursor requested another redraw')
editor.buttons[1][5].callback();assert(preview._text_widget==old_widget,'underline recreated glyphs')
editor.buttons[2][1].callback();assert(preview._text_widget==old_widget,'background recreated glyphs')
editor.buttons[1][1].callback();assert(not preview._text_widget,'cancel leaked preview')
print('text: menu sections, size limits, live sample, cache invalidation and minimal cursor refresh passed')
