-- Incremental eraser path, undo batch and repaint cadence.
local Rect = require("rect")
local Safe = require("safe")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local EraserCanvas = {}

--- Closes the eraser's undo group, if one is open.
function EraserCanvas:_endErase()
    UIManager:unschedule(self.erase_flush_cb)
    self.erase_flush_scheduled = false
    self:_flushEraseWork()
    self.erase_path = nil
    self.erasing = false
    self.last_erase_apply = nil
    self.last_erase_x, self.last_erase_y = nil, nil
    self.last_sample_at = nil
    self.outliers = 0
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
function EraserCanvas:_eraseAlong(x, y)
    local px, py = self.last_erase_x, self.last_erase_y

    -- The hand's contact can be forwarded as the pen's, exactly as it can while
    -- writing (see _isOutlier) -- and here believing it would sweep the rubber
    -- across everything between the nib and the palm.
    local scale=self.zoom or 1
    local drop, afresh = self:_isOutlier(x*scale, y*scale,
        px and px*scale, py and py*scale)
    if drop then return end
    if afresh then
        -- Finish the old connected path before starting a new contact island.
        -- Merely clearing px left the queued path's old tail attached.
        self:_applyErasePath()
        self.erase_path = nil
        px, py = nil, nil
    end

    self.erasing = true
    UIManager:unschedule(self.reconcile_cb)
    self.last_erase_x, self.last_erase_y = x, y
    self.last_point_at = time.now()
    self.last_sample_at = self.sample_time
    if px==x and py==y then return end

    -- One sweep of the eraser is one undoable action, however far it travels.
    if not px then
        self.document:beginBatch()
        px, py = x, y
    end

    local path = self.erase_path
    if not path then
        path = { px, py }
        self.erase_path = path
    end
    local n=#path
    if n>=4 then
        local ax,ay,bx,by=path[n-3],path[n-2],path[n-1],path[n]
        local dx,dy=bx-ax,by-ay
        if dx*(y-by)==dy*(x-bx) and dx*(x-bx)+dy*(y-by)>=0 then
            -- Exact collinear continuation has the same swept capsule union.
            -- Retain turns and reversals; never replace a curve by its chord.
            path[n-1],path[n]=x,y
        else
            path[n+1],path[n+2]=x,y
        end
    else
        path[n+1],path[n+2]=x,y
    end

    local now = time.now()
    local elapsed = self.last_erase_apply and time.to_ms(now - self.last_erase_apply)
        or Tuning.erase_repaint_ms
    if elapsed >= Tuning.erase_repaint_ms then
        self:_applyErasePath()
    elseif not self.erase_flush_scheduled then
        self.erase_flush_scheduled = true
        UIManager:scheduleIn(math.max(1, Tuning.erase_repaint_ms - elapsed) / 1000,
            self.erase_flush_cb)
    end
end

-- Applies all raw eraser samples gathered during one display interval in one
-- model pass. This is the important half of throttling: postponing only the
-- repaint still walked every stroke on the page for every digitizer sample.
function EraserCanvas:_applyErasePath()
    local path = self.erase_path
    if not path or #path < 4 then return end
    self.erase_path = { path[#path - 1], path[#path] }
    -- The first dab does not postpone the first actual move. Stationary
    -- samples are rejected above; a reversing path still starts the interval.
    if #path>4 or path[1]~=path[#path-1] or path[2]~=path[#path] then
        self.last_erase_apply = time.now()
    end
    self.erase_shapes = self.erase_shapes or {}
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

function EraserCanvas:_flushEraseWork()
    self:_applyErasePath()
    self:_flushEraseRepaint()
    -- The application may schedule a repaint before the explicit flush above.
    -- No pending pixels remain, so do not leave a redundant callback behind.
    UIManager:unschedule(self.erase_flush_cb)
    self.erase_flush_scheduled = false
end

--- Merges a region into the pending erase repaint, flushing on a timer.
function EraserCanvas:_queueEraseRepaint(x, y, w, h)
    if self.zoom > 1 then
        self.zoom_erase_dirty = true
        self.zoom_erase_region = Rect.grow(self.zoom_erase_region,x,y,w,h)
        self:_flushZoomErase()
        return
    end
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

function EraserCanvas:_flushEraseRepaint()
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
function EraserCanvas:_noteErased(x, y, w, h)
    self.erase_bounds = Rect.grow(self.erase_bounds, x, y, w, h)
end

return EraserCanvas
