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

test("detects and snaps regular triangle from 3-sided loop", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    -- Bottom
    for x = 100, 300, 20 do s:addPoint(x, 300, 1) end
    -- Up to apex
    for t = 0, 1, 0.1 do s:addPoint(300 - t * 100, 300 - t * 200, 1) end
    -- Down to start
    for t = 0, 1, 0.1 do s:addPoint(200 - t * 100, 100 + t * 200, 1) end

    local clean, kind = Shape.recognize(s)
    assertTrue(clean ~= nil, "should recognize triangle")
    assertEq(kind, "triangle", "shape kind")
    assertEq(clean:count(), 4, "triangle closed points")

    -- Verify the 3 sides are geometrically regular (equal distance from centroid)
    local x1, y1 = clean:getPoint(1)
    local x2, y2 = clean:getPoint(2)
    local x3, y3 = clean:getPoint(3)
    local cx = (x1 + x2 + x3) / 3
    local cy = (y1 + y2 + y3) / 3
    local r1 = math.sqrt((x1 - cx)^2 + (y1 - cy)^2)
    local r2 = math.sqrt((x2 - cx)^2 + (y2 - cy)^2)
    local r3 = math.sqrt((x3 - cx)^2 + (y3 - cy)^2)
    assertTrue(math.abs(r1 - r2) < 2, "r1 == r2 in regular triangle")
    assertTrue(math.abs(r2 - r3) < 2, "r2 == r3 in regular triangle")
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

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
