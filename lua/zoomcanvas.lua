-- Zoomed viewport, cache, pan refresh and stylus interaction.
-- Installed on Canvas so existing gesture and drawing call sites keep their API.
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Stroke = require("stroke")
local Tuning = require("tuning")
local Zoom = require("zoom")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local ZoomCanvas = {}

function ZoomCanvas:setZoom(scale)
    scale = scale == 2 and 2 or 1
    if self.zoom == scale then return end
    self:_endZoomContact()
    self:_clearZoomCache()
    self:_cancelZoomRefresh()
    self.zoom = scale
    self.zoom_x, self.zoom_y = self.content.x, self.content.y
    self:_debugEvent("zoom", nil, nil, nil, scale)
    if self.owner then UIManager:setDirty(self.owner, "ui") end
end

function ZoomCanvas:_endZoomContact()
    self.shape_snap:cancel()
    self:_clearZoomInk()
    local changed, changed_box, changed_tool
    if self.zoom_stroke then
        local stroke = self.zoom_stroke
        self.zoom_stroke = nil
        if stroke:count() > 0 then
            if stroke.tool == "highlighter" then stroke.tint = self.highlighter_color end
            self.document:addStroke(stroke)
            changed, changed_tool = true, stroke.tool
            local sx, sy, sw, sh = stroke:getBounds()
            if sx then
                local c = self.content
                changed_box = {x=c.x + (sx-self.zoom_x)*self.zoom,
                    y=c.y + (sy-self.zoom_y)*self.zoom,
                    w=sw*self.zoom, h=sh*self.zoom}
            end
            if self.zoom_cache and self.zoom_cache_page == self.document:getPage() then
                local c = self.content
                Renderer.drawPage(self.zoom_cache, {strokes={stroke}}, self.zoom,
                    -c.x*self.zoom, -c.y*self.zoom,
                    Screen.isColorEnabled and Screen:isColorEnabled())
            else
                self:_clearZoomCache()
            end
            UIManager:unschedule(self.autosave_cb)
            UIManager:scheduleIn(2.5, self.autosave_cb)
            if self.on_change then self:on_change() end
        end
    end
    if self.zoom_erasing then
        changed, changed_tool = true, "eraser"
        self.document:commitBatch()
        self:_clearZoomCache()
        if self.document.dirty then
            UIManager:unschedule(self.autosave_cb)
            UIManager:scheduleIn(2.5, self.autosave_cb)
        end
        self.zoom_erasing = nil
        self.zoom_last_x, self.zoom_last_y = nil, nil
    end
    self.pen_down = false
    if self.zoom > 1 and changed then
        local c = self.content
        if changed_tool == "eraser" or not changed_box then
            self:_renderZoom(Screen.bb, not self.zoom_cache)
            Screen:refreshUI(c.x, c.y, c.w, c.h)
        else
            local x, y, w, h = Rect.clamp(changed_box.x, changed_box.y,
                changed_box.w, changed_box.h, c)
            if x then
                if self.zoom_cache then
                    -- The live pen pixels are already correct. Only the
                    -- marker's temporary dark tint needs replacing, and it
                    -- takes one small blit rather than a viewport-sized one.
                    if changed_tool == "highlighter" then
                        self:_blitZoomCacheRegion(x, y, w, h)
                    end
                elseif changed_tool == "highlighter" then
                    self:_renderZoom(Screen.bb, true)
                end
                Screen:refreshUI(x, y, w, h)
            end
        end
        self.zoom_erase_dirty = false
    end
end

function ZoomCanvas:_zoomStylus(slot, tool)
    -- Finish a pending finger frame before putting ink at the new origin.
    -- A later pan callback must never overwrite the start of a pen stroke.
    if slot.id ~= -1 then self:_flushZoomPan() end
    if slot.id == -1 then
        local was_drawing = self.zoom_stroke ~= nil or self.zoom_erasing ~= nil
        if was_drawing then self:_endZoomContact() end
        return was_drawing
    end
    local x, y = slot.x, slot.y
    if not x or not y then return true end
    local c = self.content
    if x < c.x or x >= c.x + c.w or y < c.y or y >= c.y + c.h then
        if self.zoom_stroke or self.zoom_erasing then self:_endZoomContact() end
        return false
    end
    self.pen_down = true
    local px, py = Zoom.toPage(x, y, c, self.zoom, self.zoom_x, self.zoom_y)
    if tool == "eraser" then
        self.shape_snap:cancel()
        if self.zoom_stroke then self:_endZoomContact(); self.pen_down = true end
        if not self.zoom_erasing then
            self.document:beginBatch()
            self.zoom_erasing = true
        end
        local lx, ly = self.zoom_last_x or px, self.zoom_last_y or py
        local path = {lx, ly, px, py}
        local hit
        if self.eraser_mode == "area" then
            hit = self.document:eraseAreaAlongPath(path, self.eraser_size)
        else
            hit = self.document:eraseAlongPath(path, self.eraser_size)
        end
        self.zoom_last_x, self.zoom_last_y = px, py
        if hit then
            self.zoom_erase_dirty = true
            if self.zoom_cache then self:_clearZoomCache() end
            local now = time.now()
            if not self.last_zoom_erase_refresh
                or time.to_ms(now - self.last_zoom_erase_refresh) >= Tuning.erase_repaint_ms then
                -- Render only the visible viewport while the rubber moves.
                -- Rebuilding the enlarged full-page cache here costs four
                -- screenfuls per update; it is rebuilt once on lift-off.
                self:_renderZoom(Screen.bb, true)
                Screen:refreshUI(c.x, c.y, c.w, c.h)
                self.last_zoom_erase_refresh = now
                self.zoom_erase_dirty = false
            end
            if self.on_change then self:on_change() end
        end
        return true
    end
    if self.zoom_erasing then self:_endZoomContact(); self.pen_down = true end
    if self.zoom_stroke and self.zoom_stroke.tool ~= tool then
        self:_endZoomContact()
        self.pen_down = true
    end
    local pressure = slot.pressure and math.max(0, math.min(1, slot.pressure / 4095)) or 1
    if not self.zoom_stroke then
        self.zoom_stroke = Stroke:new{tool=tool, width=self:widthFor(tool),
            color=tool == "pen" and self:_penColor() or 0,
            tint=tool == "highlighter" and Tuning.live_highlight_tint or nil}
        self.shape_snap:begin(self.zoom_stroke, px, py, self.line_style)
    end
    local stroke = self.zoom_stroke
    if self.shape_snap.snapped then return true end
    local n = stroke:count()
    local lx, ly, lp = px, py, pressure
    if n > 0 then lx, ly, lp = stroke:getPoint(n) end
    if n > 0 and lx == px and ly == py then return true end
    if n == 0 or lx ~= px or ly ~= py then
        stroke:addPoint(px, py, pressure)
        self.shape_snap:moved(px, py)
    end
    local view = Screen.bb:viewport(c.x, c.y, c.w, c.h)
    local scaled = {tool=stroke.tool, color=stroke.color, tint=stroke.tint,
        width=stroke.width * self.zoom}
    local x0, y0 = (lx - self.zoom_x) * self.zoom, (ly - self.zoom_y) * self.zoom
    local x1, y1 = (px - self.zoom_x) * self.zoom, (py - self.zoom_y) * self.zoom
    local rx, ry, rw, rh = Renderer.drawSegment(view, scaled, x0, y0, lp,
        x1, y1, pressure, {x=0,y=0,w=c.w,h=c.h},
        Screen.isColorEnabled and Screen:isColorEnabled())
    if rx then
        self:_queueZoomInk(c.x+rx, c.y+ry, rw, rh,
            (tool == "highlighter" or stroke.color ~= 0) and "ui" or "fast")
    end
    return true
end

return ZoomCanvas
