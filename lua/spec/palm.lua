#!/usr/bin/env luajit
--[[--
Tests for telling the pen from the hand resting on the panel.

The panel and the digitizer are two input devices sharing one slot table, and a
frame from the hand regularly arrives without saying which slot it belongs to --
so the framework writes the hand's position into the slot the pen is using and
hands it to the plugin as the nib. By the time it reaches here there is nothing
in the event to tell them apart, which is why this is tested on the only thing
left: how far the contact claims to have moved, and how quickly.

Run with:  luajit spec/palm.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
uistubs.install({})

-- A clock the tests drive, in milliseconds. The canvas measures elapsed time to
-- decide what speed a sample implies, so the tests have to own it: at a real
-- clock's mercy, the same sample is an outlier or not depending on how busy the
-- machine was.
local clock = { ms = 0 }
package.loaded["ui/time"] = {
    now = function() return clock.ms end,
    to_ms = function(t) return t end,
}

local Device = package.loaded["device"]
Device.screen.bb = support.FakeBB.new(600, 800)
Device.screen.refreshFast = function() end
Device.screen.refreshUI = function() end
Device.input = {
    TOOL_TYPE_FINGER = 0,
    TOOL_TYPE_PEN = 1,
    TOOL_TYPE_ERASER = 2,
    TOOL_TYPE_HIGHLIGHTER = 3,
    registerStylusCallback = function() end,
    unregisterStylusCallback = function() end,
}

local Canvas = require("canvas")
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

--- A canvas over an empty notebook, with the clock back at zero.
local function newCanvas()
    clock.ms = 0
    local doc = Document:new("/tmp/palm.scribe")
    local canvas = Canvas:new{ document = doc }
    return canvas, doc
end

--- Moves the clock on, the way a gap between two samples would.
local function after(ms)
    clock.ms = clock.ms + ms
end

io.write("a hand landing while the pen is writing\n")

test("a sample from across the page is not joined to the stroke", function()
    local canvas = newCanvas()
    canvas:_beginStroke("pen", 100, 100, 1)
    after(10)
    canvas:_extendStroke(110, 104, 1)
    assertEq(canvas.stroke:count(), 2, "points after a plain move")

    -- The hand, half a page away, arriving as though it were the nib.
    after(10)
    canvas:_extendStroke(120, 700, 1)
    assertEq(canvas.stroke:count(), 2, "the contamination was drawn")
    assertEq(canvas.last_x, 110, "the stroke followed the hand")
end)

test("writing carries on where it left off, rather than being cut in two", function()
    local canvas = newCanvas()
    canvas:_beginStroke("pen", 100, 100, 1)
    after(10)
    canvas:_extendStroke(120, 700, 1)
    after(10)
    canvas:_extendStroke(108, 104, 1)
    assertEq(canvas.stroke:count(), 2, "the pen's own sample was refused too")
    assertEq(canvas.last_y, 104, "the stroke did not follow the pen")
end)

test("a slow move over the same distance is the pen, and is drawn", function()
    local canvas = newCanvas()
    canvas:_beginStroke("pen", 100, 100, 1)
    -- Far, but over long enough that a hand could have carried the pen there.
    after(500)
    canvas:_extendStroke(100, 700, 1)
    assertEq(canvas.stroke:count(), 2, "a deliberate long stroke was refused")
end)

test("a position that keeps being reported is believed in the end", function()
    local canvas, doc = newCanvas()
    canvas:_beginStroke("pen", 100, 100, 1)
    -- The same far position over and over is not contamination interleaved with
    -- the pen's own samples: it is where the contact now is.
    for i = 1, 12 do
        after(8)
        canvas:_extendStroke(500, 700 + i, 1)
    end
    assertTrue(#doc.pages[1].strokes >= 1, "the first stroke was never committed")
    assertTrue(canvas.stroke ~= nil, "no stroke was started at the new position")
    assertEq(canvas.last_x, 500, "the new position was never taken up")
end)

io.write("seeing where the marker is going\n")

test("the marker shows darker while it moves, and settles back afterwards", function()
    local canvas, doc = newCanvas()
    local bb = Device.screen.bb

    -- A first pass, taken all the way through to the settled tint.
    canvas:_beginStroke("highlighter", 100, 100, 1)
    after(10)
    canvas:_extendStroke(200, 100, 1)
    canvas:_endStroke()
    local settled = bb:get(150, 100)
    assertTrue(settled < 255, "the marker left nothing at all")
    assertEq(#doc.pages[1].strokes, 1, "the pass was not recorded")

    -- Going back over it: while the tip is moving the band has to darken, or
    -- there is no way to see where the marker is over ink already highlighted.
    canvas:_beginStroke("highlighter", 100, 100, 1)
    after(10)
    canvas:_extendStroke(200, 100, 1)
    assertTrue(bb:get(150, 100) < settled,
        "the second pass is invisible: nothing shows under the tip")

    -- And when it lifts, the two passes are the same flat gray again.
    canvas:_endStroke()
    assertEq(bb:get(150, 100), settled, "the darker tint outlived the stroke")
    for _, stroke in ipairs(doc.pages[1].strokes) do
        assertEq(stroke.tint, nil, "the live tint was stored on the stroke")
    end
end)

io.write("a hand landing while the eraser is sweeping\n")

--- A horizontal line, as a page to rub at.
local function lineDoc(y, x0, x1)
    local doc = Document:new("/tmp/palm-e.scribe")
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    for x = x0, x1, 4 do stroke:addPoint(x, y, 1) end
    table.insert(doc.pages[1].strokes, stroke)
    return doc
end

test("the rubber is not swept across everything between the nib and the hand", function()
    clock.ms = 0
    local doc = lineDoc(400, 50, 550)
    local canvas = Canvas:new{ document = doc }

    canvas:_eraseAlong(100, 700)
    assertEq(#doc.pages[1].strokes, 1, "the fixture starts on top of the line")

    -- Straight through the line, if the jump were believed.
    after(10)
    canvas:_eraseAlong(100, 60)
    assertEq(#doc.pages[1].strokes, 1, "the sweep followed the hand and took the line")
    assertEq(canvas.last_erase_y, 700, "the rubber moved to where the hand was")
end)

test("a sweep that is really a sweep still erases", function()
    clock.ms = 0
    local doc = lineDoc(400, 50, 550)
    local canvas = Canvas:new{ document = doc }

    canvas:_eraseAlong(100, 380)
    after(10)
    canvas:_eraseAlong(100, 420)
    assertEq(#doc.pages[1].strokes, 0, "a short, plausible sweep did not erase")
end)

io.write("stylus slot filtering and gestures\n")

test("non-stylus and finger slot events are rejected by onStylusEvent", function()
    local canvas = newCanvas()
    -- Finger slot event (tool == 0)
    local ret = canvas:onStylusEvent{ slot = 4, tool = Device.input.TOOL_TYPE_FINGER, x = 100, y = 100, id = 1 }
    assertEq(ret, false, "finger tool should be rejected")
    -- Unset tool (nil)
    ret = canvas:onStylusEvent{ slot = 4, tool = nil, x = 100, y = 100, id = 1 }
    assertEq(ret, false, "nil tool should be rejected")
    -- Genuine pen (tool == 1)
    ret = canvas:onStylusEvent{ slot = 4, tool = Device.input.TOOL_TYPE_PEN, x = 100, y = 100, id = 1 }
    assertEq(ret, true, "pen tool should be accepted")
    assertTrue(canvas.pen_down, "pen_down should be true")
    -- Release pen
    ret = canvas:onStylusEvent{ slot = 4, tool = Device.input.TOOL_TYPE_PEN, id = -1 }
    assertEq(canvas.pen_down, false, "pen_down should be false after release")
end)

test("finger swipes turn page when pen is up", function()
    local canvas = newCanvas()
    local turned = 0
    canvas.on_page_swipe = function(delta) turned = turned + delta end

    canvas:onPageSwipe(nil, { direction = "west" })
    assertEq(turned, 1, "swipe west should go forward (+1)")

    canvas:onPageSwipe(nil, { direction = "east" })
    assertEq(turned, 0, "swipe east should go backward (-1)")

    canvas:onPageSwipe(nil, { direction = "northwest" })
    assertEq(turned, 1, "swipe northwest should go forward (+1)")

    -- Pan drag release turns page
    canvas:onTouchStart(nil, { pos = { x = 400, y = 200 } })
    canvas:onTouchPan(nil, { pos = { x = 200, y = 205 } })
    canvas:onTouchRelease(nil, { pos = { x = 200, y = 205 } })
    assertEq(turned, 2, "pan drag left should go forward (+1)")
end)

io.write("dragging a selection\n")

--[[
Moving a selection repaints the region it left and the region it now covers,
which means re-rasterising every stroke overlapping either. Done once per pen
sample that is far more of it than the panel can show, and the selection falls
behind the nib. These pin down that the work is coalesced, and -- much more
importantly -- that coalescing it does not lose any of the movement.
--]]
local function draggingCanvas()
    local canvas, doc = newCanvas()
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    stroke:addPoint(100, 100, 1)
    stroke:addPoint(140, 160, 1)
    doc:getPage().strokes = { stroke }

    canvas.dragging_selection = true
    canvas.selected_strokes = { stroke }
    canvas.selection_bbox = { x = 100, y = 100, w = 40, h = 60 }
    canvas.drag_last_x, canvas.drag_last_y = 200, 200

    local repaints, last = 0, nil
    canvas._repaintRegion = function(_, x, y, w, h)
        repaints = repaints + 1
        last = { x = x, y = y, w = w, h = h }
    end
    canvas.settled = nil
    Device.screen.refreshUI = function(_, x, y, w, h)
        canvas.settled = { x = x, y = y, w = w, h = h }
    end
    canvas._showLassoMenu = function() end

    return canvas, stroke, function() return repaints end, function() return last end
end

test("a burst of samples inside one interval repaints once", function()
    local canvas, _, repaints = draggingCanvas()

    -- Ten samples two milliseconds apart: a fifth of the throttling interval
    -- covering movement that used to cost ten repaints.
    for i = 1, 10 do
        after(2)
        canvas:_extendStroke(200 + i, 200 + i, 1)
    end

    assertEq(repaints(), 1, "repaints for ten samples in twenty milliseconds")
end)

test("coalescing loses none of the movement", function()
    local canvas, stroke = draggingCanvas()
    local x0 = stroke.x_min

    for i = 1, 10 do
        after(2)
        canvas:_extendStroke(200 + i, 200 + i, 1)
    end
    -- The pen lifts, which is what flushes whatever the interval had not
    -- reached yet.
    canvas:_endStroke()

    assertEq(stroke.x_min - x0, 10, "total travel applied to the strokes")
end)

test("the selection box travels with the strokes, and does not grow", function()
    local canvas = draggingCanvas()

    for i = 1, 10 do
        after(2)
        canvas:_extendStroke(200 + i, 200 + i, 1)
    end
    canvas:_endStroke()

    assertEq(canvas.selection_bbox.x, 110, "box left edge")
    assertEq(canvas.selection_bbox.w, 40, "box width -- a moved selection keeps its shape")
end)

--[[
The dashed frame is drawn outside the selection, not on it. A repaint covering
only the selection's own bounds therefore repaints everything except the frame
around it, and the frame stays where it was -- once per step, which at a step of
a whole interval is a visible trail across the page.
--]]
test("the repainted region covers the frame the selection is leaving behind", function()
    local canvas, _, _, region = draggingCanvas()

    after(100)
    canvas:_extendStroke(260, 260, 1)

    local box = region()
    assertTrue(box ~= nil, "nothing was repainted at all")
    -- The selection started at (100, 100) and its frame a little outside that.
    assertTrue(box.x < 100, "left edge at " .. box.x .. " leaves the old frame on screen")
    assertTrue(box.y < 100, "top edge at " .. box.y .. " leaves the old frame on screen")
end)

--[[
The copies trailing behind a dragged selection are the panel, not the buffer: a
fast refresh leaves a faint remainder of what a pixel held before, and a drag
makes one per step. They clear with a refresh that settles the pixels, which is
too slow to use on every step and is therefore paid for once, when the pen comes
up, over everywhere the selection has been.
--]]
test("lifting the pen settles everywhere the selection has been", function()
    local canvas = draggingCanvas()

    after(100)
    canvas:_extendStroke(300, 300, 1)
    after(100)
    canvas:_extendStroke(500, 500, 1)
    canvas:_endStroke()

    local settled = canvas.settled
    assertTrue(settled ~= nil, "the trail was never cleared")
    -- From where the selection started, at (100, 100), to where it ended up,
    -- three hundred pixels along and forty by sixty in size.
    assertTrue(settled.x < 100, "left edge at " .. settled.x)
    assertTrue(settled.x + settled.w >= 440, "right edge at " .. (settled.x + settled.w))
    assertTrue(settled.y + settled.h >= 460, "bottom edge at " .. (settled.y + settled.h))
end)

test("samples spread over time still repaint as they come", function()
    local canvas, _, repaints = draggingCanvas()

    for i = 1, 4 do
        after(100)
        canvas:_extendStroke(200 + i, 200 + i, 1)
    end

    assertEq(repaints(), 4, "repaints for four samples a tenth of a second apart")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

