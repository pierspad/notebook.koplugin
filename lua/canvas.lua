--[[--
The drawing surface: turns stylus events into ink on the panel.

Latency strategy
----------------
While a stroke is in progress this widget deliberately bypasses UIManager and
paints straight into the screen's blitbuffer, then asks the framebuffer for a
partial refresh of just the rectangle it dirtied. Going through UIManager would
mean a repaint pass over the widget stack for every fragment of a stroke, which
is far too much work to keep up with a pen.

Two things make that safe:

  * `paintTo` remains the authoritative renderer, drawing the page from the
    vector model. If anything else triggers a repaint, the correct image is
    restored, so the fast path can never leave the screen permanently wrong.
  * Fast refreshes on this hardware are fire-and-forget -- the driver only makes
    us wait for completion on flashing/REAGL waveforms -- so consecutive
    refreshes do not serialize against each other.

Refreshes are rate-limited rather than issued per event. The digitizer reports
points far faster than the panel can update, and issuing an ioctl per point
builds a backlog that shows up as ink lagging further behind the nib the longer
you write.

@module notebook.canvas
--]]--

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Lasso = require("lasso")
local Renderer = require("renderer")
local Safe = require("safe")
local ShapeSnap = require("shapesnap")
local Stroke = require("stroke")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local _ = require("i18n")

local Screen = Device.screen
local Input = Device.input


-- The numbers that decide how the pen feels live in `tuning.lua`, one place,
-- each with the range it may take and the reason it is what it is. They are
-- read as `Tuning.<name>` at the point of use: one hash lookup per pen sample,
-- against a blit and an ioctl.

local Canvas = InputContainer:extend{
    document = nil,
    -- Currently selected on-screen tool: "pen", "highlighter" or "eraser".
    tool = "pen",
    -- What the barrel button does while held. The rubber tip always erases.
    barrel_button_tool = "highlighter",
    pen_width = 3,
    pen_color = 0,
    pen_style = "fineliner",
    line_style = "line",
    shape_kind = "rectangle",
    shape_fill = false,
    shape_color = 0,
    highlighter_width = 24,
    -- Highlighter tint in packed RGB form; rendered as gray on monochrome.
    highlighter_color = 0x1FDD835,
    eraser_size = Tuning.spec.eraser_radius.default,
    -- "stroke" removes whole strokes; "area" rubs out only what is under the tip.
    eraser_mode = "stroke",
    -- Off by default: on a device with a pen, a finger on the glass is usually
    -- a hand resting there, not an attempt to draw.
    draw_with_finger = false,
    -- Called with -1 or 1 when the reader swipes to change page.
    on_page_swipe = nil,
    zoom = 1,
}

-- The zoom interaction has its own rendering and refresh policy.
for name, method in pairs(require("zoomcache")) do
    Canvas[name] = method
end
for name, method in pairs(require("zoomcanvas")) do
    Canvas[name] = method
end
for name, method in pairs(require("zoomrefresh")) do
    Canvas[name] = method
end

-- Creating `notebook/_debug_`, `notebook/_debug_.scribe`, or opening a notebook
-- named `_debug_` opts this session into a plain-text input log.
-- Keep the file closed between events so a crash does not lose the trace.
-- Two 1 MiB files bound the storage cost even if the marker is left in place.
local DEBUG_LOG_LIMIT = 1024 * 1024
function Canvas:_debugEvent(kind, slot, x, y, tool)
    if not self.debug_log_path then return end
    local file = io.open(self.debug_log_path, "a")
    if not file then return end
    if (file:seek("end") or 0) >= DEBUG_LOG_LIMIT then
        file:close()
        os.remove(self.debug_log_path .. ".1")
        if not os.rename(self.debug_log_path, self.debug_log_path .. ".1") then return end
        file = io.open(self.debug_log_path, "a")
        if not file then return end
    end
    local format = "%s %s id=%s slot=%s raw=(%s,%s) screen=(%s,%s) tool=%s rotation=%s"
        .. " eraser_button=%s highlighter_button=%s physical_tool=%s\n"
    file:write(string.format(format,
        os.date("!%Y-%m-%dT%H:%M:%SZ"), kind,
        tostring(slot and slot.id), tostring(slot and slot.slot),
        tostring(slot and slot.x), tostring(slot and slot.y),
        tostring(x), tostring(y), tostring(tool),
        tostring(Screen.getTouchRotation and Screen:getTouchRotation()),
        tostring(Input.stylus_eraser_active), tostring(Input.stylus_highlighter_active),
        tostring(self.physical_pen_tool)))
    file:close()
end

function Canvas:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.shape_snap = ShapeSnap.new(function(clean, raw)
        if not self:_isDisplayPaused() then self:_applyShapeSnap(clean, raw) end
    end)
    self:setupZoomRefresh()

    -- The drawable area, which excludes any chrome drawn over the canvas (the
    -- toolbar). Because the live path paints straight into the screen buffer it
    -- would happily scribble under the toolbar, so points whose stamp would not
    -- fit entirely inside this rect are refused outright -- clipping after the
    -- fact would still leave ink in the buffer for the next repaint to reveal.
    self.content = self.content or Geom:new{
        x = 0, y = 0, w = self.dimen.w, h = self.dimen.h,
    }

    -- Points are stored as they arrive, in screen coordinates, so the document
    -- has to be told where this rectangle is or nothing rendering it elsewhere
    -- can put the background under the ink; see Document:contentOrigin.
    if self.document and self.document.setContentOrigin then
        self.document:setContentOrigin(self.content.x, self.content.y)
    end

    -- Live stroke state.
    self.stroke = nil
    self.last_x, self.last_y, self.last_p = nil, nil, nil

    -- Pending refresh region, accumulated between flushes.
    self.pending = nil
    self.last_refresh = nil
    self.idle_flush_scheduled = false
    self.idle_flush_cb = function()
        self.idle_flush_scheduled = false
        self:_flush()
    end

    -- Pending grayscale clean-up, and a stable callback identity so it can be
    -- rescheduled (UIManager:unschedule matches on the function itself).
    self.reconcile = nil
    self.reconcile_cb = function() self:_runReconcile() end

    -- Background auto-save on writing pause
    self.autosave_cb = function()
        if self.stroke or self.erasing or self.dragging_selection or self.shape_gesture
            or self.transform_gesture or self.zoom_stroke or self.zoom_erasing or self.text_preview
            or self.zoom_touch_active or self.zoom_pan_dirty then
            UIManager:scheduleIn(2.5, self.autosave_cb)
            return
        end
        if self.document and self.document.dirty then
            self.document:save()
        end
    end


    -- Set while the pen is in contact, plus the moment it last left, so a hand
    -- resting on the panel can be told from a deliberate touch.
    self.pen_down = false
    self.pen_left_at = nil

    -- Palm rejection, second line: see _isOutlier.
    self.jump_base = Screen:scaleBySize(Tuning.jump_base)
    self.last_point_at = nil
    self.last_sample_at=nil
    self.outliers = 0

    -- Last point the eraser was applied at, so it can rub continuously along
    -- the path instead of only where samples happened to land.
    self.last_erase_x, self.last_erase_y = nil, nil
    self.erase_pending = nil
    self.erase_path = nil
    self.last_erase_apply = nil
    self.last_erase_repaint = nil
    self.erase_flush_scheduled = false
    self.erase_flush_cb = function()
        self.erase_flush_scheduled = false
        self:_flushEraseWork()
    end
    self.shape_preview_cb = function() self:_paintShape() end
    self.transform_preview_cb = function() self:_paintShapeTransform() end
    self.drag_step_cb = function()
        self.drag_step_scheduled = false
        if self.dragging_selection then self:_maybeDragStep() end
    end

    for _, name in ipairs(self.lifecycle_callbacks) do
        local callback = self[name]
        self[name] = Safe.wrap("canvas:" .. name, function(...)
            -- ScreenSaver may already be visible before Suspend is broadcast.
            if self:_isDisplayPaused() then return end
            return callback(...)
        end)
    end

    if Device:isTouchDevice() then
        -- KOReader locates pan/hold releases at the final finger position.
        -- Keep ownership of a zoom drag across the toolbar boundary; new
        -- contacts outside the page still belong to the toolbar.
        -- Edge releases may carry a last raw coordinate just outside the
        -- display. Once owned, a contact must end regardless of its position.
        local owned_zoom_contact = { contains = function() return true end }
        local function zoom_contact_range()
            return self.zoom > 1 and self.zoom_touch_active and owned_zoom_contact or self.content
        end
        self.ges_events = {
            TouchStart        = { GestureRange:new{ ges = "touch",            range = self.content } },
            TouchPan          = { GestureRange:new{ ges = "pan",              range = zoom_contact_range } },
            TouchRelease      = { GestureRange:new{ ges = "pan_release",      range = zoom_contact_range } },
            ZoomHold          = { GestureRange:new{ ges = "hold", range = zoom_contact_range } },
            ZoomHoldPan       = { GestureRange:new{ ges = "hold_pan", range = zoom_contact_range } },
            ZoomTouchEnd      = {
                GestureRange:new{ ges = "tap", range = zoom_contact_range },
                GestureRange:new{ ges = "hold_release", range = zoom_contact_range },
                GestureRange:new{ ges = "double_tap", range = zoom_contact_range },
                GestureRange:new{ ges = "two_finger_tap", range = zoom_contact_range },
                GestureRange:new{ ges = "two_finger_pan_release", range = zoom_contact_range },
                GestureRange:new{ ges = "two_finger_hold_release", range = zoom_contact_range },
                GestureRange:new{ ges = "two_finger_hold_pan_release", range = zoom_contact_range },
            },
            PageSwipe         = { GestureRange:new{ ges = "swipe",            range = zoom_contact_range } },
            PageMultiSwipe    = { GestureRange:new{ ges = "multiswipe",       range = zoom_contact_range } },
            PageTwoFingerSwipe = { GestureRange:new{ ges = "two_finger_swipe", range = zoom_contact_range } },
        }
    end
end

-- Tool resolution --------------------------------------------------------------

--[[--
Decides which tool an incoming stylus event should use.

The on-screen selection is the baseline; the hardware overrides it for as long
as it is engaged. Flipping the pen over, or holding the barrel button, erases
and then hands control straight back to whatever was selected before, so there
is no mode to get stuck in and nothing to remember.

Devices without an eraser tip or barrel buttons simply never send these, and the
on-screen selection is all that applies.
--]]
function Canvas:resolveTool(slot_tool)
    if self.barrel_down or Input.stylus_eraser_active then
        return self.barrel_button_tool
    end
    if slot_tool == Input.TOOL_TYPE_HIGHLIGHTER then
        return "highlighter"
    elseif slot_tool == Input.TOOL_TYPE_ERASER then
        -- The framework reports the eraser tool for two different gestures: the
        -- pen flipped over onto its rubber end, and the barrel button held down.
        -- They arrive identical in the slot, but the barrel button also raises
        -- `stylus_eraser_active`, while the rubber tip does not -- so they can
        -- still be told apart, and given the behaviour each one deserves.
        --
        -- Flipping the pen over to erase is unambiguous. A side button is not,
        -- and duplicating the eraser wastes the only modifier the pen has.
        if Input.stylus_eraser_active then
            return self.barrel_button_tool
        end
        return "eraser"
    end
    return self.tool
end

--- True if a stamp of the given width, centred on (x, y), fits in the drawable area.
function Canvas:_withinContent(x, y, width)
    local pad = math.ceil(width / 2) + 1
    local c = self.content
    return x - pad >= c.x and x + pad <= c.x + c.w
       and y - pad >= c.y and y + pad <= c.y + c.h
end

function Canvas:widthFor(tool)
    if tool == "highlighter" then return self.highlighter_width end
    if tool == "lasso" then return 2 end
    return self.pen_width
end

--[[--
Whether a sample can be the same pen that produced the previous one.

This is palm rejection's second line, and on this hardware it is the one that
matters. The panel and the digitizer are separate input devices feeding one
slot table, and the frame a resting hand produces frequently arrives without
re-stating which slot it belongs to -- so the framework writes the hand's
coordinates into the slot the pen is using, and forwards them here as the nib.
Nothing in the event says otherwise: by the time it reaches a plugin the palm
*is* the pen, at a position half a page away.

Physics is the discriminator left. The nib cannot leave the ink it just laid
down and reappear across the page in a few milliseconds, so a sample that claims
it did is the hand, and is dropped -- not made into a new stroke, which is what
used to happen and is why resting a hand sent the line shooting off.

Dropping is safe because the pen's own frames keep arriving in between: writing
continues uninterrupted underneath the contamination, rather than being cut in
two by it.

@treturn boolean,boolean drop this sample; or start afresh at it
--]]
function Canvas:_isOutlier(x, y, px, py)
    if not px then return false, false end

    local limit = self.jump_base
    if self.last_point_at then
        -- Queued kernel samples may be processed back-to-back after a slow
        -- refresh. Wall-clock processing time would reject a real fast line.
        local ms = self.sample_time and self.last_sample_at
            and time.to_ms(self.sample_time-self.last_sample_at)
            or time.to_ms(time.now()-self.last_point_at)
        ms=math.max(0,ms)
        if ms > Tuning.max_jump_gap_ms then ms = Tuning.max_jump_gap_ms end
        if ms > 0 then limit = limit + ms * Tuning.max_pen_speed end
    end

    local dx, dy = x - px, y - py
    if dx * dx + dy * dy <= limit * limit then
        self.outliers = 0
        return false, false
    end

    -- A real discontinuity -- a pen genuinely picked up and put down without the
    -- lift ever being reported -- would otherwise stall the ink forever. The
    -- hand's contamination is interleaved with the pen's own samples and never
    -- gets a run this long.
    self.outliers = self.outliers + 1
    if self.outliers >= Tuning.outlier_limit then
        self.outliers = 0
        return false, true
    end
    return true, false
end

-- Drawing ----------------------------------------------------------------------

-- Shape recognition and pixel replacement live beside the recognizer.
for name, method in pairs(require("snapcanvas")) do
    Canvas[name] = method
end

for name, method in pairs(require("liveink")) do Canvas[name]=method end

for name, method in pairs(require("viewcanvas")) do Canvas[name]=method end

for name, method in pairs(require("shapecanvas")) do
    Canvas[name] = method
end

function Canvas:_beginStroke(tool, x, y, p)
    -- The pen is back on the page, so the pending tidy-up must stand down: it
    -- would otherwise fire in the middle of the new stroke. The region it had
    -- accumulated is kept, and gets folded into the next one.
    UIManager:unschedule(self.reconcile_cb)
    self.shape_snap:cancel()

    --[[
    Putting any other tool on the page ends the selection.

    Only the lasso itself used to look at whether there was one, so writing
    with the pen while something was selected left the dashed frame and the
    floating menu standing over the new ink, with no way to reach either: the
    menu's buttons still worked, and they acted on strokes the reader had
    stopped thinking about. Choosing a different tool is as clear a statement
    that the selection is finished as tapping outside it.
    --]]
    if tool ~= "lasso" and self.selected_strokes then
        self:_deselectLasso()
    end

    if tool == "text" then
        self.text_at = {x=x, y=y}
        return
    end

    if tool == "shape" then
        self:_beginShape(x, y)
        return
    end

    -- If lasso selection is active, check if touching inside selection to drag/move
    if tool == "lasso" and self.selected_strokes and self.selection_bbox then
        local b = self.selection_bbox
        if x >= b.x - 25 and x <= b.x + b.w + 25 and y >= b.y - 25 and y <= b.y + b.h + 25 then
            self.dragging_selection = true
            self:_useOpaqueTextDuringDrag()
            self.drag_start_x, self.drag_start_y = x, y
            self.drag_last_x, self.drag_last_y = x, y
            if self.lasso_menu then
                UIManager:close(self.lasso_menu)
                self.lasso_menu = nil
            end
            return
        else
            -- Tapped outside selection -> deselect
            self:_deselectLasso()
        end
    end

    self.stroke = Stroke:new{
        tool = tool,
        pen_style = tool == "pen" and self.pen_style or nil,
        width = self:widthFor(tool),
        color = tool == "pen" and self:_penColor() or 0,
    }
    if tool == "highlighter" then self.stroke.tint = self.highlighter_color end
    self:_beginLiveInk(self.stroke)
    self.refresh_mode = "fast"
    self.stroke:addPoint(x, y, p)
    self.last_x, self.last_y, self.last_p = x, y, p
    self.last_point_at = time.now()
    self.last_sample_at=self.sample_time
    self.outliers = 0

    self.shape_snap:begin(self.stroke, x, y, self.line_style)


    -- Put down the initial dot so a tap leaves a mark rather than nothing.
    local rx, ry, rw, rh = Renderer.drawSegment(Screen.bb, self:_liveBrush(self.stroke),
        x, y, p, x, y, p, nil, Screen.isColorEnabled and Screen:isColorEnabled())
    self:_trackLiveInk(rx, ry, rw, rh)
    self:_accumulate(rx, ry, rw, rh)
    self:_maybeFlush()
end

require("selectioncanvas").install(Canvas)

function Canvas:_extendStroke(x, y, p)
    if self.text_at then return end
    if self.shape_gesture then return self:_extendShape(x, y) end
    -- Handle dragging selected strokes
    if self.dragging_selection and self.selected_strokes then
        local dx = x - (self.drag_last_x or x)
        local dy = y - (self.drag_last_y or y)
        if dx ~= 0 or dy ~= 0 then
            self.drag_last_x, self.drag_last_y = x, y
            self.drag_dx = (self.drag_dx or 0) + dx
            self.drag_dy = (self.drag_dy or 0) + dy
            self:_maybeDragStep()
        end
        return
    end

    if not self.stroke then return end
    if self.shape_snap.snapped then return end
    -- Ignore repeats; they cost a refresh and add nothing.
    if x == self.last_x and y == self.last_y then return end

    local drop, afresh = self:_isOutlier(x, y, self.last_x, self.last_y)
    if drop then return end
    if afresh then
        local tool = self.stroke.tool
        self:_endStroke()
        self:_beginStroke(tool, x, y, p)
        return
    end
    self.last_point_at = time.now()
    self.last_sample_at=self.sample_time


    -- Wobble under a resting nib is not movement, and stamping it costs a
    -- refresh for nothing. See Tuning.jitter_floor_sq: this rounds the path, it does
    -- not sample it.
    local jdx = x - self.last_x
    local jdy = y - self.last_y
    if jdx * jdx + jdy * jdy < Tuning.jitter_floor_sq then return end

    local rx, ry, rw, rh = Renderer.drawSegment(Screen.bb, self:_liveBrush(self.stroke),
        self.last_x, self.last_y, self.last_p, x, y, p, nil,
        Screen.isColorEnabled and Screen:isColorEnabled())
    self.stroke:addPoint(x, y, p)
    self.last_x, self.last_y, self.last_p = x, y, p
    self.shape_snap:moved(x, y)

    self:_trackLiveInk(rx, ry, rw, rh)
    self:_accumulate(rx, ry, rw, rh)
    self:_maybeFlush()
end

function Canvas:_endStroke()
    self.shape_snap:cancel()
    if self.transform_gesture then return self:_endShapeTransform() end
    if self.text_at then
        local at=self.text_at; self.text_at=nil
        if not self.stopping and self.on_text then self:on_text(at.x,at.y) end
        return
    end
    if self.shape_gesture then return self:_endShape() end
    if self.dragging_selection then
        UIManager:unschedule(self.drag_step_cb)
        self.drag_step_scheduled = false
        self.dragging_selection = false
        -- Whatever the last interval had not got to yet. The menu is placed
        -- against the selection's box, so this has to happen before it is
        -- shown or it would be pinned to where the selection nearly was.
        self:_dragStep()
        self:_settleDrag()
        self.document:recordTranslation(self.selected_strokes,
            self.drag_moved_dx or 0, self.drag_moved_dy or 0)
        self.drag_moved_dx, self.drag_moved_dy = nil, nil
        self:_showLassoMenu(self.selected_strokes)
        if self.on_change then self:on_change() end
        return
    end

    if not self.stroke then return end
    local stroke = self.stroke
    self.stroke = nil
    self.last_x, self.last_y, self.last_p = nil, nil, nil
    self.last_point_at = nil
    self.last_sample_at=nil

    self:_flush()

    if stroke:count() > 0 then
        if stroke.tool == "lasso" then
            local bx, by, bw, bh = stroke:getBounds()
            if bx then self:_repaintRegion(bx, by, bw, bh) end

            local lasso_pts = {}
            for i = 1, stroke:count() do
                local px, py = stroke:getPoint(i)
                table.insert(lasso_pts, { x = px, y = py })
            end

            local selected = Lasso.findSelectedStrokes(self.document:getPage().strokes, lasso_pts)
            if #selected > 0 then
                self:_showLassoMenu(selected)
            else
                self:_deselectLasso()
            end
            return
        end

        self.document:addStroke(stroke)
        if not self:_finishLiveInk(stroke) then
            self:_scheduleReconcile(stroke:getBounds())
        end

        -- Schedule auto-save 2.5s after pause in writing
        if self.document.dirty then
            UIManager:unschedule(self.autosave_cb)
            UIManager:scheduleIn(2.5, self.autosave_cb)
        end
    end
    if self.on_change then self:on_change() end
end

for name, method in pairs(require("canvasrefresh")) do Canvas[name] = method end

for name, method in pairs(require("canvasrender")) do
    Canvas[name] = method
end

for name, method in pairs(require("erasercanvas")) do
    Canvas[name] = method
end

for _, module in ipairs({"stylusinput", "touchinput"}) do
    for name, method in pairs(require(module)) do
        Canvas[name] = method
    end
end

--[[--
Starts and stops listening to the pen.

Plain methods, called by the notebook, rather than `onShow` and `onCloseWidget`
event handlers. A container passes an event to its children first and only runs
its own handler if none of them consumed it, so a canvas that answered `Show`
with `true` silenced the notebook's own handler -- and with it the full refresh
that puts the notebook on the panel. Lifecycle that the parent drives should be
called by the parent, not arrived at through event propagation.
--]]
for name, method in pairs(require("canvaslifecycle")) do Canvas[name] = method end

--[[--
Protected like every other screen, but without the watchdog.

The events this class handles are finger touches while drawing, and a count hook
around those would take LuaJIT off its compiled traces on the very path that has
to keep up with a hand. The pcall costs nothing and is what matters here: it
means a fault while drawing closes the notebook rather than the reader.
--]]
return Safe.widget(Canvas, "canvas", false)
