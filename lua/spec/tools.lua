package.path = './?.lua;./spec/?.lua;' .. package.path
local support = require('support')
support.installStubs()
local rec = require('uistubs').install({})
local Device = require('device')
Device.screen.bb = support.FakeBB.new(600,800)
Device.screen.refreshFast = function() end
Device.screen.refreshUI = function() end
Device.input = {TOOL_TYPE_FINGER=0, TOOL_TYPE_PEN=1, TOOL_TYPE_ERASER=2, TOOL_TYPE_HIGHLIGHTER=3,
    pen_slot=15,
    registerStylusCallback=function(self, cb) self.stylus_callback=cb end,
    unregisterStylusCallback=function(self) self.stylus_callback=nil end}
local Canvas, Document, Shape, Stroke = require('canvas'), require('document'), require('shape'), require('stroke')
local UI, Safe = require('ui/uimanager'), require('safe')
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local function pen(c, x, y, release)
    c:onStylusEvent({slot=15,tool=1,id=release and -1 or 1,x=x,y=y})
    assert(not Safe.failed, 'stylus handler faulted')
end
local doc = Document:new('/tmp/notebook-tools.scribe')
local c = Canvas:new{document=doc}
c.tool='shape'; c.shape_kind='rectangle'
pen(c,100,150); pen(c,300,350); pen(c,300,350,true)
assert(#doc:getPage().strokes==1, 'one drag makes one shape')
local original=doc:getPage().strokes[1]
assert(original.shape_kind=='rectangle' and original.x_max==300)
assert(c.selected_strokes[1]==original, 'new shape selected for resizing')
pen(c,300,350); pen(c,400,450); pen(c,400,450,true)
local resized=doc:getPage().strokes[1]
assert(#doc:getPage().strokes==1 and resized.x_max==400 and resized.y_max==450, 'resize replaces shape')
doc:undo(); assert(doc:getPage().strokes[1]==original, 'resize undo restores original')
doc:redo(); assert(doc:getPage().strokes[1]==resized, 'resize redo')
assert(Stroke:deserialize(resized:serialize()).shape_kind=='rectangle', 'shape metadata round trips')
assert(resized:clone().shape_kind=='rectangle', 'clipboard keeps geometry')
for _,kind in ipairs({'square','circle'}) do
    local shape=Shape.create(kind,300,350,100,100,3)
    assert(math.abs((shape.x_max-shape.x_min)-(shape.y_max-shape.y_min))<0.01, 'aspect ratio retained')
end
c:_deselectLasso()
local ink=Stroke:new{width=3}; ink:addPoint(120,200); ink:addPoint(200,200); doc:addStroke(ink)
c.tool='eraser'; c.eraser_mode='stroke'; c:_eraseAlong(150,200)
c.last_erase_x, c.last_erase_y=nil,nil
c:_eraseAlong(100,200)
assert(not c.selected_strokes, 'shape selection deferred while erasing')
c:_endErase()
assert(#doc:getPage().strokes==1 and doc:getPage().strokes[1]==resized, 'only ink erased')
assert(c.selected_strokes[1]==resized, 'shape selected after erasing ends')
pen(c,500,750); pen(c,500,750,true)
assert(not c.selected_strokes and #doc:getPage().strokes==1, 'outside tap only deselects')
for _, mode in ipairs({'area','stroke'}) do
    local targets={}
    if mode=='area' then doc:eraseAreaAlongPath({100,150,400,150},30,targets)
    else doc:eraseAlongPath({100,150,400,150},30,targets) end
    assert(targets[resized] and doc:getPage().strokes[1]==resized, 'eraser preserves shapes in both modes')
end
local Gallery=require('gallery')
local g=Gallery:new{}
local a,b={path='a'},{path='b'}
g.selection={}; g.cards={{item=a,dimen={x=10,y=10,w=20,h=20}}, {item=b,dimen={x=60,y=10,w=20,h=20}}}
UI.getTopmostVisibleWidget=function() return g end
g:_listenForSelectionPen()
g._layout=function() end; g._repaint=function() end
local cb=Device.input.stylus_callback
assert(cb(nil,{id=1,x=15,y=15}))
cb(nil,{id=1,x=75,y=15}); cb(nil,{id=-1,x=75,y=15})
assert(g.selection.a and g.selection.b, 'raw stylus sweep selects intermediate cards')
cb(nil,{id=1,x=15,y=15}); cb(nil,{id=-1,x=15,y=15})
assert(not g.selection.a and g.selection.b, 'pen tap toggles selection')
UI.getTopmostVisibleWidget=function() return {} end
assert(not cb(nil,{id=1,x=15,y=15}), 'pen must reach dialog over gallery')
g:onCloseWidget(); assert(not Device.input.stylus_callback, 'gallery unregisters callback')
local nb=require('notebook'):new{document=doc}
nb:paintTo(Device.screen.bb,0,0)
nb:_showToolOptions(1)
local menu=rec.shown[#rec.shown]
assert(menu.footer and menu.anchor==nb.tool_buttons[1].dimen, 'pen sizes anchored to pen')
local selected_rows=0
for _,item in ipairs(menu.action_rows) do
    if item.row.selected then selected_rows=selected_rows+1 end
end
assert(selected_rows==3, 'pen menu marks unselected rows as selected')
assert(nb.ges_events == nil or nb.disable_double_tap == false, 'notebook does not enable double tap')
assert(nb.tool_buttons[1].ges_events.DoubleTap, 'tool has no double-tap option gesture')
assert(menu.disable_double_tap == false, 'open menu disables double tap')
local widths={2,5,9,14,22}
for i,choice in ipairs(menu.footer.choices) do
    assert(choice.value==widths[i], 'pen width progression is wrong at '..i)
end
local closed_before=#rec.closed
menu.footer.choices[4]:onTap()
assert(nb.canvas.pen_width==14 and #rec.closed==closed_before,
    'choosing a width closed the menu or did not apply')
menu.action_rows[2].row:onTap()
assert(#rec.closed==closed_before, 'choosing a pen style closed the menu')
assert(menu.actions[6].swatch=='black' and menu.actions[7].swatch=='white',
    'pen colors are not rendered as background-independent swatches')
assert(menu.footer:getSize().w==menu.width,
    'size choices do not fill the menu width')

-- A tool menu must not turn the first contact on the page into a sacrificial
-- "close" tap. The same pen/finger gesture that dismisses it starts drawing.
local outside_doc=Document:new('/tmp/notebook-menu-draw.scribe')
local outside_nb=require('notebook'):new{document=outside_doc}
outside_nb:paintTo(Device.screen.bb,0,0)
outside_nb:_showToolOptions(1)
local outside_menu=rec.shown[#rec.shown]
outside_menu:paintTo(Device.screen.bb,0,0)
UI.getTopmostVisibleWidget=function() return outside_menu end
local close_count=#rec.closed
outside_nb.canvas:onStylusEvent{slot=15,tool=1,id=1,x=1700,y=2200}
assert(#rec.closed==close_count+1 and outside_nb.canvas.stroke,
    string.format('pen contact outside an open tool menu was discarded (closed %d→%d, stroke %s, panel %d,%d %dx%d, content %d,%d %dx%d)',
        close_count,#rec.closed,tostring(outside_nb.canvas.stroke~=nil),
        outside_menu.panel.dimen.x,outside_menu.panel.dimen.y,outside_menu.panel.dimen.w,outside_menu.panel.dimen.h,
        outside_nb.canvas.content.x,outside_nb.canvas.content.y,outside_nb.canvas.content.w,outside_nb.canvas.content.h))
UI.getTopmostVisibleWidget=function() return outside_nb end
outside_nb.canvas:onStylusEvent{slot=15,tool=1,id=-1,x=1720,y=2200}
assert(#outside_doc:getPage().strokes==1,
    'pen stroke that dismissed the menu was not recorded')

outside_nb:_showToolOptions(1)
outside_menu=rec.shown[#rec.shown]
outside_menu:paintTo(Device.screen.bb,0,0)
outside_nb.canvas.draw_with_finger=true
outside_nb.canvas.pen_down=false
outside_nb.canvas.pen_left_at=nil
close_count=#rec.closed
outside_menu:onDrawOutside(nil,{pos={x=1650,y=2100}})
outside_nb.canvas:onTouchPan(nil,{pos={x=1700,y=2100}})
outside_nb.canvas:onTouchRelease(nil,{pos={x=1700,y=2100}})
assert(#rec.closed==close_count+1 and #outside_doc:getPage().strokes==2,
    'finger stroke outside an open tool menu was discarded')
UI.getTopmostVisibleWidget=function() return nil end

local eraser=nb.tool_buttons[3].dimen
menu:onToolHold(nil,{pos={x=eraser.x+1,y=eraser.y+1}})
local switched=rec.shown[#rec.shown]
assert(switched~=menu and switched.anchor==eraser,
    'holding another tool did not replace the open menu')
assert(nb.canvas.tool=='eraser' and nb.tool_buttons[3].selected and not nb.tool_buttons[1].selected,
    'opening another tool menu did not select that tool')
for _,i in ipairs({2,3,5,6}) do
    nb:_showToolOptions(i)
    menu=rec.shown[#rec.shown]
    assert(menu.anchor==nb.tool_buttons[i].dimen, 'popover anchored to its tool')
    if i==5 then assert(#menu.actions==3)
    elseif i==6 then assert(#menu.actions==11)
    else assert(menu.footer) end
end
local text_menu=menu
local expected_icons={'a','A','A','E','E','M','B','I','U̲'}
for i,expected in ipairs(expected_icons) do
    assert(text_menu.actions[i].icon_text==expected,
        'text option '..i..' has no specific icon')
end
assert(text_menu.actions[10].section=='Background'
    and text_menu.actions[10].text=='White'
    and text_menu.actions[11].text=='Transparent',
    'text background is not an explicit two-choice section')
nb.canvas.text_bold=true
nb:_editText(nil,120,220)
local editor=rec.shown[#rec.shown]
local styles={}
for _,button in ipairs(editor.buttons[1]) do styles[button.text]=button end
assert(#editor.buttons==1 and editor.text_height==1 and editor.inputtext_class.skip_paint,
    'text editor is not the compact page-preview variant')
local anchor=editor.movable.anchor()
assert(math.abs(anchor.x-120)<=2 and math.abs(anchor.y-220)<=2 and anchor.w>0 and anchor.h>0,
    'compact controls are not anchored to avoid the edited text')
assert(styles.B.checked_func() and not styles.I.checked_func()
    and not styles['U̲'].checked_func(),'text style selection is not shown')
styles.I.callback()
assert(styles.I.checked_func(),'toggled text style did not remain selected')
editor.input='Live on page'; editor.strike_callback()
assert(nb.canvas.text_preview.text=='Live on page','typed text is not previewed on the page')
assert(nb.canvas.text_preview.text_background,
    'live text preview does not use the efficient opaque work surface')
editor.input='ab'; editor._input_widget={charlist={'a','b'},charpos=2}; editor.strike_callback()
assert(nb.canvas.text_preview.text=='a│b','page preview does not mirror the input cursor')
styles['✕'].callback()
assert(not nb.canvas.text_preview and #doc:getPage().strokes==1,
    'cancelling compact text input did not restore the page')
nb.canvas.tool='text'
nb.canvas.draw_with_finger=true
nb.canvas.pen_down=nil
nb.canvas.pen_left_at=nil
nb.canvas.selected_strokes=nil
nb.canvas.selection_bbox=nil
local shown_before_touch=#rec.shown
nb.canvas:onTouchStart(nil,{pos={x=160,y=260}})
nb.canvas:onTouchRelease(nil,{pos={x=160,y=260}})
local touch_editor
for i=shown_before_touch+1,#rec.shown do
    if rec.shown[i].getInputText then touch_editor=rec.shown[i]; break end
end
assert(touch_editor and touch_editor.getInputText,
    'finger text placement did not open the editor on release')
local function validTransparentTree(widget)
    if type(widget)~='table' then return true end
    assert(not (widget.style=='solid' and widget.background==nil),
        'transparent text controls left a paintable separator with no color')
    for _,child in ipairs(widget) do validTransparentTree(child) end
end
if touch_editor.button_table then
    validTransparentTree(touch_editor.button_table.container)
end
touch_editor.buttons[1][1].callback()
local drag_text=require('textobject').create('Move',100,100,240,26,{text_background=false})
nb.canvas.selected_strokes={drag_text}
nb.canvas:_useOpaqueTextDuringDrag()
assert(drag_text.text_background==true,
    'transparent text is not made opaque during drag')
nb.canvas:_restoreTextAfterDrag()
assert(drag_text.text_background==false,
    'text background style was not restored after drag')
nb.canvas.selected_strokes=nil
local ticks_before=#rec.ticks
local dirty_before=#rec.dirty
nb:onShow()
assert(nb.clock_tick and #rec.ticks>ticks_before and #rec.dirty>dirty_before,
    'notebook clock was not initialized and scheduled')
local scheduled_before=#rec.ticks
nb.clock_tick()
assert(#rec.ticks>scheduled_before,
    'notebook clock did not schedule its next minute update')
Canvas.clipboard={ink:clone()}
local before_tap=#doc:getPage().strokes
local tap_lasso=Stroke:new{tool='lasso',width=2}
tap_lasso:addPoint(450,500,1)
c.stroke=tap_lasso
c:_endStroke()
assert(#doc:getPage().strokes==before_tap,
    'a lasso tap pasted clipboard content without an explicit Paste action')
local n=select('#',Safe.call('nil values',function() return 1,nil,3,nil end))
assert(n==4, 'protected calls preserve nil results')
local selected_shape=doc:getPage().strokes[1]
c:_showLassoMenu({selected_shape})
c.lasso_menu.on_delete()
assert(#doc:getPage().strokes==0, 'explicit delete removes preserved shape')
doc:undo(); assert(doc:getPage().strokes[1]==selected_shape, 'shape delete is undoable')
local broken=Canvas:new{document=doc}
broken._triggerShapeSnap=function() error('timer regression') end
broken.shape_snap_cb()
assert(Safe.failed, 'timer exceptions cannot escape into KOReader')
print('tools passed: pen menus, raw selection, shape creation/resize/undo, eraser, protected timers')
