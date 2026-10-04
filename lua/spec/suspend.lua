-- Cover pixels remain untouched throughout suspend and delayed unlock.
package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
require('uistubs').install({})
local Device=require('device');local Screen=Device.screen
Screen.bb=support.FakeBB.new(400,600)
local registered=0
local prior=function() end
Device.input.stylus_callback=prior
Device.input.registerStylusCallback=function(self,fn) self.stylus_callback=fn;registered=registered+1 end
local UI=require('ui/uimanager');local timers,dirty={},{}
UI.scheduleIn=function(_,delay,fn) timers[fn]=delay end
UI.unschedule=function(_,fn) timers[fn]=nil end
UI.setDirty=function(_,widget,mode) dirty[#dirty+1]={widget=widget,mode=mode} end
local panel_updates=0
for _,mode in ipairs({'Fast','UI','Full'}) do
    Screen['refresh'..mode]=function()
        assert(not Device.screen_saver_mode and not Device.screen_saver_lock,'refresh under cover')
        panel_updates=panel_updates+1
    end
end
G_reader_settings={readSetting=function() end,saveSetting=function() end}
local Document=require('document');local Notebook=require('notebook');local Safe=require('safe')
local nb=Notebook:new{document=Document:new(nil)}
local c=nb.canvas;c.content={x=0,y=60,w=400,h=540}
local saves=0
nb.document.save=function(self) saves=saves+1;self.dirty=false;return true end
local toolbar_paints=0
nb.toolbar.dimen={x=0,y=0,w=400,h=60}
nb.toolbar.paintTo=function(_,bb)
    toolbar_paints=toolbar_paints+1;bb:paintRect(0,0,400,60,0)
end
nb:onShow()
assert(Device.input.stylus_callback==c.stylus_callback and timers[nb.clock_tick])
nb.clock_tick();assert(toolbar_paints==1,'awake clock stopped')
-- The page overview covers the toolbar, including between minute ticks.
nb:_showPages()
Screen.bb:paintRect(0,0,400,600,155)
nb.clock_tick();nb:_refreshToolbar()
local overview_refreshes=panel_updates
for _,name in ipairs(c.lifecycle_callbacks) do c[name]() end
assert(panel_updates==overview_refreshes,'stale canvas callback refreshed page overview')
assert(not c:onStylusEvent({id=1,x=100,y=100,tool=1}),'hidden canvas consumed stylus')
assert(toolbar_paints==1,'page overview was overwritten by toolbar timer')
assert(timers[nb.clock_tick],'hidden clock lost its next tick')
assert(nb.page_panel,'page panel ownership missing')
nb.page_panel:onCloseWidget()
assert(not nb.page_panel,'closed page panel retained ownership')
-- A real screensaver has entered before the Suspend broadcast. A due clock
-- or canvas callback must not draw, even in this interval.
Device.screen_saver_mode=true
Screen.bb:paintRect(0,0,400,600,155)
local before=panel_updates
c.zoom=2;c.zoom_x=0;c.zoom_y=60;c.zoom_pan_dirty=true;c.zoom_pan_needs_settle=true
local copies=0;c._renderZoom=function() copies=copies+1 end
nb.clock_tick();c.zoom_pan_cb();c.zoom_pan_settle_cb();nb:_refreshToolbar()
assert(toolbar_paints==1 and copies==0 and panel_updates==before,'cover entry ran a direct painter')
assert(c:onStylusEvent({id=1,x=100,y=100,tool=1})==false,'covered canvas consumed stylus')
-- Suspend cancels every timer, yields the input callback and saves committed ink.
nb.document.dirty=true;c.barrel_down=true;c.physical_pen_tool=1
for _,name in ipairs(c.lifecycle_callbacks) do timers[c[name]]=0.1 end
nb:handleEvent{handler='onSuspend'}
assert(nb.suspended and c.suspended and Device.input.stylus_callback==prior)
assert(saves==1 and not timers[nb.clock_tick])
assert(not c.barrel_down and not c.physical_pen_tool,'sleep retained a held pen button')
for _,name in ipairs(c.lifecycle_callbacks) do assert(not timers[c[name]],'retained '..name) end
for _,name in ipairs(c.lifecycle_callbacks) do c[name]() end
assert(copies==0 and panel_updates==before,'stale canvas timer ran under cover')
for y=0,599 do for x=0,399 do assert(Screen.bb:get(x,y)==155,'cover pixels changed') end end
-- Delayed screensaver: Resume precedes dismissal and must remain paused.
Device.screen_saver_lock=true
nb:handleEvent{handler='onResume'}
assert(nb.suspended and c.suspended and Device.input.stylus_callback==prior)
nb:handleEvent{handler='onOutOfScreenSaver'}
assert(timers[nb.resume_cb]==0.05,'cover dismissal resumes before flags clear')
Device.screen_saver_mode=false;Device.screen_saver_lock=false
nb.resume_cb()
assert(not nb.suspended and not c.suspended and Device.input.stylus_callback==c.stylus_callback)
assert(timers[nb.clock_tick] and dirty[#dirty].widget==nb and dirty[#dirty].mode=='full')
local events=#dirty;local bindings=registered
nb:onResume();assert(#dirty==events and registered==bindings,'resume duplicated input ownership')
nb.clock_tick();assert(toolbar_paints==2,'clock did not restart')

-- Unfinished normal/zoom strokes survive a suspend and are committed once on
-- resume, so the first new contact cannot join onto the pre-sleep stroke.
for _,zoom in ipairs({1,2}) do
    c.zoom=zoom;c.zoom_x=0;c.zoom_y=60
    if zoom==2 then c:_zoomStylus({id=1,x=80,y=150},'pen')
    else c:_beginStroke('pen',80,150,1) end
    local active=zoom==2 and c.zoom_stroke or c.stroke
    local count=#nb.document:getPage().strokes
    Device.screen_saver_mode=true;nb:onSuspend()
    assert((zoom==2 and c.zoom_stroke or c.stroke)==active,'suspend discarded in-flight ink')
    Device.screen_saver_mode=false;nb:onResume()
    assert(#nb.document:getPage().strokes==count+1,'resume lost/doubled in-flight stroke')
    assert(not c.zoom_stroke and not c.stroke and not c.pen_down)
    assert(not timers[c.reconcile_cb] and not c.reconcile_full,'resume queued a redundant cleanup flash')
end
-- A notebook retained below Home must never paint its toolbar over Home.
local old_top=UI.getTopmostVisibleWidget
UI.getTopmostVisibleWidget=function() return {covers_fullscreen=true} end
local paints=toolbar_paints
nb.clock_tick();nb:_refreshToolbar()
assert(toolbar_paints==paints,'hidden notebook painted toolbar over Home')
assert(timers[nb.clock_tick],'hidden clock lost scheduling')
UI.getTopmostVisibleWidget=old_top
-- A queued unlock must never reattach input after closing the notebook.
nb:onSuspend();nb:onOutOfScreenSaver();local unlock=nb.resume_cb
nb:onCloseWidget();assert(not timers[unlock] and Device.input.stylus_callback==prior)
local after_close=registered;unlock();assert(registered==after_close,'closed notebook reclaimed input')
assert(not Safe.failed,'suspend or resume failed through widget dispatch')
print('suspend: untouched cover, blocked stale timers, input restoration, delayed unlock, retained ink and safe close passed')
