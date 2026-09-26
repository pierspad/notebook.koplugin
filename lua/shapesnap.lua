-- Recognizes a pen/marker stroke after the nib rests at its endpoint.
-- This module owns only the hold timer and recognition state; the caller
-- decides how to replace pixels and commit the resulting stroke.
local Shape = require("shape")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local Safe = require("safe")

local ShapeSnap = {}
ShapeSnap.__index = ShapeSnap

function ShapeSnap.new(on_snap)
    local self = setmetatable({on_snap = on_snap}, ShapeSnap)
    self.callback = Safe.wrap("canvas:shape_snap", function() self:trigger() end)
    return self
end

function ShapeSnap:cancel()
    UIManager:unschedule(self.callback)
    self.stroke = nil
    self.snapped = false
end

function ShapeSnap:begin(stroke, x, y, line_style)
    self:cancel()
    if not stroke or (stroke.tool ~= "pen" and stroke.tool ~= "highlighter") then return end
    self.stroke = stroke
    self.anchor_x, self.anchor_y = x, y
    self.line_style = line_style
    UIManager:scheduleIn(Tuning.hold_delay_ms / 1000, self.callback)
end

function ShapeSnap:moved(x, y)
    if not self.stroke or self.snapped then return end
    local dx, dy = x - self.anchor_x, y - self.anchor_y
    if dx * dx + dy * dy <= Tuning.hold_travel_sq then return end
    self.anchor_x, self.anchor_y = x, y
    UIManager:unschedule(self.callback)
    if self.stroke:count() >= 4 then
        UIManager:scheduleIn(Tuning.hold_delay_ms / 1000, self.callback)
    end
end

function ShapeSnap:trigger()
    local stroke = self.stroke
    if not stroke or self.snapped or stroke:count() < 4 then return end
    local clean = Shape.recognize(stroke, self.line_style)
    if not clean then return end
    self.snapped = true
    self.on_snap(clean, stroke)
end

return ShapeSnap
