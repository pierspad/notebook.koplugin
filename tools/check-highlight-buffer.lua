-- Run from the KOReader runtime with the plugin lua directory as argument.
-- Verify the BB8 rasterization against the stamp reference, including
-- rotated, inverted and shared-memory viewport buffers.
require("setupkoenv")
package.path = assert(arg[1], "plugin lua directory required") .. "/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Ink = require("highlightink")
for rotation=0,3 do
    for inverse=0,1 do
        local actual, expected = BB.new(240,260,BB.TYPE_BB8), BB.new(240,260,BB.TYPE_BB8)
        actual:setRotation(rotation); expected:setRotation(rotation)
        actual:setInverse(inverse); expected:setInverse(inverse)
        actual:fill(BB.COLOR_WHITE); expected:fill(BB.COLOR_WHITE)
        local a, b = actual:viewport(10,12,180,190), expected:viewport(10,12,180,190)
        a:paintRect(0,60,180,2,BB.Color8(70)); b:paintRect(0,60,180,2,BB.Color8(70))
        local tint = BB.Color8(160)
        Ink.drawSegment(a, -5, 10, 12, 180, 175, 24, tint, 0, 30, 30)
        for i=0,30 do
            local t=i/30
            Ink.stamp(b, -5+185*t, 10+165*t, 12+12*t, tint)
        end
        for y=0,actual:getHeight()-1 do for x=0,actual:getWidth()-1 do
            assert(actual:getPixel(x,y).a==expected:getPixel(x,y).a,
                string.format("pixel mismatch: rotation %d inverse %d at %d,%d",rotation,inverse,x,y))
        end end
        actual:free(); expected:free()
    end
end
print("marker matches reference in all rotations, inversions and viewports")
