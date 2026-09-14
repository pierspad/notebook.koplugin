-- Run from KOReader: ./luajit /path/bench-render.lua /path/plugin
-- Offscreen buffers only: does not touch the framebuffer, input, or notebooks.
require("setupkoenv")
package.path = assert(arg[1], "plugin directory required") .. "/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Stroke = require("stroke")
local Renderer = require("renderer")
local bb = BB.new(1860, 2480, BB.TYPE_BB8)
local full = BB.new(1860, 2480, BB.TYPE_BB8)
local clip = { x = 700, y = 700, w = 100, h = 100 }
for _, tool in ipairs({"pen", "highlighter"}) do
    local s = Stroke:new{ tool = tool, width = tool == "pen" and 3 or 24 }
    s:addPoint(50, 50, 0.5)
    s:addPoint(1800, 1800, 1)
    bb:fill(BB.COLOR_WHITE)
    full:fill(BB.COLOR_WHITE)
    Renderer.drawStroke(full, s)
    Renderer.drawStroke(bb, s, clip)
    local differences, outside = 0, 0
    for y = 0, 1859 do
        for x = 0, 1859 do
            local v = bb:getPixel(x,y):getColor8().a
            if x >= clip.x and x < clip.x+clip.w and y >= clip.y and y < clip.y+clip.h then
                if v ~= full:getPixel(x,y):getColor8().a then differences = differences+1 end
            elseif v ~= 255 then outside = outside+1 end
        end
    end
    local start = os.clock()
    for _ = 1, 30 do Renderer.drawStroke(bb, s, clip) end
    print(string.format("%s: %.3f ms/clip, inside differences=%d, outside writes=%d",
        tool, (os.clock()-start)*1000/30, differences, outside))
end
bb:free()
full:free()
