package.path = "./?.lua;./spec/?.lua;" .. package.path
require("support").installStubs()
require("uistubs").install({})
local now = 0
package.loaded["ui/time"] = {now=function() return now end, to_ms=function(t) return t end}
local UI = require("ui/uimanager")
local pending = {}
UI.scheduleIn = function(_, delay, fn) pending[fn] = delay end
UI.unschedule = function(_, fn) pending[fn] = nil end
local screen = require("device").screen
local refreshes, renders, full, ui = 0, 0, 0, 0
screen.refreshUI = function() ui=ui+1 end
screen.refreshFast = function() refreshes = refreshes+1 end
screen.refreshFull = function() full = full+1 end
local Refresh = require("zoomrefresh")
local canvas = setmetatable({zoom=2, zoom_x=0, zoom_y=0,
    content={x=0,y=0,w=400,h=600},
    _renderZoom=function() renders=renders+1 end}, {__index=Refresh})
canvas:setupZoomRefresh()
canvas:_zoomPan(-2, -2)
for _=1,20 do canvas:_zoomPan(-2, -2) end
assert(renders == 1 and refreshes == 1, "raw touch samples copied the viewport")
assert(canvas.zoom_x == 42 and canvas.zoom_y == 42, "coalescing lost pan movement")
assert(pending[canvas.zoom_pan_cb] == 0.035, "pan has no trailing frame")
now = 35
canvas.zoom_pan_cb()
assert(renders == 2 and refreshes == 2, "trailing frame did not render the latest position")
assert(pending[canvas.zoom_pan_settle_cb]==1.2, "pan cleanup is too eager")
local Touch=require("touchinput")
canvas._touchIsPalm=function() return false end
canvas._debugEvent=function() end
canvas._rejectPalmContact=Touch._rejectPalmContact
canvas._touchPoint=Touch._touchPoint
canvas.onTouchRelease=Touch.onTouchRelease
Touch.onTouchStart(canvas,nil,{pos={x=80,y=80}})
canvas:_settleZoomPan()
assert(ui==0 and full==0 and renders==2,"cleanup interrupted the next finger contact")
Touch.onTouchPan(canvas,nil,{pos={x=60,y=60}})
Touch.onTouchRelease(canvas)
assert(not canvas.zoom_touch_active,"pan release retained finger contact")
assert(canvas.zoom_x==62 and canvas.zoom_y==62,"consecutive pan lost movement")
assert(full==0 and ui==0,"release forced a cleanup")
canvas:_settleZoomPan()
assert(renders==3 and ui==0 and full==1,"idle pan should clean ghosts once without recopy")
canvas:_settleZoomPan();assert(full==1,"idle cleanup repeated")
-- Stationary taps/holds end too; swipe paths must not leave a stuck contact.
Touch.onTouchStart(canvas,nil,{pos={x=80,y=80}})
Touch.onZoomTouchEnd(canvas)
assert(not canvas.zoom_touch_active,"tap/hold release blocked later cleanup")
Touch.onTouchStart(canvas,nil,{pos={x=80,y=80}})
Touch.onPageSwipe(canvas,nil,{pos={x=80,y=80},end_pos={x=60,y=60}})
assert(not canvas.zoom_touch_active and canvas.zoom_x==82,"swipe lost movement/contact end")
canvas:_cancelZoomRefresh()
local before=renders
canvas.zoom_pan_cb();canvas.zoom_pan_settle_cb()
assert(renders==before and full==1,"cancelled pan still rendered")
print("pan coalesces viewport copies and preserves the final position")

local ink_refreshes = 0
screen.refreshUI = function() ink_refreshes=ink_refreshes+1; ui=ui+1 end
now=100
canvas:_queueZoomInk(10,10,5,5,"ui")
now=110
canvas:_queueZoomInk(15,10,5,5,"ui")
assert(pending[canvas.zoom_ink_cb], "marker did not schedule trailing pixels")
-- The next sample arrives after the interval but before the queued callback
-- has been dispatched. Its immediate refresh must cancel that old callback.
now=181
canvas:_queueZoomInk(20,10,5,5,"ui")
assert(not pending[canvas.zoom_ink_cb] and not canvas.zoom_ink_scheduled,
    "immediate marker flush left an obsolete timer")
now=182
canvas:_queueZoomInk(25,10,5,5,"ui")
assert(pending[canvas.zoom_ink_cb] > 0.07 and ink_refreshes==2,
    "marker refreshes escaped their intended cadence")

-- Other active tools also postpone pan cleanup. A pending full-screen menu
-- repair must include the toolbar, not be consumed by a viewport-only update.
canvas.zoom_pan_needs_settle=true
for _,flag in ipairs({'pen_down','stroke','zoom_stroke','shape_gesture','transform_gesture',
    'erasing','zoom_erasing','dragging_selection'}) do
 local before_ui=ui
 canvas[flag]=true;canvas:_settleZoomPan();canvas[flag]=nil
 assert(full==1 and ui==before_ui,'pan cleanup interrupted '..flag)
end
canvas._runReconcile=require('canvasrefresh')._runReconcile
canvas.reconcile={x=0,y=0,w=400,h=600};canvas.reconcile_full=true
canvas.reconcile_cb=function() end
now=3000;canvas:_settleZoomPan()
assert(full==2 and not canvas.reconcile_full and not canvas.reconcile,
    'pan cleanup lost a pending whole-screen menu repair')
