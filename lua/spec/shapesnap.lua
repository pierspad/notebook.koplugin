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

-- Endpoint hold must not regularize freehand figures, for either drawing tool.
for _,tool in ipairs({"pen","highlighter"}) do
    for _,style in ipairs({"line","arrow"}) do
        local loop=Stroke:new{tool=tool,width=3}
        for i=0,40 do
            local angle=i*math.pi/20
            loop:addPoint(200+80*math.cos(angle),200+80*math.sin(angle),0.7)
        end
        result=nil
        snap:begin(loop,280,200,style)
        snap:trigger()
        assert(not result and not snap.snapped,"held circle was regularized")
        assert(loop:count()==41,"hold altered freehand points")
        snap:cancel()
    end
end

print("hold-to-straighten timing and pen/marker recognition passed")

-- Replacing freehand ink must cancel any trailing fast frame and use a local
-- grayscale refresh before the held nib is lifted, without a full-screen flash.
local Refresh=require("canvasrefresh")
local SnapCanvas=require("snapcanvas")
local screen=require("device").screen
local modes={}
screen.refreshUI=function() modes[#modes+1]="ui" end
screen.refreshFast=function() modes[#modes+1]="fast" end
local raw=stroke
local clean=require("shape").recognize(raw,"arrow")
local canvas={stroke=raw,zoom=1,content={x=0,y=0,w=600,h=800},refresh_mode="fast",
    idle_flush_cb=function() end,_restoreLiveInk=function() end,_repaintRegion=function() end}
setmetatable(canvas,{__index=function(_,key) return Refresh[key] or SnapCanvas[key] end})
local renderer=require("renderer");local draw=renderer.drawStroke
renderer.drawStroke=function() end
canvas:_accumulate(95,195,10,10)
pending[canvas.idle_flush_cb]=0.02
canvas:_applyShapeSnap(clean,raw)
renderer.drawStroke=draw
assert(canvas.stroke==clean and modes[1]=="ui" and #modes==1,"snap used fast/full waveform")
assert(not pending[canvas.idle_flush_cb] and not canvas.pending,"obsolete raw ink refresh survived snap")
assert(canvas.refresh_mode=="fast" and not canvas.reconcile_full,"snap changed live ink policy")
print("recognized arrow refresh replaces raw ink immediately with a local grayscale update")
