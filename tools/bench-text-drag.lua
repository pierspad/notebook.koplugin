-- KOReader runtime, generated text selection drag benchmark. No notebook data.
-- Run from the KOReader runtime directory with the plugin's lua path as arg 1.
-- luacheck: globals G_defaults G_reader_settings
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local settings_path = os.tmpname()
os.remove(settings_path)
G_reader_settings = require("luasettings"):open(settings_path)
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = (arg[4] and arg[4] .. "/?.lua;" or "") .. assert(arg[1]) .. "/?.lua;" .. package.path

local Blitbuffer = require("ffi/blitbuffer")
local Canvas = require("canvas")
local Document = require("document")
local Stroke = require("stroke")
local Lasso = require("lasso")
local Text = require("textobject")
local Tuning = require("tuning")
local screen = Device.screen

local font_size = tonumber(arg[2]) or 26
local motion = arg[3] or "fractional"
assert(motion == "fractional" or motion == "integer", "motion must be fractional or integer")
Tuning.drag_repaint_ms = 60
local original_bb = screen.bb
local original_fast_refresh, original_ui_refresh = screen.refreshFast, screen.refreshUI
screen.bb = Blitbuffer.new(1860, 2480, Blitbuffer.TYPE_BB8)
local fast_refreshes, ui_refreshes = 0, 0
screen.refreshFast = function() fast_refreshes = fast_refreshes + 1 end
screen.refreshUI = function() ui_refreshes = ui_refreshes + 1 end

local doc = Document:new("/tmp/notebook-audit/unsaved-text-drag.scribe")
doc:setTemplate("grid")
-- 500 strokes cross the text's repaint region. Another 1,500 are in the page
-- but outside it, so the benchmark also measures the per-frame page scan.
for i = 1, 500 do
    local stroke = Stroke:new{ width = 3 }
    local y = 900 + i % 180
    stroke:addPoint(300, y, 1)
    stroke:addPoint(1600, y + 90, 1)
    doc:addStroke(stroke)
end
for i = 1, 1500 do
    local stroke = Stroke:new{ width = 3 }
    local y = 2000 + i % 300
    stroke:addPoint(100, y, 1)
    stroke:addPoint(300, y + 2, 1)
    doc:addStroke(stroke)
end
local label_text = ("Text drag rendering benchmark, long enough to cover several lines. "):rep(5)
local label = Text.create(label_text, 800, 1000, 600, font_size, { text_background = false })
doc:addStroke(label)

local original_widget = Text.widget
local widget_builds = 0
Text.widget = function(...)
    widget_builds = widget_builds + 1
    return original_widget(...)
end
local canvas = Canvas:new{ document = doc }
canvas.content = { x = 0, y = 0, w = 1860, h = 2480 }
canvas.dimen = { w = 1860, h = 2480 }
canvas.selected_strokes = { label }
canvas.selection_bbox = Lasso.getSelectionBounds(canvas.selected_strokes)
canvas.dragging_selection = true
canvas.drag_last_x, canvas.drag_last_y = 800, 1000
canvas._showLassoMenu = function() end -- isolate drag/release raster cost from menu construction
canvas:_useOpaqueTextDuringDrag()

-- Drive the real pointer path at 125 Hz and let the production scheduler
-- coalesce it at the configured 60 ms repaint interval.
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local now_ms, scheduled = 0, {}
local original_time_now = time.now
local original_schedule_in, original_unschedule = UIManager.scheduleIn, UIManager.unschedule
time.now = function() return time.ms(now_ms) end
UIManager.scheduleIn = function(_, seconds, callback)
    scheduled[callback] = now_ms + seconds * 1000
end
UIManager.unschedule = function(_, callback) scheduled[callback] = nil end
local dx, dy = motion == "integer" and 3 or 0.1, motion == "integer" and 2 or 0.05
local input_started = os.clock()
for i = 1, 40 do
    now_ms = now_ms + 8
    for callback, due in pairs(scheduled) do
        if due <= now_ms then
            scheduled[callback] = nil
            callback()
        end
    end
    canvas:_extendStroke(800 + i * dx, 1000 + i * dy, 1)
end
local input_ms = (os.clock() - input_started) * 1000
local release_started = os.clock()
now_ms = now_ms + 8
canvas:_endStroke()
local release_ms = (os.clock() - release_started) * 1000
local expected_x = motion == "integer" and 920 or 804
local expected_y = motion == "integer" and 1080 or 1002
assert(math.abs(label.x_min - expected_x) < 0.001, "drag release lost its final position")
assert(math.abs(label.y_min - expected_y) < 0.001, "drag release lost its final position")
assert(doc:canUndo(), "drag did not create one undoable translation")

-- Compare native glyph pixels at the final position with a fresh layout at the
-- same page origin. This catches clipping/layout changes while allowing the
-- renderer to reuse the original widget during the drag.
local size = label._text_widget:getSize()
local actual = Blitbuffer.new(size.w, size.h, Blitbuffer.TYPE_BB8)
local reference = Blitbuffer.new(size.w, size.h, Blitbuffer.TYPE_BB8)
actual:paintRect(0, 0, size.w, size.h, Blitbuffer.COLOR_WHITE)
reference:paintRect(0, 0, size.w, size.h, Blitbuffer.COLOR_WHITE)
Text.draw(actual, label, 1, -label.x_min, -label.y_min)
local builds_during_drag = widget_builds
Text.widget = original_widget
local fresh = Text.create(label_text, 0, 0, 600, font_size, { text_background = false })
Text.draw(reference, fresh)
for y = 0, size.h - 1 do
    for x = 0, size.w - 1 do
        assert(actual:getPixel(x, y):getColor8().a == reference:getPixel(x, y):getColor8().a,
            string.format("translated text pixel mismatch at %d,%d", x, y))
    end
end
actual:free(); reference:free(); Text.freeCache(fresh)
canvas.selected_strokes = nil
canvas:_restoreTextAfterDrag()
doc:undo()
assert(math.abs(label.x_min - 800) < 0.001 and math.abs(label.y_min - 1000) < 0.001,
    "undo did not restore the original text position")
print(string.format(
    "1860x2480 grid, 2,001 strokes, font=%d, %s: 40 samples at 125 Hz; "
        .. "input CPU %.2f ms, release CPU %.2f ms; fast/UI refreshes %d/%d; "
        .. "extra text layouts %d; glyph pixel parity and undo passed",
    font_size, motion, input_ms, release_ms, fast_refreshes, ui_refreshes, builds_during_drag))
Text.freeCache(label)
require("textcache").clear()
screen.bb:free()
screen.bb = original_bb
screen.refreshFast, screen.refreshUI = original_fast_refresh, original_ui_refresh
time.now = original_time_now
UIManager.scheduleIn, UIManager.unschedule = original_schedule_in, original_unschedule
os.remove(settings_path)
