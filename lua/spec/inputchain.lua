-- KOReader's input handlers are shared with every other plugin. Notebook must
-- never leave a closure in that chain that can fault, swallow power/cover keys
-- or keep redirecting events once its screen is gone, whatever order other
-- plugins wrap and unwrap the same handlers in.
package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs()
require('uistubs').install({})
local Input=require('device').input
local Safe=require('safe')
Input.pen_slot=4;Input.wacom_protocol=true;Input.main_finger_slot=0
local slots={}
Input.setupSlotData=function(self,n) self.cur_slot=n;slots[n]=slots[n] or {} end
Input.setCurrentMtSlot=function(self,k,v) slots[self.cur_slot][k]=v end
Input.setCurrentMtSlotChecked=Input.setCurrentMtSlot
local touch_seen,key_seen={},{}
local original_touch=function(_,ev) touch_seen[#touch_seen+1]=ev;return 'touch' end
local original_key=function(_,ev) key_seen[#key_seen+1]=ev;return 'key' end
Input.handleTouchEv=original_touch;Input.handleKeyBoardEv=original_key
Input.stylus_callback=nil
Input.registerStylusCallback=function(self,fn) self.stylus_callback=fn end
Input.unregisterStylusCallback=function(self) self.stylus_callback=nil end
local Bridge=require('stylusbridge')
local drawn=0
local canvas={onStylusEvent=function() drawn=drawn+1;return true end}

-- Power management and sleep-cover keys always reach KOReader while drawing.
Bridge.start(canvas)
for _,code in ipairs({59,35,116,10000,10001,10020}) do
    local before=#key_seen
    Input:handleKeyBoardEv{type=1,code=code,value=1}
    assert(#key_seen==before+1,'key '..code..' (power/cover) was swallowed by Notebook')
end
Bridge.stop(canvas)

-- Another plugin wraps on top of Notebook and unwraps after Notebook closed.
local function wrapper(name)
    local held=Input[name]
    local fn=function(this,ev) return held(this,ev) end
    Input[name]=fn
    return fn,function() if Input[name]==fn then Input[name]=held end end
end
Bridge.start(canvas)
local _,unwrap_touch=wrapper('handleTouchEv')
local _,unwrap_key=wrapper('handleKeyBoardEv')
Bridge.stop(canvas) -- not on top: cannot unhook itself
local ok,err=pcall(function()
    Input:handleTouchEv{type=3,code=0,value=10,fd=3}
    Input:handleKeyBoardEv{type=1,code=59,value=1,fd=4}
    Input:handleKeyBoardEv{type=1,code=330,value=1,fd=5}
end)
assert(ok,'stale Notebook input handler faulted after close: '..tostring(err))
assert(touch_seen[#touch_seen].code==0,'stale handler still redirects ABS_X to the pen slot')
assert(key_seen[#key_seen].code==330,'stale handler still swallows BTN_TOUCH')
unwrap_touch();unwrap_key()
-- The other plugin restored Notebook's closure; it must be a pass-through.
local before_t,before_k=#touch_seen,#key_seen
assert(pcall(function()
    Input:handleTouchEv{type=3,code=1,value=10}
    Input:handleKeyBoardEv{type=1,code=10000,value=1}
end),'restored stale Notebook handler faulted')
assert(#touch_seen==before_t+1 and #key_seen==before_k+1,'restored stale handler dropped events')
Input.handleTouchEv=original_touch;Input.handleKeyBoardEv=original_key

-- Repeated reopen with an interleaved wrapper never grows a faulting chain.
for _=1,50 do
    Bridge.start(canvas)
    local _,u=wrapper('handleTouchEv')
    Bridge.stop(canvas)
    u()
end
assert(pcall(function() Input:handleTouchEv{type=3,code=0,value=1} end),'reopen cycles faulted')
Input.handleTouchEv=original_touch

-- A stale stylus callback restored by another plugin must not draw on a
-- closed canvas nor claim pen events from the rest of KOReader.
local other_calls=0
local other=function() other_calls=other_calls+1;return false end
Input.stylus_callback=nil
Bridge.start(canvas)
local notebook_cb=Input.stylus_callback
Input:registerStylusCallback(other)      -- e.g. a reader highlight tool
Bridge.stop(canvas)                      -- cannot take it back: not current
Input:registerStylusCallback(notebook_cb) -- the other tool restores its "previous"
drawn=0
local claimed=Input.stylus_callback(Input,{slot=15,id=15,x=1,y=1,tool=1})
assert(drawn==0,'closed Notebook canvas still drew from a stale stylus callback')
assert(not claimed,'stale Notebook stylus callback still claims pen events')
assert(not Safe.failed,'stale stylus callback faulted')
Input.stylus_callback=nil

print('inputchain: power/cover keys pass, stale handlers and callbacks are inert under foreign wrapping')
