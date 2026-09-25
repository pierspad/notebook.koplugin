#!/usr/bin/env luajit
--[[--
Comprehensive tests for geometric shape recognition and snapping.

Run with:  luajit spec/shape.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local Stroke = require("stroke")
local Shape = require("shape")

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

io.write("shape recognition and geometry snapping\n")

test("explicit triangle keeps rectangular drag bounds and black ink", function()
    local triangle = Shape.create("triangle", 20, 30, 220, 130, 3, 0)
    assertTrue(triangle, "triangle")
    assertEq(triangle.shape_kind, "triangle", "kind")
    assertEq(triangle.color, 0, "color")
    assertEq(triangle:count(), 4, "closed vertices")
    assertEq(triangle.x_min, 20, "left")
    assertEq(triangle.x_max, 220, "right")
    assertEq(triangle.y_min, 30, "top")
    assertEq(triangle.y_max, 130, "bottom")
end)

test("edge resize and rotation use the original figure", function()
    local triangle = Shape.create("triangle", 100, 100, 300, 200, 3, 0)
    local wider = Shape.transform(triangle, "e", 400, 150, 300, 150)
    assertEq(wider.x_min, 100, "fixed left edge")
    assertEq(wider.x_max, 400, "moved right edge")
    assertEq(triangle.x_max, 300, "original unchanged")
    local rotated = Shape.transform(triangle, "rotate", 200, 250, 350, 150)
    assertEq(rotated.shape_kind, "triangle", "kind retained")
    assertTrue(rotated.y_max > triangle.y_max, "rotation moved vertices")
    assertEq(rotated:count(), triangle:count(), "points retained")
end)

test("detects straight line from imperfect freehand stroke", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    for x = 100, 500, 10 do
        local noise = math.sin(x / 20) * 3
        s:addPoint(x, 200 + noise, 1)
    end
    local clean, kind = Shape.recognize(s)
    assertTrue(clean ~= nil, "should recognize line")
    assertEq(kind, "line", "shape kind")
    assertEq(clean:count(), 2, "clean line point count")
    local x1, y1 = clean:getPoint(1)
    local x2, y2 = clean:getPoint(2)
    assertEq(x1, 100, "start x")
    assertEq(x2, 500, "end x")
end)

test("detects diagonal and vertical straight lines", function()
    -- Vertical line
    local s_vert = Stroke:new{ tool = "pen", width = 3 }
    for y = 100, 600, 15 do
        s_vert:addPoint(300 + ((y % 30 == 0) and 2 or -2), y, 1)
    end
    local clean_v, kind_v = Shape.recognize(s_vert)
    assertTrue(clean_v ~= nil, "should recognize vertical line")
    assertEq(kind_v, "line", "shape kind")

    -- Diagonal line (45 deg)
    local s_diag = Stroke:new{ tool = "pen", width = 3 }
    for i = 100, 500, 15 do
        s_diag:addPoint(i + 2, i - 2, 1)
    end
    local clean_d, kind_d = Shape.recognize(s_diag)
    assertTrue(clean_d ~= nil, "should recognize diagonal line")
    assertEq(kind_d, "line", "shape kind")
end)

test("detects circle from rough freehand loop", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    local cx, cy, r = 300, 400, 100
    for deg = 0, 360, 10 do
        local rad = math.rad(deg)
        local jitter = (deg % 20 == 0) and 4 or -4
        s:addPoint(cx + (r + jitter) * math.cos(rad), cy + (r + jitter) * math.sin(rad), 1)
    end
    local clean, kind = Shape.recognize(s)
    assertTrue(clean ~= nil, "should recognize circle")
    assertEq(kind, "circle", "shape kind")
    assertTrue(clean:count() > 20, "circle points")
end)

test("detects horizontal and rotated rectangles", function()
    -- Axis-aligned rectangle
    local s = Stroke:new{ tool = "pen", width = 3 }
    for x = 100, 400, 20 do s:addPoint(x, 100, 1) end
    for y = 100, 250, 20 do s:addPoint(400, y, 1) end
    for x = 400, 100, -20 do s:addPoint(x, 250, 1) end
    for y = 250, 100, -20 do s:addPoint(100, y, 1) end

    local clean, kind = Shape.recognize(s)
    assertTrue(clean ~= nil, "should recognize rectangle")
    assertTrue(kind == "rectangle" or kind == "square", "shape kind")
    assertEq(clean:count(), 5, "rectangle closed points")

    -- Rotated 45-degree rectangle (diamond / rotated box)
    local s_rot = Stroke:new{ tool = "pen", width = 3 }
    local theta = math.rad(45)
    local cos_t, sin_t = math.cos(theta), math.sin(theta)
    local function rotPt(lx, ly)
        return 400 + lx * cos_t - ly * sin_t, 400 + lx * sin_t + ly * cos_t
    end
    for lx = -100, 100, 20 do local x, y = rotPt(lx, -50); s_rot:addPoint(x, y, 1) end
    for ly = -50, 50, 20 do local x, y = rotPt(100, ly); s_rot:addPoint(x, y, 1) end
    for lx = 100, -100, -20 do local x, y = rotPt(lx, 50); s_rot:addPoint(x, y, 1) end
    for ly = 50, -50, -20 do local x, y = rotPt(-100, ly); s_rot:addPoint(x, y, 1) end

    local clean_rot, kind_rot = Shape.recognize(s_rot)
    assertTrue(clean_rot ~= nil, "should recognize rotated rectangle")
    assertEq(clean_rot:count(), 5, "rotated rectangle closed points")
end)

--- The corner of `clean` nearest (x, y), and how far off it is.
local function nearestVertex(clean, x, y)
    local best = math.huge
    for i = 1, clean:count() do
        local vx, vy = clean:getPoint(i)
        local d = math.sqrt((vx - x)^2 + (vy - y)^2)
        if d < best then best = d end
    end
    return best
end

test("leaves triangles as freehand ink", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    -- Bottom
    for x = 100, 300, 20 do s:addPoint(x, 300, 1) end
    -- Up to apex
    for t = 0, 1, 0.1 do s:addPoint(300 - t * 100, 300 - t * 200, 1) end
    -- Down to start
    for t = 0, 1, 0.1 do s:addPoint(200 - t * 100, 100 + t * 200, 1) end

    local clean, kind = Shape.recognize(s)
    assertEq(clean, nil, "triangles stay freehand")
    assertEq(kind, nil, "unsupported geometry has no shape metadata")
end)

test("regularizes a trapezium to an axis-aligned rectangle", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    -- A trapezium: wide base, narrow top, sloping sides.
    for x = 100, 400, 20 do s:addPoint(x, 300, 1) end
    for t = 0, 1, 0.1 do s:addPoint(400 - t * 80, 300 - t * 150, 1) end
    for x = 320, 180, -20 do s:addPoint(x, 150, 1) end
    for t = 0, 1, 0.1 do s:addPoint(180 - t * 80, 150 + t * 150, 1) end

    local clean, kind = Shape.recognize(s)
    assertTrue(clean ~= nil, "should recognize a four-sided shape")
    assertEq(kind, "rectangle", "sloping sides become a regular rectangle")
    assertEq(clean:count(), 5, "rectangle is closed")
    for i=1,4 do
        local x0,y0=clean:getPoint(i)
        local x1,y1=clean:getPoint(i+1)
        assertTrue(x0==x1 or y0==y1, "edges are horizontal or vertical")
    end
end)

test("filters micro-jitter clusters when pen is held stationary at end of stroke", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    for x = 100, 500, 20 do
        s:addPoint(x, 200, 1)
    end
    -- Add 40 stationary points with 1px hand tremor
    for i = 1, 40 do
        s:addPoint(500 + (i % 2), 200 + ((i + 1) % 2), 1)
    end

    local clean, kind = Shape.recognize(s)
    assertTrue(clean ~= nil, "should recognize line despite holding still")
    assertEq(kind, "line", "shape kind")
    assertEq(clean:count(), 2, "clean line point count without tail smudges")
end)

test("rejects squiggly random handwriting and open spirals", function()
    local s1 = Stroke:new{ tool = "pen", width = 3 }
    s1:addPoint(100, 100, 1)
    s1:addPoint(120, 150, 1)
    s1:addPoint(110, 130, 1)
    s1:addPoint(140, 180, 1)
    s1:addPoint(130, 160, 1)
    local clean1, _ = Shape.recognize(s1)
    assertEq(clean1, nil, "should not recognize arbitrary handwriting as shape")

    -- Open spiral
    local s2 = Stroke:new{ tool = "pen", width = 3 }
    for deg = 0, 720, 15 do
        local rad = math.rad(deg)
        local r = 20 + deg * 0.2
        s2:addPoint(300 + r * math.cos(rad), 300 + r * math.sin(rad), 1)
    end
    local clean2, _ = Shape.recognize(s2)
    assertEq(clean2, nil, "should not recognize open spiral as circle or polygon")
end)

test("gracefully handles very short strokes", function()
    assertEq(Shape.recognize(nil), nil, "nil stroke")
    local s_tiny = Stroke:new{ tool = "pen", width = 3 }
    s_tiny:addPoint(100, 100, 1)
    s_tiny:addPoint(102, 101, 1)
    assertEq(Shape.recognize(s_tiny), nil, "tiny stroke length < 25px")
end)

test("line snap can add an arrowhead without changing the raw stroke", function()
    local s = Stroke:new{ width = 3 }
    for x = 100, 500, 10 do s:addPoint(x, 200, 1) end
    local line, line_kind = Shape.recognize(s, "line")
    local arrow, kind = Shape.recognize(s, "arrow")
    assertEq(line_kind, "line", "ordinary line")
    assertEq(line:count(), 2, "line vertices")
    assertEq(kind, "arrow", "arrow mode")
    assertTrue(arrow:count() >= 5, "arrowhead missing")
    local x, y = arrow:getPoint(2)
    assertEq(x, 500, "tip x")
    assertEq(y, 200, "tip y")
    assertEq(s:count(), 41, "raw stroke was changed")
end)

test("circle recognition tolerates a slow quarter and an imperfect closure", function()
    local s = Stroke:new{width=3}
    for i=0,200 do
        local angle = (i/200)^2 * math.pi * 1.97
        local r = 100 + 3*math.sin(angle*5)
        s:addPoint(250+r*math.cos(angle),300+r*math.sin(angle))
    end
    local clean, kind = Shape.recognize(s)
    assertEq(kind,"circle","unevenly sampled circle")
    assertTrue(math.abs(clean.x_min-150)<8,"centre shifted towards slow samples")
end)

test("curved arrows retain their shaft and end with a tangent arrowhead", function()
    local s = Stroke:new{width=3}
    for i=0,100 do
        s:addPoint(100+i*3,200+80*math.sin(i*math.pi/100)+math.sin(i*2))
    end
    local clean, kind = Shape.recognize(s,"arrow")
    assertEq(kind,"arrow","curved arrow")
    assertTrue(clean.y_max>270,"curve flattened")
    local x,y = clean:getPoint(clean.n-3)
    assertEq(x,400,"tip remains at endpoint")
    assertTrue(math.abs(y-s.pts[(s.n-1)*3+2])<.01,"endpoint moved")
    assertTrue(clean.n<s.n,"smoothing should reduce the point count")
end)

test("an almost closed loop stays an arrow when its endpoints do not touch", function()
    local s=Stroke:new{width=4}
    for i=0,94 do
        local a=i/100*2*math.pi
        s:addPoint(300+120*math.cos(a),400+120*math.sin(a))
    end
    local clean,kind=Shape.recognize(s,"arrow")
    assertEq(kind,"arrow","almost-circle arrow")
    assertTrue(clean and clean:count()>8,"curved shaft was replaced by a primitive")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
