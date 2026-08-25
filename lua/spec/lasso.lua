#!/usr/bin/env luajit
--[[--
Comprehensive tests for lasso selection, geometry transformations, and clipboard.

Run with:  luajit spec/lasso.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
uistubs.install()
package.loaded["logger"] = { warn = function() end, dbg = function() end, info = function() end, err = function() end }

local Stroke = require("stroke")
local Lasso = require("lasso")
local Document = require("document")

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

io.write("lasso selection and transformations\n")

test("selects strokes inside a polygon lasso loop", function()
    local inside_stroke = Stroke:new{ tool = "pen", width = 3 }
    inside_stroke:addPoint(200, 200, 1)
    inside_stroke:addPoint(220, 220, 1)

    local outside_stroke = Stroke:new{ tool = "pen", width = 3 }
    outside_stroke:addPoint(500, 500, 1)
    outside_stroke:addPoint(520, 520, 1)

    local page_strokes = { inside_stroke, outside_stroke }

    -- Bounding lasso polygon around (100, 100) to (300, 300)
    local lasso_pts = {
        { x = 100, y = 100 },
        { x = 300, y = 100 },
        { x = 300, y = 300 },
        { x = 100, y = 300 },
    }

    local selected = Lasso.findSelectedStrokes(page_strokes, lasso_pts)
    assertEq(#selected, 1, "selected stroke count")
    assertEq(selected[1], inside_stroke, "selected stroke identity")
end)

test("handles empty inputs safely", function()
    assertEq(#Lasso.findSelectedStrokes({}, { { x = 0, y = 0 }, { x = 10, y = 10 } }), 0, "empty strokes")
    assertEq(#Lasso.findSelectedStrokes({ Stroke:new{ tool = "pen", width = 3 } }, {}), 0, "empty lasso")
    local empty_b = Lasso.getSelectionBounds({})
    assertEq(empty_b, nil, "empty bounds returns nil")
end)

test("selects multiple mixed-tool strokes inside irregular lasso", function()
    local s1 = Stroke:new{ tool = "pen", width = 3 }
    s1:addPoint(150, 150, 1)
    s1:addPoint(160, 160, 1)

    local s2 = Stroke:new{ tool = "highlighter", width = 20 }
    s2:addPoint(200, 180, 1)
    s2:addPoint(250, 180, 1)

    local s3 = Stroke:new{ tool = "pen", width = 5 }
    s3:addPoint(800, 800, 1)

    local lasso_pts = {
        { x = 100, y = 100 },
        { x = 300, y = 120 },
        { x = 350, y = 250 },
        { x = 120, y = 240 },
    }

    local selected = Lasso.findSelectedStrokes({ s1, s2, s3 }, lasso_pts)
    assertEq(#selected, 2, "two strokes selected inside lasso")
end)

test("translates strokes by positive and negative offsets", function()
    local s = Stroke:new{ tool = "pen", width = 3 }
    s:addPoint(100, 100, 1)
    s:addPoint(150, 120, 1)

    -- Positive translation
    Lasso.translateStrokes({ s }, 50, 30)
    local x1, y1 = s:getPoint(1)
    local x2, y2 = s:getPoint(2)
    assertEq(x1, 150, "translated +x1")
    assertEq(y1, 130, "translated +y1")
    assertEq(x2, 200, "translated +x2")
    assertEq(y2, 150, "translated +y2")

    -- Negative translation
    Lasso.translateStrokes({ s }, -30, -20)
    x1, y1 = s:getPoint(1)
    assertEq(x1, 120, "translated -x1")
    assertEq(y1, 110, "translated -y1")
end)

test("computes bounding box union accurately", function()
    local s1 = Stroke:new{ tool = "pen", width = 4 }
    s1:addPoint(100, 100, 1)
    s1:addPoint(200, 150, 1)

    local s2 = Stroke:new{ tool = "pen", width = 4 }
    s2:addPoint(300, 200, 1)
    s2:addPoint(400, 300, 1)

    local b = Lasso.getSelectionBounds({ s1, s2 })
    assertTrue(b.x <= 100, "min x includes s1")
    assertTrue(b.y <= 100, "min y includes s1")
    assertTrue(b.x + b.w >= 400, "max x includes s2")
    assertTrue(b.y + b.h >= 300, "max y includes s2")
end)

test("clones strokes independently for clipboard operations", function()
    local s = Stroke:new{ tool = "pen", width = 3, color = 0 }
    s:addPoint(100, 100, 1)
    s:addPoint(200, 200, 1)

    local clones = Lasso.cloneStrokes({ s })
    assertEq(#clones, 1, "clone count")
    assertEq(clones[1].tool, "pen", "cloned tool")
    assertEq(clones[1]:count(), 2, "cloned point count")

    -- Modifying original does not mutate clone
    s:addPoint(300, 300, 1)
    assertEq(s:count(), 3, "original count updated")
    assertEq(clones[1]:count(), 2, "clone count unchanged")

    -- Translating clone does not mutate original
    Lasso.translateStrokes(clones, 50, 50)
    local ox1, oy1 = s:getPoint(1)
    local cx1, cy1 = clones[1]:getPoint(1)
    assertEq(ox1, 100, "original x1 unchanged")
    assertEq(cx1, 150, "cloned x1 translated")
end)

test("LassoMenu builds with Cut, Copy, Delete and Paste actions", function()
    uistubs.install()
    local LassoMenu = require("lassomenu")
    local menu = LassoMenu:new{
        bbox = { x = 200, y = 200, w = 100, h = 100 },
        has_clipboard = true,
    }
    assertTrue(menu ~= nil, "LassoMenu instance")
    assertTrue(menu:getSize() ~= nil, "menu getSize")
    assertTrue(menu.content_frame ~= nil, "menu content frame")
end)

test("the menu answers taps where it is drawn, not at the top left of the screen", function()
    uistubs.install()
    local LassoMenu = require("lassomenu")
    local menu = LassoMenu:new{
        bbox = { x = 300, y = 700, w = 200, h = 120 },
        has_clipboard = true,
    }

    local range = menu.ges_events.Tap[1].range
    assertTrue(range ~= nil, "the menu has a tap range")
    -- A gesture range is matched against the touch's position on the screen, so
    -- a range left at the origin is a live tap zone over the tool buttons --
    -- and a Tap this class does not handle reaches the first child that does,
    -- which is Cut.
    assertEq(range.x, menu.dimen.x, "tap range x follows the menu")
    assertEq(range.y, menu.dimen.y, "tap range y follows the menu")
    assertTrue(menu.dimen.x > 0 or menu.dimen.y > 0, "the menu is not at the origin")
end)

io.write("what a lasso loop does and does not catch\n")

--- An L: down the left side, then along the bottom. Nothing near the centre.
local function elbowStroke()
    local s = Stroke:new{ tool = "pen", width = 3, color = 0 }
    for i = 0, 100 do s:addPoint(100, 100 + i * 2, 1) end
    for i = 1, 100 do s:addPoint(100 + i * 2, 300, 1) end
    return s
end

local function boxLoop(x, y, w, h)
    return { { x = x, y = y }, { x = x + w, y = y },
             { x = x + w, y = y + h }, { x = x, y = y + h } }
end

test("a loop in the empty middle of a concave stroke catches nothing", function()
    -- The centre of the bounding box is not a point of the stroke: for anything
    -- concave it is in the space the stroke encloses, and counting it selected
    -- an L from a loop drawn in the gap inside it.
    assertEq(Lasso.isStrokeSelected(elbowStroke(), boxLoop(180, 170, 60, 60)), false,
        "the L was caught without being touched")
end)

test("a loop around either arm of it does catch it", function()
    assertEq(Lasso.isStrokeSelected(elbowStroke(), boxLoop(80, 150, 40, 40)), true,
        "the upright was missed")
    assertEq(Lasso.isStrokeSelected(elbowStroke(), boxLoop(200, 280, 40, 40)), true,
        "the foot was missed")
end)

test("a short loop over a long stroke catches it", function()
    -- Tested every so many points, the resolution of the test was a fraction of
    -- the stroke: on a line of writing put down in one stroke, a loop around a
    -- word fell between two tested points and selected nothing.
    local long = Stroke:new{ tool = "pen", width = 3, color = 0 }
    for i = 0, 600 do long:addPoint(100 + i, 500, 1) end
    assertEq(Lasso.isStrokeSelected(long, boxLoop(300, 480, 40, 40)), true,
        "a 40px loop over a 600px stroke missed it")
end)

test("cloning carries the tint across", function()
    local s = Stroke:new{ tool = "highlighter", width = 24, color = 0, tint = 100 }
    s:addPoint(10, 10, 1)
    s:addPoint(40, 10, 1)
    assertEq(Lasso.cloneStrokes({ s })[1].tint, 100, "clone tint")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
