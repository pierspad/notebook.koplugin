-- Native REAGL routing proof without issuing framebuffer ioctls or repainting.
-- Run from a Kindle KOReader runtime with the plugin Lua directory as argument.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/dev/null')
local Device=require('device')
require('document/canvascontext'):init(Device)
local load=dofile(assert(arg[1])..'/loader.lua')(arg[1])
local Screen,BB,ffi=Device.screen,require('ffi/blitbuffer'),require('ffi')
assert(Screen.mech_refresh and Screen._isREAGLWaveFormMode
 and Screen:_isREAGLWaveFormMode(Screen.waveform_partial),'REAGL backend required')
local UI=require('ui/uimanager')
local pending={}
UI.scheduleIn=function(_,delay,callback) pending[callback]=delay end
UI.unschedule=function(_,callback) pending[callback]=nil end
local previous_bb,previous_refresh=Screen.bb,Screen.mech_refresh
local w,h=Screen:getWidth(),Screen:getHeight()
Screen.bb=BB.new(w,h,BB.TYPE_BB8);Screen.bb:fill(BB.COLOR_WHITE)
Screen.bb:paintRect(25,70,145,80,BB.Color8(160))
local pixels=ffi.string(Screen.bb.data,tonumber(Screen.bb.stride)*Screen.bb.h)
local calls={}
Screen.mech_refresh=function(_,flashing,waveform,x,y,rw,rh,dither)
 calls[#calls+1]={flashing=flashing,waveform=waveform,x=x,y=y,w=rw,h=rh,dither=dither}
end
local c=setmetatable({content={x=20,y=60,w=w-40,h=h-80},reconcile_cb=function() end},
 {__index=load('canvasrefresh')})
c:_scheduleReconcile(25,70,100,50,true)
c:_scheduleReconcile(120,100,50,50,true)
assert(pending[c.reconcile_cb]==0.8,'burst did not retain its quiet window')
c.pen_down=true;c:_runReconcile();c.pen_down=false
assert(#calls==0 and c.reconcile_color,'panel driven while pen was down')
c:_runReconcile();c:_runReconcile()
assert(#calls==1,'burst generated multiple native refresh submissions')
local call=calls[1]
assert(call.waveform==Screen.waveform_partial and not call.flashing,
 'final ink did not request the native nonflashing REAGL path')
local x,y,rw,rh=Screen:calculateRealCoordinates(25,70,145,80)
assert(call.x==x and call.y==y and call.w==rw and call.h==rh,'native rectangle/rotation changed')
assert(not pending[c.reconcile_cb] and not c.reconcile,'cleanup retained timer or bounds')
assert(pixels==ffi.string(Screen.bb.data,tonumber(Screen.bb.stride)*Screen.bb.h),
 'reconciliation rerendered or modified committed pixels')
Screen.mech_refresh=previous_refresh;Screen.bb:free();Screen.bb=previous_bb
if Device.input and Device.input.teardown then Device.input:teardown() end
print('native reconciliation: one regional nonflashing REAGL submission, no contact update, no pixel rewrite or ioctl')
