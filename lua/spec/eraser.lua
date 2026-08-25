#!/usr/bin/env luajit
--[[--
Tests for erasing along the path the hand actually travelled.

The eraser is reported to the plugin as a handful of positions per contact, far
apart when the hand moves quickly. What is checked here is that what gets rubbed
out is the continuous shape swept between those positions, and not just what
happened to be sitting under the few points the digitizer chose to report.

Run with:  luajit spec/eraser.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()

local Document = require("document")
local Stroke = require("stroke")

-- Test framework ---------------------------------------------------------------

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

--- A stroke along a horizontal line.
local function lineStroke(y, x0, x1)
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    for x = x0, x1, 4 do stroke:addPoint(x, y, 1) end
    return stroke
end

local function docWith(...)
    local doc = Document:new("/tmp/e.scribe")
    for _, stroke in ipairs({ ... }) do
        table.insert(doc.pages[1].strokes, stroke)
    end
    return doc
end

local R = 12

-- Whole strokes ------------------------------------------------------------------

io.write("erasing whole strokes\n")

test("a quick sweep takes out what it passed over, not just where it was sampled", function()
    -- Two reported positions, 400 pixels apart, with the stroke in between them.
    -- This is the case the old point-at-a-time eraser missed entirely: neither
    -- endpoint is anywhere near the line.
    local doc = docWith(lineStroke(300, 100, 500))
    local path = { 300, 100, 300, 500 }

    assertTrue(not doc.pages[1].strokes[1]:hitTest(path[1], path[2], R),
        "the fixture is wrong: the first sample already touches the stroke")
    assertTrue(not doc.pages[1].strokes[1]:hitTest(path[3], path[4], R),
        "the fixture is wrong: the last sample already touches the stroke")

    local removed = doc:eraseAlongPath(path, R)
    assertTrue(removed ~= nil, "the sweep passed straight through the line")
    assertEq(#doc.pages[1].strokes, 0, "strokes left")
end)

test("a sweep leaves alone what it did not pass over", function()
    local doc = docWith(lineStroke(300, 100, 500), lineStroke(900, 100, 500))
    doc:eraseAlongPath({ 300, 100, 300, 500 }, R)
    assertEq(#doc.pages[1].strokes, 1, "strokes left")
    assertEq(doc.pages[1].strokes[1]:getPoint(1), 100, "the wrong stroke went")
end)

test("a sweep that misses everything reports nothing", function()
    local doc = docWith(lineStroke(300, 100, 500))
    assertTrue(doc:eraseAlongPath({ 900, 100, 900, 500 }, R) == nil,
        "reported a removal that did not happen")
    assertEq(#doc.pages[1].strokes, 1, "strokes left")
end)

test("one sweep is one thing to undo, however far it travelled", function()
    local doc = docWith(lineStroke(300, 100, 500), lineStroke(320, 100, 500))
    doc:beginBatch()
    doc:eraseAlongPath({ 300, 100, 300, 300 }, R)
    doc:eraseAlongPath({ 300, 300, 310, 500 }, R)
    doc:commitBatch(0, 0, 1000, 1000)
    assertEq(#doc.pages[1].strokes, 0, "strokes left")

    doc:undo()
    assertEq(#doc.pages[1].strokes, 2, "one undo did not bring the sweep back")
end)

-- Rubbing out an area ---------------------------------------------------------------

io.write("rubbing out an area\n")

--- The smallest distance from any point of any stroke to the path.
local function closestApproach(doc, path)
    local best = math.huge
    for _, stroke in ipairs(doc.pages[1].strokes) do
        for i = 1, stroke:count() do
            local x, y = stroke:getPoint(i)
            for j = 1, #path - 3, 2 do
                -- Distance to the segment, computed the plain way.
                local ax, ay = path[j], path[j + 1]
                local bx, by = path[j + 2], path[j + 3]
                local dx, dy = bx - ax, by - ay
                local len = dx * dx + dy * dy
                local t = len > 0 and ((x - ax) * dx + (y - ay) * dy) / len or 0
                t = math.max(0, math.min(1, t))
                local ex, ey = x - (ax + t * dx), y - (ay + t * dy)
                best = math.min(best, math.sqrt(ex * ex + ey * ey))
            end
        end
    end
    return best
end

test("a sweep rubs out a continuous piece, not a dotted line of bites", function()
    -- A line crossed at a shallow angle by a fast sweep. Anything left behind
    -- must be clear of the whole path, not merely clear of its endpoints.
    local doc = docWith(lineStroke(300, 0, 800))
    local path = { 100, 260, 700, 340 }

    local hit = doc:eraseAreaAlongPath(path, R)
    assertTrue(hit, "nothing was rubbed out")
    assertTrue(#doc.pages[1].strokes > 0, "the whole line went, not just the part swept")

    local closest = closestApproach(doc, path)
    assertTrue(closest > R - 1,
        string.format("a piece survived %.1f from the path, inside the %d rubber",
            closest, R))
end)

test("rubbing out the middle of a line leaves two lines", function()
    local doc = docWith(lineStroke(300, 0, 800))
    doc:eraseAreaAlongPath({ 400, 300, 405, 300 }, R)
    assertEq(#doc.pages[1].strokes, 2, "pieces left")
end)

test("what is left keeps the tool it was drawn with", function()
    local stroke = lineStroke(300, 0, 800)
    stroke.tool = "highlighter"
    stroke.width = 24
    local doc = docWith(stroke)
    doc:eraseAreaAlongPath({ 400, 300, 405, 300 }, R)
    for _, fragment in ipairs(doc.pages[1].strokes) do
        assertEq(fragment.tool, "highlighter", "tool")
        assertEq(fragment.width, 24, "width")
    end
end)

test("undo puts back exactly the line that was rubbed out", function()
    local doc = docWith(lineStroke(300, 0, 800))
    local original = doc.pages[1].strokes[1]
    doc:eraseAreaAlongPath({ 400, 300, 405, 300 }, R)
    doc:undo()
    assertEq(#doc.pages[1].strokes, 1, "strokes back")
    assertEq(doc.pages[1].strokes[1], original, "not the same stroke")
end)

test("a sweep across a page of strokes touches only what it crossed", function()
    local strokes = {}
    for i = 1, 10 do strokes[i] = lineStroke(100 + i * 60, 100, 500) end
    local doc = docWith((table.unpack or unpack)(strokes))
    assertEq(#doc.pages[1].strokes, 10, "fixture")

    -- Straight down through all of them. Each line is cut, so pieces survive on
    -- both sides of the column; what must not survive is anything inside it.
    local path = { 150, 140, 150, 720 }
    doc:eraseAreaAlongPath(path, R)
    assertTrue(#doc.pages[1].strokes > 10, "the lines were not cut, they were removed")

    local closest = closestApproach(doc, path)
    assertTrue(closest > R - 1,
        string.format("a piece survived %.1f into the swept column", closest))
end)

test("rubbing one end of a long line does not repaint the whole line", function()
    -- The two rectangles that come back are different things: what changed on
    -- screen, and what undo would have to put back. Handing the second to the
    -- repaint is what made this crawl -- a dab on a page-long stroke repainted
    -- everything the stroke spanned, from the vector model, on every sample.
    local doc = docWith(lineStroke(300, 0, 800))
    local hit, dx, dy, dw, dh, ux, uy, uw, uh =
        doc:eraseAreaAlongPath({ 40, 300, 60, 300 }, R)

    assertTrue(hit, "nothing was rubbed out")
    assertTrue(dw < 100, "the repaint is " .. dw .. " wide, for a 40-pixel rub")
    assertTrue(dh < 100, "the repaint is " .. dh .. " tall, for a 40-pixel rub")
    assertTrue(dx >= 0 and dy >= 0, "the repaint starts off the stroke")
    assertTrue(uw > 700, "the undo record does not cover the whole line")
    assertTrue(uh > 0, "the undo record has no height")
end)

test("the coarse index changes nothing about what survives", function()
    -- A long, folded stroke: its bounding box covers most of the page, so it is
    -- exactly the shape the per-run index exists for. What it must not do is
    -- change the answer.
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    for i = 0, 600 do
        stroke:addPoint(100 + i, 300 + math.floor(i / 40) % 2 * 200, 1)
    end
    local doc = docWith(stroke)

    -- Brute force, ignoring every index: which points should be left.
    local path = { 350, 280, 420, 520 }
    local wanted = {}
    for i = 1, stroke:count() do
        local x, y = stroke:getPoint(i)
        local best = math.huge
        for j = 1, #path - 3, 2 do
            local ax, ay, bx, by = path[j], path[j + 1], path[j + 2], path[j + 3]
            local ddx, ddy = bx - ax, by - ay
            local len = ddx * ddx + ddy * ddy
            local t = len > 0 and ((x - ax) * ddx + (y - ay) * ddy) / len or 0
            t = math.max(0, math.min(1, t))
            local ex, ey = x - (ax + t * ddx), y - (ay + t * ddy)
            best = math.min(best, math.sqrt(ex * ex + ey * ey))
        end
        if best > R then wanted[#wanted + 1] = { x, y } end
    end
    assertTrue(#wanted > 0 and #wanted < stroke:count(), "the fixture misses the stroke")

    doc:eraseAreaAlongPath(path, R)

    local got = {}
    for _, fragment in ipairs(doc.pages[1].strokes) do
        for i = 1, fragment:count() do
            local x, y = fragment:getPoint(i)
            got[#got + 1] = { x, y }
        end
    end
    assertEq(#got, #wanted, "surviving points")
    for i = 1, #wanted do
        assertEq(got[i][1], wanted[i][1], "point " .. i .. " x")
        assertEq(got[i][2], wanted[i][2], "point " .. i .. " y")
    end
end)

test("a fragment knows its own extent, not the one it was cut from", function()
    local doc = docWith(lineStroke(300, 0, 800))
    doc:eraseAreaAlongPath({ 400, 300, 405, 300 }, R)
    local first = doc.pages[1].strokes[1]
    local x, y, w, h = first:getBounds()
    assertTrue(w < 500, "the left-hand piece still claims the whole line: " .. w)
    assertTrue(y < 300 and y + h > 300, "the piece is not where the line was")
    assertTrue(x < 10, "the piece does not start where the line did")
end)

-- Rectangles ------------------------------------------------------------------------

io.write("rectangles\n")

local Rect = require("rect")

test("growing from nothing gives the rectangle itself", function()
    local box = Rect.grow(nil, 10, 20, 30, 40)
    assertEq(box.x, 10, "x") assertEq(box.y, 20, "y")
    assertEq(box.w, 30, "w") assertEq(box.h, 40, "h")
end)

test("growing covers both rectangles and no more", function()
    local box = Rect.grow(nil, 0, 0, 10, 10)
    Rect.grow(box, 90, 90, 10, 10)
    assertEq(box.x, 0, "x") assertEq(box.y, 0, "y")
    assertEq(box.w, 100, "w") assertEq(box.h, 100, "h")
end)

test("growing by something already inside changes nothing", function()
    local box = Rect.grow(nil, 0, 0, 100, 100)
    Rect.grow(box, 10, 10, 5, 5)
    assertEq(box.w, 100, "w") assertEq(box.h, 100, "h")
end)

test("clamping keeps what is inside the bounds", function()
    local bounds = { x = 0, y = 100, w = 200, h = 200 }
    local x, y, w, h = Rect.clamp(-50, 50, 100, 100, bounds)
    assertEq(x, 0, "x") assertEq(y, 100, "y")
    assertEq(w, 50, "w") assertEq(h, 50, "h")
end)

test("clamping something wholly outside gives nothing", function()
    local bounds = { x = 0, y = 100, w = 200, h = 200 }
    assertTrue(Rect.clamp(500, 500, 10, 10, bounds) == nil,
        "a rectangle outside the bounds came back")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
