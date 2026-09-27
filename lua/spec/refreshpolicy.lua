package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs();require('uistubs').install({})
local Refresh=require('canvasrefresh');local Screen=require('device').screen
local scheduled={};local UI=require('ui/uimanager')
UI.scheduleIn=function(_,delay,fn) scheduled[fn]=delay end
UI.unschedule=function(_,fn) scheduled[fn]=nil end
local ui,full=0,0
Screen.refreshUI=function(_,x,y,w,h) ui=ui+1;assert(x>=0 and y>=0 and w>0 and h>0) end
Screen.refreshFull=function() full=full+1 end
local c=setmetatable({content={x=0,y=0,w=600,h=800},reconcile_cb=function() end},{__index=Refresh})
c:_scheduleReconcile(10,20,30,40)
assert(scheduled[c.reconcile_cb]==2,'ordinary cleanup default changed')
c:_scheduleReconcile(40,20,30,40,true)
assert(scheduled[c.reconcile_cb]==0.8,'color still waits two seconds')
-- A second scheduling call on zoom lift must not reset the faster deadline.
c:_scheduleReconcile(10,20,60,40)
assert(scheduled[c.reconcile_cb]==0.8,'zoom/black stroke postponed pending color')
for _,flag in ipairs({'pen_down','stroke','zoom_stroke','transform_gesture','shape_gesture',
    'dragging_selection','erasing','zoom_erasing','zoom_pan_dirty'}) do
    c[flag]=true;c:_runReconcile();c[flag]=nil
    assert(ui==0 and full==0 and c.reconcile_color,'refresh interrupted '..flag)
    assert(scheduled[c.reconcile_cb]==0.6,'active contact was not rescheduled')
end
c:_runReconcile();c:_runReconcile()
assert(ui==1 and not c.reconcile_color and not c.reconcile,'color cleanup missing or repeated')
c:_scheduleCleanScreen();assert(scheduled[c.reconcile_cb]==2,'old color flag leaked into next operation')
c:_runReconcile();assert(full==1,'full cleanup was downgraded to UI')
print('refresh policy: color at 800ms, no refresh during contact, one final cleanup')
