#!/usr/bin/env luajit
--[[--
Tests for the two ways this plugin could take the device down, and the two
things that stop it.

These are not tests of a feature. They are tests of a promise: that whatever is
wrong inside this plugin, the reader is left with a Kindle that still answers.
The failure they stand against is not a wrong pixel or a lost stroke -- it is a
device that has to be held down to reboot, with whatever was on the page at the
time.

Run with:  luajit spec/safe.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")
support.installStubs()
local rec = uistubs.install({})

local Safe = require("safe")

-- Test framework ---------------------------------------------------------------

local passed, failed = 0, 0

local function test(name, fn)
    -- Each case starts with the plugin not already shut down.
    Safe.failed = false
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

-- Errors -------------------------------------------------------------------------

io.write("an error does not leave the loop\n")

test("a handler that throws does not throw at the caller", function()
    local widget = { boom = function() error("something is nil") end }
    -- Whatever the loop does next, it must be reached.
    local reached = false
    local ok = pcall(function()
        Safe.call("test:boom", widget.boom)
        reached = true
    end)
    assertTrue(ok, "the error came out of Safe.call")
    assertTrue(reached, "the caller never got control back")
end)

test("the plugin shuts down, and says so", function()
    rec.shown = {}
    Safe.call("test:boom", function() error("something is nil") end)
    assertTrue(Safe.failed, "the plugin carried on as though nothing happened")
    assertTrue(#rec.shown > 0, "the reader was told nothing")
end)

test("the pen is handed back before anything else", function()
    -- The stylus callback is invoked from inside input polling. If the fault is
    -- in there, every further pen event would go into the same broken code, and
    -- there would be no way to put the pen down that avoided it.
    local Device = require("device")
    local handed_back = false
    Device.input.unregisterStylusCallback = function() handed_back = true end

    Safe.call("canvas:stylus", function() error("bad slot") end)
    assertTrue(handed_back, "the stylus callback was left registered")
end)

test("a fault that repeats reports once, not once per event", function()
    rec.shown = {}
    for _ = 1, 20 do
        Safe.call("test:boom", function() error("again") end)
    end
    assertEq(#rec.shown, 1, "dialogs shown")
end)

test("a call that works is left completely alone", function()
    local a, b = Safe.call("test:fine", function(x) return x, x * 2 end, 21)
    assertEq(a, 21, "first return")
    assertEq(b, 42, "second return")
    assertTrue(not Safe.failed, "a successful call reported a failure")
end)

-- Loops --------------------------------------------------------------------------

io.write("a loop that never ends does not become a dead device\n")

test("the watchdog interrupts a runaway and names it", function()
    local logged
    local report = Safe.report
    Safe.report = function(where, err) logged = err end

    Safe.watched("test:runaway", function()
        local n = 0
        while true do n = n + 1 end
    end)

    Safe.report = report
    assertTrue(logged ~= nil, "the loop was never interrupted")
    assertTrue(tostring(logged):match("watchdog"), "not reported as a watchdog trip")
    assertTrue(tostring(logged):match("test:runaway"), "the runaway was not named")
end)

test("the watchdog leaves ordinary work alone", function()
    local total = 0
    local out = Safe.watched("test:work", function()
        for i = 1, 200000 do total = total + i end
        return "done"
    end)
    assertEq(out, "done", "result")
    assertTrue(not Safe.failed, "ordinary work tripped the watchdog")
end)

test("the hook is taken back off afterwards", function()
    -- Left on, every line of the plugin would run interpreted from then on.
    Safe.watched("test:work", function() return 1 end)
    assertTrue(debug.gethook() == nil, "a debug hook was left installed")
end)

-- Yielding -----------------------------------------------------------------------

io.write("follow-up work yields to input\n")

test("Safe.later schedules ahead, never for this instant", function()
    -- A task due now is run before the loop checks input again, so a chain of
    -- them means input is never checked at all. A task due in a moment lets the
    -- loop settle, and a tap lands.
    local delays = {}
    local UIManager = package.loaded["ui/uimanager"]
    local scheduleIn = UIManager.scheduleIn
    UIManager.scheduleIn = function(self, delay, fn)
        table.insert(delays, delay)
        return scheduleIn(self, delay, fn)
    end

    Safe.later("test:work", function() end)

    UIManager.scheduleIn = scheduleIn
    assertEq(#delays, 1, "scheduled once")
    assertTrue(delays[1] > 0, "scheduled for right now, which does not yield")
end)

test("nothing in the plugin schedules with nextTick", function()
    -- The rule this file exists to keep. A chain of nextTick tasks is the one
    -- pattern that reliably stops a Kindle answering.
    local offenders = {}
    local listing = io.popen("ls ./*.lua 2>/dev/null")
    for path in listing:lines() do
        local file = io.open(path, "r")
        if file then
            local line_no = 0
            for line in file:lines() do
                line_no = line_no + 1
                -- Prose about the rule is not a breach of it.
                local code = not line:match("^%s*%-%-")
                if code and line:find("UIManager:nextTick(", 1, true) then
                    table.insert(offenders, path .. ":" .. line_no)
                end
            end
            file:close()
        end
    end
    listing:close()
    assertEq(#offenders, 0,
        "these still chain nextTick: " .. table.concat(offenders, ", "))
end)

test("Safe.later and Safe.wrap support both 1-arg and 2-arg signatures", function()
    local called1 = false
    local called2 = false

    local wrapped1 = Safe.wrap(function() called1 = true end)
    wrapped1()
    assertTrue(called1, "1-arg Safe.wrap executed")

    local wrapped2 = Safe.wrap("test:tag", function() called2 = true end)
    wrapped2()
    assertTrue(called2, "2-arg Safe.wrap executed")

    local later_called = false
    Safe.later(function() later_called = true end)
    assertTrue(rec.runTicks() > 0, "later scheduled and ran")
    assertTrue(later_called, "later callback executed")
end)

test("the screens are all protected", function()
    -- A screen that forgot to go through Safe.widget is a screen whose faults
    -- reach the event loop.
    for _, name in ipairs{ "gallery", "notebook", "newnotebook", "settings",
                           "pagepanel", "templatepicker", "actionmenu", "canvas" } do
        package.loaded[name] = nil
        local ok, class = pcall(require, name)
        assertTrue(ok, name .. " does not load: " .. tostring(class))
        assertTrue(class.notebook_screen ~= nil,
            name .. " is not wrapped by Safe.widget")
    end
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
