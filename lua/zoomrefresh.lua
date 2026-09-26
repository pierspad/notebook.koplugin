-- Refresh cadence for zoom panning and live ink. Full E-Ink cleanup runs only
-- after a finger has stopped moving; live marker updates are coalesced.
local Device = require("device")
local Rect = require("rect")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local Zoom = require("zoom")
local time = require("ui/time")

local Screen = Device.screen
local ZoomRefresh = {}
local PAN_INTERVAL = 35
local PAN_SETTLE_SECONDS = 0.4
local MARKER_INTERVAL = 80

function ZoomRefresh:setupZoomRefresh()
    self.zoom_pan_cb = function()
        self.zoom_pan_scheduled = false
        self:_flushZoomPan()
    end
    self.zoom_pan_settle_cb = function() self:_settleZoomPan() end
    self.zoom_ink_cb = function()
        self.zoom_ink_scheduled = false
        self:_flushZoomInk()
    end
end

function ZoomRefresh:_cancelZoomRefresh()
    UIManager:unschedule(self.zoom_pan_cb)
    UIManager:unschedule(self.zoom_pan_settle_cb)
    UIManager:unschedule(self.zoom_ink_cb)
    self.zoom_pan_scheduled = false
    self.zoom_pan_dirty = false
    self.zoom_pan_needs_settle = false
    self.zoom_ink_scheduled = false
    self.zoom_ink_pending = nil
end

function ZoomRefresh:_zoomPan(dx, dy)
    local c = self.content
    local next_x = Zoom.clamp(self.zoom_x - dx / self.zoom, c.x, c.w, self.zoom)
    local next_y = Zoom.clamp(self.zoom_y - dy / self.zoom, c.y, c.h, self.zoom)
    if math.floor(next_x*self.zoom) == math.floor(self.zoom_x*self.zoom)
        and math.floor(next_y*self.zoom) == math.floor(self.zoom_y*self.zoom) then return end
    self.zoom_x, self.zoom_y = next_x, next_y
    self.zoom_pan_dirty = true
    local now = time.now()
    local elapsed = self.last_zoom_pan_refresh
        and time.to_ms(now - self.last_zoom_pan_refresh) or PAN_INTERVAL
    if elapsed >= PAN_INTERVAL then
        self:_flushZoomPan()
    elseif not self.zoom_pan_scheduled then
        self.zoom_pan_scheduled = true
        UIManager:scheduleIn((PAN_INTERVAL - elapsed) / 1000, self.zoom_pan_cb)
    end
    self:_scheduleZoomPanSettle()
end

function ZoomRefresh:_flushZoomPan()
    if not self.zoom_pan_dirty then return end
    if self.zoom <= 1 then self.zoom_pan_dirty = false; return end
    UIManager:unschedule(self.zoom_pan_cb)
    self.zoom_pan_scheduled = false
    -- Coalesce both the framebuffer copy and its refresh. Touch samples can
    -- arrive much faster than frames can be displayed on the panel.
    self:_renderZoom(Screen.bb)
    local c = self.content
    Screen:refreshFast(c.x, c.y, c.w, c.h)
    self.last_zoom_pan_refresh = time.now()
    self.zoom_pan_dirty = false
end

function ZoomRefresh:_scheduleZoomPanSettle()
    self.zoom_pan_needs_settle = true
    UIManager:unschedule(self.zoom_pan_settle_cb)
    UIManager:scheduleIn(PAN_SETTLE_SECONDS, self.zoom_pan_settle_cb)
end

function ZoomRefresh:_settleZoomPan()
    if self.zoom <= 1 or not self.zoom_pan_needs_settle then return end
    -- Some quick drags end as a swipe, without pan_release. A remembered
    -- touch coordinate must not postpone cleanup forever. Movement itself
    -- restarts the debounce; a resting finger does not prevent a redraw.
    if self.pen_down then
        UIManager:scheduleIn(PAN_SETTLE_SECONDS, self.zoom_pan_settle_cb)
        return
    end
    UIManager:unschedule(self.zoom_pan_cb)
    self.zoom_pan_scheduled = false
    self.zoom_pan_dirty = false
    -- Restore authoritative grayscale pixels before the full waveform.
    self:_renderZoom(Screen.bb, true)
    local c = self.content
    Screen:refreshFull(c.x, c.y, c.w, c.h)
    self.zoom_pan_needs_settle = false
end

function ZoomRefresh:_queueZoomInk(x, y, w, h, mode)
    x, y, w, h = Rect.clamp(x, y, w, h, self.content)
    if not x then return end
    self.zoom_ink_pending = Rect.grow(self.zoom_ink_pending, x, y, w, h)
    self.zoom_ink_mode = mode
    local interval = mode == "ui" and MARKER_INTERVAL
        or math.max(20, Tuning.refresh_interval_ms)
    local now = time.now()
    local elapsed = self.last_zoom_ink_refresh
        and time.to_ms(now - self.last_zoom_ink_refresh) or interval
    if elapsed >= interval then
        self:_flushZoomInk()
    elseif not self.zoom_ink_scheduled then
        self.zoom_ink_scheduled = true
        UIManager:scheduleIn(math.max(1, interval - elapsed) / 1000, self.zoom_ink_cb)
    end
end

function ZoomRefresh:_flushZoomInk()
    UIManager:unschedule(self.zoom_ink_cb)
    self.zoom_ink_scheduled = false
    local box = self.zoom_ink_pending
    if not box then return end
    self.zoom_ink_pending = nil
    if self.zoom_ink_mode == "ui" then
        Screen:refreshUI(box.x, box.y, box.w, box.h)
    else
        Screen:refreshFast(box.x, box.y, box.w, box.h)
    end
    self.last_zoom_ink_refresh = time.now()
end

function ZoomRefresh:_clearZoomInk()
    UIManager:unschedule(self.zoom_ink_cb)
    self.zoom_ink_pending = nil
    self.zoom_ink_scheduled = false
    self.last_zoom_ink_refresh = nil
end

return ZoomRefresh
