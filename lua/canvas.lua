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
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local Input = Device.input

-- Minimum gap between partial refreshes while drawing. Roughly matches what an
-- A2 update costs on this panel; going lower queues work faster than the
-- hardware retires it.
local REFRESH_INTERVAL_MS = 20

-- If the pen stops moving mid-stroke, the last fragment would otherwise sit
-- unrefreshed until lift-off. This is how long we wait before flushing it.
local IDLE_FLUSH_MS = 35

-- How long after the pen leaves the page before the grayscale clean-up pass runs.
-- Set to a generous 2000ms pause so handwriting never triggers a refresh mid-sentence.
local RECONCILE_DELAY_MS = 2000

--[[--
The gray the highlighter paints with while the stroke is still being drawn.

Darker than the tint it settles to. Highlighting is idempotent -- passing over a
band twice leaves it exactly as it was -- which is right for the result and
useless while you are working: going back over a highlighted line to catch a word
at its edge showed nothing at all under the tip, so there was no way to see where
the marker was or where it still had to go.

Laying the live stroke down darker makes the pass visible over blank paper and
over existing highlight alike. When the pen lifts, the area is repainted from the
model at the real tint, so what is left is the same flat band as before -- the
darker gray only ever exists while the marker is moving.
--]]
local LIVE_HIGHLIGHT_TINT = 100

-- How close the eraser has to come to a stroke to remove it.
local ERASER_RADIUS = 12

-- Fastest the nib is believed to travel, in pixels per millisecond.
-- 6 px/ms is about 1800 px in a third of a second: a flick right across the
-- panel, faster than anyone writes.
local MAX_PEN_SPEED = 6

-- Distance any one sample may jump regardless of how little time passed, which
-- covers the coarse timestamps and the occasional late-delivered event.
local JUMP_BASE = 48

-- Longest gap the speed allowance is computed over. Without a cap, one late
-- event would license a jump to anywhere.
local MAX_JUMP_GAP_MS = 120

-- Consecutive refusals before the position is believed after all, so a genuine
-- discontinuity cannot wedge the stroke permanently.
local OUTLIER_LIMIT = 8

--[[--
How far the nib must travel, squared, before the shape recogniser accepts that
it has moved at all.

Hold-to-snap fires when the pen stops, so "stopped" needs a tolerance: a nib
resting on glass still reports a pixel or two of wander, and taken literally
that would keep pushing the deadline back and the snap would never come.

This is a tolerance for the *recogniser*, and nothing else. It used to also
decide which samples were added to the stroke, which made it a sampling
interval of eight pixels: everything drawn inside it -- an accent, a comma, the
curve of a small letter -- was discarded rather than merely rounded, and
ordinary handwriting came out as a chain of eight-pixel chords.
--]]
local HOLD_TRAVEL_SQ = 64

--[[--
Below this distance, squared, from the last point taken, a sample is wobble.

Measured from the last point actually taken, so it can only ever round the path
-- a slow hand crossing it in two samples instead of one still lays down every
pixel it went over. Two pixels is a sixth of a millimetre on a 300 dpi panel:
below anything a hand can mean, and above what the digitizer invents while the
nib is resting.
--]]
local JITTER_FLOOR_SQ = 4

-- How long after the pen lifts before touches are trusted again.
--
-- Writing means resting a hand on the panel, and the digitizer reports that
-- contact just like a deliberate tap. Ignoring touches while the pen is down is
-- most of the fix, but the hand usually leaves the glass slightly *after* the
-- nib does, so the block has to outlast the stroke by a moment.
local PALM_GRACE_MS = 600

-- Minimum gap between repaints while the eraser is sweeping.
--
-- Every application of the eraser repaints its area from the vector model, which
-- means re-rasterising every stroke that overlaps it. At the sampling rate of a
-- moving hand that is far more repainting than the panel can show, so the work
-- piles up and the eraser drags. Coalescing to a few a second looks identical
-- and costs a fraction.
local ERASE_REPAINT_MS = 70

--[[--
Minimum gap between repaints while a selection is being dragged.

The same problem as the eraser, and worse. Moving a selection repaints the
region it left together with the region it now covers, which means re-rasterising
every stroke that overlaps either -- and a dragged selection is usually the
busiest part of the page, since it is the part worth moving. Doing that on every
pen sample asks for fifty of those a second from a panel that can show perhaps
ten, so the queue grows, and what you see is the selection trailing further and
further behind the nib.

Movement is accumulated and applied on this interval instead. The arithmetic is
unchanged -- the same total translation, in fewer steps -- and the last one
always lands, so where it ends up does not depend on the timing.
--]]
local DRAG_REPAINT_MS = 60

local Canvas = InputContainer:extend{
    document = nil,
    -- Currently selected on-screen tool: "pen", "highlighter" or "eraser".
    tool = "pen",
    -- What the barrel button does while held. The rubber tip always erases.
    barrel_button_tool = "highlighter",
    pen_width = 3,
    highlighter_width = 24,
    eraser_size = ERASER_RADIUS,
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
    self.coverage = nil

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
    self.jump_base = Screen:scaleBySize(JUMP_BASE)
    self.last_point_at = nil
    self.outliers = 0

    -- Last point the eraser was applied at, so it can rub continuously along
    -- the path instead of only where samples happened to land.
    self.last_erase_x, self.last_erase_y = nil, nil
    self.erase_pending = nil
    self.last_erase_repaint = nil
    self.erase_flush_scheduled = false

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

    -- Waveform choice while a stroke is live. Both alternatives to what is here
    -- were tried on the device and both were worse:
    --
    --  * refreshPartial (grayscale/REAGL) is forced to UPDATE_MODE_FULL by the
    --    driver, and full updates are fenced, so every segment blocks on the
    --    previous one and the ink crawls behind the nib.
    --  * refreshFast (DU) is a binary waveform, so the highlighter's gray gets
    --    rounded to white: nothing appears at all until the stroke is finished.
    --
    -- refreshUI (AUTO) lets the driver decide per update. For the highlighter it
    -- shows the band dark immediately and settles it to gray a moment later --
    -- two passes rather than one, but it tracks the pen, and tracking the pen is
    -- what matters while you are drawing.
    if self.refresh_mode == "ui" then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshFast(x, y, w, h)
    end
end

--- Flushes now if enough time has passed, otherwise arranges for it to happen.
function Canvas:_maybeFlush()
    local now = time.now()
    if not self.last_refresh
        or time.to_ms(now - self.last_refresh) >= REFRESH_INTERVAL_MS then
        self:_flush()
        return
    end

    if not self.idle_flush_scheduled then
        self.idle_flush_scheduled = true
        UIManager:scheduleIn(IDLE_FLUSH_MS / 1000, self.idle_flush_cb)
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
        if ms > MAX_JUMP_GAP_MS then ms = MAX_JUMP_GAP_MS end
        if ms > 0 then limit = limit + ms * MAX_PEN_SPEED end
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
    if self.outliers >= OUTLIER_LIMIT then
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
    local clean = Shape.recognize(self.stroke)
    if clean then
        self.shape_snapped = true
        local bx, by, bw, bh = self.stroke:getBounds()
        self.stroke = clean
        if bx then self:_repaintRegion(bx, by, bw, bh, true) end
        local nbx, nby, nbw, nbh = clean:getBounds()
        if nbx then
            Renderer.drawStroke(Screen.bb, clean)
            self:_accumulate(nbx, nby, nbw, nbh)
            self:_flush()
        end
    end
end

-- Drawing ----------------------------------------------------------------------

function Canvas:_beginStroke(tool, x, y, p)
    -- The pen is back on the page, so the pending tidy-up must stand down: it
    -- would otherwise fire in the middle of the new stroke. The region it had
    -- accumulated is kept, and gets folded into the next one.
    UIManager:unschedule(self.reconcile_cb)
    UIManager:unschedule(self.shape_snap_cb)

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
        color = 0,
    }
    self.coverage = tool == "highlighter" and {} or nil
    self.refresh_mode = tool == "highlighter" and "ui" or "fast"
    -- While it is being drawn the highlighter lays down a darker tint than the
    -- one it settles to when the pen lifts; see LIVE_HIGHLIGHT_TINT.
    self.stroke.tint = tool == "highlighter" and LIVE_HIGHLIGHT_TINT or nil
    self.stroke:addPoint(x, y, p)
    self.last_x, self.last_y, self.last_p = x, y, p
    self.last_point_at = time.now()
    self.outliers = 0

    -- Hold-to-snap shape recognition tracking
    self.hold_start_x = x
    self.hold_start_y = y
    self.shape_snapped = false
    if tool ~= "eraser" and tool ~= "lasso" then
        UIManager:scheduleIn(0.35, self.shape_snap_cb)
    end

    -- Put down the initial dot so a tap leaves a mark rather than nothing.
    local rx, ry, rw, rh = Renderer.drawSegment(Screen.bb, self.stroke,
        x, y, p, x, y, p, self.coverage)
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

-- How far outside the selection its dashed frame is drawn, plus enough to cover
-- the dashes themselves.
local FRAME_MARGIN = 10
function Canvas:_dragStep()
    local dx, dy = self.drag_dx or 0, self.drag_dy or 0
    self.drag_dx, self.drag_dy = 0, 0
    if dx == 0 and dy == 0 then return end
    if not self.selected_strokes then return end

    local old_b = self.selection_bbox or Lasso.getSelectionBounds(self.selected_strokes)
    if not old_b then return end

    Lasso.translateStrokes(self.selected_strokes, dx, dy)
    local new_b = { x = old_b.x + dx, y = old_b.y + dy, w = old_b.w, h = old_b.h }
    self.selection_bbox = new_b
    self.last_drag_step = time.now()

    local m = FRAME_MARGIN
    local box = Rect.grow(
        { x = old_b.x - m, y = old_b.y - m, w = old_b.w + 2 * m, h = old_b.h + 2 * m },
        new_b.x - m, new_b.y - m, new_b.w + 2 * m, new_b.h + 2 * m)
    self:_repaintRegion(box.x, box.y, box.w, box.h, true)
    Renderer.drawDashedRect(Screen.bb, new_b.x - 6, new_b.y - 6, new_b.w + 12, new_b.h + 12)
    Screen:refreshFast(box.x, box.y, box.w, box.h)

    -- Everywhere the selection has been during this drag, for the one clean
    -- refresh that ends it; see _settleDrag.
    self.drag_touched = Rect.grow(self.drag_touched, box.x, box.y, box.w, box.h)
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
    Screen:refreshUI(touched.x, touched.y, touched.w, touched.h)
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
        or time.to_ms(now - self.last_drag_step) >= DRAG_REPAINT_MS then
        return self:_dragStep()
    end

    if not self.drag_step_scheduled then
        self.drag_step_scheduled = true
        UIManager:scheduleIn(DRAG_REPAINT_MS / 1000, function()
            self.drag_step_scheduled = false
            self:_dragStep()
        end)
    end
end

function Canvas:_extendStroke(x, y, p)
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
        if hdx * hdx + hdy * hdy > HOLD_TRAVEL_SQ then
            self.hold_start_x = x
            self.hold_start_y = y
            UIManager:unschedule(self.shape_snap_cb)
            if self.stroke:count() >= 4 then
                UIManager:scheduleIn(0.35, self.shape_snap_cb)
            end
        end
    end

    -- Wobble under a resting nib is not movement, and stamping it costs a
    -- refresh for nothing. See JITTER_FLOOR_SQ: this rounds the path, it does
    -- not sample it.
    local jdx = x - self.last_x
    local jdy = y - self.last_y
    if jdx * jdx + jdy * jdy < JITTER_FLOOR_SQ then return end

    local rx, ry, rw, rh = Renderer.drawSegment(Screen.bb, self.stroke,
        self.last_x, self.last_y, self.last_p, x, y, p, self.coverage)
    self.stroke:addPoint(x, y, p)
    self.last_x, self.last_y, self.last_p = x, y, p

    self:_accumulate(rx, ry, rw, rh)
    self:_maybeFlush()
end

function Canvas:_endStroke()
    if self.dragging_selection then
        self.dragging_selection = false
        -- Whatever the last interval had not got to yet. The menu is placed
        -- against the selection's box, so this has to happen before it is
        -- shown or it would be pinned to where the selection nearly was.
        self:_dragStep()
        self:_settleDrag()
        self:_showLassoMenu(self.selected_strokes)
        if self.on_change then self:on_change() end
        return
    end

    if not self.stroke then return end
    local stroke = self.stroke
    self.stroke = nil
    self.coverage = nil
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
                for _, s in ipairs(Canvas.clipboard) do
                    local copy = Stroke:new{ tool = s.tool, width = s.width, color = s.color, tint = s.tint }
                    for i = 1, s:count() do
                        local px, py, p = s:getPoint(i)
                        copy:addPoint(px + dx, py + dy, p)
                    end
                    table.insert(pasted, copy)
                    self.document:addStroke(copy)
                end
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
        Screen:refreshFast(bbox.x - 8, bbox.y - 8, bbox.w + 16, bbox.h + 16)
    end

    self.lasso_menu = LassoMenu:new{
        bbox = bbox or { x = self.content.x + 100, y = self.content.y + 100, w = 200, h = 100 },
        has_clipboard = Canvas.clipboard ~= nil and #Canvas.clipboard > 0,
        on_cut = function()
            self.lasso_menu = nil
            Canvas.clipboard = {}
            local page_strokes = self.document:getPage().strokes
            for _, s in ipairs(selected) do
                table.insert(Canvas.clipboard, s)
                for i = #page_strokes, 1, -1 do
                    if page_strokes[i] == s then
                        table.remove(page_strokes, i)
                        break
                    end
                end
            end
            self.selected_strokes = nil
            self.selection_bbox = nil
            self:_repaintRegion(self.content.x, self.content.y, self.content.w, self.content.h)
            if self.on_change then self:on_change() end
        end,
        on_copy = function()
            self.lasso_menu = nil
            Canvas.clipboard = {}
            for _, s in ipairs(selected) do
                local copy = Stroke:new{ tool = s.tool, width = s.width, color = s.color, tint = s.tint }
                for i = 1, s:count() do
                    local x, y, p = s:getPoint(i)
                    copy:addPoint(x, y, p)
                end
                table.insert(Canvas.clipboard, copy)
            end
            self:_deselectLasso()
        end,
        on_paste = function()
            self.lasso_menu = nil
            if not Canvas.clipboard or #Canvas.clipboard == 0 then return end
            local pasted = {}
            for _, s in ipairs(Canvas.clipboard) do
                local copy = Stroke:new{ tool = s.tool, width = s.width, color = s.color, tint = s.tint }
                for i = 1, s:count() do
                    local x, y, p = s:getPoint(i)
                    copy:addPoint(x + 40, y + 40, p)
                end
                table.insert(pasted, copy)
                self.document:addStroke(copy)
            end
            self:_repaintRegion(self.content.x, self.content.y, self.content.w, self.content.h)
            if self.on_change then self:on_change() end
            self:_showLassoMenu(pasted)
        end,
        on_delete = function()
            self.lasso_menu = nil
            local page_strokes = self.document:getPage().strokes
            for _, sel in ipairs(selected) do
                for i = #page_strokes, 1, -1 do
                    if page_strokes[i] == sel then
                        table.remove(page_strokes, i)
                        break
                    end
                end
            end
            self.selected_strokes = nil
            self.selection_bbox = nil
            self:_repaintRegion(self.content.x, self.content.y, self.content.w, self.content.h)
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
    if self.lasso_menu then
        UIManager:close(self.lasso_menu)
        self.lasso_menu = nil
    end
    if self.selection_bbox then
        local bx = self.selection_bbox
        self.selected_strokes = nil
        self.selection_bbox = nil
        self:_repaintRegion(bx.x - 10, bx.y - 10, bx.w + 20, bx.h + 20)
    else
        self.selected_strokes = nil
    end
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
    UIManager:scheduleIn(RECONCILE_DELAY_MS / 1000, self.reconcile_cb)
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
    self:_flushEraseRepaint()
    local b = self.erase_bounds
    self.erase_bounds = nil
    if b then
        self.document:commitBatch(b.x, b.y, b.w, b.h)
    else
        self.document:commitBatch()
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

    local path = { px, py, x, y }
    local hit, rx, ry, rw, rh, ux, uy, uw, uh
    if self.eraser_mode == "area" then
        hit, rx, ry, rw, rh, ux, uy, uw, uh =
            self.document:eraseAreaAlongPath(path, self.eraser_size)
    else
        hit, rx, ry, rw, rh = self.document:eraseAlongPath(path, self.eraser_size)
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
        or time.to_ms(now - self.last_erase_repaint) >= ERASE_REPAINT_MS then
        self:_flushEraseRepaint()
    elseif not self.erase_flush_scheduled then
        -- Too soon to repaint again, so make sure something comes back for it.
        -- Without this the last sweep of a slow, short rub sat in the buffer
        -- until the pen was lifted, and the ink looked like it had survived.
        self.erase_flush_scheduled = true
        UIManager:scheduleIn(ERASE_REPAINT_MS / 1000, function()
            self.erase_flush_scheduled = false
            self:_flushEraseRepaint()
        end)
    end
end

function Canvas:_flushEraseRepaint()
    local p = self.erase_pending
    if not p then return end
    self.erase_pending = nil
    self.last_erase_repaint = time.now()
    self:_repaintRegion(p.x, p.y, p.w, p.h)
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
    Screen.bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    self:_drawTemplate(Screen.bb, clip)
    -- Rejected first by bounding box, then per run of points inside the stroke:
    -- a line that merely crosses this region is not rasterised end to end.
    for _, stroke in ipairs(self.document:getPage().strokes) do
        local sx, sy, sw, sh = stroke:getBounds()
        if sx < x + w and sx + sw > x and sy < y + h and sy + sh > y then
            Renderer.drawStroke(Screen.bb, stroke, clip)
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
        if self.stroke then self:_endStroke() end
        return false
    end

    -- Explicit finger tools are always rejected from the stylus callback
    if slot.tool == Input.TOOL_TYPE_FINGER then
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

    if not is_stylus then
        return false
    end

    local tool = self:resolveTool(slot.tool)

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
        self.pen_down = false
        self.pen_left_at = time.now()
        -- Forget where the eraser was, so the next sweep does not rub out the
        -- whole path back to wherever it was last lifted, and close the sweep's
        -- undo group.
        self.last_erase_x, self.last_erase_y = nil, nil
        self:_endErase()
        if tool == "eraser" then
            self.erasing = false
        else
            self:_endStroke()
        end
        return was_drawing
    end

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
        if self.stroke or self.dragging_selection then self:_endStroke() end
        return false
    end

    -- Constant pressure, for now.
    local p = 1

    if tool == "eraser" then
        self.erasing = true
        self:_eraseAlong(x, y)
        return true
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
        and time.to_ms(time.now() - self.pen_left_at) < PALM_GRACE_MS then
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
        if self.stroke then self:_endStroke() end
        return true
    end

    if self.tool == "eraser" then
        self:_eraseAlong(x, y)
    elseif self.stroke then
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

    if self.dragging_selection then
        self:_endStroke()
        return true
    end

    if self.draw_with_finger then
        self.last_erase_x, self.last_erase_y = nil, nil
        self:_endErase()
        if self.stroke then self:_endStroke() end
        return true
    end

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
    if self.pen_down then return true end
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
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    self:_drawTemplate(bb)
    Renderer.drawPage(bb, self.document:getPage())
end

--[[--
Lays the page's background down, under the ink.

Called from both places that rebuild pixels from the model, which is what makes
the background un-erasable: the eraser does not remove pixels, it repaints an
area from scratch, so as long as that repaint starts with the background, rubbing
out a word written across a ruled line leaves the line untouched.
--]]
function Canvas:_drawTemplate(bb, clip)
    Template.draw(bb, self.document:templateFor(), self.content, 1, clip)
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
    -- The patches below are KOReader's, not ours, and they outlive any screen
    -- of ours that is holding them. A fault closes this plugin without ever
    -- reaching onCloseWidget, so the undoing is registered here as well rather
    -- than left to the normal path alone; see Safe.onShutdown.
    Safe.onShutdown("canvas:input", function() self:stop() end)

    if Input and Input.pen_slot then
        self.orig_pen_slot = Input.pen_slot
        -- Move pen_slot out of the capacitive multi-touch panel's slot range (0..9)
        Input.pen_slot = 15

        -- On Notebook: ensure all single-touch Wacom digitizer events route strictly to pen_slot
        if not self.orig_handleTouchEv and Input.handleTouchEv then
            self.orig_handleTouchEv = Input.handleTouchEv
            Input.handleTouchEv = function(this, ev)
                if ev.type == 3 then -- EV_ABS
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
    -- Whichever path got here first is the one that does it; the other must not
    -- run again and put the patches back on top of the restored handlers.
    Safe.clearShutdown("canvas:input")

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
    end
    self:_deselectLasso()
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
