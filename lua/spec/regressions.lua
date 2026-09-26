package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support'); support.installStubs()
local rec=require('uistubs').install({})
local BB=support.FakeBB
local Shape,Stroke,Renderer=require('shape'),require('stroke'),require('renderer')
-- Filled geometry survives scaling, rotation, serialization and clipboard.
for _,kind in ipairs({'rectangle','square','circle','triangle'}) do
    local shape=Shape.create(kind,30,30,90,90,3,0,true)
    for _,value in ipairs({shape,shape:clone(),Stroke:deserialize(shape:serialize()),
        Shape.transform(shape,'rotate',90,90,90,60)}) do
        for _,scale in ipairs({1,2,0.5}) do
            local bb=BB.new(220,220)
            Renderer.drawPage(bb,{strokes={value}},scale)
            assert(bb:get(60*scale,60*scale)==0,kind..' lost its fill')
        end
    end
end
-- A 180 degree rotated triangle points down, not up inside its bounding box.
local triangle=Shape.create('triangle',30,30,90,90,2,0,true)
triangle=Shape.transform(triangle,'rotate',30,60,90,60)
local bb=BB.new(120,120);Renderer.drawStroke(bb,triangle)
assert(bb:get(35,35)==0 and bb:get(35,85)==255,'triangle ignored rotated vertices')
-- Partial redraw must equal whole redraw, including graphite grain at clip edges.
for _,style in ipairs({'pencil','fountain'}) do
    local stroke=Stroke:new{tool='pen',pen_style=style,width=12,color=0}
    stroke:addPoint(10,20,0.4);stroke:addPoint(90,80,1)
    local full,partial=BB.new(120,120),BB.new(120,120)
    Renderer.drawStroke(full,stroke)
    Renderer.drawStroke(partial,stroke,{x=23,y=27,w=41,h=38})
    for y=0,119 do for x=0,119 do
        local wanted=(x>=23 and x<64 and y>=27 and y<65) and full:get(x,y) or 255
        assert(partial:get(x,y)==wanted,style..' changed after clipped redraw')
    end end
    -- Same scaled page crop used for cache repair and panning.
    local large,crop=BB.new(240,240),BB.new(80,80)
    Renderer.drawPage(large,{strokes={stroke}},2)
    Renderer.drawPage(crop,{strokes={stroke}},2,-40,-30)
    for y=0,79 do for x=0,79 do
        assert(crop:get(x,y)==large:get(x+40,y+30),style..' changed after viewport translation')
    end end
end
-- Brushes and fills must not disappear in thumbnails/exports with an offset.
local s=Stroke:new{tool='pen',pen_style='pencil',width=12,color=0}
s:addPoint(20,20);s:addPoint(80,20)
local pencil=BB.new(180,100);Renderer.drawPage(pencil,{strokes={s}},2)
s.pen_style='fineliner';local pen=BB.new(180,100);Renderer.drawPage(pen,{strokes={s}},2)
local different=false
for y=28,52 do for x=40,160 do if pencil:get(x,y)~=pen:get(x,y) then different=true end end end
assert(different,'scaled pencil became uniform')
local Text=require('textobject')
for _,blank in ipairs({'',' \t\n','\194\160','\227\128\128','\226\128\139'}) do
    assert(not Text.hasContent(blank),'invisible label accepted')
end
assert(Text.hasContent('à') and Text.hasContent('a\n b'),'visible Unicode text rejected')
local Device=require('device')
Device.screen.bb=BB.new(600,800)
Device.screen.refreshFast=function() end;Device.screen.refreshUI=function() end
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local doc=require('document'):new('/tmp/notebook-regressions.scribe')
local nb=require('notebook'):new{document=doc}
nb.canvas.content={x=0,y=0,w=600,h=800}
for _,background in ipairs({true,false}) do
    nb.canvas.text_background=background
    nb:_editText(nil,20,100)
    local dialog=rec.shown[#rec.shown]
    local height=dialog.buttons[1][1].height
    for _,row in ipairs(dialog.buttons) do for _,button in ipairs(row) do
        assert(button.height==height,'text controls have different label heights')
    end end
    dialog.input=' \n\t';dialog.buttons[2][5].callback()
    assert(#doc:getPage().strokes==0,'blank label committed')
end
local original=Text.create('Keep me',20,100,240,24,{})
doc:addStroke(original)
nb:_editText(original)
local dialog=rec.shown[#rec.shown]
dialog.input='';dialog.buttons[2][5].callback()
assert(#doc:getPage().strokes==0,'cleared label was restored instead of removed')
doc:undo();assert(doc:getPage().strokes[1]==original,'cleared label cannot be restored with undo')
-- Typing over a busy page reuses pixels; unrelated vector strokes are not replayed.
local replay=Renderer.drawStroke
local originals_drawn=0
Renderer.drawStroke=function(buffer,stroke,...)
    if stroke==original then originals_drawn=originals_drawn+1 end
    return replay(buffer,stroke,...)
end
nb:_editText(nil,20,180)
dialog=rec.shown[#rec.shown]
for _,value in ipairs({'a','ab','abc','ab'}) do dialog.input=value;dialog.strike_callback() end
assert(originals_drawn==0,'typing rerendered underlying document text')
dialog.buttons[1][1].callback()
Renderer.drawStroke=replay
-- Framework dismissal (e.g. Back) must release the preview too.
nb:_editText(original)
dialog=rec.shown[#rec.shown];dialog:onCloseWidget()
assert(not nb.canvas.hidden_stroke and not nb.canvas.text_preview,'framework close left an active preview')
-- Rotation coalesces events, but release commits the very last endpoint.
local clock=0
local time=require('ui/time');time.now=function() return clock end;time.to_ms=function(t) return t end
local UI=require('ui/uimanager');local callbacks={}
UI.scheduleIn=function(_,_,fn) callbacks[fn]=true end
UI.unschedule=function(_,fn) callbacks[fn]=nil end
local figure=Shape.create('rectangle',100,100,300,300,4,0,true)
local canvas=nb.canvas;doc:addStroke(figure)
canvas:_beginShapeTransform(figure,'rotate',350,200)
canvas:_extendShapeTransform(340,220)
local first=canvas.transform_gesture.preview
for y=221,240 do canvas:_extendShapeTransform(340,y) end
assert(canvas.transform_gesture.preview==first and callbacks[canvas.transform_preview_cb],
    'rotation rendered every input event')
canvas:_endShapeTransform()
assert(not callbacks[canvas.transform_preview_cb], 'rotation left a trailing callback')
local final=doc:getPage().strokes[#doc:getPage().strokes]
local expected=Shape.transform(figure,'rotate',340,240,350,200)
assert(math.abs(final.x_min-expected.x_min)<0.001,'rotation lost final pointer position')
-- Text cache is bounded even when history keeps old labels alive.
local labels={}
for i=1,40 do labels[i]=Text.create('Label '..i,0,0,200,24,{}) end
assert(labels[1]._text_widget==nil and labels[40]._text_widget,'native text cache is unbounded')
require('textcache').clear()
assert(not labels[40]._text_widget,'text cache was not released')
print('regressions: filled transforms, scaled brushes, clipped grain, blank text, undo and bounded cache passed')
