#!/usr/bin/env luajit
--[[--
Tests for what opens the tuning dock, and for what it does to the page.

The dock is a band across the bottom, which means the page is shorter while it
is open. That is fine in the notebook it is meant for and would be a silent
disaster anywhere else -- ink is stored in screen coordinates, so a page laid
out against the wrong rectangle is a page whose ink is in the wrong place. So
what is pinned here is the gate itself: exactly one title opens it, and every
other notebook gets the geometry it has always had.

Run with:  luajit spec/tuninggate.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
uistubs.install({})

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

G_reader_settings = {
    kept = {},
    readSetting = function(self, k) return self.kept[k] end,
    saveSetting = function(self, k, v) self.kept[k] = v end,
    delSetting = function(self, k) self.kept[k] = nil end,
}

local Device = package.loaded["device"]
Device.screen.bb = support.FakeBB.new(600, 800)
Device.screen.refreshFast = function() end
Device.screen.refreshUI = function() end
Device.screen.refreshPartial = function() end

local Document = require("document")
local Notebook = require("notebook")

local function notebookNamed(title)
    return Notebook:new{ document = Document:new("/tmp/gate.scribe"), title = title }
end

io.write("the gate\n")

test("a notebook called _tuning_ gets the dock", function()
    local nb = notebookNamed("_tuning_")
    assertTrue(nb.tuning_dock, "no dock")
end)

test("every other notebook does not", function()
    for _, title in ipairs({ "notes", "tuning", "_tuning", "tuning_", "_TUNING_", "" }) do
        local nb = notebookNamed(title)
        assertTrue(nb.tuning_dock == nil, "dock opened for " .. string.format("%q", title))
    end
end)

test("a notebook with no title at all does not raise", function()
    -- The title is passed in by whoever opens the notebook, so it can be
    -- missing, and a comparison against nil must not be a crash.
    local nb = notebookNamed(nil)
    assertTrue(nb.tuning_dock == nil, "dock opened for a nameless notebook")
end)

io.write("the page underneath\n")

test("an ordinary notebook has the geometry it always had", function()
    local nb = notebookNamed("notes")
    local toolbar_h = nb.canvas.content.y
    assertEq(nb.canvas.content.h, nb.dimen.h - toolbar_h, "content height")
end)

test("the tuning notebook gives up a band at the bottom", function()
    local plain = notebookNamed("notes")
    local tuned = notebookNamed("_tuning_")
    assertTrue(tuned.canvas.content.h < plain.canvas.content.h, "page was not shortened")
    assertEq(tuned.canvas.content.y, plain.canvas.content.y, "top is unchanged")
    -- The page and the band together are the screen, with nothing left over and
    -- nothing overlapping: ink painted into a gap would be ink under the dock.
    assertEq(tuned.canvas.content.y + tuned.canvas.content.h + tuned.tuning_dock.height,
        tuned.dimen.h, "page plus band is not the screen")
end)

io.write("the remembered tab\n")

test("the tab is remembered across openings", function()
    local first = notebookNamed("_tuning_")
    first.tuning_dock:setTab("lasso")
    local second = notebookNamed("_tuning_")
    assertEq(second.tuning_dock.tab, "lasso", "reopened on a different tab")
end)

io.write("the band fits what is in it\n")

--[[--
Every control the dock has drawn, and how far down the lowest of them reaches.

Painted first, because a widget does not know where it is until it has been:
the rectangle a tap is matched against is written during paintTo.
--]]
local function lowestControl(nb)
    local bb = support.FakeBB.new(nb.dimen.w, nb.dimen.h)
    nb:paintTo(bb, 0, 0)

    local lowest, count = 0, 0
    local function walk(w)
        if type(w) ~= "table" then return end
        if w.onTap and w.dimen and w.dimen.y then
            count = count + 1
            local bottom = w.dimen.y + (w.dimen.h or 0)
            if bottom > lowest then lowest = bottom end
        end
        for _, child in ipairs(w) do walk(child) end
    end
    walk(nb.tuning_dock)
    return lowest, count
end

test("no tab runs off the bottom of the screen", function()
    --[[
    The band is a fixed fraction of the screen and the tabs are not all the
    same length. At the size a control wants to be, the two five-parameter tabs
    are taller than the band: their last two rows were painted past the edge of
    the screen, where they were neither visible nor tappable. A control that is
    off the screen is worse than one that is absent, because nothing says so.
    --]]
    local Tuning = require("tuning")
    local nb = notebookNamed("_tuning_")

    for _, tab in ipairs(Tuning.tabs) do
        nb.tuning_dock:setTab(tab.id)
        local lowest, count = lowestControl(nb)
        assertTrue(count > 0, "the " .. tab.id .. " tab drew no controls at all")
        assertTrue(lowest <= nb.dimen.h, string.format(
            "the %s tab reaches %d down a screen of %d", tab.id, lowest, nb.dimen.h))
    end
end)

test("the dock is painted, not merely listed as a child", function()
    --[[
    The owner paints its children by hand rather than letting the container do
    it, so being in the numbered list makes a widget tappable and nothing else.
    A dock that is listed and not painted is a pane of glass over the bottom of
    the page: taps land on controls nobody can see.
    --]]
    local nb = notebookNamed("_tuning_")
    local painted = false
    local drawn = nb.tuning_dock.paintTo
    nb.tuning_dock.paintTo = function(dock, bb, x, y)
        painted = true
        return drawn(dock, bb, x, y)
    end

    nb:paintTo(support.FakeBB.new(nb.dimen.w, nb.dimen.h), 0, 0)
    assertTrue(painted, "the owner never painted the dock")

    -- And where the page ends, not at the top of the screen.
    assertEq(nb.tuning_dock.dimen.y, nb.dimen.h - nb.tuning_dock.height,
        "the band is not at the bottom")
end)

test("holding the pen opens persistent nib and line options", function()
    local nb = notebookNamed("notes")
    local pen = nb.tool_buttons[1]
    assertTrue(pen.ges_events.Hold, "pen has no hold gesture")
    local ui = require("ui/uimanager")
    local old_show, shown = ui.show, nil
    ui.show = function(_, widget) shown = widget end
    pen:onHold()
    ui.show = old_show
    assertTrue(shown and #shown.actions >= 5, "pen options not opened")
    shown.actions[2].callback()
    assertEq(nb.canvas.pen_style, "fountain", "fountain selection")
    shown.actions[5].callback()
    assertEq(nb.canvas.line_style, "arrow", "arrow selection")
    local reopened = notebookNamed("notes")
    assertEq(reopened.canvas.pen_style, "fountain", "nib not persisted")
    assertEq(reopened.canvas.line_style, "arrow", "arrow not persisted")
end)

test("changing page drops the old page's selection", function()
    local nb = notebookNamed("notes")
    local Stroke = require("stroke")
    local stroke = Stroke:new{}
    stroke:addPoint(100, 200, 1)
    nb.document:addStroke(stroke)
    nb.canvas.selected_strokes = {stroke}
    nb.canvas.selection_bbox = {x=90, y=190, w=20, h=20}
    nb:_turnPage(1)
    assertEq(nb.canvas.selected_strokes, nil, "old page selection survived")
    assertEq(nb.document.current_page, 2, "page did not turn")
end)

test("a failed save keeps the notebook open with an error message", function()
    local nb = notebookNamed("notes")
    nb.document.save = function() return false, "disk full" end
    local ui = require("ui/uimanager")
    local close, show = ui.close, ui.show
    local closed, notice = false, nil
    ui.close = function(_, widget) if widget == nb then closed = true end end
    ui.show = function(_, widget) notice = widget end
    nb:_close()
    ui.close, ui.show = close, show
    assertEq(closed, false, "unsaved notebook closed")
    assertTrue(notice and notice.text, "save failure was silent")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
