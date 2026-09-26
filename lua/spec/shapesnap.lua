package.path = "./?.lua;./spec/?.lua;" .. package.path

require("support").installStubs()
require("uistubs").install({})

local UIManager = require("ui/uimanager")
local pending = {}
UIManager.scheduleIn = function(_, delay, callback)
    pending[callback] = delay
end
UIManager.unschedule = function(_, callback)
    pending[callback] = nil
end

local ShapeSnap = require("shapesnap")
local Stroke = require("stroke")
local Tuning = require("tuning")

local result
local snap = ShapeSnap.new(function(clean) result = clean end)
local stroke = Stroke:new{tool="pen", width=3}
stroke:addPoint(100, 200, 1)
snap:begin(stroke, 100, 200, "arrow")
assert(pending[snap.callback] == Tuning.hold_delay_ms / 1000,
    "hold timer was not scheduled")

-- Early timer expiry does not transform a tap into a figure.
snap:trigger()
assert(not result and not snap.snapped, "a dot was recognized as a shape")
for x=110,300,10 do
    stroke:addPoint(x, 200, 1)
    snap:moved(x, 200)
end
assert(pending[snap.callback], "moving the nib did not restart the hold timer")
snap.callback()
assert(result and result.shape_kind == "arrow", "the held line did not become an arrow")
assert(snap.snapped, "recognition did not stop further live points")

snap:cancel()
assert(not pending[snap.callback] and not snap.stroke,
    "a released pen left the hold timer active")
result = nil
local marker = Stroke:new{tool="highlighter", width=24}
for x=100,300,10 do marker:addPoint(x, 300, 1) end
snap:begin(marker, 100, 300, "line")
snap:trigger()
assert(result and result.shape_kind == "line" and result.tool == "highlighter",
    "marker hold did not preserve the marker tool")

print("hold-to-straighten timing and pen/marker recognition passed")
