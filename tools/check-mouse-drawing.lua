-- Native KOReader gesture dispatch: mouse releases must commit live ink.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/dev/null')
local Device=require('device')
require('document/canvascontext'):init(Device)
local directory=assert(arg[1])
local load=dofile(directory..'/loader.lua')(directory)
load('pluginicons')()
local Event=require('ui/event')
local Screen=Device.screen
Screen.isColorEnabled=function() return true end
Screen.refreshFast=function() end
Screen.refreshUI=function() end
local Document=load('document')
for _,ending in ipairs({'tap','swipe','hold_release','pan_release','edge_release'}) do
    local doc=Document:new(nil);doc:setTemplate('blank')
    local nb=load('notebook'):new{document=doc}
    local c=nb.canvas;c.draw_with_finger=true;c.tool='highlighter';c.highlighter_color=0x143A047
    nb:paintTo(Screen.bb,0,0)
    local y=c.content.y+60
    local function gesture(kind,x,py)
        nb:handleEvent(Event:new('Gesture',{ges=kind,pos={x=x,y=py,w=0,h=0},
            direction='west',end_pos={x=x,y=py,w=0,h=0}}))
        assert(not load('safe').failed,'mouse gesture crashed')
    end
    gesture('touch',80,y)
    if ending=='hold_release' then gesture('hold',80,y);gesture('hold_pan',160,y)
    elseif ending~='tap' then gesture('pan',160,y) end
    gesture(ending=='edge_release' and 'pan_release' or ending,160,ending=='edge_release' and -1 or y)
    assert(not c.stroke and not c.live_ink,'native '..ending..' kept black preview')
    assert(#doc:getPage().strokes==1,'native '..ending..' lost stroke')
    local p=Screen.bb:getPixel(80,y)
    assert(p:getAlpha()==255,'native marker pixel is transparent')
    assert(p:getR()==67 and p:getG()==160 and p:getB()==71,'native '..ending..' lost green tint')
    nb:paintTo(Screen.bb,0,0)
    p=Screen.bb:getPixel(80,y)
    assert(p:getAlpha()==255,'native marker pixel is transparent')
    assert(p:getR()==67 and p:getG()==160 and p:getB()==71,'native '..ending..' lost stroke on repaint')
    c:stop()
end
print('native mouse: tap, swipe, hold, pan and off-screen release save colored marker and survive repaint')
