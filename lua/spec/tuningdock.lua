#!/usr/bin/env luajit
--[[--
Tests for the tuning dock's wiring.

What can be checked without a panel is the arithmetic and the plumbing: that a
step lands on the value, that the ends of a range hold, that the tabs are the
ones the tuning module declares, and that a tab built for every group does not
raise. What it looks like at 1860 px is the headless render's job.

Run with:  luajit spec/tuningdock.lua   (from the plugin directory)
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

local store = {
    kept = {},
    readSetting = function(self, k) return self.kept[k] end,
    saveSetting = function(self, k, v) self.kept[k] = v end,
    delSetting = function(self, k) self.kept[k] = nil end,
}
G_reader_settings = store

local Tuning = require("tuning")
local TuningDock = require("tuningdock")

local function dock()
    return TuningDock:new{ width = 800, height = 300 }
end

io.write("stepping a value\n")

test("plus adds one step, minus takes one away", function()
    Tuning.resetAll()
    local d = dock()
    local base = Tuning.refresh_interval_ms
    local step = Tuning.spec.refresh_interval_ms.step

    d:step("refresh_interval_ms", 1)
    assertEq(Tuning.refresh_interval_ms, base + step, "after plus")

    d:step("refresh_interval_ms", -1)
    assertEq(Tuning.refresh_interval_ms, base, "back where it started")
    Tuning.resetAll()
end)

test("stepping stops at the ends of the range instead of running off", function()
    Tuning.resetAll()
    local d = dock()
    local s = Tuning.spec.outlier_limit
    for _ = 1, 500 do d:step("outlier_limit", 1) end
    assertEq(Tuning.outlier_limit, s.max, "top of the range")
    for _ = 1, 500 do d:step("outlier_limit", -1) end
    assertEq(Tuning.outlier_limit, s.min, "bottom of the range")
    Tuning.resetAll()
end)

test("a step is saved, not just applied", function()
    Tuning.resetAll()
    local d = dock()
    d:step("palm_grace_ms", -1)
    assertEq(store.kept["notebook_tuning_palm_grace_ms"], Tuning.palm_grace_ms, "stored")
    Tuning.resetAll()
end)

io.write("the tabs\n")

test("every tab the tuning module declares can be built", function()
    -- A tab whose rows raise when built is a tab that takes the notebook down
    -- with it, and it would only be found by tapping it on the device.
    for _, tab in ipairs(Tuning.tabs) do
        local d = dock()
        local ok, err = pcall(function() d:setTab(tab.id) end)
        assertTrue(ok, tab.id .. " failed to build: " .. tostring(err))
        assertEq(d.tab, tab.id, "current tab")
    end
end)

test("it opens on the first tab", function()
    local d = dock()
    assertEq(d.tab, Tuning.tabs[1].id, "opening tab")
end)

test("an unknown tab is ignored rather than leaving the dock blank", function()
    local d = dock()
    d:setTab("a tab that does not exist")
    assertEq(d.tab, Tuning.tabs[1].id, "still on the first tab")
end)

io.write("reset\n")

test("reset tab puts back only that tab's parameters", function()
    Tuning.resetAll()
    local d = dock()
    Tuning.set("refresh_interval_ms", 40)   -- ink
    Tuning.set("palm_grace_ms", 0)          -- input
    d:setTab("ink")
    d:resetTab()
    assertEq(Tuning.refresh_interval_ms, Tuning.spec.refresh_interval_ms.default, "ink reset")
    assertEq(Tuning.palm_grace_ms, 0, "input untouched")
    Tuning.resetAll()
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
