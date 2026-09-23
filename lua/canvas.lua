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

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Lasso = require("lasso")
local LassoMenu = require("lassomenu")
local Rect = require("rect")
local Renderer = require("renderer")
local Safe = require("safe")
local Shape = require("shape")
local Stroke = require("stroke")
local Template = require("template")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

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
    pen_style = "fineliner",
    line_style = "line",
    shape_kind = "rectangle",
    highlighter_width = 24,
    eraser_size = Tuning.spec.eraser_radius.default,
    -- "stroke" removes whole strokes; "area" rubs out only what is under the tip.
    eraser_mode = "stroke",
    -- Off by default: on a device with a pen, a finger on the glass is usually
    -- a hand resting there, not an attempt to draw.
    draw_with_finger = false,
    -- Called with -1 or 1 when the reader swipes to change page.
    on_page_swipe = nil,
}

function Canvas:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

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
        if self.stroke or self.erasing or self.dragging_selection or self.shape_gesture then
            UIManager:scheduleIn(2.5, self.autosave_cb)
            return
        end
        if self.document and self.document.dirty then
            self.document:save()
        end
    end

    -- Real-time hold-to-snap callback
    self.shape_snap_cb = function()
        self:_triggerShapeSnap()
    end

    -- Set while the pen is in contact, plus the moment it last left, so a hand
    -- resting on the panel can be told from a deliberate touch.
    self.pen_down = false
    self.pen_left_at = nil

    -- Palm rejection, second line: see _isOutlier.
    self.jump_base = Screen:scaleBySize(Tuning.jump_base)
    self.last_point_at = nil
    self.outliers = 0

    -- Last point the eraser was applied at, so it can rub continuously along
    -- the path instead of only where samples happened to land.
    self.last_erase_x, self.last_erase_y = nil, nil
    self.erase_pending = nil
    self.last_erase_repaint = nil
    self.erase_flush_scheduled = false
    self.erase_flush_cb = function()
        self.erase_flush_scheduled = false
        self:_flushEraseRepaint()
    end
    self.shape_preview_cb = function() self:_paintShape() end
    self.drag_step_cb = function()
        self.drag_step_scheduled = false
        if self.dragging_selection then self:_maybeDragStep() end
    end

    for _, name in ipairs({"idle_flush_cb", "reconcile_cb", "autosave_cb",
        "shape_snap_cb", "erase_flush_cb", "drag_step_cb", "shape_preview_cb"}) do
        self[name] = Safe.wrap("canvas:" .. name, self[name])
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            TouchStart        = { GestureRange:new{ ges = "touch",            range = self.content } },
            TouchPan          = { GestureRange:new{ ges = "pan",              range = self.content } },
            TouchRelease      = { GestureRange:new{ ges = "pan_release",      range = self.content } },
            PageSwipe         = { GestureRange:new{ ges = "swipe",            range = self.content } },
            PageMultiSwipe    = { GestureRange:new{ ges = "multiswipe",       range = self.content } },
            PageTwoFingerSwipe = { GestureRange:new{ ges = "two_finger_swipe", range = self.content } },
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

-- Refresh management -----------------------------------------------------------

--- Merges a rectangle into the pending refresh region.
function Canvas:_accumulate(x, y, w, h)
    self.pending = Rect.grow(self.pending, x, y, w, h)
end

--[[--
Shows a rectangle now, clipped to the drawing area.

Every rectangle that reaches the panel goes through here or through `_flush`,
and for the same two reasons. The framebuffer drops a region that hangs over
the edge of the screen, so a selection dragged against the left margin -- whose
frame is drawn a few pixels outside it -- asked for a refresh at a negative x
and got nothing back. And the toolbar sits directly above the drawing area, so
a rectangle that overhangs it upwards refreshes the buttons under a fast
waveform and makes them flash for no reason.
--]]
function Canvas:_refreshNow(x, y, w, h, mode)
    x, y, w, h = Rect.clamp(x, y, w, h, self.content)
    if not x then return end
    if mode == "ui" then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshFast(x, y, w, h)
    end
end

--- Issues the pending partial refresh, if any.
function Canvas:_flush()
    local p = self.pending
    if not p then return end
    self.pending = nil
    self.last_refresh = time.now()

    -- Clamp to the drawable area; the framebuffer rejects out-of-bounds regions,
    -- and refreshing over the toolbar would make it flicker for no reason.
    local x, y, w, h = Rect.clamp(p.x, p.y, p.w, p.h, self.content)
    if not x then return end

    -- Waveform choice while a stroke is live.
    --
    --  * refreshPartial (grayscale/REAGL) is forced to UPDATE_MODE_FULL by the
    --    driver, and full updates are fenced, so every segment blocks on the
    --    previous one and the ink crawls behind the nib.
    --  * refreshFast (DU) is binary, so it cannot reveal grayscale marker ink.
    --    The highlighter uses refreshUI at a separately throttled cadence and
    --    is redrawn at its lighter resting tint on lift.
    --
    -- refreshUI (AUTO) also remains necessary for pencil gray. Calling it for
    -- every raw sample queues work; _maybeFlush coalesces marker samples.
    if self.refresh_mode == "ui" then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshFast(x, y, w, h)
    end
end

--- Flushes now if enough time has passed, otherwise arranges for it to happen.
function Canvas:_maybeFlush()
    local now = time.now()
    local interval = self.stroke and self.stroke.tool == "highlighter"
        and Tuning.live_highlight_refresh_ms or Tuning.refresh_interval_ms
    local elapsed = self.last_refresh and time.to_ms(now - self.last_refresh) or interval
    if not self.last_refresh
        or elapsed >= interval then
        self:_flush()
        return
    end

    if not self.idle_flush_scheduled then
        self.idle_flush_scheduled = true
        -- Pen ink can use the ordinary idle delay. The marker must also honour
        -- its slower grayscale cadence or repeated AUTO updates queue faster
        -- than an e-ink panel can display them.
        local delay=math.max(Tuning.idle_flush_ms,interval-elapsed)
        UIManager:scheduleIn(delay / 1000, self.idle_flush_cb)
    end
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
        local ms = time.to_ms(time.now() - self.last_point_at)
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

-- Shape snap in real time while holding still
function Canvas:_triggerShapeSnap()
    if not self.stroke or self.shape_snapped or self.stroke:count() < 4 or self.erasing or self.dragging_selection then
        return
    end
    local clean = Shape.recognize(self.stroke, self.line_style)
    if clean then
        self.shape_snapped = true
        local bx, by, bw, bh = self.stroke:getBounds()
        self.stroke = clean
        if bx then
            self:_repaintRegion(bx, by, bw, bh, true)
            -- The refresh has to cover what the raw stroke occupied as well as
            -- what the tidied one does, and the tidied one is often the smaller
            -- of the two: a wide scrawl becomes a compact circle. Refreshing
            -- only the shape left the parts of the scrawl outside it corrected
            -- in the buffer and still on the panel, as a ghost that stayed
            -- until something else happened to repaint over it.
            self:_accumulate(bx, by, bw, bh)
        end
        local nbx, nby, nbw, nbh = clean:getBounds()
        if nbx then
            Renderer.drawStroke(Screen.bb, clean, self.content)
            self:_accumulate(nbx, nby, nbw, nbh)
        end
        self:_flush()
    end
end

-- Drawing ----------------------------------------------------------------------

function Canvas:_beginShape(x, y, original)
    UIManager:unschedule(self.shape_snap_cb)
    UIManager:unschedule(self.reconcile_cb)
    self.shape_gesture = {x=x, y=y, original=original,
        kind=original and original.shape_kind or self.shape_kind or "rectangle"}
    self:_deselectLasso()
    if original then self:_repaintRegion(original:getBounds()) end
    -- One immutable raster snapshot per gesture replaces rerendering all the
    -- underlying vector ink on every preview frame (about 5 MB on a Scribe).
    self.shape_gesture.background = Screen.bb:copy()
    self.refresh_mode = "fast"
end

function Canvas:_extendShape(x, y)
    local gesture = self.shape_gesture
    gesture.next_x, gesture.next_y = x, y
    local spacing = Screen:scaleBySize(24)
    local px, py = gesture.paint_x or gesture.x, gesture.paint_y or gesture.y
    local dx, dy = x-px, y-py
    if dx*dx+dy*dy >= spacing*spacing then
        self:_paintShape()
    else
        -- Trailing debounce: a slow stream of one-pixel samples must not make
        -- us repaint a page-sized preview over and over. It still catches up
        -- shortly after the nib pauses, and release always paints the endpoint.
        UIManager:unschedule(self.shape_preview_cb)
        gesture.scheduled = true
        UIManager:scheduleIn(0.12, self.shape_preview_cb)
    end
end

function Canvas:_paintShape()
    local gesture = self.shape_gesture
    if not gesture or not gesture.next_x then return end
    gesture.last_paint = time.now()
    UIManager:unschedule(self.shape_preview_cb)
    gesture.scheduled = nil
    local x, y = gesture.next_x, gesture.next_y
    gesture.paint_x, gesture.paint_y = x, y
    gesture.next_x, gesture.next_y = nil, nil
    local original = gesture.original
    local x0, y0 = gesture.x, gesture.y
    if original then x0, y0 = original.x_min, original.y_min end
    local clean
    if original and original.text then
        clean=require("textobject").create(original.text,x0,y0,math.max(40,x-x0),
            original.font_size,{font_family=original.font_family,text_bold=original.text_bold,
                text_italic=original.text_italic,text_underline=original.text_underline})
    else
        clean = Shape.create(gesture.kind, x0, y0, x, y,
            original and original.width or self.pen_width, original and original.color or 0)
    end
    local old = self.stroke
    self.stroke = nil
    if old then
        local bx, by, bw, bh = old:getBounds()
        -- getBounds can reach beyond the drawing area at the initial point.
        bx, by, bw, bh = Rect.clamp(bx, by, bw, bh, self.content)
        if bx then
            Screen.bb:blitFrom(gesture.background, bx, by, bx, by, bw, bh)
            self:_accumulate(bx, by, bw, bh)
        end
    end
    self.stroke = clean
    if clean then
        Renderer.drawStroke(Screen.bb, clean, self.content)
        self:_accumulate(clean:getBounds())
    end
    self:_flush()
end

function Canvas:_endShape()
    UIManager:unschedule(self.shape_preview_cb)
    self:_paintShape()
    local gesture, stroke = self.shape_gesture, self.stroke
    if gesture.background then gesture.background:free(); gesture.background = nil end
    self.shape_gesture, self.stroke = nil, nil
    self:_flush()
    if stroke and stroke.x_max-stroke.x_min >= 4 and stroke.y_max-stroke.y_min >= 4 then
        if gesture.original then
            self.document:replaceStroke(gesture.original, stroke)
            -- The preview background still contains the old shape. Clean the
            -- union once after a resize; repainting old and new separately did
            -- the same expensive vector pass twice.
            local dirty = Rect.grow(nil, gesture.original:getBounds())
            dirty = Rect.grow(dirty, stroke:getBounds())
            self:_repaintRegion(dirty.x, dirty.y, dirty.w, dirty.h)
        else
            self.document:addStroke(stroke)
            -- The final preview is already the exact stored shape. Repainting
            -- it from the document here made pen-up look frozen, especially
            -- for a large, thick figure.
        end
        if not self.stopping then
            self:_showLassoMenu({stroke})
            UIManager:unschedule(self.autosave_cb)
            UIManager:scheduleIn(2.5, self.autosave_cb)
        end
        if self.on_change then self:on_change() end
    else
        if stroke then self:_repaintRegion(stroke:getBounds()) end
        if gesture.original then self:_repaintRegion(gesture.original:getBounds()) end
    end
end

function Canvas:_beginStroke(tool, x, y, p)
    -- The pen is back on the page, so the pending tidy-up must stand down: it
    -- would otherwise fire in the middle of the new stroke. The region it had
    -- accumulated is kept, and gets folded into the next one.
    UIManager:unschedule(self.reconcile_cb)
    UIManager:unschedule(self.shape_snap_cb)

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
        width = self:widthFor(tool),
        color = tool == "pen" and self.pen_style == "pencil" and 96 or 0,
    }
    -- Grayscale marker pixels are not reliably visible through the binary DU
    -- waveform. Use AUTO for the marker, but at its own slower cadence, so the
    -- band follows the nib with a small bounded delay instead of disappearing
    -- until lift-off or building an ever-growing refresh queue.
    self.refresh_mode = (tool == "highlighter" or self.stroke.color ~= 0) and "ui" or "fast"
    -- While it is being drawn the highlighter lays down a darker tint than the
    -- one it settles to when the pen lifts; see Tuning.live_highlight_tint.
    self.stroke.tint = tool == "highlighter" and Tuning.live_highlight_tint or nil
    self.stroke:addPoint(x, y, p)
    self.last_x, self.last_y, self.last_p = x, y, p
    self.last_point_at = time.now()
    self.outliers = 0

    -- Hold-to-snap shape recognition tracking
    self.hold_start_x = x
    self.hold_start_y = y
    self.shape_snapped = false
    if tool ~= "eraser" and tool ~= "lasso" then
        UIManager:scheduleIn(Tuning.hold_delay_ms / 1000, self.shape_snap_cb)
    end

    -- Put down the initial dot so a tap leaves a mark rather than nothing.
    local rx, ry, rw, rh = Renderer.drawSegment(Screen.bb, self.stroke,
        x, y, p, x, y, p)
    self:_accumulate(rx, ry, rw, rh)
    self:_maybeFlush()
end

--[[--
Applies the movement gathered since the last one, and shows it.

The bounding box is carried rather than recomputed. It is the same rectangle
translated -- a selection that moves does not change shape -- so asking every
stroke in it where it now is would be work whose answer is already known.

`Rect.grow` mutates the box it is given, so the old one is copied before it is
grown over the new one; growing `self.selection_bbox` in place would leave the
selection believing it covers both where it is and where it was, and the dashed
frame would drift wider on every step.

Both boxes are padded by the margin the dashed frame is drawn at, and that is
not decoration. The frame sits *outside* the selection, so a region covering
only the selection's own bounds repaints everything except the frame around it
-- and the frame stays on the screen. At two pixels a step that went unnoticed,
because the next step painted over it; at a step of a whole interval the leftover
frames stand apart, and a drag across the page leaves a trail of dozens of them.
--]]

function Canvas:_dragStep()
    local dx, dy = self.drag_dx or 0, self.drag_dy or 0
    self.drag_dx, self.drag_dy = 0, 0
    if dx == 0 and dy == 0 then return end
    if not self.selected_strokes then return end

    local old_b = self.selection_bbox or Lasso.getSelectionBounds(self.selected_strokes)
    if not old_b then return end

    Lasso.translateStrokes(self.selected_strokes, dx, dy)
    -- The whole distance the selection has travelled since it was picked up:
    -- the drag arrives as dozens of steps, and one entry in the history that
    -- undoes all of them is what the hand did. Cleared when the drag ends, so
    -- a fresh one starts from nothing without either caller having to say so.
    self.drag_moved_dx = (self.drag_moved_dx or 0) + dx
    self.drag_moved_dy = (self.drag_moved_dy or 0) + dy
    local new_b = { x = old_b.x + dx, y = old_b.y + dy, w = old_b.w, h = old_b.h }
    self.selection_bbox = new_b

    local m = Tuning.frame_margin
    local box = Rect.grow(
        { x = old_b.x - m, y = old_b.y - m, w = old_b.w + 2 * m, h = old_b.h + 2 * m },
        new_b.x - m, new_b.y - m, new_b.w + 2 * m, new_b.h + 2 * m)
    self:_repaintRegion(box.x, box.y, box.w, box.h, true)
    Renderer.drawDashedRect(Screen.bb, new_b.x - 6, new_b.y - 6, new_b.w + 12, new_b.h + 12)
    self:_refreshNow(box.x, box.y, box.w, box.h)

    -- Everywhere the selection has been during this drag, for the one clean
    -- refresh that ends it; see _settleDrag.
    self.drag_touched = Rect.grow(self.drag_touched, box.x, box.y, box.w, box.h)
    self.last_drag_step = time.now()
end

--[[--
Clears what the fast refreshes left behind, once the pen is up.

The copies of the selection trailing behind it are not drawn by anything: the
buffer holds one selection, in one place, and every step repaints the region it
came from. They are the panel. A fast refresh drives each pixel with a short
waveform that gets it close to the value asked for without settling it, which is
what makes it fast, and what it does not settle is a faint remainder of what was
there before. Ten steps, ten remainders.

They cannot be avoided during the drag: the refresh that does settle a pixel
takes long enough that using it here is the slow, lagging version this was
trying to get away from. So the drag keeps the fast one and pays for it once, at
the end, over everywhere it has been -- which is a single refresh of an area
that is already correct in the buffer, and takes the trail with it.
--]]
function Canvas:_settleDrag()
    local touched = self.drag_touched
    self.drag_touched = nil
    if not touched then return end

    self:_repaintRegion(touched.x, touched.y, touched.w, touched.h, true)
    local b = self.selection_bbox
    if b then
        Renderer.drawDashedRect(Screen.bb, b.x - 6, b.y - 6, b.w + 12, b.h + 12)
    end
    self:_refreshNow(touched.x, touched.y, touched.w, touched.h, "ui")
end

--[[--
Moves the selection now if enough time has passed, or shortly if not.

The deferred call is what makes the last movement land. Without it a drag that
stops inside the interval -- which every drag does, since it ends when the pen
lifts -- would leave the final few pixels of travel applied to the strokes but
never drawn, and the selection would settle a fraction away from where it was
put down.
--]]
function Canvas:_maybeDragStep()
    local now = time.now()
    if not self.last_drag_step
        or time.to_ms(now - self.last_drag_step) >= Tuning.drag_repaint_ms then
        return self:_dragStep()
    end

    if not self.drag_step_scheduled then
        self.drag_step_scheduled = true
        local remaining = Tuning.drag_repaint_ms - time.to_ms(now - self.last_drag_step)
        UIManager:scheduleIn(math.max(1, remaining) / 1000, self.drag_step_cb)
    end
end

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

    if self.shape_snapped then return end

    -- Hold-to-snap: the anchor only moves once the nib has genuinely travelled,
    -- and while it has not, the pending snap is left alone to come due.
    if self.stroke.tool ~= "eraser" and self.stroke.tool ~= "lasso" then
        local hdx = x - (self.hold_start_x or x)
        local hdy = y - (self.hold_start_y or y)
        if hdx * hdx + hdy * hdy > Tuning.hold_travel_sq then
            self.hold_start_x = x
            self.hold_start_y = y
            UIManager:unschedule(self.shape_snap_cb)
            if self.stroke:count() >= 4 then
                UIManager:scheduleIn(Tuning.hold_delay_ms / 1000, self.shape_snap_cb)
            end
        end
    end

    -- Wobble under a resting nib is not movement, and stamping it costs a
    -- refresh for nothing. See Tuning.jitter_floor_sq: this rounds the path, it does
    -- not sample it.
    local jdx = x - self.last_x
    local jdy = y - self.last_y
    if jdx * jdx + jdy * jdy < Tuning.jitter_floor_sq then return end

    local rx, ry, rw, rh = Renderer.drawSegment(Screen.bb, self.stroke,
        self.last_x, self.last_y, self.last_p, x, y, p)
    self.stroke:addPoint(x, y, p)
    self.last_x, self.last_y, self.last_p = x, y, p

    self:_accumulate(rx, ry, rw, rh)
    self:_maybeFlush()
end

function Canvas:_endStroke()
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

    self:_flush()

    if stroke:count() > 0 then
        if stroke.tool == "lasso" then
            local bx, by, bw, bh = stroke:getBounds()
            if bx then self:_repaintRegion(bx, by, bw, bh) end

            -- Quick tap on canvas with clipboard contents -> Paste at tap position!
            if (not bw or (bw < 24 and bh < 24)) and Canvas.clipboard and #Canvas.clipboard > 0 then
                local cb_bbox = Lasso.getSelectionBounds(Canvas.clipboard)
                local cx = cb_bbox and (cb_bbox.x + cb_bbox.w / 2) or self.content.x
                local cy = cb_bbox and (cb_bbox.y + cb_bbox.h / 2) or self.content.y
                local tap_x, tap_y = stroke:getPoint(1)
                local dx = tap_x - cx
                local dy = tap_y - cy

                local pasted = {}
                self.document:beginBatch()
                for _, s in ipairs(Canvas.clipboard) do
                    local copy = s:clone()
                    copy:translate(dx,dy)
                    table.insert(pasted, copy)
                    self.document:addStroke(copy)
                end
                self.document:commitBatch()
                self:_repaintRegion(self.content.x, self.content.y, self.content.w, self.content.h)
                if self.on_change then self:on_change() end
                self:_showLassoMenu(pasted)
                return
            end

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

        local was_live_highlight = stroke.tint ~= nil
        -- What is stored is the ordinary highlight; the darker tint belonged to
        -- the drawing of it, not to the mark.
        stroke.tint = nil
        self.document:addStroke(stroke)
        if stroke.tool == "highlighter" then
            -- Repaint the band from the model, which takes the live tint back
            -- down to the one every other highlight is drawn at.
            if was_live_highlight then
                self:_repaintRegion(stroke:getBounds())
            end
        else
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

function Canvas:_showLassoMenu(selected)
    if self.lasso_menu then
        UIManager:close(self.lasso_menu)
        self.lasso_menu = nil
    end

    self.selected_strokes = selected
    local bbox = Lasso.getSelectionBounds(selected)
    self.selection_bbox = bbox

    -- Draw dashed selection outline
    if bbox then
        Renderer.drawDashedRect(Screen.bb, bbox.x - 6, bbox.y - 6, bbox.w + 12, bbox.h + 12)
        self:_refreshNow(bbox.x - 8, bbox.y - 8, bbox.w + 16, bbox.h + 16)
    end

    if #selected == 1 and selected[1].shape_kind then
        local shape = selected[1]
        Renderer.drawDashedRect(Screen.bb, shape.x_max-9, shape.y_max-9, 18, 18)
        self:_refreshNow(shape.x_max-12, shape.y_max-12, 24, 24)
    end

    self.lasso_menu = LassoMenu:new{
        bbox = bbox or { x = self.content.x + 100, y = self.content.y + 100, w = 200, h = 100 },
        has_clipboard = Canvas.clipboard ~= nil and #Canvas.clipboard > 0,
        on_edit = #selected == 1 and selected[1].text and self.on_edit_text and function()
            local text = selected[1]
            self.lasso_menu = nil
            self.selected_strokes, self.selection_bbox = nil, nil
            self:on_edit_text(text)
        end or nil,
        on_cut = function()
            self.lasso_menu = nil
            --[[
            Copies, like the copy above, and for a reason cut makes easy to
            miss: the strokes it takes off the page are not gone, they are on
            the undo stack, and one press of undo puts those very objects back
            where they were. Holding the originals meant the clipboard went on
            following them -- move the restored writing and what came out of a
            later paste was where it had been moved to, not what had been cut.
            ]]
            Canvas.clipboard = Lasso.cloneStrokes(selected)
            local box = self.selection_bbox
            self.document:removeStrokes(selected)
            self.selected_strokes = nil
            self.selection_bbox = nil
            self:_repaintSelection(box)
            if self.on_change then self:on_change() end
        end,
        on_copy = function()
            self.lasso_menu = nil
            Canvas.clipboard = Lasso.cloneStrokes(selected)
            self:_deselectLasso()
        end,
        on_paste = function()
            self.lasso_menu = nil
            if not Canvas.clipboard or #Canvas.clipboard == 0 then return end
            local pasted = {}
            self.document:beginBatch()
            for _, s in ipairs(Canvas.clipboard) do
                local copy = s:clone()
                copy:translate(40,40)
                table.insert(pasted, copy)
                self.document:addStroke(copy)
            end
            self.document:commitBatch()
            self:_repaintRegion(self.content.x, self.content.y, self.content.w, self.content.h)
            if self.on_change then self:on_change() end
            self:_showLassoMenu(pasted)
        end,
        on_delete = function()
            self.lasso_menu = nil
            local box = self.selection_bbox
            self.document:removeStrokes(selected)
            self.selected_strokes = nil
            self.selection_bbox = nil
            self:_repaintSelection(box)
            if self.on_change then self:on_change() end
        end,
        on_close = function()
            self.lasso_menu = nil
            self:_deselectLasso()
        end,
    }
    UIManager:show(self.lasso_menu)
end

function Canvas:_deselectLasso()
    self.erased_shape_selection = nil
    if not self.selected_strokes and not self.selection_bbox and not self.lasso_menu then return end
    if self.lasso_menu then
        UIManager:close(self.lasso_menu)
        self.lasso_menu = nil
    end
    local bx = self.selection_bbox
    self.selected_strokes = nil
    self.selection_bbox = nil
    self:_repaintSelection(bx)
end

--[[--
Repaints where a selection was, frame and all, or the page if it is not known.

The frame is drawn *outside* the box the selection occupies, so repainting the
box alone leaves the dashes standing around an empty rectangle. The slack is
the one the drag uses, which is now a number the reader can change: taking it
back to the ten that used to be written here would leave a ring of dashes
behind for anyone who had raised it.

Cut and delete used to repaint the whole drawing area instead. What they take
away is inside the selection by definition, so that was a full-page raster and
a full-page refresh -- the two operations that most obviously ought to be
instant were the two slowest things the lasso could do.
--]]
function Canvas:_repaintSelection(box)
    if not box then
        return self:_repaintRegion(self.content.x, self.content.y,
            self.content.w, self.content.h)
    end
    local m = Tuning.frame_margin
    self:_repaintRegion(box.x - m, box.y - m, box.w + 2 * m, box.h + 2 * m)
end

--[[--
Queues the grayscale clean-up for an area, coalescing it with anything already
pending and pushing the deadline back.

Deliberately *not* a UIManager repaint. The pixels in the screen buffer are
already correct -- the fast path drew them -- so all that is needed is the same
area shown again under a better waveform. Going through UIManager would instead
repaint the whole widget, which means rasterising every stroke on the page from
the vector model, and that cost grows with each stroke until writing stalls.
--]]
function Canvas:_scheduleReconcile(x, y, w, h)
    self.reconcile = Rect.grow(self.reconcile, x, y, w, h)

    UIManager:unschedule(self.reconcile_cb)
    UIManager:scheduleIn(Tuning.reconcile_delay_ms / 1000, self.reconcile_cb)
end

function Canvas:_runReconcile()
    local r = self.reconcile
    if not r then return end
    self.reconcile = nil

    local x, y, w, h = Rect.clamp(r.x, r.y, r.w, r.h, self.content)
    if not x then return end

    -- The grayscale waveform is slow and blocks, which is normally fine here:
    -- this runs once, after the pen has been still for a moment.
    --
    -- But its cost scales with the area, and the area is the bounding box of
    -- what was drawn. One long diagonal stroke has a bounding box the size of
    -- the page, and a few of them coalesce into the whole screen -- so the
    -- "invisible" clean-up turns into a blocking full-screen update, and
    -- writing long lines feels like it stalls.
    --
    -- Past a threshold, hand it to AUTO instead: the driver picks something
    -- cheaper, and it is not forced to a fenced full update.
    -- AUTO, not the grayscale waveform.
    --
    -- The grayscale one is REAGL, which the driver forces to a fenced full
    -- update: it blocks. Landing that mid-sentence -- and a pause between two
    -- words is exactly when it lands -- reads as the pen freezing and the page
    -- reloading. Letting the driver choose keeps the tidy-up out of the way.
    Screen:refreshUI(x, y, w, h)
end

--- Closes the eraser's undo group, if one is open.
function Canvas:_endErase()
    UIManager:unschedule(self.erase_flush_cb)
    self.erase_flush_scheduled = false
    self:_flushEraseRepaint()
    local shapes = self.erase_shapes
    self.erase_shapes = nil
    local b = self.erase_bounds
    self.erase_bounds = nil
    if b then
        self.document:commitBatch(b.x, b.y, b.w, b.h)
    else
        self.document:commitBatch()
    end
    if shapes and not Safe.failed and not self.stopping then
        local selected = {}
        for _, stroke in ipairs(self.document:getPage().strokes) do
            if shapes[stroke] then table.insert(selected, stroke) end
        end
        if #selected > 0 then
            self.erased_shape_selection = true
            self:_showLassoMenu(selected)
        end
    end
end

--[[--
Rubs out along the path travelled since the last event, in one pass.

The digitizer samples far apart when the hand moves quickly, and an eraser
applied only at those sample points skips the gaps between them. The fix used to
be to interpolate steps along the segment and apply the eraser at each one --
which was continuous, but meant walking every stroke on the page a dozen times
for one flick, and that cost is what made the eraser lag behind the hand,
arrive in jerks, and take out whatever was under the tip several samples ago.

Now the segment itself is handed to the model, which measures against it. One
pass, and the swept shape is a true capsule rather than a row of circles.
--]]
function Canvas:_eraseAlong(x, y)
    local px, py = self.last_erase_x, self.last_erase_y

    -- The hand's contact can be forwarded as the pen's, exactly as it can while
    -- writing (see _isOutlier) -- and here believing it would sweep the rubber
    -- across everything between the nib and the palm.
    local drop, afresh = self:_isOutlier(x, y, px, py)
    if drop then return end
    if afresh then px, py = nil, nil end

    self.last_erase_x, self.last_erase_y = x, y
    self.last_point_at = time.now()

    -- One sweep of the eraser is one undoable action, however far it travels.
    if not px then
        self.document:beginBatch()
        px, py = x, y
    end

    self.erase_shapes = self.erase_shapes or {}
    local path = { px, py, x, y }
    local hit, rx, ry, rw, rh, ux, uy, uw, uh
    if self.eraser_mode == "area" then
        hit, rx, ry, rw, rh, ux, uy, uw, uh =
            self.document:eraseAreaAlongPath(path, self.eraser_size, self.erase_shapes)
    else
        hit, rx, ry, rw, rh = self.document:eraseAlongPath(path, self.eraser_size, self.erase_shapes)
    end

    if hit then
        -- Two regions, when the model distinguishes them: the small one is what
        -- has to be shown again now, the large one is what undo would have to
        -- put back. Repainting the large one on every sample is what made the
        -- area eraser crawl.
        self:_noteErased(ux or rx, uy or ry, uw or rw, uh or rh)
        self:_queueEraseRepaint(rx, ry, rw, rh)
        if self.on_change then self:on_change() end
    end
end

--- Merges a region into the pending erase repaint, flushing on a timer.
function Canvas:_queueEraseRepaint(x, y, w, h)
    self.erase_pending = Rect.grow(self.erase_pending, x, y, w, h)

    local now = time.now()
    if not self.last_erase_repaint
        or time.to_ms(now - self.last_erase_repaint) >= Tuning.erase_repaint_ms then
        self:_flushEraseRepaint()
    elseif not self.erase_flush_scheduled then
        -- Too soon to repaint again, so make sure something comes back for it.
        -- Without this the last sweep of a slow, short rub sat in the buffer
        -- until the pen was lifted, and the ink looked like it had survived.
        self.erase_flush_scheduled = true
        UIManager:scheduleIn(Tuning.erase_repaint_ms / 1000, self.erase_flush_cb)
    end
end

function Canvas:_flushEraseRepaint()
    local p = self.erase_pending
    if not p then return end
    self.erase_pending = nil
    self:_repaintRegion(p.x, p.y, p.w, p.h)
    self.last_erase_repaint = time.now()
end

--[[--
No eraser outline is drawn.

There was one: a ring or a square following the tip, so the size of the rubber
was visible. It cost a full repaint of its own area from the vector model on
every sample, plus its own refreshes, on top of the erasing itself -- and that
was most of why the eraser could not keep up with the hand. The outline that was
meant to show where the eraser is was the reason it was not there yet.

Without it, the eraser is aimed by the pen, which is a physical object sitting
on the glass and therefore easier to see than any ring drawn under it.
--]]

--- Grows the region this eraser sweep has touched, for the undo record.
function Canvas:_noteErased(x, y, w, h)
    self.erase_bounds = Rect.grow(self.erase_bounds, x, y, w, h)
end

--- Repaints a region from the vector model.
-- With `defer_refresh`, the pixels are restored but nothing is sent to the
-- panel: the caller is about to refresh a region that covers this one anyway,
-- and two overlapping refreshes would flicker.
function Canvas:_repaintRegion(x, y, w, h, defer_refresh)
    x, y, w, h = Rect.clamp(x, y, w, h, self.content)
    if not x then return end

    local clip = { x = x, y = y, w = w, h = h }
    if self.background_cache then
        Screen.bb:blitFrom(self.background_cache,x,y,x,y,w,h)
    else
        Screen.bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
        self:_drawTemplate(Screen.bb, clip)
    end
    -- Rejected first by bounding box, then per run of points inside the stroke:
    -- a line that merely crosses this region is not rasterised end to end.
    for _, stroke in ipairs(self.document:getPage().strokes) do
        local sx, sy, sw, sh = stroke:getBounds()
        if stroke ~= self.hidden_stroke
            and not (self.shape_gesture and stroke == self.shape_gesture.original)
            and sx < x + w and sx + sw > x and sy < y + h and sy + sh > y then
            Renderer.drawStroke(Screen.bb, stroke, clip)
        end
    end
    if self.text_preview then
        local sx,sy,sw,sh=self.text_preview:getBounds()
        if sx < x+w and sx+sw > x and sy < y+h and sy+sh > y then
            Renderer.drawStroke(Screen.bb,self.text_preview,clip)
        end
    end
    if not defer_refresh then
        Screen:refreshUI(x, y, w, h)
    end
end

-- Stylus input -----------------------------------------------------------------

--[[--
Receives fully processed stylus slots, ahead of gesture detection.

Returning true "dominates" the event, keeping it out of the gesture engine --
otherwise every stroke would also register as a swipe or a tap and start
turning pages underneath the drawing.
--]]
function Canvas:onStylusEvent(slot)
    -- Only draw when the notebook is the frontmost thing on screen.
    --
    -- This callback runs ahead of gesture detection and claims the event, so
    -- without this check the pen keeps drawing on the canvas underneath an open
    -- dialog -- and, worse, the dialog's own buttons never see the tap, so they
    -- cannot be pressed with the pen and tapping outside does not dismiss them.
    local top_widget = UIManager:getTopmostVisibleWidget()
    if self.owner and top_widget ~= self.owner and top_widget ~= self.lasso_menu then
        if self.stroke or self.shape_gesture then self:_endStroke() end
        return false
    end

    -- Explicit finger tools are always rejected from the stylus callback
    local pen_release = slot.id == -1 and Input.pen_slot and slot.slot == Input.pen_slot
    if slot.tool == Input.TOOL_TYPE_FINGER and not pen_release then
        return false
    end

    -- Touchscreen panel slots (0..9) with no explicit stylus tool are palm contacts
    local from_panel = slot.slot and slot.slot < 10
    local is_pen = slot.tool == Input.TOOL_TYPE_PEN
        or slot.tool == Input.TOOL_TYPE_ERASER
        or slot.tool == Input.TOOL_TYPE_HIGHLIGHTER
    if from_panel and not is_pen then
        return false
    end

    local is_stylus = (Input.pen_slot and slot.slot == Input.pen_slot)
        or slot.tool == Input.TOOL_TYPE_PEN
        or slot.tool == Input.TOOL_TYPE_ERASER
        or slot.tool == Input.TOOL_TYPE_HIGHLIGHTER
        or pen_release

    if not is_stylus then
        return false
    end

    -- KOReader may overwrite a persistent slot.tool with the barrel tool.
    -- Remember the physical Wacom end separately so releasing the button does
    -- not leave the pen stuck in that override until it exits proximity.
    local slot_tool = self.physical_pen_tool or slot.tool
    if self.physical_pen_tool == Input.TOOL_TYPE_PEN then
        if Input.stylus_eraser_active then slot_tool = Input.TOOL_TYPE_ERASER
        elseif Input.stylus_highlighter_active then slot_tool = Input.TOOL_TYPE_HIGHLIGHTER end
    end
    local tool = self:resolveTool(slot_tool)

    -- If tapping directly on the lasso menu buttons with the stylus, pass through to the menu
    if self.lasso_menu and self.lasso_menu.dimen and slot.x and slot.y then
        local md = self.lasso_menu.dimen
        if slot.x >= md.x and slot.x <= md.x + md.w and slot.y >= md.y and slot.y <= md.y + md.h then
            return false
        end
    end

    -- id == -1 marks the contact being released.
    if slot.id == -1 then
        -- Only claim the release if we were actually drawing. A lift-off that
        -- ends a tap on the toolbar has to reach the gesture engine, or the
        -- button never completes its tap.
        local was_drawing = self.stroke ~= nil or self.erasing or self.dragging_selection
            or self.shape_gesture ~= nil or self.text_at ~= nil or self.dismiss_contact
        self.dismiss_contact = nil
        self.pen_down = false
        self.pen_left_at = time.now()
        -- Forget where the eraser was, so the next sweep does not rub out the
        -- whole path back to wherever it was last lifted, and close the sweep's
        -- undo group.
        self.last_erase_x, self.last_erase_y = nil, nil
        self:_endErase()
        self.erasing = false
        self:_endStroke()
        return was_drawing
    end

    local new_contact = not self.pen_down
    self.pen_down = true
    self.pen_left_at = nil

    local x, y = slot.x, slot.y
    if not x or not y then return true end

    -- Anything outside the drawable area is not ours. Critically, it must NOT be
    -- dominated: returning true here would swallow the event before gesture
    -- detection ever sees it, and every toolbar button would stop responding to
    -- the pen while still working under a finger.
    --
    -- Ending the stroke as well means dragging off the canvas lifts the pen,
    -- rather than leaving a segment that jumps the gap when you come back.
    if not self:_withinContent(x, y, self:widthFor(tool)) then
        if self.stroke or self.dragging_selection or self.shape_gesture then self:_endStroke() end
        return false
    end

    -- The Scribe Wacom digitizer reports 0..4095 (EVIOCGABS ABS_PRESSURE).
    -- Pressure is baked into ordinary stroke points, so exports and old readers
    -- need no new codec or brush metadata. Missing pressure keeps a solid line.
    local p = 1
    if tool == "pen" and self.pen_style ~= "fineliner" and Input.wacom_protocol then
        local pressure = slot.pressure
        if pressure == nil and self.pressure_sensor then
            pressure = self.pressure_sensor:read()
        end
        if pressure then p = math.max(0, math.min(1, pressure / 4095)) end
        if self.stroke and self.stroke.tool == "pen" and self.stroke.n>0 then
            local lx,ly,lp=self.stroke:getPoint(self.stroke.n)
            local distance=math.sqrt((x-lx)^2+(y-ly)^2)
            -- Smooth pressure over distance rather than sample count, keeping
            -- the response consistent at different input rates and speeds.
            p=lp+(p-lp)*(1-math.exp(-distance/12))
        end
    end

    if self.dismiss_contact then return true end
    if new_contact and self.selected_strokes then
        local selected = self.selected_strokes
        local shape = #selected == 1 and selected[1]
        if shape and (shape.shape_kind == "rectangle" or shape.shape_kind == "square"
            or shape.shape_kind == "circle" or shape.text) and math.abs(x-shape.x_max) <= Screen:scaleBySize(24)
            and math.abs(y-shape.y_max) <= Screen:scaleBySize(24) then
            self:_beginShape(x, y, shape)
            return true
        end
        if shape and shape.text and self.selection_bbox then
            local b=self.selection_bbox
            if x>=b.x-25 and x<=b.x+b.w+25 and y>=b.y-25 and y<=b.y+b.h+25 then
                self.dragging_selection=true
                self.drag_start_x,self.drag_start_y=x,y
                self.drag_last_x,self.drag_last_y=x,y
                if self.lasso_menu then UIManager:close(self.lasso_menu); self.lasso_menu=nil end
                return true
            end
        end
        if self.erased_shape_selection then
            self.erased_shape_selection = nil
            self:_deselectLasso()
            self.dismiss_contact = true
            return true
        end
    end
    if self.shape_gesture then self:_extendShape(x, y); return true end

    if tool == "eraser" then
        if self.stroke or self.dragging_selection or self.shape_gesture then self:_endStroke() end
        self.erasing = true
        self:_eraseAlong(x, y)
        return true
    end

    if self.erasing then
        self:_endErase()
        self.erasing = false
        self.last_erase_x, self.last_erase_y = nil, nil
    end

    if self.dragging_selection then
        self:_extendStroke(x, y, p)
    elseif not self.stroke then
        self:_beginStroke(tool, x, y, p)
    else
        -- The tool can change mid-contact (barrel button pressed while writing).
        -- Finish the current stroke and start a new one so each stroke stays
        -- homogeneous, which is what the undo and erase models assume.
        if self.stroke.tool ~= tool then
            self:_endStroke()
            self:_beginStroke(tool, x, y, p)
        else
            self:_extendStroke(x, y, p)
        end
    end
    return true
end

-- Touch input --------------------------------------------------------------------

--[[--
Drawing with a finger, which is also the only way to draw in the emulator --
SDL synthesises finger touches, never stylus events, so without this path none
of the drawing code could be exercised off-device.

These go through the ordinary gesture engine rather than the stylus callback,
so they arrive already coalesced into pan events. The tool is always whatever
is selected on screen: a finger has no barrel button to override it with.
--]]
function Canvas:_touchPoint(ges)
    local pos = ges.pos
    if not pos then return nil end
    return pos.x, pos.y
end

--[[--
Whether a touch should be acted on at all.

Anything arriving while the pen is on the panel, or just after it left, is
almost certainly the side of a hand. Swallowing it (returning true from the
handler) rather than passing it on matters: left to the gesture engine it
becomes a swipe, and the page turns underneath the writing.
--]]
function Canvas:_touchIsPalm()
    if self.pen_down then return true end
    if self.pen_left_at
        and time.to_ms(time.now() - self.pen_left_at) < Tuning.palm_grace_ms then
        return true
    end
    return false
end

--[[--
The drawing area belongs to the canvas, whether or not it draws.

Every touch inside it is answered here and goes no further. That is the whole of
palm rejection: a hand resting on the page is a contact like any other, and an
unanswered contact travels on to become a tap on whatever is underneath -- which
is how resting a palm pressed toolbar buttons and repainted pieces of the screen
under the ink.
--]]
function Canvas:onTouchStart(_, ges)
    if self:_touchIsPalm() then return true end

    local x, y = self:_touchPoint(ges)
    if not x then return true end

    self.touch_start_x = x
    self.touch_start_y = y
    self.touch_last_x = x
    self.touch_last_y = y

    -- A resting hand must not move or dismiss a pen selection.
    if self.selected_strokes and not self.draw_with_finger then return true end

    -- If lasso selection is active, finger touching inside selection initiates drag/move
    if self.tool == "lasso" and self.selected_strokes and self.selection_bbox then
        if self.lasso_menu and self.lasso_menu.dimen then
            local md = self.lasso_menu.dimen
            if x >= md.x and x <= md.x + md.w and y >= md.y and y <= md.y + md.h then
                return false
            end
        end

        local b = self.selection_bbox
        if x >= b.x - 30 and x <= b.x + b.w + 30 and y >= b.y - 30 and y <= b.y + b.h + 30 then
            self.dragging_selection = true
            self.drag_start_x, self.drag_start_y = x, y
            self.drag_last_x, self.drag_last_y = x, y
            if self.lasso_menu then
                UIManager:close(self.lasso_menu)
                self.lasso_menu = nil
            end
            return true
        else
            -- Tapped outside selection -> deselect
            self:_deselectLasso()
        end
    end

    if not self.draw_with_finger then
        return true
    end

    if not self:_withinContent(x, y, self:widthFor(self.tool)) then return true end

    if self.tool == "eraser" then
        self:_eraseAlong(x, y)
    else
        self:_beginStroke(self.tool, x, y, 1)
    end
    return true
end

function Canvas:onTouchPan(_, ges)
    if self:_touchIsPalm() then return true end

    local x, y = self:_touchPoint(ges)
    if not x then return true end

    self.touch_last_x = x
    self.touch_last_y = y

    if self.dragging_selection then
        self:_extendStroke(x, y, 1)
        return true
    end

    if not self.draw_with_finger then
        return true
    end

    if not self:_withinContent(x, y, self:widthFor(self.tool)) then
        if self.stroke or self.shape_gesture then self:_endStroke() end
        return true
    end

    if self.tool == "eraser" then
        self:_eraseAlong(x, y)
    elseif self.stroke or self.shape_gesture then
        self:_extendStroke(x, y, 1)
    else
        self:_beginStroke(self.tool, x, y, 1)
    end
    return true
end

function Canvas:onTouchRelease(_, ges)
    local start_x = self.touch_start_x
    local start_y = self.touch_start_y
    local end_x = self.touch_last_x or (ges and ges.pos and ges.pos.x)
    local end_y = self.touch_last_y or (ges and ges.pos and ges.pos.y)
    self.touch_start_x, self.touch_start_y = nil, nil
    self.touch_last_x, self.touch_last_y = nil, nil

    if self:_touchIsPalm() then return true end

    if self.dragging_selection then
        self:_endStroke()
        return true
    end

    if self.draw_with_finger then
        self.last_erase_x, self.last_erase_y = nil, nil
        self:_endErase()
        if self.stroke or self.shape_gesture then self:_endStroke() end
        return true
    end

    if self.selected_strokes then return true end

    -- Slower horizontal pan drags also turn pages reliably
    if not self.pen_down and start_x and end_x and self.on_page_swipe then
        local dx = end_x - start_x
        local dy = (end_y and start_y) and math.abs(end_y - start_y) or 0
        local min_dist = Screen:scaleBySize(60)
        if math.abs(dx) >= min_dist and math.abs(dx) > 1.2 * dy then
            self.on_page_swipe(dx < 0 and 1 or -1)
            return true
        end
    end

    return true
end

--- Horizontal finger swipes turn the page, the way they do in the reader.
function Canvas:onPageSwipe(_, ges)
    if self.selected_strokes or self.dragging_selection then return true end
    if self:_touchIsPalm() then return true end
    -- A swipe while drawing with a finger is part of the drawing, not a gesture.
    if self.draw_with_finger and self.stroke then return true end
    if not self.on_page_swipe then return false end

    local dir = ges.direction
    if dir == "west" or dir == "northwest" or dir == "southwest" then
        self.on_page_swipe(1)
        return true
    elseif dir == "east" or dir == "northeast" or dir == "southeast" then
        self.on_page_swipe(-1)
        return true
    end

    if ges.pos and ges.end_pos then
        local dx = ges.end_pos.x - ges.pos.x
        local dy = math.abs(ges.end_pos.y - ges.pos.y)
        if math.abs(dx) >= Screen:scaleBySize(40) and math.abs(dx) > dy then
            self.on_page_swipe(dx < 0 and 1 or -1)
            return true
        end
    end

    return false
end

function Canvas:onPageMultiSwipe(_, ges)
    return self:onPageSwipe(_, ges)
end

function Canvas:onPageTwoFingerSwipe(_, ges)
    return self:onPageSwipe(_, ges)
end

-- Widget lifecycle ---------------------------------------------------------------

--- Authoritative render, straight from the vector model.
function Canvas:paintTo(bb, x, y)
    local page=self.document:getPage()
    local background=page.background
    local cache_key=table.concat({tostring(page),self.document:templateFor() or "",
        background and background.file or "",background and background.page or ""},"|")
    if self.background_cache and self.background_cache_key==cache_key then
        bb:blitFrom(self.background_cache,x,y,x,y,self.dimen.w,self.dimen.h)
    else
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
        self:_drawTemplate(bb)
        if self.background_cache then self.background_cache:free() end
        self.background_cache=bb:copy()
        self.background_cache_key=cache_key
    end
    for _,stroke in ipairs(self.document:getPage().strokes) do
        if stroke ~= self.hidden_stroke then Renderer.drawStroke(bb,stroke) end
    end
    if self.text_preview then Renderer.drawStroke(bb,self.text_preview) end
end

--[[--
Lays the page's background down, under the ink.

Called from both places that rebuild pixels from the model, which is what makes
the background un-erasable: the eraser does not remove pixels, it repaints an
area from scratch, so as long as that repaint starts with the background, rubbing
out a word written across a ruled line leaves the line untouched.
--]]
function Canvas:_drawTemplate(bb, clip)
    local background=self.document:getPage().background
    if background then require("pdfbackground").draw(bb,background,self.content,clip)
    else Template.draw(bb, self.document:templateFor(), self.content, 1, clip) end
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
function Canvas:start()
    self.stopping = false
    -- The patches below are KOReader's, not ours, and they outlive any screen
    -- of ours that is holding them. A fault closes this plugin without ever
    -- reaching onCloseWidget, so the undoing is registered here as well rather
    -- than left to the normal path alone; see Safe.onShutdown.
    Safe.onShutdown("canvas:input", function() self:stop() end)

    if Input and Input.pen_slot and Input.wacom_protocol then
        self.pressure_sensor = require("pressure").open()
        self.orig_pen_slot = Input.pen_slot
        -- Move pen_slot out of the capacitive multi-touch panel's slot range (0..9)
        Input.pen_slot = 15
        self.panel_slot = Input.main_finger_slot or 0

        -- On Notebook: ensure all single-touch Wacom digitizer events route strictly to pen_slot
        if not self.orig_handleTouchEv and Input.handleTouchEv then
            self.orig_handleTouchEv = Input.handleTouchEv
            Input.handleTouchEv = function(this, ev)
                if ev.type == 3 then -- EV_ABS
                    -- Each device retains its own current slot across frames.
                    -- Wacom ABS_X/Y must not redirect a later slotless MT frame.
                    if ev.code == 47 then -- ABS_MT_SLOT
                        self.panel_slot = ev.value
                    elseif ev.code >= 48 and ev.code <= 61 then -- ABS_MT_*
                        this:setupSlotData(self.panel_slot)
                    end
                    if ev.code == 0 then -- ABS_X
                        this:setupSlotData(this.pen_slot)
                        this:setCurrentMtSlotChecked("x", ev.value)
                        return
                    elseif ev.code == 1 then -- ABS_Y
                        this:setupSlotData(this.pen_slot)
                        this:setCurrentMtSlotChecked("y", ev.value)
                        return
                    elseif ev.code == 24 then -- ABS_PRESSURE
                        this:setupSlotData(this.pen_slot)
                        this:setCurrentMtSlotChecked("pressure", ev.value)
                        return
                    end
                end
                return self.orig_handleTouchEv(this, ev)
            end
        end

        if not self.orig_handleKeyBoardEv and Input.handleKeyBoardEv then
            self.orig_handleKeyBoardEv = Input.handleKeyBoardEv
            Input.handleKeyBoardEv = function(this, ev)
                if ev.code == 320 or ev.code == 321 then -- BTN_TOOL_PEN/RUBBER
                    self.physical_pen_tool = ev.value == 1
                        and (ev.code == 320 and this.TOOL_TYPE_PEN or this.TOOL_TYPE_ERASER) or nil
                end
                if ev.code == 330 then -- BTN_TOUCH
                    this:setupSlotData(this.pen_slot)
                    if ev.value == 1 then
                        this:setCurrentMtSlot("id", this.pen_slot)
                    else
                        this:setCurrentMtSlot("id", -1)
                    end
                    return
                end
                return self.orig_handleKeyBoardEv(this, ev)
            end
        end
    end
    Input:registerStylusCallback(Safe.wrap("canvas:stylus", function(_, slot)
        return self:onStylusEvent(slot)
    end))
end

function Canvas:stop()
    self.stopping = true
    -- Whichever path got here first is the one that does it; the other must not
    -- run again and put the patches back on top of the restored handlers.
    Safe.clearShutdown("canvas:input")
    if self.pressure_sensor then self.pressure_sensor:close(); self.pressure_sensor = nil end

    Input:unregisterStylusCallback()
    if self.orig_handleTouchEv and Input then
        Input.handleTouchEv = self.orig_handleTouchEv
        self.orig_handleTouchEv = nil
    end
    if self.orig_handleKeyBoardEv and Input then
        Input.handleKeyBoardEv = self.orig_handleKeyBoardEv
        self.orig_handleKeyBoardEv = nil
    end
    if self.orig_pen_slot and Input then
        Input.pen_slot = self.orig_pen_slot
        Input.cur_slot = Input.main_finger_slot or 0
        self.orig_pen_slot = nil
    end
    for _, name in ipairs({"idle_flush_cb", "reconcile_cb", "autosave_cb",
        "shape_snap_cb", "erase_flush_cb", "drag_step_cb", "shape_preview_cb"}) do
        if self[name] then UIManager:unschedule(self[name]) end
    end
    self:_endStroke()
    require("pdfbackground").clear()
    if self.background_cache then self.background_cache:free(); self.background_cache=nil end
    self.background_cache_key=nil
    self:_endErase()
    self.physical_pen_tool = nil
    self:_deselectLasso()
    UIManager:unschedule(self.drag_step_cb)
    UIManager:unschedule(self.erase_flush_cb)
    UIManager:unschedule(self.reconcile_cb)
    UIManager:unschedule(self.autosave_cb)
    UIManager:unschedule(self.shape_snap_cb)
    if self.document and self.document.dirty then
        self.document:save()
    end
    if self.idle_flush_cb then
        UIManager:unschedule(self.idle_flush_cb)
    end
    self:_flush()
end

--[[--
Protected like every other screen, but without the watchdog.

The events this class handles are finger touches while drawing, and a count hook
around those would take LuaJIT off its compiled traces on the very path that has
to keep up with a hand. The pcall costs nothing and is what matters here: it
means a fault while drawing closes the notebook rather than the reader.
--]]
return Safe.widget(Canvas, "canvas", false)
