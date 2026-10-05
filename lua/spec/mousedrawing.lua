package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
require('uistubs').install({})
local Screen=require('device').screen
Screen.refreshFast=function() end;Screen.refreshUI=function() end
local Canvas,Document=require('canvas'),require('document')
G_reader_settings={readSetting=function() end,saveSetting=function() end}
for _,tool in ipairs({'pen','highlighter'}) do
for _,ending in ipairs({'tap','swipe','hold_release','pan_release'}) do
    Screen.bb=support.FakeBB.new(160,200)
    local doc=Document:new('/tmp/mouse-gesture.scribe');doc:setTemplate('blank')
    local c=Canvas:new{document=doc,content={x=0,y=10,w=160,h=190},draw_with_finger=true}
    c.dimen={x=0,y=0,w=160,h=200};c.tool=tool;c.highlighter_color=160;c.pen_color=90
    local turns=0;c.on_page_swipe=function() turns=turns+1 end
    c:paintTo(Screen.bb,0,0)
    c:onTouchStart(nil,{pos={x=30,y=60}})
    if ending~='tap' then c:onTouchPan(nil,{pos={x=110,y=60}}) end
    if ending=='swipe' then c:onPageSwipe(nil,{direction='west',pos={x=30,y=60},end_pos={x=110,y=60}})
    elseif ending=='pan_release' then c:onTouchRelease(nil,{pos={x=110,y=60}})
    else c:onZoomTouchEnd(nil,{pos={x=30,y=60}}) end
    assert(not c.stroke and not c.live_ink, ending..' left an uncommitted black marker preview')
    assert(#doc:getPage().strokes==1,ending..' lost the stroke')
    assert(turns==0,'drawing turned the page')
    local before=Screen.bb:copy();c:paintTo(Screen.bb,0,0)
    for y=10,199 do for x=0,159 do
        assert(before:get(x,y)==Screen.bb:get(x,y),ending..' changed pixels on repaint')
    end end
    assert(Screen.bb:get(30,60)==(tool=='highlighter' and 160 or 90),ending..' did not restore selected marker shade')
end
end
print('mouse drawing: tap, swipe, hold release and pan release commit marker and preserve repaint')
