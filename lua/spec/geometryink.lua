package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()
local Shape = require("shape")
local Renderer = require("renderer")
local FakeBB = support.FakeBB

for _, kind in ipairs({"rectangle", "square", "circle"}) do
    local figure = Shape.create(kind, 12, 16, 70, 64, 4, 0)
    local native = FakeBB.new(200, 200)
    Renderer.drawStroke(native, figure)
    local zoomed = FakeBB.new(400, 400)
    local stamps = 0
    local old = zoomed.paintCircle
    zoomed.paintCircle = function(self, ...)
        stamps = stamps + 1
        return old(self, ...)
    end
    Renderer.drawPage(zoomed, {strokes={figure}}, 2, 0, 0)
    assert(stamps == 0, kind .. " was replayed as many pen stamps at 2x")
    -- The primitive is the same at native and enlarged scale away from edges.
    assert(zoomed:get(24,32) == native:get(12,16), kind .. " changed its corner")
    assert(zoomed:get(82,80) == native:get(41,40), kind .. " changed its interior")
end
-- The four-rectangle path must preserve the old scanline coverage, including
-- clipping, fractional geometry and figures narrower than the pen itself.
local GeometryInk = require("geometryink")
for _, bounds in ipairs({{10,12,70,64}, {-8,2,40,55}, {12.4,20.6,17.8,23.1}}) do
    for _, width in ipairs({1,3,18,40}) do
        local figure = Shape.create("rectangle", unpack(bounds))
        figure.width = width
        local actual, expected = FakeBB.new(96,88), FakeBB.new(96,88)
        local calls = 0
        local paint = actual.paintRect
        actual.paintRect = function(self, ...)
            calls = calls+1
            return paint(self, ...)
        end
        local clip = {x=5,y=7,w=80,h=70}
        GeometryInk.draw(actual, figure, clip, 0, false)
        local r = width/2
        for y=math.max(7,math.ceil(figure.y_min-r)),math.min(76,math.floor(figure.y_max+r)) do
            for x=5,84 do
                local edge = y<=figure.y_min+r or y>=figure.y_max-r
                    or x<=math.floor(figure.x_min+r) or x>=math.ceil(figure.x_max-r)
                if edge and x>=math.ceil(figure.x_min-r) and x<=math.floor(figure.x_max+r) then
                    expected:set(x,y,0)
                end
            end
        end
        for y=0,87 do for x=0,95 do
            assert(actual:get(x,y)==expected:get(x,y), "rectangle coverage changed")
        end end
        assert(calls<=4, "rectangle still paints one row at a time")
    end
end
-- Recognized marker figures keep their blend semantics at normal and 2x
-- scale: geometric shortcuts must not turn the marker into opaque black ink.
for _, scale in ipairs({1,2}) do
    local marker = Shape.create("rectangle", 20,20,60,60,8,0)
    marker.tool, marker.tint = "highlighter", 160
    local bb = FakeBB.new(160,160)
    bb:paintRect(0,20*scale,160,1,70)
    Renderer.drawPage(bb, {strokes={marker}}, scale)
    assert(bb:get(40*scale,20*scale)==70, "marker shape erased darker ruling")
    assert(bb:get(40*scale,21*scale)==160, "marker shape became opaque pen ink")
end
print("geometric figures retain primitive rasterization at 2x")
