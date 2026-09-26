-- Rendering, dirty rectangles and E-Ink refresh scheduling.
-- Owns full-page rendering and the shared region repaint path.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Template = require("template")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local CanvasRender = {}

-- Refresh management -----------------------------------------------------------

--- Merges a rectangle into the pending refresh region.
function CanvasRender:_accumulate(x, y, w, h)
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
function CanvasRender:_refreshNow(x, y, w, h, mode)
    x, y, w, h = Rect.clamp(x, y, w, h, self.content)
    if not x then return end
    if mode == "ui" then
        Screen:refreshUI(x, y, w, h)
    else
        Screen:refreshFast(x, y, w, h)
    end
end

--- Issues the pending partial refresh, if any.
function CanvasRender:_flush()
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
function CanvasRender:_maybeFlush()
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
Queues the grayscale clean-up for an area, coalescing it with anything already
pending and pushing the deadline back.

Deliberately *not* a UIManager repaint. The pixels in the screen buffer are
already correct -- the fast path drew them -- so all that is needed is the same
area shown again under a better waveform. Going through UIManager would instead
repaint the whole widget, which means rasterising every stroke on the page from
the vector model, and that cost grows with each stroke until writing stalls.
--]]
function CanvasRender:_scheduleReconcile(x, y, w, h)
    self.reconcile = Rect.grow(self.reconcile, x, y, w, h)

    UIManager:unschedule(self.reconcile_cb)
    UIManager:scheduleIn(Tuning.reconcile_delay_ms / 1000, self.reconcile_cb)
end

function CanvasRender:_runReconcile()
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

--- Repaints a region from the vector model.
-- With `defer_refresh`, the pixels are restored but nothing is sent to the
-- panel: the caller is about to refresh a region that covers this one anyway,
-- and two overlapping refreshes would flicker.
function CanvasRender:_repaintRegion(x, y, w, h, defer_refresh)
    if self.zoom > 1 then
        self:_clearZoomCache()
        self:_renderZoom(Screen.bb)
        if not defer_refresh then
            local c = self.content
            Screen:refreshUI(c.x, c.y, c.w, c.h)
        end
        return
    end
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
            and not (self.transform_gesture and stroke == self.transform_gesture.original)
            and sx < x + w and sx + sw > x and sy < y + h and sy + sh > y then
            Renderer.drawStroke(Screen.bb, stroke, clip, Screen.isColorEnabled and Screen:isColorEnabled())
        end
    end
    if self.text_preview then
        local sx,sy,sw,sh=self.text_preview:getBounds()
        if sx < x+w and sx+sw > x and sy < y+h and sy+sh > y then
            Renderer.drawStroke(Screen.bb,self.text_preview,clip, Screen.isColorEnabled and Screen:isColorEnabled())
        end
    end
    if not defer_refresh then
        Screen:refreshUI(x, y, w, h)
    end
end

--- Authoritative render, straight from the vector model.
function CanvasRender:paintTo(bb, x, y)
    if self.zoom > 1 then return self:_renderZoom(bb) end
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
        if stroke ~= self.hidden_stroke then Renderer.drawStroke(bb,stroke,nil, Screen.isColorEnabled and Screen:isColorEnabled()) end
    end
    if self.text_preview then Renderer.drawStroke(bb,self.text_preview,nil, Screen.isColorEnabled and Screen:isColorEnabled()) end
end

--[[--
Lays the page's background down, under the ink.

Called from both places that rebuild pixels from the model, which is what makes
the background un-erasable: the eraser does not remove pixels, it repaints an
area from scratch, so as long as that repaint starts with the background, rubbing
out a word written across a ruled line leaves the line untouched.
--]]
function CanvasRender:_drawTemplate(bb, clip)
    local background=self.document:getPage().background
    if background then require("pdfbackground").draw(bb,background,self.content,clip)
    else Template.draw(bb, self.document:templateFor(), self.content, 1, clip) end
end

return CanvasRender
