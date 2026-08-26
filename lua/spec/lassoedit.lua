#!/usr/bin/env luajit
--[[--
Tests for what the lasso's edit actions leave in the undo history.

Cut, delete, move and paste all change the page, and a change the history does
not know about is worse than one that never happened: undo then takes back some
earlier stroke instead, and the document can be closed without ever being
written, because nothing marked it dirty. These pin down that every lasso edit
is one entry in the history and that the document knows it has changed.

Run with:  luajit spec/lassoedit.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
uistubs.install({})

local Device = package.loaded["device"]
Device.screen.bb = support.FakeBB.new(600, 800)
Device.screen.refreshFast = function() end
Device.screen.refreshUI = function() end
Device.screen.refreshPartial = function() end
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
local Renderer = require("renderer")
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

-- Fixtures ---------------------------------------------------------------------

local function line(x0, y0, x1, y1)
    local s = Stroke:new{ tool = "pen", width = 3, color = 0 }
    s:addPoint(x0, y0, 1)
    s:addPoint(x1, y1, 1)
    return s
end

--- A canvas over a page with `n` short strokes, all far apart.
local function newCanvas(n)
    local doc = Document:new("/tmp/scribe-lassoedit.scribe")
    for i = 1, n do
        doc:addStroke(line(100, 100 * i, 160, 100 * i))
    end
    local canvas = Canvas:new{ document = doc }
    -- The strokes above went in through addStroke, so they are already in the
    -- history. The tests are about what the lasso adds on top of that.
    doc.undo_stack = {}
    doc.redo_stack = {}
    doc.dirty = false
    return canvas, doc
end

--- Opens the lasso menu over `selected` and returns its action callbacks.
local function menuFor(canvas, selected)
    canvas.selected_strokes = selected
    canvas:_showLassoMenu(selected)
    return canvas.lasso_menu
end

io.write("lasso edits and the undo history\n")

test("cut takes one undo to put back", function()
    local canvas, doc = newCanvas(3)
    local victim = doc:getPage().strokes[2]

    menuFor(canvas, { victim }).on_cut()

    assertEq(#doc:getPage().strokes, 2, "strokes left after the cut")
    assertTrue(doc:canUndo(), "cut left nothing to undo")

    doc:undo()
    assertEq(#doc:getPage().strokes, 3, "strokes after undoing the cut")
    assertEq(doc:getPage().strokes[2], victim, "the cut stroke came back elsewhere")
end)

test("cut marks the document dirty", function()
    local canvas, doc = newCanvas(2)
    menuFor(canvas, { doc:getPage().strokes[1] }).on_cut()
    assertTrue(doc.dirty, "a cut left the document looking unchanged")
end)

test("delete takes one undo to put back", function()
    local canvas, doc = newCanvas(3)
    local a = doc:getPage().strokes[1]
    local b = doc:getPage().strokes[3]

    menuFor(canvas, { a, b }).on_delete()

    assertEq(#doc:getPage().strokes, 1, "strokes left after the delete")
    assertTrue(doc:canUndo(), "delete left nothing to undo")

    doc:undo()
    assertEq(#doc:getPage().strokes, 3, "strokes after undoing the delete")
end)

test("delete marks the document dirty", function()
    local canvas, doc = newCanvas(2)
    menuFor(canvas, { doc:getPage().strokes[1] }).on_delete()
    assertTrue(doc.dirty, "a delete left the document looking unchanged")
end)

test("a pasted selection takes one undo to remove, not one per stroke", function()
    local canvas, doc = newCanvas(3)
    menuFor(canvas, { doc:getPage().strokes[1],
                      doc:getPage().strokes[2],
                      doc:getPage().strokes[3] }).on_copy()
    assertEq(#Canvas.clipboard, 3, "strokes on the clipboard")

    canvas.lasso_menu = nil
    doc.undo_stack = {}
    menuFor(canvas, {}).on_paste()
    assertEq(#doc:getPage().strokes, 6, "strokes after the paste")

    doc:undo()
    assertEq(#doc:getPage().strokes, 3, "one undo did not take the whole paste back")
end)

test("moving a selection takes one undo to put back", function()
    local canvas, doc = newCanvas(1)
    local moved = doc:getPage().strokes[1]
    local x0, y0 = moved:getPoint(1)

    canvas.selected_strokes = { moved }
    canvas.selection_bbox = nil
    canvas.dragging_selection = true
    canvas.drag_dx, canvas.drag_dy = 30, 20
    canvas:_endStroke()

    local mx, my = doc:getPage().strokes[1]:getPoint(1)
    assertEq(mx, x0 + 30, "the selection did not move")
    assertTrue(doc:canUndo(), "a move left nothing to undo")
    assertTrue(doc.dirty, "a move left the document looking unchanged")

    doc:undo()
    local ux, uy = doc:getPage().strokes[1]:getPoint(1)
    assertEq(ux, x0, "undo did not put the selection back, x")
    assertEq(uy, y0, "undo did not put the selection back, y")
    assertEq(my, y0 + 20, "the selection did not move, y")
end)

io.write("\nthe selection frame stays inside the screen\n")

--[[--
A buffer that refuses writes outside itself.

The real blitbuffer's setPixel indexes the row pointer without checking, so a
frame drawn past the edge is not a clipped frame but a write into whatever is
next in memory. FakeBB politely drops those, which is exactly the wrong thing
for this test to do.
--]]
local function strictBB(w, h)
    return {
        w = w, h = h,
        getWidth = function(self) return self.w end,
        getHeight = function(self) return self.h end,
        setPixel = function(self, x, y)
            if x < 0 or y < 0 or x >= self.w or y >= self.h then
                error(string.format("wrote outside the buffer at (%d, %d)", x, y), 0)
            end
        end,
    }
end

test("a frame straddling the top left corner is clipped", function()
    Renderer.drawDashedRect(strictBB(600, 800), -20, -30, 200, 100, 0)
end)

test("a frame straddling the bottom right corner is clipped", function()
    Renderer.drawDashedRect(strictBB(600, 800), 500, 700, 200, 300, 0)
end)

test("a frame entirely off the buffer draws nothing", function()
    Renderer.drawDashedRect(strictBB(600, 800), -400, -400, 100, 100, 0)
    Renderer.drawDashedRect(strictBB(600, 800), 900, 900, 100, 100, 0)
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
