#!/usr/bin/env luajit
--[[--
Tests for the tuning parameters.

These numbers decide how the pen feels, and the panel that edits them is not
reachable from the test bench: what is checkable here is that the values behave
like values -- that a default is inside its own range, that a bad one saved by
an earlier build cannot get in, and that what comes out of dump goes back in.

Run with:  luajit spec/tuning.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

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

--- A settings store holding whatever is given, recording what happens to it.
local function storeWith(values)
    local kept = {}
    for k, v in pairs(values) do kept[k] = v end
    return {
        kept = kept,
        readSetting = function(self, k) return self.kept[k] end,
        saveSetting = function(self, k, v) self.kept[k] = v end,
        delSetting = function(self, k) self.kept[k] = nil end,
    }
end

local Tuning = require("tuning")

io.write("the spec table\n")

test("every default sits inside its own range", function()
    for key, s in pairs(Tuning.spec) do
        assertTrue(s.default >= s.min, key .. " default is below min")
        assertTrue(s.default <= s.max, key .. " default is above max")
        assertTrue(s.step > 0, key .. " has a step that goes nowhere")
        assertTrue(type(s.doc) == "string" and #s.doc > 0, key .. " has no doc")
    end
end)

test("every parameter appears on exactly one tab", function()
    local seen = {}
    for _, tab in ipairs(Tuning.tabs) do
        assertTrue(#tab.keys > 0, tab.id .. " is an empty tab")
        for _, key in ipairs(tab.keys) do
            assertTrue(Tuning.spec[key], key .. " is on a tab but not in the spec")
            assertTrue(not seen[key], key .. " is on two tabs")
            seen[key] = true
        end
    end
    for key in pairs(Tuning.spec) do
        assertTrue(seen[key], key .. " is in the spec but on no tab")
    end
end)

test("the values start at their defaults", function()
    for key, s in pairs(Tuning.spec) do
        assertEq(Tuning[key], s.default, key)
    end
end)

io.write("setting a value\n")

test("a value inside the range is taken and saved", function()
    local store = storeWith{}
    local got = Tuning.set("refresh_interval_ms", 32, store)
    assertEq(got, 32, "returned")
    assertEq(Tuning.refresh_interval_ms, 32, "field")
    assertEq(store.kept["notebook_tuning_refresh_interval_ms"], 32, "stored")
    Tuning.reset("refresh_interval_ms", store)
end)

test("a value outside the range is clamped, not refused", function()
    local store = storeWith{}
    local s = Tuning.spec.refresh_interval_ms
    assertEq(Tuning.set("refresh_interval_ms", 9999, store), s.max, "above")
    assertEq(Tuning.set("refresh_interval_ms", -5, store), s.min, "below")
    -- What was clamped is what got stored, so reloading cannot reintroduce it.
    assertEq(store.kept["notebook_tuning_refresh_interval_ms"], s.min, "stored")
    Tuning.reset("refresh_interval_ms", store)
end)

test("resetting clears the stored key rather than storing the default", function()
    -- A default that changes in a later release must reach a device that had
    -- reset the parameter, and it only can if nothing is written under the key.
    local store = storeWith{}
    Tuning.set("erase_repaint_ms", 200, store)
    Tuning.reset("erase_repaint_ms", store)
    assertEq(Tuning.erase_repaint_ms, Tuning.spec.erase_repaint_ms.default, "field")
    assertEq(store.kept["notebook_tuning_erase_repaint_ms"], nil, "stored")
end)

test("resetAll puts every parameter back", function()
    local store = storeWith{}
    Tuning.set("palm_grace_ms", 0, store)
    Tuning.set("jump_base", 200, store)
    Tuning.resetAll(store)
    for key, s in pairs(Tuning.spec) do
        assertEq(Tuning[key], s.default, key)
    end
end)

io.write("loading what was stored\n")

test("stored values are read back onto the fields", function()
    local store = storeWith{ notebook_tuning_drag_repaint_ms = 30 }
    Tuning.load(store)
    assertEq(Tuning.drag_repaint_ms, 30, "drag_repaint_ms")
    Tuning.resetAll(store)
end)

test("junk left by an earlier build cannot get in", function()
    -- Every one of these has been a real shape of stale state: a key that no
    -- longer exists, a value saved as text, and a number from a range that has
    -- since been narrowed. None of them may stop a notebook from opening.
    local store = storeWith{
        notebook_tuning_a_parameter_that_was_removed = 5,
        notebook_tuning_palm_grace_ms = "600",
        notebook_tuning_max_pen_speed = 10000,
    }
    Tuning.load(store)
    assertEq(Tuning.palm_grace_ms, Tuning.spec.palm_grace_ms.default, "text value ignored")
    assertEq(Tuning.max_pen_speed, Tuning.spec.max_pen_speed.max, "out-of-range clamped")
    assertTrue(Tuning.a_parameter_that_was_removed == nil, "unknown key not adopted")
    Tuning.resetAll(store)
end)

io.write("dump\n")

test("dump lists only what was changed, and lists it as Lua", function()
    local store = storeWith{}
    Tuning.set("refresh_interval_ms", 28, store)
    Tuning.set("erase_repaint_ms", 40, store)

    local text = Tuning.dump()
    assertTrue(text:find("refresh_interval_ms", 1, true), "changed key present")
    assertTrue(text:find("erase_repaint_ms", 1, true), "second changed key present")
    assertTrue(not text:find("palm_grace_ms", 1, true), "unchanged key absent")

    -- The point of the format is that it can be read back, so read it back.
    local chunk = loadstring("return {" .. text .. "}")
    assertTrue(chunk, "dump is not valid Lua: " .. text)
    local t = chunk()
    assertEq(t.refresh_interval_ms, 28, "round-tripped")
    assertEq(t.erase_repaint_ms, 40, "round-tripped")

    Tuning.resetAll(store)
end)

test("dump with nothing changed says so instead of returning nothing", function()
    local store = storeWith{}
    Tuning.resetAll(store)
    assertTrue(#Tuning.dump() > 0, "empty dump")
end)

io.write("guarded defaults\n")

test("every tuning default is intentional and accounted for", function()
    -- A changed number changes how the pen feels. Keep the complete expected
    -- set here so additions and accidental default changes are both explicit.
    local was = {
        refresh_interval_ms  = 20,
        idle_flush_ms        = 35,
        reconcile_delay_ms   = 2000,
        jitter_floor_sq      = 4,
        live_highlight_tint  = 100,
        live_highlight_refresh_ms = 20,
        eraser_radius        = 12,
        erase_repaint_ms     = 70,
        drag_repaint_ms      = 60,
        lasso_sample_spacing = 12,
        frame_margin         = 10,
        hold_travel_sq       = 64,
        hold_delay_ms        = 350,
        rect_angle_tolerance = 18,
        palm_grace_ms        = 600,
        max_pen_speed        = 6,
        jump_base            = 48,
        max_jump_gap_ms      = 120,
        outlier_limit        = 8,
    }
    for key, value in pairs(was) do
        assertTrue(Tuning.spec[key], key .. " is gone from the spec")
        assertEq(Tuning.spec[key].default, value, key)
    end
    -- And nothing was added to the spec without being accounted for here.
    for key in pairs(Tuning.spec) do
        assertTrue(was[key] ~= nil, key .. " is in the spec but not in this list")
    end
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
