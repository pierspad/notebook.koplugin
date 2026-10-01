-- Run from the KOReader runtime with the plugin lua directory as argument.
-- Verify the BB8 rasterization against independent sweep inequalities, including
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
        for y=0,189 do for x=0,179 do
            local low,high=0,1
            for _,q in ipairs({{x+5-12,-185-12},{-5-x-12,185-12},
                {y-10-12,-165-12},{10-y-12,165-12}}) do
                if q[2]>0 then high=math.min(high,-q[1]/q[2])
                else low=math.max(low,-q[1]/q[2]) end
            end
            if low<=high+1e-8 and b:getPixel(x,y).a>160 then b:setPixel(x,y,tint) end
        end end
        for y=0,actual:getHeight()-1 do for x=0,actual:getWidth()-1 do
            assert(actual:getPixel(x,y).a==expected:getPixel(x,y).a,
                string.format("pixel mismatch: rotation %d inverse %d at %d,%d",rotation,inverse,x,y))
        end end
        actual:free(); expected:free()
    end
end
print("marker matches reference in all rotations, inversions and viewports")
-- Independent RGB expectations: highlighting must not replace colored ink
-- with the marker hue or brighten any of its channels.
for _, kind in ipairs({BB.TYPE_BBRGB32,BB.TYPE_BBRGB24,BB.TYPE_BBRGB16}) do
    for rotation=0,3 do
        local bb=BB.new(32,32,kind)
        bb:setRotation(rotation)
        local tint=BB.ColorRGB32(253,216,53)
        for _,rgb in ipairs({{255,255,255},{0,0,0},{229,57,53},{30,120,220},{180,180,180}}) do
            bb:paintRect(0,0,32,32,BB.ColorRGB32(unpack(rgb)))
            local before=BB.ColorRGB32(bb:getPixel(16,16):getR(),bb:getPixel(16,16):getG(),bb:getPixel(16,16):getB())
            Ink.drawSegment(bb,16,16,8,18,16,8,tint,0,1,1)
            local after=BB.ColorRGB32(bb:getPixel(16,16):getR(),bb:getPixel(16,16):getG(),bb:getPixel(16,16):getB())
            -- RGB16 quantizes channels; compare to the same native conversion.
            local want=BB.ColorRGB32(math.min(before:getR(),253),
                math.min(before:getG(),216),math.min(before:getB(),53))
            local expected=BB.new(1,1,kind);expected:setPixel(0,0,want)
            local pixel=expected:getPixel(0,0)
            assert(after:getR()==pixel:getR() and after:getG()==pixel:getG()
                and after:getB()==pixel:getB(),string.format('RGB kind=%s rot=%d got=%d,%d,%d want=%d,%d,%d',kind,rotation,after:getR(),after:getG(),after:getB(),pixel:getR(),pixel:getG(),pixel:getB()))
            Ink.drawSegment(bb,16,16,8,18,16,8,tint,0,1,1)
            pixel=bb:getPixel(16,16)
            assert(after:getR()==pixel:getR() and after:getG()==pixel:getG()
                and after:getB()==pixel:getB(),'repeated marker pass changed color')
            expected:free()
        end
        bb:free()
    end
end
print('RGB marker preserves dark channels on white, black, red, blue and gray; repeated passes are stable')
