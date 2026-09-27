-- Dirty regions and refresh scheduling. Pixel rendering lives in canvasrender.lua.
local Device = require("device")
local Rect = require("rect")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Screen = Device.screen
local Refresh = {}
local COLOR_DELAY_SECONDS = 0.8

-- Refresh management -----------------------------------------------------------

--- Merges a rectangle into the pending refresh region.
function Refresh:_accumulate(x, y, w, h)
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
function Refresh:_refreshNow(x, y, w, h, mode)
    x, y, w, h = Rect.clamp(x, y, w, h, self.content)
    if not x then return end
    if mode == "ui" then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshFast(x, y, w, h)
    end
end

--- Issues the pending partial refresh, if any.
function Refresh:_flush()
    UIManager:unschedule(self.idle_flush_cb)
    self.idle_flush_scheduled = false
    local p = self.pending
    if not p then return end
    self.pending = nil
    self.last_refresh = time.now()

    -- Clamp to the drawable area; the framebuffer rejects out-of-bounds regions,
    -- and refreshing over the toolbar would make it flicker for no reason.
    local x, y, w, h = Rect.clamp(p.x, p.y, p.w, p.h, self.content)
    if not x then return end

    -- All live ink has a binary preview. Gray/color reconciliation runs once
    -- at rest, so slow waveforms cannot accumulate behind the moving nib.
    if self.refresh_mode == "ui" then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshFast(x, y, w, h)
    end
end

--- Flushes now if enough time has passed, otherwise arranges for it to happen.
function Refresh:_maybeFlush()
    local now = time.now()
    local interval = self.refresh_mode == "ui"
        and 80 or Tuning.refresh_interval_ms
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
Queues the grayscale clean-up for an area, coalescing it with anything already
pending and pushing the deadline back.

Deliberately *not* a UIManager repaint. The pixels in the screen buffer are
already correct -- the fast path drew them -- so all that is needed is the same
area shown again under a better waveform. Going through UIManager would instead
repaint the whole widget, which means rasterising every stroke on the page from
the vector model, and that cost grows with each stroke until writing stalls.
--]]
function Refresh:_scheduleReconcile(x, y, w, h, color)
    self.reconcile = Rect.grow(self.reconcile, x, y, w, h)

    self.reconcile_color = self.reconcile_color or color
    local delay = Tuning.reconcile_delay_ms / 1000
    if self.reconcile_color then delay = math.min(delay, COLOR_DELAY_SECONDS) end
    UIManager:unschedule(self.reconcile_cb)
    UIManager:scheduleIn(math.max(0.6, delay), self.reconcile_cb)
end

function Refresh:_scheduleCleanScreen()
    self.reconcile_full=true
    self:_scheduleReconcile(self.content.x,self.content.y,self.content.w,self.content.h)
end

function Refresh:_runReconcile()
    local r = self.reconcile
    if not r then return end
    local recent_pan=self.last_zoom_pan_refresh and time.to_ms(time.now()-self.last_zoom_pan_refresh)<600
    if self.pen_down or self.stroke or self.zoom_stroke or self.transform_gesture or self.shape_gesture
        or self.dragging_selection or self.erasing or self.zoom_erasing or self.zoom_pan_dirty
        or self.zoom_touch_active or self.zoom_pan_needs_settle or recent_pan then
        UIManager:scheduleIn(0.6,self.reconcile_cb)
        return
    end
    self.reconcile = nil
    self.reconcile_color = nil
    if self.reconcile_full then
        self.reconcile_full=nil
        Screen:refreshFull(0,0,Screen:getWidth(),Screen:getHeight())
        return
    end

    local x, y, w, h = Rect.clamp(r.x, r.y, r.w, r.h, self.content)
    if not x then return end

    -- The pixels are authoritative already. AUTO lets the device choose its
    -- UI waveform without rerasterizing the page or forcing REAGL per stroke.
    Screen:refreshUI(x, y, w, h)
end

return Refresh
