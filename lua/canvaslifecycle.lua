-- Input ownership and callback lifetime, including screensaver suspension.
local DataStorage = require("datastorage")
local Device = require("device")
local Safe = require("safe")
local UIManager = require("ui/uimanager")
local Lifecycle = {
    lifecycle_callbacks = {"idle_flush_cb", "reconcile_cb", "autosave_cb",
        "erase_flush_cb", "drag_step_cb", "shape_preview_cb", "transform_preview_cb", "zoom_pan_cb",
        "zoom_pan_settle_cb", "zoom_ink_cb", "zoom_erase_cb"},
}

function Lifecycle:_isDisplayPaused()
    return self.suspended or Device.screen_saver_mode or Device.screen_saver_lock
end

function Lifecycle:_unscheduleCanvasCallbacks()
    for _, name in ipairs(self.lifecycle_callbacks) do
        if self[name] then UIManager:unschedule(self[name]) end
    end
end

-- Retain unfinished tool state in memory. Finalize it after the screensaver
-- closes: its snapshots belong to the notebook and must not overwrite a cover.
function Lifecycle:pause()
    if self.suspended then return end
    self.suspended = true
    self:_unscheduleCanvasCallbacks()
    self:_cancelZoomRefresh()
    self.shape_snap:cancel()
    self.barrel_down, self.physical_pen_tool = false, nil
    self.resume_input = self.stylus_callback ~= nil
    if self.resume_input then require("stylusbridge").stop(self) end
end

function Lifecycle:resume()
    if not self.suspended or Device.screen_saver_mode or Device.screen_saver_lock then return false end
    self.suspended = nil
    if self.resume_input then require("stylusbridge").start(self) end
    self.resume_input = nil
    self.pen_down, self.pen_left_at = false, nil
    return true
end

function Lifecycle:_resolveDebugLogPath()
    local debug_root = DataStorage:getDataDir() .. "/notebook"
    if self.document and self.document.path then
        local p = self.document.path:lower()
        if p:match("[/\\]_debug_%.scribe$") or p:match("[/\\]_debug_$") then
            return debug_root .. "/notebook-debug.log"
        end
    end
    for _, name in ipairs({ "_debug_", "_debug_.scribe" }) do
        local f = io.open(debug_root .. "/" .. name, "r")
        if f then
            f:close()
            return debug_root .. "/notebook-debug.log"
        end
    end
    return nil
end

function Lifecycle:start()
    self.stopping = false
    self.debug_log_path = self:_resolveDebugLogPath()
    if self.debug_log_path then
        self:_debugEvent("session-start", nil, nil, nil, self.tool)
    end
    -- KOReader's input handlers outlive this screen. Register restoration
    -- for faults too, since recovery can bypass the normal CloseWidget path.
    Safe.onShutdown("canvas:input", function() self:stop() end)

    require("stylusbridge").start(self)
end

function Lifecycle:stop()
    if self.zoom > 1 then self:_endZoomContact() end
    self:_clearZoomCache()
    self:_cancelZoomRefresh()
    self.shape_snap:cancel()
    self:_debugEvent("session-stop", nil, nil, nil, self.tool)
    self.debug_log_path = nil
    self.stopping = true
    -- Whichever path got here first is the one that does it; the other must not
    -- run again and put the patches back on top of the restored handlers.
    Safe.clearShutdown("canvas:input")
    require("stylusbridge").stop(self)
    self:_unscheduleCanvasCallbacks()
    self:_endStroke()
    self:_endShapeTransform()
    require("textcache").clear()
    require("pdfbackground").clear()
    if self.background_cache then self.background_cache:free(); self.background_cache=nil end
    self.background_cache_key=nil
    self:_endErase()
    self.physical_pen_tool = nil
    self.barrel_down = false
    self.zoom_pan_dirty = false
    self:_deselectLasso()
    UIManager:unschedule(self.drag_step_cb)
    UIManager:unschedule(self.erase_flush_cb)
    UIManager:unschedule(self.reconcile_cb)
    UIManager:unschedule(self.autosave_cb)
    if self.document and self.document.dirty then
        self.document:save()
    end
    if self.idle_flush_cb then
        UIManager:unschedule(self.idle_flush_cb)
    end
    self:_flush()
end

return Lifecycle
