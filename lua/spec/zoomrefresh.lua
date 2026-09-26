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
local refreshes, renders, full = 0, 0, 0
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
assert(canvas.zoom_x == 21 and canvas.zoom_y == 21, "coalescing lost pan movement")
assert(pending[canvas.zoom_pan_cb] == 0.035, "pan has no trailing frame")
now = 35
canvas.zoom_pan_cb()
assert(renders == 2 and refreshes == 2, "trailing frame did not render the latest position")
canvas.zoom_touch_x = 10 -- missing pan_release must not block cleanup
canvas:_settleZoomPan()
assert(renders == 3, "settled pan did not redraw grayscale pixels")
assert(full == 1, "settled pan did not perform full cleanup")
canvas:_zoomPan(-2,-2)
canvas:_cancelZoomRefresh()
canvas.zoom_pan_cb()
assert(renders == 3, "cancelled pan still rendered")
print("pan coalesces viewport copies and preserves the final position")

local ink_refreshes = 0
screen.refreshUI = function() ink_refreshes=ink_refreshes+1 end
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
