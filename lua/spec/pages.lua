#!/usr/bin/env luajit
--[[--
Tests for page backgrounds and page management.

Two things are being pinned down here. The first is arithmetic: a ruled line
belongs at a particular place and a notebook with three pages has three pages
after an undo. The second is the property the whole design of backgrounds rests
on -- that a background is not ink, and therefore cannot be erased.

Run with:  luajit spec/pages.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local store = support.installStubs()

local Document = require("document")
local Stroke = require("stroke")
local Template = require("template")
local Renderer = require("renderer")

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

local function assertNil(v, what)
    if v ~= nil then error((what or "value") .. ": expected nil, got " .. tostring(v), 2) end
end

local AREA = { x = 0, y = 0, w = 400, h = 600 }

--- The y of every row that has any non-white pixel in it.
local function inkedRows(bb)
    local rows = {}
    for y = 0, bb.h - 1 do
        for x = 0, bb.w - 1 do
            if bb.px[y][x] < 255 then
                table.insert(rows, y)
                break
            end
        end
    end
    return rows
end

--- The first row of each band of inked rows, so a two-pixel rule counts once.
local function inkedBands(bb)
    local bands = {}
    local previous
    for _, y in ipairs(inkedRows(bb)) do
        if not previous or y > previous + 1 then table.insert(bands, y) end
        previous = y
    end
    return bands
end

local function inkedColumns(bb)
    local cols = {}
    for x = 0, bb.w - 1 do
        for y = 0, bb.h - 1 do
            if bb.px[y][x] < 255 then
                table.insert(cols, x)
                break
            end
        end
    end
    return cols
end

-- Backgrounds --------------------------------------------------------------------

io.write("backgrounds\n")

test("blank draws nothing at all", function()
    local bb = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(bb, "blank", AREA, 1)
    assertEq(bb:inkedCount(), 0, "pixels painted")
end)

test("an unknown background draws nothing rather than erroring", function()
    local bb = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(bb, "tartan", AREA, 1)
    assertEq(bb:inkedCount(), 0, "pixels painted")
end)

test("ruled lines are evenly spaced", function()
    local bb = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(bb, "lined", AREA, 1)
    local rows = inkedBands(bb)
    assertTrue(#rows >= 3, "expected several lines, got " .. #rows)

    local gap = rows[2] - rows[1]
    for i = 3, #rows do
        local this_gap = rows[i] - rows[i - 1]
        assertTrue(math.abs(this_gap - gap) <= 1,
            string.format("line %d is %d from the last, not %d", i, this_gap, gap))
    end
end)

test("narrow ruling is tighter than ordinary ruling", function()
    local wide = support.FakeBB.new(AREA.w, AREA.h)
    local narrow = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(wide, "lined", AREA, 1)
    Template.draw(narrow, "narrow", AREA, 1)
    assertTrue(#inkedBands(narrow) > #inkedBands(wide),
        "narrow ruling should fit more lines on the same page")
end)

test("a grid's vertical rules stay inside the clip", function()
    local bb = support.FakeBB.new(AREA.w, AREA.h)
    local clip = { x = 0, y = 300, w = AREA.w, h = 60 }
    Template.draw(bb, "grid", AREA, 1, clip)
    for y = 0, AREA.h - 1 do
        if y < clip.y or y >= clip.y + clip.h then
            for x = 0, AREA.w - 1 do
                assertEq(bb.px[y][x], 255,
                    string.format("a vertical rule reached (%d, %d)", x, y))
            end
        end
    end
end)

test("a grid rules both ways, a lined page only one", function()
    local grid = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(grid, "grid", AREA, 1)
    assertTrue(#inkedColumns(grid) > 3, "no vertical ruling in a grid")

    local lined = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(lined, "lined", AREA, 1)
    -- A ruled line spans the width, so every column inside the ruling is inked;
    -- what tells the two apart is that the grid also inks the rows between lines.
    assertTrue(#inkedRows(grid) > #inkedRows(lined),
        "a grid should ink more rows than plain ruling")
end)

test("nothing is drawn outside the page", function()
    local bb = support.FakeBB.new(AREA.w, AREA.h)
    local area = { x = 50, y = 40, w = 200, h = 300 }
    Template.draw(bb, "grid", area, 1)
    for y = 0, bb.h - 1 do
        for x = 0, bb.w - 1 do
            if bb.px[y][x] < 255 then
                assertTrue(x >= area.x and x < area.x + area.w
                       and y >= area.y and y < area.y + area.h,
                    string.format("painted at (%d, %d), outside the page", x, y))
            end
        end
    end
end)

test("drawing twice leaves exactly the same page", function()
    -- Callers repaint overlapping regions all the time; a background that
    -- darkened where it was drawn twice would streak wherever they overlap.
    local once = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(once, "checklist", AREA, 1)
    local twice = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(twice, "checklist", AREA, 1)
    Template.draw(twice, "checklist", AREA, 1)
    for y = 0, AREA.h - 1 do
        for x = 0, AREA.w - 1 do
            assertEq(twice.px[y][x], once.px[y][x],
                string.format("pixel (%d, %d) changed on the second pass", x, y))
        end
    end
end)

test("a clip restricts the work without moving the lines", function()
    local full = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(full, "lined", AREA, 1)

    local clip = { x = 0, y = 200, w = AREA.w, h = 100 }
    local part = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(part, "lined", AREA, 1, clip)

    assertTrue(part:inkedCount() < full:inkedCount(), "the clip drew everything")
    -- Nothing outside it: the eraser restores a small region and anything
    -- painted beyond it lands on pixels nobody is going to refresh.
    for y = 0, AREA.h - 1 do
        if y < clip.y or y >= clip.y + clip.h then
            for x = 0, AREA.w - 1 do
                assertEq(part.px[y][x], 255,
                    string.format("painted at (%d, %d), outside the clip", x, y))
            end
        end
    end
    -- What it did draw has to agree with the unclipped page, pixel for pixel.
    for y = clip.y, clip.y + clip.h - 1 do
        for x = 0, AREA.w - 1 do
            assertEq(part.px[y][x], full.px[y][x],
                string.format("pixel (%d, %d) differs inside the clip", x, y))
        end
    end
end)

test("ruling too fine to read is left out rather than smeared", function()
    local bb = support.FakeBB.new(40, 60)
    Template.draw(bb, "narrow", { x = 0, y = 0, w = 40, h = 60 }, 0.02)
    assertEq(bb:inkedCount(), 0, "pixels painted at a tiny scale")
end)

-- The property the design rests on ------------------------------------------------

io.write("backgrounds and the eraser\n")

test("erasing a stroke written across a ruled line leaves the line", function()
    -- What the canvas does when the eraser passes: paint the region white,
    -- lay the background down again, then redraw the strokes that remain.
    local bb = support.FakeBB.new(AREA.w, AREA.h)
    Template.draw(bb, "lined", AREA, 1)

    local before = {}
    for _, y in ipairs(inkedRows(bb)) do before[y] = true end
    assertTrue(next(before) ~= nil, "no ruling to erase across")

    local region = { x = 100, y = 0, w = 120, h = AREA.h }
    bb:paintRect(region.x, region.y, region.w, region.h, 255)
    Template.draw(bb, "lined", AREA, 1, region)

    local after = {}
    for _, y in ipairs(inkedRows(bb)) do after[y] = true end
    for y in pairs(before) do
        assertTrue(after[y],
            "line at y=" .. y .. " was rubbed out along with the ink")
    end
end)

-- Inheritance -----------------------------------------------------------------------

io.write("background inheritance\n")

local function newDoc()
    local doc = Document:new("/tmp/t.scribe")
    return doc
end

test("a new notebook is blank, and its pages follow it", function()
    local doc = newDoc()
    assertEq(doc.template, "blank", "notebook background")
    assertEq(doc:templateFor(1), "blank", "page background")
end)

test("changing the notebook changes the pages that follow it", function()
    local doc = newDoc()
    doc:insertPage(1)
    doc:setTemplate("grid")
    assertEq(doc:templateFor(1), "grid", "page 1")
    assertEq(doc:templateFor(2), "grid", "page 2")
end)

test("a page given its own background keeps it", function()
    local doc = newDoc()
    doc:insertPage(1)
    doc:setPageTemplate(2, "dots")
    doc:setTemplate("lined")
    assertEq(doc:templateFor(1), "lined", "the page that follows")
    assertEq(doc:templateFor(2), "dots", "the page with its own")
end)

test("applying to every page clears the pages that had their own", function()
    local doc = newDoc()
    doc:insertPage(1)
    doc:setPageTemplate(2, "dots")
    assertTrue(doc:hasPageTemplates(), "override not recorded")
    doc:setTemplate("lined", true)
    assertEq(doc:templateFor(2), "lined", "page 2")
    assertTrue(not doc:hasPageTemplates(), "an override survived")
end)

test("an unknown background is refused rather than stored", function()
    local doc = newDoc()
    assertTrue(not doc:setTemplate("tartan"), "accepted an unknown background")
    assertEq(doc.template, "blank", "notebook background")
end)

test("a new page follows the notebook, not the page it came after", function()
    local doc = newDoc()
    doc:setTemplate("lined")
    doc:setPageTemplate(1, "grid")
    local n = doc:insertPage(1)
    assertNil(doc.pages[n].template, "the new page carries an override")
    assertEq(doc:templateFor(n), "lined", "new page background")
end)

test("a duplicated page keeps the background of the page it copies", function()
    local doc = newDoc()
    doc:setPageTemplate(1, "dots")
    local n = doc:duplicatePage(1)
    assertEq(doc.pages[n].template, "dots", "the copy's background")
end)

-- Page management --------------------------------------------------------------------

io.write("page management\n")

local function inkedPage(doc, index, x)
    local stroke = Stroke:new{ tool = "pen", width = 3 }
    stroke:addPoint(x or 10, 10, 1)
    stroke:addPoint((x or 10) + 20, 30, 1)
    table.insert(doc.pages[index].strokes, stroke)
    return stroke
end

test("a page is inserted after the one asked for, not at the end", function()
    local doc = newDoc()
    doc:insertPage(1)
    doc:insertPage(1)
    assertEq(doc:pageCount(), 3, "pages")
    assertEq(doc.current_page, 2, "landed on")
end)

test("undo takes an inserted page back", function()
    local doc = newDoc()
    doc:insertPage(1)
    assertEq(doc:pageCount(), 2, "pages after insert")
    doc:undo()
    assertEq(doc:pageCount(), 1, "pages after undo")
    doc:redo()
    assertEq(doc:pageCount(), 2, "pages after redo")
end)

test("undo brings a deleted page back with everything on it", function()
    local doc = newDoc()
    doc:insertPage(1)
    local stroke = inkedPage(doc, 2)
    doc:deletePage(2)
    assertEq(doc:pageCount(), 1, "pages after delete")

    doc:undo()
    assertEq(doc:pageCount(), 2, "pages after undo")
    assertEq(doc.pages[2].strokes[1], stroke, "the stroke that was on it")
end)

test("the last page cannot be deleted", function()
    local doc = newDoc()
    assertTrue(not doc:deletePage(1), "deleted the only page")
    assertEq(doc:pageCount(), 1, "pages")
end)

test("a duplicate carries the strokes and does not share them", function()
    local doc = newDoc()
    inkedPage(doc, 1)
    local copy = doc:duplicatePage(1)
    assertEq(#doc.pages[copy].strokes, 1, "strokes on the copy")

    inkedPage(doc, 1, 200)
    assertEq(#doc.pages[1].strokes, 2, "strokes on the original")
    assertEq(#doc.pages[copy].strokes, 1,
        "writing on the original also changed the copy")
end)

test("the current page stays inside the notebook after an undo", function()
    local doc = newDoc()
    doc:insertPage(1)
    doc:insertPage(2)
    assertEq(doc.current_page, 3, "landed on")
    doc:undo()
    assertTrue(doc.current_page <= doc:pageCount(),
        "current page " .. doc.current_page .. " is past the end")
end)

test("deleting a page does not disturb the ink on the others", function()
    local doc = newDoc()
    doc:insertPage(1)
    doc:insertPage(2)
    local first = inkedPage(doc, 1)
    local last = inkedPage(doc, 3)
    doc:deletePage(2)
    assertEq(doc.pages[1].strokes[1], first, "page 1")
    assertEq(doc.pages[2].strokes[1], last, "the page that was third")
end)

-- Persistence ---------------------------------------------------------------------------

io.write("persistence\n")

test("backgrounds survive a save and a load", function()
    local doc = Document:new("/tmp/bg.scribe")
    doc:setTemplate("grid")
    doc:insertPage(1)
    doc:setPageTemplate(2, "dots")
    doc:save()

    local reloaded = Document:new("/tmp/bg.scribe")
    assertTrue(reloaded:load(), "load failed")
    assertEq(reloaded.template, "grid", "notebook background")
    assertEq(reloaded:templateFor(1), "grid", "page 1")
    assertEq(reloaded:templateFor(2), "dots", "page 2")
end)

test("a notebook written before backgrounds existed still opens", function()
    -- Exactly the shape the previous version wrote: no template anywhere.
    store["/tmp/old.scribe"] = {
        version = 1,
        current_page = 1,
        pages = { { strokes = {} }, { strokes = {} } },
    }
    local doc = Document:new("/tmp/old.scribe")
    assertTrue(doc:load(), "an existing notebook was refused")
    assertEq(doc:pageCount(), 2, "pages")
    assertEq(doc:templateFor(1), "blank", "background")
end)

test("a background this build does not know is dropped, not carried", function()
    store["/tmp/future.scribe"] = {
        version = 1,
        current_page = 1,
        template = "hexagons",
        pages = { { strokes = {}, template = "isometric" } },
    }
    local doc = Document:new("/tmp/future.scribe")
    assertTrue(doc:load(), "load failed")
    assertEq(doc:templateFor(1), "blank", "background")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
