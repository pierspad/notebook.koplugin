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
for _,i in ipairs({2,3,5}) do
    nb:_showToolOptions(i)
    menu=rec.shown[#rec.shown]
    assert(menu.anchor==nb.tool_buttons[i].dimen, 'popover anchored to its tool')
    if i==5 then assert(#menu.actions==3) else assert(menu.footer) end
end
nb.canvas.text_bold=true
nb:_editText(nil,120,220)
local editor=rec.shown[#rec.shown]
local styles={}
for _,button in ipairs(editor.buttons[1]) do styles[button.text]=button end
assert(styles.Bold.checked_func() and not styles.Italic.checked_func()
    and not styles.Underline.checked_func(),'text style selection is not shown')
styles.Italic.callback()
assert(styles.Italic.checked_func(),'toggled text style did not remain selected')
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
