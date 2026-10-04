-- Exercise the production bridge with KOReader's input inhibition ordering.
package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs()
require('uistubs').install({})
local Input=require('device').input
Input.pen_slot=4;Input.wacom_protocol=true
local original_touch=function() end
local original_key=function() end
Input.handleTouchEv=original_touch;Input.handleKeyBoardEv=original_key
Input.registerStylusCallback=function(self,fn) self.stylus_callback=fn end
local Bridge=require('stylusbridge')
local canvas={onStylusEvent=function() return true end}
local void=function() end
for cycle=1,20 do
    Bridge.start(canvas)
    Input._abs_ev_handler=Input.handleTouchEv;Input._key_ev_handler=Input.handleKeyBoardEv
    Input.handleTouchEv=void;Input.handleKeyBoardEv=void
    Bridge.stop(canvas)
    assert(Input.handleTouchEv==void and Input.handleKeyBoardEv==void,
        'suspend bypassed KOReader input inhibition')
    assert(Input._abs_ev_handler==original_touch and Input._key_ev_handler==original_key,
        'resume would restore a stale Notebook closure')
    Input.handleTouchEv=Input._abs_ev_handler;Input._abs_ev_handler=nil
    Input.handleKeyBoardEv=Input._key_ev_handler;Input._key_ev_handler=nil
    Bridge.start(canvas)
    local cb=Input.stylus_callback
    Bridge.start(canvas)
    assert(Input.stylus_callback==cb,'duplicate Show replaced callback ownership')
    Bridge.stop(canvas)
    assert(Input.handleTouchEv==original_touch and Input.handleKeyBoardEv==original_key)
    assert(Input.pen_slot==4 and Input.stylus_callback==nil)
end
local slots={}
Input.setupSlotData=function(self,n) self.cur_slot=n;slots[n]=slots[n] or {} end
Input.setCurrentMtSlot=function(self,k,v) slots[self.cur_slot][k]=v end
Input.setCurrentMtSlotChecked=Input.setCurrentMtSlot
Input.handleTouchEv=function(self,ev)
    if ev.code==47 then self:setupSlotData(ev.value)
    elseif ev.code==53 then self:setCurrentMtSlotChecked('x',ev.value)
    elseif ev.code==54 then self:setCurrentMtSlotChecked('y',ev.value) end
end
Input.handleKeyBoardEv=function() end
Bridge.start(canvas)
Input:handleTouchEv{type=3,code=47,value=2,fd=22}
Input:handleTouchEv{type=3,code=0,value=500,fd=22}
Input:handleTouchEv{type=3,code=1,value=700,fd=22}
assert(not slots[15],'panel axes populated pen before proximity')
Input:handleKeyBoardEv{type=1,code=320,value=1,fd=11}
Input:handleTouchEv{type=3,code=0,value=100,fd=11}
Input:handleTouchEv{type=3,code=1,value=120,fd=11}
Input:handleTouchEv{type=3,code=47,value=2,fd=22}
Input:handleTouchEv{type=3,code=53,value=500,fd=22}
Input:handleTouchEv{type=3,code=54,value=700,fd=22}
-- Capacitive panels also emit legacy ABS_X/Y and BTN_TOUCH.
Input:handleTouchEv{type=3,code=0,value=500,fd=22}
Input:handleTouchEv{type=3,code=1,value=700,fd=22}
Input:handleKeyBoardEv{type=1,code=330,value=1,fd=22}
assert(slots[15].x==100 and slots[15].y==120,'legacy palm coordinates became nib coordinates')
assert(slots[15].id==nil,'palm BTN_TOUCH created a pen dot')
Input:handleKeyBoardEv{type=1,code=330,value=1,fd=11}
assert(slots[15].id==15,'real nib contact lost')
Input:handleKeyBoardEv{type=1,code=330,value=0,fd=22}
assert(slots[15].id==15,'palm lift ended pen stroke')
Input:handleKeyBoardEv{type=1,code=330,value=0,fd=11}
assert(slots[15].id==-1,'real nib lift lost')
Bridge.stop(canvas)
print('bridge_lifecycle: 20 inhibited cycles, duplicate start and separate panel/nib devices passed')
