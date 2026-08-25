#!/usr/bin/env luajit
--[[--
Test bench for the Scribe plugin's device-independent logic.

Run with:  luajit spec/run.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
support.installStubs()

local Stroke = require("stroke")
local Document = require("document")
local Renderer = require("renderer")
local Export = require("export")

-- Minimal test framework ------------------------------------------------------

local passed, failed = 0, 0
local current

local function test(name, fn)
    current = name
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

local function assertNil(v, what)
    if v ~= nil then error((what or "value") .. ": expected nil, got " .. tostring(v), 2) end
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- Stroke ----------------------------------------------------------------------

io.write("stroke\n")

test("stores points and reports count", function()
    local s = Stroke:new{ width = 4 }
    s:addPoint(10, 20, 0.5)
    s:addPoint(11, 21, 0.6)
    assertEq(s:count(), 2, "count")
    local x, y, p = s:getPoint(2)
    assertEq(x, 11, "x"); assertEq(y, 21, "y"); assertEq(p, 0.6, "pressure")
end)

test("bounds are inflated by half the stroke width", function()
    local s = Stroke:new{ width = 4 }
    s:addPoint(100, 100, 1)
    s:addPoint(110, 120, 1)
    local x, y, w, h = s:getBounds()
    -- pad = ceil(4/2) + 1 = 3
    assertEq(x, 97, "x"); assertEq(y, 97, "y")
    assertEq(w, 16, "w"); assertEq(h, 26, "h")
end)

test("hitTest finds a point within radius", function()
    local s = Stroke:new{ width = 2 }
    s:addPoint(50, 50, 1)
    s:addPoint(60, 50, 1)
    assertTrue(s:hitTest(60, 53, 5), "near hit")
    assertTrue(not s:hitTest(200, 200, 5), "far miss")
end)

test("hitTest hits between two widely spaced points", function()
    -- A fast stroke is sampled sparsely, so most of its visible length lies
    -- between recorded points. Testing vertices only would let the eraser fall
    -- straight through the middle of a line that is plainly there.
    local s = Stroke:new{ width = 2 }
    s:addPoint(0, 0, 1)
    s:addPoint(200, 0, 1)
    assertTrue(s:hitTest(100, 1, 5), "midpoint of a long segment must hit")
    assertTrue(s:hitTest(37, 3, 5), "arbitrary point along the segment must hit")
    assertTrue(not s:hitTest(100, 40, 5), "well off the segment must miss")
end)

test("hitTest respects segment ends rather than the infinite line", function()
    local s = Stroke:new{ width = 2 }
    s:addPoint(0, 0, 1)
    s:addPoint(50, 0, 1)
    -- Collinear but beyond the end of the stroke.
    assertTrue(not s:hitTest(120, 0, 5), "past the end must miss")
end)

test("hitTest rejects points inside the bbox but off the stroke", function()
    -- An L-shaped stroke: the bbox corner is empty space.
    local s = Stroke:new{ width = 2 }
    s:addPoint(0, 0, 1)
    s:addPoint(0, 100, 1)
    s:addPoint(100, 100, 1)
    assertTrue(not s:hitTest(95, 5, 4), "empty bbox corner must not hit")
end)

test("survives a serialize/deserialize round trip", function()
    local s = Stroke:new{ tool = "highlighter", width = 12, color = 128 }
    s:addPoint(1, 2, 0.25)
    s:addPoint(300, 400, 1)
    local restored = Stroke:deserialize(deepcopy(s:serialize()))
    assertEq(restored.tool, "highlighter", "tool")
    assertEq(restored.width, 12, "width")
    assertEq(restored.color, 128, "color")
    assertEq(restored:count(), 2, "count")
    local x, y, p = restored:getPoint(2)
    assertEq(x, 300, "x"); assertEq(y, 400, "y"); assertEq(p, 1, "pressure")
    -- Bounds must be rebuilt, not inherited from the file.
    local bx, by = restored:getBounds()
    assertEq(bx, 1 - 7, "recomputed bounds x")
    assertEq(by, 2 - 7, "recomputed bounds y")
end)

-- Document --------------------------------------------------------------------

io.write("document\n")

local function strokeAt(x, y)
    local s = Stroke:new{ width = 2 }
    s:addPoint(x, y, 1)
    s:addPoint(x + 5, y + 5, 1)
    return s
end

test("adds strokes to the current page", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    d:addStroke(strokeAt(20, 20))
    assertEq(#d:getPage().strokes, 2, "stroke count")
    assertTrue(d.dirty, "document marked dirty")
end)

test("undo removes the last stroke, redo restores it", function()
    local d = Document:new("/tmp/nb")
    local a, b = strokeAt(10, 10), strokeAt(20, 20)
    d:addStroke(a); d:addStroke(b)

    assertTrue(d:canUndo(), "can undo")
    d:undo()
    assertEq(#d:getPage().strokes, 1, "after undo")
    assertEq(d:getPage().strokes[1], a, "the right stroke survived")

    assertTrue(d:canRedo(), "can redo")
    d:redo()
    assertEq(#d:getPage().strokes, 2, "after redo")
    assertEq(d:getPage().strokes[2], b, "redo restored order")
end)

test("undo reports the affected area", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(100, 100))
    local page, x, y, w, h = d:undo()
    assertEq(page, 1, "page")
    assertEq(x, 98, "x"); assertEq(y, 98, "y")
    assertEq(w, 9, "w"); assertEq(h, 9, "h")
end)

test("a new edit discards the redo branch", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    d:undo()
    assertTrue(d:canRedo(), "redo available before new edit")
    d:addStroke(strokeAt(50, 50))
    assertTrue(not d:canRedo(), "redo discarded after new edit")
end)

test("eraser removes every stroke it touches and reports the union", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    d:addStroke(strokeAt(12, 12))
    d:addStroke(strokeAt(500, 500))

    local removed, x, y, w, h = d:eraseAlongPath({ 13, 13, 13, 13 }, 6)
    assertEq(#removed, 2, "two strokes erased")
    assertEq(#d:getPage().strokes, 1, "one stroke left")
    assertTrue(w > 0 and h > 0, "non-empty bbox")
    -- Union must cover both erased strokes, inflated by their half-width.
    assertEq(x, 8, "union x"); assertEq(y, 8, "union y")
end)

test("eraser returns nil when nothing is hit", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    assertNil(d:eraseAlongPath({ 900, 900, 900, 900 }, 5), "miss returns nil")
end)

test("undoing an erase restores strokes at their original index", function()
    local d = Document:new("/tmp/nb")
    local a, b, c = strokeAt(10, 10), strokeAt(12, 12), strokeAt(14, 14)
    d:addStroke(a); d:addStroke(b); d:addStroke(c)

    d:eraseAlongPath({ 12, 12, 12, 12 }, 3)
    local before = #d:getPage().strokes
    assertTrue(before < 3, "something was erased")

    d:undo()
    local strokes = d:getPage().strokes
    assertEq(#strokes, 3, "all restored")
    assertEq(strokes[1], a, "index 1")
    assertEq(strokes[2], b, "index 2")
    assertEq(strokes[3], c, "index 3")
end)

test("area eraser splits a stroke in two", function()
    local d = Document:new("/tmp/nb")
    local s = Stroke:new{ width = 2 }
    for x = 0, 100, 5 do s:addPoint(x, 50, 1) end
    d:addStroke(s)

    assertTrue(d:eraseAreaAlongPath({ 50, 50, 50, 50 }, 10), "erase reported a change")
    local strokes = d:getPage().strokes
    assertEq(#strokes, 2, "one stroke became two")
    -- The gap must actually be gone from both fragments.
    assertTrue(not strokes[1]:hitTest(50, 50, 2), "left fragment cleared the hole")
    assertTrue(not strokes[2]:hitTest(50, 50, 2), "right fragment cleared the hole")
    -- And the far ends must survive.
    assertTrue(strokes[1]:hitTest(5, 50, 3) or strokes[2]:hitTest(5, 50, 3), "start kept")
    assertTrue(strokes[1]:hitTest(95, 50, 3) or strokes[2]:hitTest(95, 50, 3), "end kept")
end)

test("area eraser trims an end without splitting", function()
    local d = Document:new("/tmp/nb")
    local s = Stroke:new{ width = 2 }
    for x = 0, 100, 5 do s:addPoint(x, 50, 1) end
    d:addStroke(s)

    assertTrue(d:eraseAreaAlongPath({ 100, 50, 100, 50 }, 12), "erase reported a change")
    local strokes = d:getPage().strokes
    assertEq(#strokes, 1, "still one stroke")
    assertTrue(not strokes[1]:hitTest(100, 50, 2), "tail removed")
    assertTrue(strokes[1]:hitTest(10, 50, 3), "head kept")
end)

test("area eraser removes a stroke that fits entirely inside it", function()
    local d = Document:new("/tmp/nb")
    local s = Stroke:new{ width = 2 }
    s:addPoint(50, 50, 1); s:addPoint(52, 52, 1)
    d:addStroke(s)

    assertTrue(d:eraseAreaAlongPath({ 51, 51, 51, 51 }, 20), "erase reported a change")
    assertEq(#d:getPage().strokes, 0, "stroke gone")
end)

test("area eraser leaves untouched strokes alone and reports nothing", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    assertNil(d:eraseAreaAlongPath({ 500, 500, 500, 500 }, 20), "miss returns nil")
    assertEq(#d:getPage().strokes, 1, "stroke untouched")
end)

test("undo restores a stroke split by the area eraser", function()
    local d = Document:new("/tmp/nb")
    local s = Stroke:new{ width = 2 }
    for x = 0, 100, 5 do s:addPoint(x, 50, 1) end
    d:addStroke(s)

    d:eraseAreaAlongPath({ 50, 50, 50, 50 }, 10)
    assertEq(#d:getPage().strokes, 2, "split happened")

    d:undo()
    local strokes = d:getPage().strokes
    assertEq(#strokes, 1, "back to one stroke")
    assertEq(strokes[1], s, "the original object, not a rebuild")
    assertTrue(strokes[1]:hitTest(50, 50, 2), "the hole is filled back in")

    d:redo()
    assertEq(#d:getPage().strokes, 2, "redo splits again")
end)

test("a batched eraser sweep is one undo, not one per step", function()
    -- A sweep applies the eraser many times along its path. Without batching
    -- each application is its own history entry, so taking back one wipe means
    -- pressing undo twenty times.
    local d = Document:new("/tmp/nb")
    local s = Stroke:new{ width = 2 }
    for x = 0, 200, 5 do s:addPoint(x, 50, 1) end
    d:addStroke(s)

    local depth = #d.undo_stack
    d:beginBatch()
    for x = 20, 180, 8 do d:eraseAreaAlongPath({ x, 50, x, 50 }, 10) end
    d:commitBatch(0, 0, 200, 100)

    -- Twenty-one applications of the eraser, one history entry.
    assertEq(#d.undo_stack, depth + 1, "the sweep added exactly one undo step")

    -- Rubbing out the middle leaves the two ends standing.
    local after = d:getPage().strokes
    assertEq(#after, 2, "the sweep left the two ends")
    assertTrue(not after[1]:hitTest(100, 50, 4), "the middle really is gone")
    assertTrue(not after[2]:hitTest(100, 50, 4), "on both fragments")

    -- One undo puts the whole line back.
    d:undo()
    local strokes = d:getPage().strokes
    assertEq(#strokes, 1, "a single undo restores the sweep")
    assertEq(strokes[1], s, "the original stroke object is back")
end)

test("a batch that changes nothing records no history", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    local depth = #d.undo_stack

    d:beginBatch()
    d:eraseAreaAlongPath({ 900, 900, 900, 900 }, 10)
    d:commitBatch()

    assertEq(#d.undo_stack, depth, "a sweep that hit nothing adds no undo step")
end)

test("whole-stroke erasing batches too", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    d:addStroke(strokeAt(60, 60))

    d:beginBatch()
    d:eraseAlongPath({ 12, 12, 12, 12 }, 8)
    d:eraseAlongPath({ 62, 62, 62, 62 }, 8)
    d:commitBatch(0, 0, 100, 100)

    assertEq(#d:getPage().strokes, 0, "both strokes gone")
    d:undo()
    assertEq(#d:getPage().strokes, 2, "one undo brings both back")
end)

test("saves and reloads a notebook", function()
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(10, 10))
    d:addPage()
    d:addStroke(strokeAt(20, 20))
    assertTrue(d:save(), "save succeeded")
    assertTrue(not d.dirty, "clean after save")

    local e = Document:new("/tmp/nb")
    assertTrue(e:load(), "load succeeded")
    assertEq(e:pageCount(), 2, "page count")
    assertEq(#e.pages[1].strokes, 1, "page 1 strokes")
    assertEq(#e.pages[2].strokes, 1, "page 2 strokes")
    assertTrue(not e:canUndo(), "history is not persisted")
end)

-- Renderer ---------------------------------------------------------------------

io.write("renderer\n")

test("pressure modulates the radius but never to zero", function()
    local s = Stroke:new{ width = 10 }
    local r_full = Renderer.radiusFor(s, 1)
    local r_none = Renderer.radiusFor(s, 0)
    assertEq(r_full, 5, "full pressure")
    assertTrue(r_none > 0, "zero pressure still draws")
    assertTrue(r_none < r_full, "lighter pressure is thinner")
end)

test("a segment leaves no gaps along its length", function()
    local bb = support.FakeBB.new(120, 120)
    local s = Stroke:new{ width = 1, color = 0 }
    -- A shallow diagonal is the case most likely to expose stamp spacing bugs.
    Renderer.drawSegment(bb, s, 10, 10, 1, 100, 40, 1)

    -- Walk the ideal line and require ink within one pixel of every step.
    for i = 0, 100 do
        local t = i / 100
        local x = 10 + 90 * t
        local y = 10 + 30 * t
        local found = false
        for dy = -1, 1 do
            for dx = -1, 1 do
                local v = bb:get(math.floor(x + 0.5) + dx, math.floor(y + 0.5) + dy)
                if v and v < 255 then found = true end
            end
        end
        assertTrue(found, string.format("gap at t=%.2f (%.1f,%.1f)", t, x, y))
    end
end)

test("the reported dirty rect covers every pixel actually painted", function()
    -- This is the test that matters most for the device: if the dirty rect
    -- under-covers, ink is drawn but never refreshed, and the artifact only
    -- shows up on real hardware.
    local cases = {
        { 20, 20, 80, 60, 3 },
        { 80, 60, 20, 20, 3 },   -- reversed direction
        { 50, 50, 50, 50, 12 },  -- zero-length, thick
        { 10, 90, 90, 10, 7 },   -- steep, opposite diagonal
    }
    for _, c in ipairs(cases) do
        local x0, y0, x1, y1, width = c[1], c[2], c[3], c[4], c[5]
        local bb = support.FakeBB.new(140, 140)
        local s = Stroke:new{ width = width, color = 0 }
        local rx, ry, rw, rh = Renderer.drawSegment(bb, s, x0, y0, 1, x1, y1, 1)

        for y = 0, bb.h - 1 do
            for x = 0, bb.w - 1 do
                if bb.px[y][x] < 255 then
                    assertTrue(x >= rx and x < rx + rw and y >= ry and y < ry + rh,
                        string.format("painted (%d,%d) outside dirty rect (%d,%d,%d,%d)",
                            x, y, rx, ry, rw, rh))
                end
            end
        end
    end
end)

test("highlighter tints without obliterating what is underneath", function()
    local bb = support.FakeBB.new(60, 60)
    -- Lay down black ink first.
    local pen = Stroke:new{ width = 3, color = 0 }
    Renderer.drawSegment(bb, pen, 10, 30, 1, 50, 30, 1)
    assertEq(bb:get(30, 30), 0, "pen ink is black")

    local hl = Stroke:new{ tool = "highlighter", width = 20 }
    Renderer.drawSegment(bb, hl, 10, 30, 1, 50, 30, 1)
    assertEq(bb:get(30, 30), 0, "highlighter must not lighten existing ink")
    -- Blank paper beside the pen line should have picked up gray.
    local beside = bb:get(30, 36)
    assertTrue(beside < 255 and beside > 0, "blank paper becomes gray, not black")
end)

test("highlighter leaves alone anything already darker than the tint", function()
    --[[
    The blend darkens a pixel *to* the tint and never past it, which is what
    makes it idempotent -- and what keeps the dots of dot grid paper, drawn
    darker than the tint on purpose, from being washed out by a highlight
    passing over them.

    The threshold it compares against is read off the colour, and a colour is
    FFI cdata on a device: type() answers "cdata" there, so asking it whether it
    is a table or a number and defaulting to zero made the threshold zero. Pen
    ink survived that, being pure black; everything between black and the tint
    did not. support.cdataColor is that shape, so this cannot pass by being
    handed a friendlier colour than a device would hand it.
    --]]
    local Blitbuffer = package.loaded["ffi/blitbuffer"]
    local plain = Blitbuffer.Color8
    Blitbuffer.Color8 = support.cdataColor

    local ok, err = pcall(function()
        local bb = support.FakeBB.new(60, 60)
        bb:paintRect(20, 20, 8, 8, 85)    -- a dot grid dot: darker than the tint
        bb:paintRect(20, 40, 20, 2, 170)  -- a ruled line: lighter than the tint
        bb:paintRect(20, 50, 8, 4, 0)     -- pen ink

        local hl = Stroke:new{ tool = "highlighter", width = 60 }
        hl:addPoint(30, 35, 1)
        Renderer.drawStroke(bb, hl)

        assertEq(bb:get(22, 22), 85, "the dot grid dot was washed out")
        assertEq(bb:get(22, 51), 0, "pen ink was lightened")
        assertTrue(bb:get(25, 40) < 170, "the ruled line was not darkened")
        assertTrue(bb:get(45, 35) < 255, "blank paper was not tinted at all")
    end)

    Blitbuffer.Color8 = plain
    if not ok then error(err, 0) end
end)

test("a highlighter stamp overhanging the buffer does not write past it", function()
    -- getPixel and setPixel are the two primitives here that do not clip, so a
    -- stamp reaching over the edge would read and write outside the buffer. The
    -- canvas keeps the nib well inside the page, but an export renders into a
    -- buffer of its own size and a page written on a wider panel hangs over it.
    local bb = support.FakeBB.new(40, 40)
    local hl = Stroke:new{ tool = "highlighter", width = 30 }
    hl:addPoint(39, 39, 1)
    hl:addPoint(-4, -4, 1)
    Renderer.drawStroke(bb, hl)

    assertTrue(bb:get(39, 39) < 255, "the corner inside the buffer was painted")
    assertEq(bb:get(45, 45), nil, "nothing exists outside the buffer")
end)

test("overlapping highlighter stamps tint each pixel only once", function()
    -- The failure this guards against: stamps overlap heavily along a stroke,
    -- so a per-stamp multiply compounds and drives the whole stroke to black.
    local bb = support.FakeBB.new(80, 80)
    local hl = Stroke:new{ tool = "highlighter", width = 20 }
    hl:addPoint(20, 40, 1)
    hl:addPoint(60, 40, 1)
    Renderer.drawStroke(bb, hl)

    local mid = bb:get(40, 40)
    local start_px = bb:get(21, 40)
    assertTrue(mid > 100, "mid-stroke stayed a light gray, got " .. tostring(mid))
    assertEq(mid, start_px, "tint is uniform along the stroke")
end)

test("a highlighter stroke that crosses itself does not darken at the crossing", function()
    local bb = support.FakeBB.new(100, 100)
    local hl = Stroke:new{ tool = "highlighter", width = 16 }
    hl:addPoint(20, 50, 1)
    hl:addPoint(80, 50, 1)
    hl:addPoint(50, 20, 1)
    hl:addPoint(50, 80, 1)
    Renderer.drawStroke(bb, hl)

    local crossing = bb:get(50, 50)
    local plain = bb:get(25, 50)
    assertEq(crossing, plain, "self-intersection must not compound the tint")
end)

test("a second highlighter pass over the first does not darken it", function()
    -- Highlighting the same words twice, in separate strokes, must look exactly
    -- like highlighting them once. Any accumulating blend fails this.
    local bb = support.FakeBB.new(80, 80)
    local hl = Stroke:new{ tool = "highlighter", width = 20 }
    hl:addPoint(10, 40, 1)
    hl:addPoint(70, 40, 1)

    Renderer.drawStroke(bb, hl)
    local after_once = bb:get(40, 40)

    Renderer.drawStroke(bb, hl)
    assertEq(bb:get(40, 40), after_once, "a second pass changes nothing")

    -- And a third, for good measure: this is the case the reader hit.
    Renderer.drawStroke(bb, hl)
    assertEq(bb:get(40, 40), after_once, "nor a third")
end)

test("highlighter over ink leaves the ink alone", function()
    local bb = support.FakeBB.new(80, 80)
    local pen = Stroke:new{ width = 4, color = 0 }
    Renderer.drawSegment(bb, pen, 10, 40, 1, 70, 40, 1)

    local hl = Stroke:new{ tool = "highlighter", width = 24 }
    Renderer.drawSegment(bb, hl, 10, 40, 1, 70, 40, 1)
    assertEq(bb:get(40, 40), 0, "black ink stays black under the marker")
end)

test("drawStroke renders a whole multi-point stroke", function()
    local bb = support.FakeBB.new(80, 80)
    local s = Stroke:new{ width = 2, color = 0 }
    s:addPoint(10, 10, 1); s:addPoint(40, 10, 1); s:addPoint(40, 60, 1)
    Renderer.drawStroke(bb, s)
    assertTrue(bb:get(25, 10) < 255, "first leg drawn")
    assertTrue(bb:get(40, 40) < 255, "second leg drawn")
    assertTrue(bb:inkedCount() > 100, "a plausible amount of ink")
end)

test("a clipped redraw puts back everything inside the clip", function()
    -- What the eraser leans on: after rubbing a small area, the strokes that
    -- cross it are drawn again with the region as a clip. Inside that region
    -- the result has to be pixel-for-pixel what a full redraw would give --
    -- anything less and the ink comes back with a bite out of it.
    local s = Stroke:new{ width = 3, color = 0 }
    for i = 0, 400 do s:addPoint(20 + i, 20 + math.floor(i / 3), 1) end

    local full = support.FakeBB.new(500, 220)
    Renderer.drawStroke(full, s)

    local clipped = support.FakeBB.new(500, 220)
    local clip = { x = 200, y = 60, w = 60, h = 60 }
    Renderer.drawStroke(clipped, s, clip)

    local checked = 0
    for y = clip.y, clip.y + clip.h - 1 do
        for x = clip.x, clip.x + clip.w - 1 do
            assertEq(clipped:get(x, y), full:get(x, y),
                string.format("pixel %d,%d", x, y))
            checked = checked + 1
        end
    end
    assertTrue(checked > 0, "nothing was compared")
    assertTrue(clipped:inkedCount() < full:inkedCount() / 2,
        "the clip drew the whole stroke anyway")
end)

test("a short stroke is drawn with a clip as well as without one", function()
    -- Short strokes carry no index to skip runs with, which is a different path
    -- through the clipped draw -- and the one nearly every stroke on a page of
    -- handwriting takes, so the eraser's repaint goes through it constantly.
    local s = Stroke:new{ width = 3, color = 0 }
    for i = 0, 10 do s:addPoint(20 + i * 2, 20 + i, 1) end

    local bb = support.FakeBB.new(80, 80)
    Renderer.drawStroke(bb, s, { x = 0, y = 0, w = 80, h = 80 })
    assertTrue(bb:inkedCount() > 0, "a clipped short stroke drew nothing")
end)

test("a single-point stroke still leaves a dot", function()
    local bb = support.FakeBB.new(40, 40)
    local s = Stroke:new{ width = 6, color = 0 }
    s:addPoint(20, 20, 1)
    Renderer.drawStroke(bb, s)
    assertTrue(bb:inkedCount() > 0, "dot was drawn")
end)

-- Export -----------------------------------------------------------------------

io.write("export\n")

-- RunLengthDecode decoder for round-trip validation matching PDF 1.4 spec.
local function decodeRLE(encoded)
    local out = {}
    local i = 1
    local len = #encoded
    while i <= len do
        local b = encoded:byte(i)
        i = i + 1
        if b == 128 then
            break -- PDF RLE EOD marker
        elseif b < 128 then
            local count = b + 1
            table.insert(out, encoded:sub(i, i + count - 1))
            i = i + count
        else
            local count = 257 - b
            local char = encoded:sub(i, i)
            i = i + 1
            table.insert(out, string.rep(char, count))
        end
    end
    return table.concat(out)
end

test("RunLengthDecode round-trips empty and single-byte data", function()
    local empty_enc = Export.encodeRLE("")
    assertEq(decodeRLE(empty_enc), "", "empty round-trip")
    assertEq(empty_enc, string.char(128), "empty emitted EOD only")

    local single_enc = Export.encodeRLE("A")
    assertEq(decodeRLE(single_enc), "A", "single byte round-trip")
    assertEq(single_enc, string.char(0) .. "A" .. string.char(128), "single byte encoding")
end)

test("RunLengthDecode round-trips runs of identical bytes", function()
    -- Minimum run (2 bytes)
    local run2 = "AA"
    local enc2 = Export.encodeRLE(run2)
    assertEq(decodeRLE(enc2), run2, "run of 2 round-trip")
    assertEq(enc2, string.char(255) .. "A" .. string.char(128), "run of 2 format")

    -- Short run (5 bytes)
    local run5 = "XXXXX"
    local enc5 = Export.encodeRLE(run5)
    assertEq(decodeRLE(enc5), run5, "run of 5 round-trip")
    assertEq(enc5, string.char(252) .. "X" .. string.char(128), "run of 5 format")

    -- Maximum single run length (128 bytes)
    local run128 = string.rep("\xFF", 128)
    local enc128 = Export.encodeRLE(run128)
    assertEq(decodeRLE(enc128), run128, "run of 128 round-trip")
    assertEq(enc128, string.char(129) .. "\xFF" .. string.char(128), "run of 128 format")

    -- Run longer than maximum single chunk (129 bytes: 128 run + 1 literal)
    local run129 = string.rep("Z", 129)
    local enc129 = Export.encodeRLE(run129)
    assertEq(decodeRLE(enc129), run129, "run of 129 round-trip")

    -- Run of 256 bytes (two 128 runs)
    local run256 = string.rep("\x00", 256)
    local enc256 = Export.encodeRLE(run256)
    assertEq(decodeRLE(enc256), run256, "run of 256 round-trip")
    assertEq(enc256, string.char(129, 0, 129, 0, 128), "run of 256 format")

    -- Large blank page simulation (10,000 identical bytes)
    local large = string.rep("\xFF", 10000)
    local large_enc = Export.encodeRLE(large)
    assertEq(decodeRLE(large_enc), large, "large run round-trip")
    assertTrue(#large_enc < #large / 50, "high compression on blank paper runs")
end)

test("RunLengthDecode round-trips literal sequences and mixed data", function()
    -- Sequence of non-repeating bytes (128 bytes)
    local t = {}
    for i = 0, 127 do table.insert(t, string.char(i)) end
    local lit128 = table.concat(t)
    local enc_lit128 = Export.encodeRLE(lit128)
    assertEq(decodeRLE(enc_lit128), lit128, "128 literals round-trip")
    assertEq(enc_lit128:sub(1, 1), string.char(127), "128 literals header")

    -- Sequence of 130 non-repeating bytes (splits into 128 + 2)
    local t2 = {}
    for i = 0, 129 do table.insert(t2, string.char(i)) end
    local lit130 = table.concat(t2)
    local enc_lit130 = Export.encodeRLE(lit130)
    assertEq(decodeRLE(enc_lit130), lit130, "130 literals round-trip")

    -- Mixed alternating runs and literals
    local mixed = string.rep("A", 10) .. "12345" .. string.rep("B", 80) .. "xyz" .. string.rep("C", 130)
    local enc_mixed = Export.encodeRLE(mixed)
    assertEq(decodeRLE(enc_mixed), mixed, "mixed sequence round-trip")
end)

test("packs one byte per pixel, preserving gray levels", function()
    -- Eight bits per pixel, not one: the highlighter is gray, and any threshold
    -- either loses it into the paper or turns it into a black bar.
    local w, h = 10, 3
    local bb = support.FakeBB.new(w, h)
    bb:fill(255)

    bb:set(0, 0, 0)     -- black ink
    bb:set(9, 1, 160)   -- highlighter gray
    bb:set(4, 2, 64)    -- a darker gray

    local packed = Export.packPage(bb, w, h)
    assertEq(#packed, w * h, "one byte per pixel, no padding")

    assertEq(packed:byte(1), 0, "black pixel kept as 0")
    assertEq(packed:byte(2), 255, "white paper kept as 255")
    -- Row 1 starts at offset w+1; pixel 9 is the last of that row.
    assertEq(packed:byte(w + 10), 160, "mid gray survives instead of being thresholded")
    assertEq(packed:byte(2 * w + 5), 64, "darker gray survives too")
end)

test("packed size is width times height for any width", function()
    for _, w in ipairs({ 1, 7, 8, 9, 15, 16, 17, 31, 33, 1860 }) do
        local h = 5
        local bb = support.FakeBB.new(w, h)
        bb:fill(255)
        assertEq(#Export.packPage(bb, w, h), w * h,
            string.format("width %d", w))
    end
end)

test("PDF export produces exact xref byte offsets matching object headers", function()
    local d = Document:new("/tmp/test_export_xref.scribe")
    d:addStroke(strokeAt(100, 100))
    d:addPage()
    d:addStroke(strokeAt(200, 200))

    local out_path = "/tmp/test_export_xref.pdf"
    local ok, err = Export.toPDF(d, out_path, { width = 100, height = 100 })
    assertTrue(ok, "export to PDF succeeded: " .. tostring(err))

    local file = io.open(out_path, "rb")
    assertTrue(file ~= nil, "PDF file exists")
    local content = file:read("*a")
    file:close()
    os.remove(out_path)

    -- Header verification
    assertEq(content:sub(1, 9), "%PDF-1.4\n", "PDF-1.4 header")

    -- Find startxref
    local xref_offset_str = content:match("startxref\n(%d+)\n%%%%EOF")
    assertTrue(xref_offset_str ~= nil, "startxref found")
    local xref_offset = tonumber(xref_offset_str)

    -- Verify xref keyword position (0-indexed byte offset converted to Lua 1-indexed)
    assertEq(content:sub(xref_offset + 1, xref_offset + 5), "xref\n", "xref starts at startxref offset")

    -- Parse xref section: xref\n0 <total_plus_1>\n
    local xref_section = content:sub(xref_offset + 1)
    local total_objs = tonumber(xref_section:match("xref\n0 (%d+)\n"))
    assertTrue(total_objs ~= nil and total_objs > 0, "xref object count found")

    -- Verify each in-use object offset points to exact "<obj_id> 0 obj"
    local count = 0
    for offset_str, gen_str, flag in xref_section:gmatch("(%d%d%d%d%d%d%d%d%d%d) (%d%d%d%d%d) ([fn])") do
        if count == 0 then
            assertEq(flag, "f", "object 0 is free")
            assertEq(offset_str, "0000000000", "object 0 offset is 0")
        else
            assertEq(flag, "n", string.format("object %d is in-use", count))
            local offset = tonumber(offset_str)
            local expected_header = string.format("%d 0 obj", count)
            local actual_header = content:sub(offset + 1, offset + #expected_header)
            assertEq(actual_header, expected_header,
                string.format("xref offset %d for object %d matches actual obj header", offset, count))
        end
        count = count + 1
    end
    assertEq(count, total_objs, "parsed all xref entries")
end)

test("PDF export produces correct page count, structure, and stream dimensions", function()
    local d = Document:new("/tmp/test_export_pages.scribe")
    d:addStroke(strokeAt(50, 50))
    d:addPage()
    d:addStroke(strokeAt(150, 150))
    d:addPage()
    d:addStroke(strokeAt(250, 250))
    assertEq(d:pageCount(), 3, "notebook has 3 pages")

    local w, h = 1860, 2480
    local out_path = "/tmp/test_export_3pages.pdf"
    local ok, err = Export.toPDF(d, out_path, { width = w, height = h })
    assertTrue(ok, "export 3-page PDF succeeded: " .. tostring(err))

    local file = io.open(out_path, "rb")
    local content = file:read("*a")
    file:close()
    os.remove(out_path)

    -- Catalog (Object 1) and Pages (Object 2)
    assertTrue(content:find("1 0 obj.-\n<<.-\n  /Type /Catalog.-\n>>") ~= nil, "Catalog object present")
    assertTrue(content:find("2 0 obj.-\n<<.-\n  /Type /Pages.-\n  /Count 3.-\n>>") ~= nil, "Pages object has /Count 3")
    assertTrue(content:find("/Kids %[ 3 0 R 6 0 R 9 0 R %]") ~= nil, "Pages object has correct Kids array")

    -- 3 Pages, 3 Content streams, 3 Image XObjects (Objects 3 through 11, total 11)
    -- One byte per pixel at 8 bits per component.
    local expected_decompressed_len = w * h
    -- 300 dpi: the panel's density, so the page is its true physical size.
    local page_w, page_h = w * 72 / 300, h * 72 / 300

    for i = 1, 3 do
        local page_obj = 3 + (i - 1) * 3
        local content_obj = page_obj + 1
        local image_obj = page_obj + 2

        -- Page dictionary
        local page_pattern = string.format("%d 0 obj.-\n<<.-\n  /Type /Page.-\n  /Contents %d 0 R.-\n  /Resources <<.-\n    /XObject <<.-\n      /Im1 %d 0 R",
            page_obj, content_obj, image_obj)
        assertTrue(content:find(page_pattern) ~= nil, string.format("Page %d dictionary correctly wired", i))

        -- Content stream. The matrix scales the image to the page box, which is
        -- measured in points -- not in pixels, or the page comes out about four
        -- times too big in each direction.
        local body = string.format("q\n%.2f 0 0 %.2f 0 0 cm\n/Im1 Do\nQ\n", page_w, page_h)
        local content_pattern = string.format("%d 0 obj.-\n<<.-\n  /Length %d.-\n>>\nstream\n%s\nendstream",
            content_obj, #body, (body:gsub("[%%%.%%-%%+%%*%%?%%[%%]%%^%%$%%(%%)]", "%%%%%%0")))
        assertTrue(content:find(content_pattern) ~= nil, string.format("Content stream %d scales to the page box in points", i))

        -- Image XObject dictionary and stream
        local img_pattern = string.format("%d 0 obj.-\n<<.-\n  /Type /XObject.-\n  /Subtype /Image.-\n  /Width %d.-\n  /Height %d.-\n  /ColorSpace /DeviceGray.-\n  /BitsPerComponent 8.-\n  /Filter /RunLengthDecode.-\n  /Length (%%d+).-\n>>\nstream\n(.-)\nendstream",
            image_obj, w, h)
        local length_str, raw_stream = content:match(img_pattern)
        assertTrue(length_str ~= nil, string.format("Image XObject %d stream found", i))
        assertEq(#raw_stream, tonumber(length_str), string.format("Image XObject %d stream length matches /Length", i))

        -- Decompress image stream and verify it matches expected uncompressed page bitmap size
        local decompressed = decodeRLE(raw_stream)
        assertEq(#decompressed, expected_decompressed_len, string.format("Image %d decompressed size is %d bytes", i, expected_decompressed_len))
    end
end)

test("PDF page size is in points, not pixels", function()
    -- The regression this guards: MediaBox takes points (72 per inch). Writing
    -- pixel counts there yields a page around four times too large in each
    -- direction -- 65 x 87 cm instead of a notebook page. The file still opens,
    -- so only a check like this catches it.
    local d = Document:new("/tmp/nb")
    d:addStroke(strokeAt(50, 50))

    local path = "/tmp/scribe-pagesize.pdf"
    assertTrue(Export.toPDF(d, path, { width = 1860, height = 2480, dpi = 300 }))

    local f = io.open(path, "rb")
    local content = f:read("*a")
    f:close()
    os.remove(path)

    local mw, mh = content:match("/MediaBox %[ 0 0 ([%d%.]+) ([%d%.]+) %]")
    assertTrue(mw ~= nil, "MediaBox present")
    -- 1860 px at 300 dpi = 6.2 in = 446.4 pt; 2480 px = 8.27 in = 595.2 pt.
    assertEq(tonumber(mw), 446.4, "page width in points")
    assertEq(tonumber(mh), 595.2, "page height in points")
end)

test("PDF export validates inputs and error handling", function()
    -- Nil document
    local ok1, err1 = Export.toPDF(nil, "/tmp/out.pdf")
    assertTrue(not ok1, "nil document rejected")
    assertTrue(err1 ~= nil, "error message provided")

    -- Document with 0 pages
    local empty_doc = { pages = {}, pageCount = function() return 0 end }
    local ok2, err2 = Export.toPDF(empty_doc, "/tmp/out.pdf")
    assertTrue(not ok2, "empty document rejected")
    assertTrue(err2 ~= nil, "error message provided")

    -- Unwritable output path
    local d = Document:new("/tmp/test.scribe")
    local ok3, err3 = Export.toPDF(d, "/nonexistent_dir_12345/out.pdf")
    assertTrue(not ok3, "unwritable path rejected")
    assertTrue(err3 ~= nil, "error message provided")
end)

--[[--
Renders a document through the exporter and hands back the page buffer.

The exporter allocates its own buffer and does not give it out, so this catches
it on the way past. Everything the export drew is still in it when toPDF
returns.
--]]
local function exportedPage(doc, opts)
    local Blitbuffer = package.loaded["ffi/blitbuffer"]
    local plain_new = Blitbuffer.new
    local captured
    Blitbuffer.new = function(w, h, t)
        captured = plain_new(w, h, t)
        return captured
    end

    local ok, err = pcall(Export.toPDF, doc, "/tmp/notebook-align.pdf", opts)
    Blitbuffer.new = plain_new
    if not ok then error(err, 0) end
    return captured
end

test("the background is drawn where the ink is, not at the top of the page", function()
    --[[
    Strokes are stored in screen coordinates, so every point carries the height
    of the toolbar above the drawing area in its y. The export drew the ruling
    from the top of its own buffer regardless, which put the lines and the
    writing that had been sitting on them out of step by that height modulo the
    line spacing: on paper the words floated between the rules.
    --]]
    local d = Document:new("/tmp/align.scribe")
    d.template = "lined"
    d:setContentOrigin(0, 90)
    local s = Stroke:new{ tool = "pen", width = 3, color = 0 }
    s:addPoint(20, 120, 1)
    s:addPoint(200, 120, 1)
    d:addStroke(s)

    local bb = exportedPage(d, { width = 300, height = 400 })
    assertTrue(bb ~= nil, "no page buffer was captured")

    -- The first rule belongs at the origin, and the strip above it -- where the
    -- toolbar was, and where no stroke can ever be -- stays blank.
    assertTrue(bb:get(150, 90) < 255, "no rule at the content origin")
    assertEq(bb:get(150, 0), 255, "a rule was drawn above the drawing area")
    assertEq(bb:get(150, 40), 255, "the toolbar strip was ruled")
end)

test("a notebook with no origin recorded exports the way it always did", function()
    -- Written before the origin existed, so there is nothing to read: the page
    -- must still come out, ruled from its top left.
    local d = Document:new("/tmp/align-legacy.scribe")
    d.template = "lined"
    local s = Stroke:new{ tool = "pen", width = 3, color = 0 }
    s:addPoint(20, 120, 1)
    s:addPoint(200, 120, 1)
    d:addStroke(s)

    local bb = exportedPage(d, { width = 300, height = 400 })
    assertTrue(bb:get(150, 0) < 255, "no rule at the top of a legacy page")
end)

test("the content origin survives a save and a load", function()
    local d = Document:new("/tmp/origin.scribe")
    d:setContentOrigin(0, 90)
    assertTrue(d.dirty, "recording the origin left the notebook clean")
    assertTrue(d:save(), "save succeeded")

    local back = Document:new("/tmp/origin.scribe")
    assertTrue(back:load(), "load succeeded")
    local ox, oy = back:contentOrigin()
    assertEq(ox, 0, "origin x")
    assertEq(oy, 90, "origin y")

    -- And a notebook that has never been told reads back as the top left, which
    -- is what everything written before this did.
    local fresh = Document:new("/tmp/origin-fresh.scribe")
    local fx, fy = fresh:contentOrigin()
    assertEq(fx, 0, "default origin x")
    assertEq(fy, 0, "default origin y")
end)

-- Summary ----------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
