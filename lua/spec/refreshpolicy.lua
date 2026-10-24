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
    'dragging_selection','erasing','zoom_erasing','zoom_pan_dirty','zoom_touch_active','zoom_pan_needs_settle'}) do
    c[flag]=true;c:_runReconcile();c[flag]=nil
    assert(ui==0 and full==0 and c.reconcile_color,'refresh interrupted '..flag)
    assert(scheduled[c.reconcile_cb]==0.6,'active contact was not rescheduled')
end
c:_runReconcile();c:_runReconcile()
assert(ui==1 and not c.reconcile_color and not c.reconcile,'color cleanup missing or repeated')
c:_scheduleCleanScreen();assert(scheduled[c.reconcile_cb]==2,'old color flag leaked into next operation')
c:_runReconcile();assert(full==1,'full cleanup was downgraded to UI')
print('refresh policy: color at 800ms, no refresh during contact, one final cleanup')
-- AUTO/UI may skip pixels already sent through the fast binary preview. A
-- REAGL-capable panel must be driven once over the committed burst's whole box.
local partial,box,dither=0,nil,nil
Screen.waveform_partial=4
Screen._isREAGLWaveFormMode=function(_,mode) return mode==4 end
Screen.isColorEnabled=function() return false end
Screen.refreshPartial=function(_,x,y,w,h,d)
 partial=partial+1;box={x,y,w,h};dither=d
end
c.content={x=10,y=50,w=200,h=200}
c:_scheduleReconcile(-5,40,70,50,true)
c:_scheduleReconcile(150,180,100,100,true)
c.stroke={};c:_runReconcile();c.stroke=nil
assert(partial==0 and c.reconcile_color,'REAGL interrupted an active contact')
c:_runReconcile();c:_runReconcile()
assert(partial==1,'colored ink was not driven once through regional REAGL')
assert(table.concat(box,',')=='10,50,200,200','burst cleanup missed/clipped its dirty union incorrectly')
assert(not dither,'monochrome panel requested a color update')
assert(not scheduled[c.reconcile_cb],'completed cleanup left a redundant timer')
-- Already-final pixels need driving, not a complete vector page repaint.
assert(not c.reconcile and not c.reconcile_color,'completed REAGL retained stale debt')
Screen.isColorEnabled=function() return true end
c:_scheduleReconcile(20,70,20,20,true);c:_runReconcile()
assert(partial==2 and dither==true,'color cleanup lost the native color-waveform hint')
-- Plain black reconciliation and other backends retain their previous policy.
local before_ui=ui
c:_scheduleReconcile(20,70,20,20);c:_runReconcile()
assert(partial==2 and ui==before_ui+1,'ordinary black ink requested unnecessary REAGL')
Screen._isREAGLWaveFormMode=function() return false end
c:_scheduleReconcile(20,70,20,20,true);c:_runReconcile()
assert(partial==2 and ui==before_ui+2,'non-REAGL backend changed its cleanup policy')
-- Cover entry can precede the Suspend event; keep cleanup debt without driving
-- the panel until the covering surface has left.
Screen._isREAGLWaveFormMode=function() return true end
c._isDisplayPaused=function() return true end
c:_scheduleReconcile(20,70,20,20,true);c:_runReconcile()
assert(partial==2 and c.reconcile_color and scheduled[c.reconcile_cb],
 'covered canvas drove or discarded pending color cleanup')
c._isDisplayPaused=function() return false end
c:_runReconcile();assert(partial==3,'uncovered canvas did not finish pending cleanup')
c:_scheduleReconcile(-100,-100,5,5,true);c:_runReconcile()
assert(partial==3,'off-canvas ink caused a hardware update')
print('REAGL reconciliation: clipped burst, native color hint, cover/contact deferral and backend fallback passed')

-- A late callback after close must not drive pixels belonging to the gallery.
c.stopping=true
c:_scheduleReconcile(20,70,20,20,true);c:_runReconcile()
assert(partial==3 and not c.reconcile and not scheduled[c.reconcile_cb],
 'closed canvas retained or issued a deferred panel update')
