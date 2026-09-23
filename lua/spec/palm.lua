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
local Tuning = require("tuning")
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

test("the moving marker uses visible throttled grayscale refreshes", function()
    local canvas = newCanvas()
    local fast,ui=0,0
    Device.screen.refreshFast=function() fast=fast+1 end
    Device.screen.refreshUI=function() ui=ui+1 end
    canvas:_beginStroke("highlighter",100,180,1)
    assertEq(canvas.refresh_mode,"ui","marker waveform")
    for i=1,12 do after(5); canvas:_extendStroke(100+i*8,180,1) end
    assertTrue(ui>=1,"the live marker was never shown")
    -- One immediate update, then no more than one per configured interval.
    local maximum=1+math.ceil(60/Tuning.live_highlight_refresh_ms)
    assertTrue(ui<=maximum,"grayscale refreshes were not throttled")
    assertEq(fast,0,"marker used the binary waveform")
    canvas:_endStroke()
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

io.write("what a slow hand puts down\n")

--[[--
The stroke keeps what was written, whatever speed it was written at.

Hold-to-snap needs to know when the nib has stopped moving, and its tolerance
for that was eight pixels. That tolerance was also, by accident, the test for
whether a sample joined the stroke at all: anything inside it was discarded, so
eight pixels stopped being a tolerance and became a sampling interval.
Handwriting came back as a chain of eight-pixel chords, and anything smaller
than that -- an accent, a comma, the bowl of a small letter -- came back as the
single dot the stroke had started with.
--]]
local function draw(canvas, points)
    canvas:_beginStroke("pen", points[1][1], points[1][2], 1)
    for i = 2, #points do
        after(8)
        canvas:_extendStroke(points[i][1], points[i][2], 1)
    end
    return canvas.stroke:count()
end

test("a slow, deliberate drag keeps every sample of itself", function()
    local canvas = newCanvas()
    local pts = {}
    for i = 0, 40 do table.insert(pts, { 100 + i * 2, 100 }) end
    assertEq(draw(canvas, pts), 41, "points kept from a 2px-per-sample drag")
end)

test("a mark smaller than the hold tolerance is still a mark", function()
    local canvas = newCanvas()
    -- A comma: six samples, none of them more than five pixels from where the
    -- nib landed.
    local n = draw(canvas, { {100,100}, {101,101}, {102,102}, {103,103},
                             {103,104}, {102,105}, {101,105} })
    assertTrue(n >= 4, "a comma collapsed to " .. n .. " point(s)")
end)

test("a small letter keeps its shape", function()
    local canvas = newCanvas()
    local pts = {}
    for i = 0, 24 do
        local a = i / 24 * 2 * math.pi
        table.insert(pts, { 200 + math.floor(7 * math.cos(a)),
                            200 + math.floor(7 * math.sin(a)) })
    end
    local n = draw(canvas, pts)
    assertTrue(n >= 12, "a 7px 'o' came back as " .. n .. " point(s)")

    -- And it is a loop, not a dot: it has to have some extent in both axes.
    local _, _, bw, bh = canvas.stroke:getBounds()
    assertTrue(bw >= 10 and bh >= 10, "the loop has no extent left")
end)

test("wobble under a resting nib is still not drawn", function()
    local canvas = newCanvas()
    canvas:_beginStroke("pen", 300, 300, 1)
    local before = canvas.stroke:count()
    -- The digitizer inventing a pixel either way while the pen rests.
    for i = 1, 20 do
        after(8)
        canvas:_extendStroke(300 + (i % 2), 300 + ((i + 1) % 2), 1)
    end
    assertEq(canvas.stroke:count(), before, "wobble was accumulated as ink")
end)

io.write("putting another tool on the page while something is selected\n")

test("drawing with the pen ends the selection", function()
    local canvas, doc = newCanvas()
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    stroke:addPoint(100, 100, 1)
    stroke:addPoint(140, 160, 1)
    doc:getPage().strokes = { stroke }

    -- What a closed lasso leaves behind: the strokes it caught, the frame
    -- around them, and the menu floating beside it.
    canvas.selected_strokes = { stroke }
    canvas.selection_bbox = { x = 100, y = 100, w = 40, h = 60 }
    canvas.lasso_menu = {}
    local UIManager = require("ui/uimanager")
    local was_close = UIManager.close
    local closed = {}
    UIManager.close = function(_, widget) table.insert(closed, widget) end

    canvas:_beginStroke("pen", 300, 400, 1)
    UIManager.close = was_close

    assertTrue(canvas.selected_strokes == nil, "the selection outlived the tool that made it")
    assertTrue(canvas.selection_bbox == nil, "the dashed frame is still claimed")
    assertTrue(canvas.lasso_menu == nil, "the lasso menu was left on screen")
    assertEq(#closed, 1, "widgets closed")
    assertTrue(canvas.stroke ~= nil, "the pen stroke was not started")
end)

test("the lasso itself still gets to pick the selection up", function()
    local canvas, doc = newCanvas()
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    stroke:addPoint(100, 100, 1)
    doc:getPage().strokes = { stroke }
    canvas.selected_strokes = { stroke }
    canvas.selection_bbox = { x = 100, y = 100, w = 40, h = 60 }

    -- Inside the selection: this is a drag, and it must not be read as the
    -- selection being abandoned.
    canvas:_beginStroke("lasso", 110, 110, 1)
    assertTrue(canvas.dragging_selection, "the drag never started")
    assertTrue(canvas.selected_strokes ~= nil, "the selection was dropped instead of picked up")
end)

io.write("snapping a shape under the nib\n")

--[[--
The snap replaces the stroke in the buffer, so the panel has to be told about
everywhere the old one was.

A tidied shape is regularly smaller than the scrawl it came from -- that is much
of the point of it -- and the refresh used to cover only the shape. The parts of
the scrawl outside it were rubbed out of the buffer and left standing on the
panel, as a ghost that stayed until something else happened to repaint over it.
--]]
local function snappingCanvas()
    local canvas = newCanvas()
    local refreshed = nil
    Device.screen.refreshFast = function(_, x, y, w, h)
        refreshed = { x = x, y = y, w = w, h = h }
    end
    Device.screen.refreshUI = function(_, x, y, w, h)
        refreshed = { x = x, y = y, w = w, h = h }
    end
    return canvas, function() return refreshed end
end

--- True if the rectangle `outer` covers `inner` entirely.
local function covers(outer, x, y, w, h)
    return outer
        and outer.x <= x and outer.y <= y
        and outer.x + outer.w >= x + w
        and outer.y + outer.h >= y + h
end

test("the refresh after a snap covers where the raw stroke was", function()
    local canvas, refreshed = snappingCanvas()

    -- A line drawn with a belly in it: recognised as a line, and a line is
    -- straightened to its two ends, so the belly ends up outside the tidied
    -- shape entirely.
    canvas:_beginStroke("pen", 100, 300, 1)
    for i = 1, 40 do
        after(8)
        local t = i / 40
        canvas:_extendStroke(math.floor(100 + 400 * t),
                             math.floor(300 - 15 * math.sin(t * math.pi)), 1)
    end

    local rx, ry, rw, rh = canvas.stroke:getBounds()
    canvas:_triggerShapeSnap()
    assertTrue(canvas.shape_snapped, "the fixture is wrong: nothing was recognised")

    local sx, sy, sw, sh = canvas.stroke:getBounds()
    assertTrue(sw < rw or sh < rh,
        "the fixture is wrong: the tidied shape is not the smaller of the two")

    local box = refreshed()
    assertTrue(box ~= nil, "the snap sent no refresh at all")
    -- Clamped to the drawing area, so the comparison is too.
    local c = canvas.content
    local cx = math.max(rx, c.x)
    local cy = math.max(ry, c.y)
    local cw = math.min(rx + rw, c.x + c.w) - cx
    local ch = math.min(ry + rh, c.y + c.h) - cy
    assertTrue(covers(box, cx, cy, cw, ch),
        "the refresh left part of the raw stroke on the panel")
    assertTrue(covers(box, sx, sy, sw, sh),
        "the refresh does not cover the shape it drew")
end)

test("palm grace blocks every page gesture after pen lift", function()
    local canvas = newCanvas()
    local turned = 0
    canvas.on_page_swipe = function() turned = turned + 1 end
    canvas.pen_left_at = clock.ms
    after(100)
    canvas:onPageSwipe(nil, { direction = "west" })
    canvas:onPageMultiSwipe(nil, { direction = "west" })
    canvas:onPageTwoFingerSwipe(nil, { direction = "west" })
    assertEq(turned, 0, "palm turned the page during grace")
    after(700)
    canvas:onPageSwipe(nil, { direction = "west" })
    assertEq(turned, 1, "intentional swipe after grace")
end)

test("palm release cannot finish a stylus selection drag", function()
    local canvas = draggingCanvas()
    canvas.pen_down = true
    canvas:onTouchRelease(nil, { pos = { x = 300, y = 300 } })
    assertTrue(canvas.dragging_selection, "palm release ended the pen drag")
end)

test("slow repaint does not immediately license another drag repaint", function()
    local canvas, _, repaints = draggingCanvas()
    local repaint = canvas._repaintRegion
    canvas._repaintRegion = function(...)
        repaint(...)
        after(100) -- work itself is slower than the refresh interval
    end
    canvas:_extendStroke(201, 201, 1)
    canvas:_extendStroke(202, 202, 1)
    assertEq(repaints(), 1, "back-to-back expensive frames")
end)

test("switching to eraser commits the pen stroke before erasing", function()
    local canvas, doc = newCanvas()
    canvas:onStylusEvent{ tool = 1, x = 100, y = 100, id = 1 }
    canvas:onStylusEvent{ tool = 2, x = 300, y = 300, id = 1 }
    assertEq(canvas.stroke, nil, "pen remained live under eraser")
    assertEq(#doc:getPage().strokes, 1, "pen stroke not committed")
    canvas:onStylusEvent{ tool = 2, id = -1 }
    assertEq(canvas.erasing, false, "eraser did not end")
end)

test("panel coordinates without a repeated slot never overwrite the pen", function()
    local input = Device.input
    input.pen_slot, input.main_finger_slot, input.cur_slot = 4, 0, 0
    input.wacom_protocol = true
    local slots = {}
    input.setupSlotData = function(self, n)
        self.cur_slot = n
        slots[n] = slots[n] or {}
    end
    input.setCurrentMtSlotChecked = function(self, key, value) slots[self.cur_slot][key] = value end
    input.setCurrentMtSlot = input.setCurrentMtSlotChecked
    input.handleTouchEv = function(self, ev)
        if ev.code == 47 then self:setupSlotData(ev.value)
        elseif ev.code == 53 then self:setCurrentMtSlotChecked("x", ev.value)
        elseif ev.code == 54 then self:setCurrentMtSlotChecked("y", ev.value) end
    end
    input.handleKeyBoardEv = function() end
    local canvas = newCanvas()
    canvas:start()
    input:handleTouchEv{ type = 3, code = 47, value = 2 }
    input:handleTouchEv{ type = 3, code = 0, value = 100 }
    input:handleTouchEv{ type = 3, code = 1, value = 120 }
    input:handleTouchEv{ type = 3, code = 53, value = 500 }
    input:handleTouchEv{ type = 3, code = 54, value = 700 }
    local pen_x, panel_x = slots[15].x, slots[2].x
    canvas:stop()
    input.pen_slot = nil
    assertEq(pen_x, 100, "palm overwrote nib")
    assertEq(panel_x, 500, "panel lost its selected slot")
end)

test("queued drag callback is cancelled at release", function()
    local canvas = draggingCanvas()
    local ui = require("ui/uimanager")
    local old_schedule, old_unschedule = ui.scheduleIn, ui.unschedule
    local queue = {}
    ui.scheduleIn = function(_, _, fn) queue[fn] = true end
    ui.unschedule = function(_, fn) queue[fn] = nil end
    canvas:_extendStroke(201, 201, 1)
    after(2)
    canvas:_extendStroke(202, 202, 1)
    canvas:_endStroke()
    local pending = 0
    for _ in pairs(queue) do pending = pending + 1 end
    ui.scheduleIn, ui.unschedule = old_schedule, old_unschedule
    assertEq(pending, 0, "callback escaped its drag lifetime")
end)

test("autosave waits while a new stroke is active", function()
    local canvas, doc = newCanvas()
    local saved = 0
    doc.save = function() saved = saved + 1 end
    canvas:_beginStroke("pen", 100, 100, 1)
    doc.dirty = true
    canvas.autosave_cb()
    assertEq(saved, 0, "disk serialization interrupted writing")
end)

test("pressure brushes preserve their appearance in ordinary stroke data", function()
    local input = Device.input
    input.wacom_protocol = true
    local canvas, doc = newCanvas()
    canvas.pen_style = "fountain"
    canvas:onStylusEvent{tool=1, id=1, x=100, y=100, pressure=1024}
    after(10)
    canvas:onStylusEvent{tool=1, id=1, x=120, y=100, pressure=4095}
    canvas:onStylusEvent{tool=1, id=-1}
    local s = doc:getPage().strokes[1]
    local _, _, low = s:getPoint(1)
    local _, _, high = s:getPoint(2)
    assertTrue(low < high, "pressure ignored")
    canvas.pen_style = "pencil"
    canvas:onStylusEvent{tool=1, id=1, x=200, y=200, pressure=2048}
    canvas:onStylusEvent{tool=1, id=-1}
    local pencil = doc:getPage().strokes[2]
    local copy = Stroke:deserialize(pencil:serialize())
    assertEq(copy.color, 96, "pencil gray not persisted")
    assertEq(copy.pts[3], pencil.pts[3], "pencil pressure not persisted")
end)

test("virtual stylus without pressure uses the physical sensor", function()
    Device.input.wacom_protocol = true
    local canvas, doc = newCanvas()
    canvas.pen_style = "fountain"
    local pressure = 100
    canvas.pressure_sensor = {read=function() return pressure end}
    canvas:onStylusEvent{tool=1,id=1,x=100,y=100}
    pressure = 3900
    after(10)
    canvas:onStylusEvent{tool=1,id=1,x=150,y=100}
    canvas:onStylusEvent{tool=1,id=-1}
    local stroke = doc:getPage().strokes[1]
    assertTrue(stroke.pts[3]<.1 and stroke.pts[6]>.9,"physical pressure was ignored")
end)

test("a stylus release still ends the stroke when proximity clears its tool", function()
    local input = Device.input
    input.pen_slot = 15
    local canvas, doc = newCanvas()
    canvas:onStylusEvent{slot=15, tool=1, id=1, x=100, y=100}
    canvas:onStylusEvent{slot=15, tool=0, id=-1}
    input.pen_slot = nil
    assertEq(canvas.stroke, nil, "pen stroke stuck after tool cleared")
    assertEq(canvas.pen_down, false, "palm block stuck on")
    assertEq(#doc:getPage().strokes, 1, "stroke lost at proximity exit")
end)

test("barrel release returns to pen despite a mutated framework slot", function()
    local input = Device.input
    local canvas, doc = newCanvas()
    canvas.physical_pen_tool = input.TOOL_TYPE_PEN
    input.stylus_eraser_active = true
    canvas:onStylusEvent{tool=2, id=1, x=100, y=100}
    input.stylus_eraser_active = false
    after(10)
    canvas:onStylusEvent{tool=2, id=1, x=120, y=100}
    canvas:onStylusEvent{tool=2, id=-1}
    assertEq(#doc:getPage().strokes, 2, "barrel tool never returned to pen")
    assertEq(doc:getPage().strokes[1].tool, "highlighter", "barrel tool")
    assertEq(doc:getPage().strokes[2].tool, "pen", "released barrel tool")
end)

test("resting hand cannot dismiss a pen selection or turn its page", function()
    local canvas = newCanvas()
    canvas.tool = "lasso"
    canvas.draw_with_finger = false
    canvas.selected_strokes = {}
    canvas.selection_bbox = {x=100,y=100,w=50,h=50}
    local turns = 0
    canvas.on_page_swipe = function() turns = turns + 1 end
    canvas:onTouchStart(nil,{pos={x=400,y=400}})
    assertTrue(canvas.selected_strokes ~= nil, "palm dismissed selection")
    canvas:onPageSwipe(nil,{direction="west"})
    canvas:onTouchRelease(nil,{pos={x=50,y=400}})
    assertEq(turns,0,"selection gesture changed page")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
