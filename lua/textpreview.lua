-- An editing session reuses immutable page pixels. Typing only lays out and
-- draws the changing label, instead of replaying every stroke behind it.
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Preview = {}
Preview.__index = Preview

function Preview.new(canvas, original)
    if original then canvas:_repaintRegion(original:getBounds()) end
    return setmetatable({canvas=canvas, background=Device.screen.bb:copy()}, Preview)
end

function Preview:paint(stroke, dirty)
    local screen=Device.screen
    local x,y,w,h=Rect.clamp(dirty.x,dirty.y,dirty.w,dirty.h,self.canvas.content)
    if not x then return end
    screen.bb:blitFrom(self.background,x,y,x,y,w,h)
    Renderer.drawStroke(screen.bb,stroke,{x=x,y=y,w=w,h=h},
        screen.isColorEnabled and screen:isColorEnabled())
    self.canvas:_refreshNow(x,y,w,h,"fast")
end

function Preview:free()
    if self.background then self.background:free(); self.background=nil end
end

return Preview
