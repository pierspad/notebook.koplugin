package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()
local HighlightInk = require("highlightink")
local FakeBB = support.FakeBB

local function check(x0, y0, x1, y1, r0, r1, steps, first, last)
    local actual, reference = FakeBB.new(96, 88), FakeBB.new(96, 88)
    -- Ink and a gray paper rule must survive the idempotent marker blend.
    for x = 0, 95 do
        actual:set(x, 32, 100)
        reference:set(x, 32, 100)
    end
    for i = first, last do
        local t = i / steps
        HighlightInk.stamp(reference, x0+(x1-x0)*t, y0+(y1-y0)*t,
            r0+(r1-r0)*t, 160)
    end
    HighlightInk.drawSegment(actual, x0, y0, r0, x1, y1, r1,
        160, first, last, steps)
    for y = 0, 87 do
        for x = 0, 95 do
            assert(actual:get(x,y) == reference:get(x,y),
                string.format("marker differs at (%d,%d) for (%d,%d)-(%d,%d)",
                    x,y,x0,y0,x1,y1))
        end
    end
end

for _, points in ipairs({
    {10,10,80,70}, {80,10,10,70}, {5,45,92,45},
    {-8,2,90,85}, {40,-9,40,100}, {80,70,6,3},
}) do
    for _, radius in ipairs({3, 8, 16, 24}) do
        local x0,y0,x1,y1 = unpack(points)
        local dist = math.sqrt((x1-x0)^2+(y1-y0)^2)
        local steps = math.max(1, math.ceil(dist/math.max(2,math.floor(radius*0.8))))
        check(x0,y0,x1,y1,radius,radius,steps,0,steps)
        check(x0,y0,x1,y1,radius,radius,steps,
            math.floor(steps/4), math.ceil(steps*3/4))
    end
end
check(10,10,85,40,8,20,13,0,13)
check(85,40,10,10,20,8,13,0,13)
math.randomseed(1741)
for _ = 1, 120 do
    local x0, y0 = math.random(-15,105), math.random(-15,100)
    local x1, y1 = math.random(-15,105), math.random(-15,100)
    local r0, r1 = math.random(2,25), math.random(2,25)
    local dist = math.sqrt((x1-x0)^2+(y1-y0)^2)
    local steps = math.max(1, math.ceil(dist/math.max(2,math.floor(math.min(r0,r1)*0.8))))
    check(x0,y0,x1,y1,r0,r1,steps,0,steps)
end
print("marker raster matches overlapping stamps and preserves dark ink")

-- Fractional coordinates/widths, clipping and reversed paths exercise the
-- direct constant-width scanline bounds against independent square stamping.
for _=1,600 do
    local x0,y0=math.random(-400,1000)/10,math.random(-400,1000)/10
    local x1,y1=math.random(-400,1000)/10,math.random(-400,1000)/10
    local radius=math.random(20,350)/10
    local steps=math.max(1,math.ceil(math.sqrt((x1-x0)^2+(y1-y0)^2)/math.max(2,math.floor(radius*.8))))
    local first,last=math.random(0,math.floor(steps/2)),math.random(math.ceil(steps/2),steps)
    check(x0,y0,x1,y1,radius,radius,steps,first,last)
    local actual,mask=FakeBB.new(96,88),FakeBB.new(96,88)
    for i=first,last do
        local t=i/steps
        HighlightInk.stamp(mask,x0+(x1-x0)*t,y0+(y1-y0)*t,radius,0)
    end
    HighlightInk.drawSegment(actual,x0,y0,radius,x1,y1,radius,160,first,last,steps,true)
    for y=0,87 do for x=0,95 do
        local expected=mask:get(x,y)==0 and (x+y)%4==0 and 0 or 255
        assert(actual:get(x,y)==expected,'binary marker scanline changed coverage')
    end end
end
print('marker: 600 fractional/clipped/reversed sweeps and binary previews match reference stamps')
