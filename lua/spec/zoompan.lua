-- Real timer ordering and gesture-range dispatch, including toolbar crossings.
package.path = './?.lua;./spec/?.lua;' .. package.path
require('support').installStubs()
require('uistubs').install({})
local now, timers, calls = 0, {}, {}
package.loaded['ui/time'] = {now=function() return now end, to_ms=function(t) return t end}
local UI = require('ui/uimanager')
UI.scheduleIn = function(_, delay, fn)
    timers[#timers+1] = {at=now+delay*1000, fn=fn}
end
UI.unschedule = function(_, fn)
    for i=#timers,1,-1 do if timers[i].fn == fn then table.remove(timers,i) end end
end
local function advance(ms)
    local target = now + ms
    while true do
        local index
        for i,t in ipairs(timers) do
            if t.at <= target and (not index or t.at < timers[index].at) then index=i end
        end
        if not index then break end
        local timer = table.remove(timers,index)
        now=timer.at; timer.fn()
    end
    now=target
end
local screen=require('device').screen
for _,mode in ipairs({'Fast','UI','Full'}) do
    screen['refresh'..mode]=function(_,x,y,w,h)
        calls[#calls+1]={mode=mode,at=now,x=x,y=y,w=w,h=h}
    end
end
local Canvas=require('canvas')
local Notebook=require('notebook')
local Document=require('document')
local c, parent, toolbar_calls, renders
local function gesture(kind,x,y,end_pos)
    local ges={ges=kind,pos={x=x,y=y},end_pos=end_pos}
    return parent:propagateEvent{handler='onGesture',args={ges}}
end
local function reset()
    now,timers,calls,renders,toolbar_calls=0,{},{},0,0
    c=Canvas:new{document=Document:new(nil),content={x=0,y=60,w=400,h=540}}
    c.zoom=2;c.zoom_x=0;c.zoom_y=60
    c._renderZoom=function() renders=renders+1 end
    -- Stub InputContainer dispatch otherwise omits KOReader's on prefix.
    c.handleEvent=function(self,event)
        local ges=event.args[1]
        for name,ranges in pairs(self.ges_events) do
            for _,range in ipairs(ranges) do
                if range:match(ges) and self['on'..name](self,nil,ges) then return true end
            end
        end
    end
    local toolbar={handleEvent=function(_,event)
        local ges=event.args[1]
        if ges.pos.y<60 and (ges.ges=='tap' or ges.ges=='hold' or ges.ges=='hold_release') then
            toolbar_calls=toolbar_calls+1;return true
        end
    end}
    parent=setmetatable({toolbar,c,canvas=c},{__index=Notebook})
end
local function fullCount()
    local n=0;for _,call in ipairs(calls) do if call.mode=='Full' then n=n+1 end end
    return n
end
reset()
gesture('touch',200,200);gesture('pan',180,180)
advance(100);gesture('pan',160,40) -- leaves paper, still our drag
assert(c.zoom_y==220 and c.zoom_touch_active,'pan stopped at toolbar')
advance(5000)
assert(fullCount()==0,'resting contact was interrupted')
gesture('pan_release',160,40)
assert(not c.zoom_touch_active,'out-of-page release got lost')
advance(1199);assert(fullCount()==0,'release cleanup too eager')
advance(1);assert(fullCount()==1,'idle cleanup missing')
local last=calls[#calls]
assert(last.x==0 and last.y==60 and last.w==400 and last.h==540,'cleanup included toolbar')
assert(renders==2,'cleanup rerasterized a settled page')
advance(10000);assert(fullCount()==1,'idle cleanup repeated')
gesture('tap',30,20);assert(toolbar_calls==1,'ordinary toolbar tap was stolen')

-- A tap without displacement has no ghost debt to clean.
reset();gesture('touch',200,200);gesture('tap',200,200);advance(5000)
assert(#calls==0 and renders==0,'stationary tap forced a page refresh')

-- A hold becomes hold_pan, whose release a real toolbar button can consume.
reset();gesture('touch',200,200);gesture('hold',200,200)
gesture('hold_pan',160,40);gesture('hold',160,40)
assert(c.zoom_y==220 and toolbar_calls==0,'held pan escaped to toolbar')
gesture('hold_release',160,40)
assert(not c.zoom_touch_active and toolbar_calls==0,'toolbar stole hold release')
advance(1200);assert(fullCount()==1,'held pan never cleaned up')

-- A new contact at the deadline defers cleaning, even without motion.
reset();gesture('touch',200,200);gesture('pan',180,180);gesture('pan_release',180,180)
advance(1199);gesture('touch',180,180);advance(5000)
assert(fullCount()==0,'new contact was interrupted')
gesture('tap',180,180);advance(1200);assert(fullCount()==1)

-- Rapid repeated drags flush their last position without intermediate flashes.
reset()
for i=1,20 do
    gesture('touch',200,200);gesture('pan',198,198);gesture('pan',196,196)
    gesture('pan_release',196,196);advance(100)
end
assert(fullCount()==0 and c.zoom_x==80 and c.zoom_y==140,'rapid pans lost movement or flashed')
advance(1100);assert(fullCount()==1)

-- All terminal gesture types clear ownership outside the content rectangle.
for _,kind in ipairs({'tap','double_tap','two_finger_tap','two_finger_pan_release',
    'two_finger_hold_release','two_finger_hold_pan_release','swipe','multiswipe','two_finger_swipe'}) do
    reset();gesture('touch',200,200);gesture('pan',180,180)
    gesture(kind,180,40,{x=160,y=40})
    assert(not c.zoom_touch_active,kind..' retained contact')
    advance(1200);assert(fullCount()==1,kind..' lost cleanup')
end

-- Physical edge releases, including one-pixel sensor/rotation overshoot.
for _,pos in ipairs({{-1,200},{401,200},{200,-1},{200,601},
    {0,200},{400,200},{200,0},{200,600},{-1,-1},{401,601}}) do
    reset();gesture('touch',200,200);gesture('pan',180,180)
    gesture('pan',pos[1],pos[2]);advance(1500)
    assert(fullCount()==0,'edge pan flashed under contact')
    gesture('pan_release',pos[1],pos[2])
    assert(not c.zoom_touch_active,'edge release retained contact')
    advance(1200);assert(fullCount()==1,'edge release lost cleanup')
end
-- The page can also reach its pan clamp before the finger reaches the bezel.
reset();gesture('touch',200,200);gesture('pan',-500,-500);advance(50)
assert(c.zoom_x==200 and c.zoom_y==330,'page did not clamp')
gesture('pan',-550,-550);gesture('pan_release',-550,-550)
advance(1200);assert(fullCount()==1,'clamped page lost cleanup')

-- Rejected palm swipes must still release a previously accepted contact.
reset();gesture('touch',200,200);gesture('pan',180,180);c.pen_down=true
gesture('swipe',180,180,{x=160,y=160});assert(not c.zoom_touch_active)
advance(2000);assert(fullCount()==0);c.pen_down=false

-- Pen lift restarts the entire idle interval, not the remainder of a retry.
-- Out-of-page samples suffice here: no synthetic rasterizer is needed.
c:_zoomStylus({id=1,x=10,y=20},'pen')
advance(100);c:_zoomStylus({id=-1},'pen')
advance(1199);assert(fullCount()==0,'cleanup ran immediately after pen lift')
advance(1);assert(fullCount()==1)

-- Pending ink/menu repair is consumed by one request, including the toolbar.
reset();gesture('touch',200,200);gesture('pan',180,180);gesture('pan_release',180,180)
c:_scheduleCleanScreen();advance(1200)
assert(fullCount()==1 and calls[#calls].y==0 and calls[#calls].h==screen:getHeight())
advance(5000);assert(fullCount()==1 and not c.reconcile_full and not c.reconcile)

-- Cancellation removes both trailing pan and idle work and resets cadence.
reset();gesture('touch',200,200);gesture('pan',180,180);gesture('pan',160,160)
local before=renders;c:_cancelZoomRefresh();advance(5000)
assert(renders==before and fullCount()==0 and not c.zoom_touch_active)
assert(not c.last_zoom_pan_refresh,'old pan timestamp leaked across sessions')
c.zoom=1;assert(not c:onZoomHoldPan(nil,{pos={x=20,y=80}}),'hold pan changed 1x behavior')
-- Autosave serialization must yield to a finger drag just like a pen stroke.
reset()
local saves=0;c.document.dirty=true
c.document.save=function() saves=saves+1;return true end
gesture('touch',200,200);gesture('pan',180,180)
c.autosave_cb();advance(7500)
assert(saves==0,'autosave serialized during pan')
gesture('pan_release',180,180);advance(2500)
assert(saves==1,'deferred autosave was lost')

print('zoom pan: timed release, boundary capture, holds, palm/swipe, pen idle, cleanup merge and cancellation passed')
