-- Run from KOReader's root: SDL_VIDEODRIVER=dummy ./base/build/x86_64-pc-linux-gnu-debug/luajit PATH/bench-dashes.lua PLUGIN_DIR
require('setupkoenv')
package.path = assert(arg[1], 'plugin directory required') .. '/lua/?.lua;' .. package.path
local BB = require('ffi/blitbuffer')
local Renderer = require('renderer')
local function old(bb, x, y, w, h)
    local color, max_x, max_y = BB.COLOR_BLACK, bb:getWidth()-1, bb:getHeight()-1
    local function horizontal(py)
        if py < 0 or py > max_y then return end
        for i = math.max(0,-x), math.min(w,max_x-x) do
            if i % 14 < 8 then bb:setPixel(x+i,py,color) end
        end
    end
    local function vertical(px)
        if px < 0 or px > max_x then return end
        for j = math.max(0,-y), math.min(h,max_y-y) do
            if j % 14 < 8 then bb:setPixel(px,y+j,color) end
        end
    end
    horizontal(y); horizontal(y+h); vertical(x); vertical(x+w)
end
local a, b = BB.new(930,1240,BB.TYPE_BB8), BB.new(930,1240,BB.TYPE_BB8)
a:fill(BB.COLOR_WHITE); b:fill(BB.COLOR_WHITE)
old(a,70,100,680,850)
Renderer.drawDashedRect(b,70,100,680,850)
for y=0,1239 do
    for x=0,929 do
        assert(a:getPixel(x,y):getColor8().a == b:getPixel(x,y):getColor8().a,
            string.format('pixel differs at %d,%d',x,y))
    end
end
local loops=200
local function measure(fn, bb)
    local start=os.clock()
    for _=1,loops do fn(bb,70,100,680,850) end
    return (os.clock()-start)*1000/loops
end
local old_ms=measure(old,a)
local new_ms=measure(Renderer.drawDashedRect,b)
print(string.format('equal pixels; old %.3f ms/frame; new %.3f ms/frame; speedup %.2fx',
    old_ms,new_ms,old_ms/new_ms))
a:free(); b:free()
