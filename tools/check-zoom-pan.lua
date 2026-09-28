-- Real KOReader event dispatch, native pixels and CPU-only pan measurements.
-- SDL_VIDEODRIVER=dummy ./luajit /path/check-zoom-pan.lua /path/plugin/lua
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/dev/null')
local Device=require('device')
require('document/canvascontext'):init(Device)
local directory=assert(arg[1],'plugin Lua directory required')
local load=dofile(directory..'/loader.lua')(directory)
local Icon=require('ui/widget/iconwidget');local init=Icon.init
Icon.init=function(self)
    if self.icon and self.icon:match('^notebook%.') then self.file=directory..'/icons/'..self.icon..'.svg' end
    return init(self)
end
local BB=require('ffi/blitbuffer')
local UI=require('ui/uimanager')
local Event=require('ui/event')
local Screen=Device.screen
local full,fast=0,0
Screen.refreshFast=function() fast=fast+1 end
Screen.refreshUI=function() end
Screen.refreshFull=function(_,x,y,w,h)
    assert(x>=0 and y>=0 and w>0 and h>0);full=full+1
end
local Document=load('document')
local nb=load('notebook'):new{document=Document:new(nil)}
nb:paintTo(Screen.bb,0,0)
local c=nb.canvas
c:setZoom(2);nb:paintTo(Screen.bb,0,0)
local function gesture(kind,x,y)
    nb:handleEvent(Event:new('Gesture',{ges=kind,pos={x=x,y=y,w=0,h=0}}))
    assert(not load('safe').failed,'gesture crashed canvas')
end
local py=c.content.y+200
for _,hold in ipairs({false,true}) do
    gesture('touch',300,py)
    if hold then gesture('hold',300,py) end
    gesture(hold and 'hold_pan' or 'pan',250,20)
    assert(c.zoom_touch_active,'native gesture dispatch lost contact')
    local before=full;c:_settleZoomPan();assert(full==before,'native cleanup interrupted contact')
    gesture(hold and 'hold_release' or 'pan_release',250,20)
    assert(not c.zoom_touch_active,'toolbar consumed release')
    c:_settleZoomPan();assert(full==before+1,'native idle cleanup missing')
    assert(not c.reconcile and not c.zoom_pan_needs_settle)
end
-- Device rotations/sensor limits can place the release just outside the panel.
for _,pos in ipairs({{-1,py},{Screen:getWidth()+1,py},{300,-1},
    {300,Screen:getHeight()+1},{0,py},{Screen:getWidth(),py}}) do
    gesture('touch',300,py);gesture('pan',250,py-40)
    gesture('pan',pos[1],pos[2]);gesture('pan_release',pos[1],pos[2])
    assert(not c.zoom_touch_active,'native edge release retained contact')
    c:_settleZoomPan();assert(not c.zoom_pan_needs_settle,'native edge failed to settle')
end
-- Pixel equality for cached viewport copies, at page edges and after ink.
local Canvas=load('canvas');local Stroke=load('stroke')
for _,kind in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
    for _,native in ipairs({false,true}) do
        BB:setUseCBB(native)
        for rotation=0,3 do
            for _,paper in ipairs({'blank','lined','narrow','grid','dots','checklist'}) do
                local actual=BB.new(260,320,kind);actual:setRotation(rotation)
                local expected=BB.new(260,320,kind);expected:setRotation(rotation)
                local w,h=actual:getWidth(),actual:getHeight()
                local doc=Document:new(nil);doc:setTemplate(paper)
                local canvas=Canvas:new{document=doc,content={x=7,y=25,w=w-14,h=h-35}}
                canvas.zoom=2;canvas.zoom_x=7;canvas.zoom_y=25
                for index,style in ipairs({'fineliner','fountain','pencil'}) do
                    local stroke=Stroke:new{width=5,pen_style=style}
                    for x=15,w-20,17 do stroke:addPoint(x,45+index*20+x/3,0.7) end
                    doc:addStroke(stroke)
                end
                for _,offset in ipairs({0,0.5,13.5,(canvas.content.w)/2}) do
                    canvas.zoom_x=7+offset
                    canvas.zoom_y=25+math.min(offset,canvas.content.h/2)
                    actual:fill(BB.COLOR_WHITE);expected:fill(BB.COLOR_WHITE)
                    canvas:_renderZoom(actual);canvas:_renderZoom(expected,true)
                    for y=0,h-1 do for x=0,w-1 do
                        assert(actual:getPixel(x,y)==expected:getPixel(x,y),
                            string.format('cache mismatch %s rotation=%d native=%s at %d,%d',paper,rotation,tostring(native),x,y))
                    end end
                end
                canvas:_clearZoomCache();actual:free();expected:free()
            end
        end
    end
end
BB:setUseCBB(true)
-- Typical warm pan versus forced vector redraw, without device refresh IO.
local doc=Document:new(nil);doc:setTemplate('grid')
local width,height=1860,2400
for i=1,80 do
    local stroke=Stroke:new{width=3,pen_style=({'fineliner','fountain','pencil'})[i%3+1]}
    local row=(i-1)%40
    for j=0,29 do stroke:addPoint(60+j*55,80+row*54+math.sin(j)*12,0.7) end
    doc:addStroke(stroke)
end
local canvas=Canvas:new{document=doc,content={x=0,y=80,w=width,h=height}}
canvas.zoom=2;canvas.zoom_x=0;canvas.zoom_y=80
local bb=BB.new(width,height+80,BB.TYPE_BB8)
canvas:_renderZoom(bb)
local cache=canvas.zoom_cache
local function measure(direct)
    local samples={}
    for round=1,7 do
        local start=os.clock()
        for i=1,40 do
            canvas.zoom_x=i*5;canvas.zoom_y=80+i*7
            canvas:_renderZoom(bb,direct)
        end
        samples[round]=(os.clock()-start)*1000/40
    end
    table.sort(samples);return samples[4]
end
local warm,direct=measure(false),measure(true)
assert(canvas.zoom_cache==cache,'warm pan rebuilt its cache')
print(string.format('CPU 1860x2400, 80 strokes/2400 points: cached pan %.3f ms, vector redraw %.3f ms',warm,direct))
canvas:_clearZoomCache();bb:free()
UI:unschedule(c.zoom_pan_cb);UI:unschedule(c.zoom_pan_settle_cb)
c:_clearZoomCache()
print('native zoom pan: real toolbar release/hold dispatch; 384 pixel comparisons across paper, rotation, BB8/RGB32 and C/Lua passed')
