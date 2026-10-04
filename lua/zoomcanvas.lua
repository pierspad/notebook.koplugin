-- Zoomed viewport, cache, pan refresh and stylus interaction.
-- Installed on Canvas so existing gesture and drawing call sites keep their API.
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Stroke = require("stroke")
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
    self:_flushZoomInk()
    self:_clearZoomInk()
    if self.transform_gesture then self:_endShapeTransform() end
    if self.shape_gesture then self:_endShape() end
    local changed, changed_box, changed_tool
    if self.zoom_stroke then
        local stroke = self.zoom_stroke
        self.zoom_stroke = nil
        if stroke:count() > 0 then
            if stroke.tool == "highlighter" then stroke.tint = self.highlighter_color end
            if stroke.tool=="lasso" then
                self:_renderZoom(Screen.bb,true)
                local points={}
                for i=1,stroke:count() do local x,y=stroke:getPoint(i);points[#points+1]={x=x,y=y} end
                local selected=require("lasso").findSelectedStrokes(self.document:getPage().strokes,points)
                self.pen_down=false;self.zoom_point_at=nil
                if #selected>0 then self:_showLassoMenu(selected) else self:_deselectLasso() end
                return
            end
            self.document:addStroke(stroke)
            self:_finishLiveInk(stroke)
            changed, changed_tool = true, stroke.tool
            local sx, sy, sw, sh = stroke:getBounds()
            if sx then
                local c = self.content
                changed_box = {x=c.x + (sx-self.zoom_x)*self.zoom,
                    y=c.y + (sy-self.zoom_y)*self.zoom,
                    w=sw*self.zoom, h=sh*self.zoom}
            end
            if self.zoom_cache and self.zoom_cache_page == self.document:getPage() then
                self.zoom_cache_pending=self.zoom_cache_pending or {}
                self.zoom_cache_pending[#self.zoom_cache_pending+1]=stroke
                self.zoom_cache_pending_revision=self.document:getPage().revision or 0
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
        self:_endErase()
        self:_flushZoomErase()
        if self.zoom_cache then self.zoom_cache_revision=self.document:getPage().revision or 0 end
        if self.document.dirty then
            UIManager:unschedule(self.autosave_cb)
            UIManager:scheduleIn(2.5, self.autosave_cb)
        end
        self.zoom_erasing = nil
        self.zoom_last_x, self.zoom_last_y = nil, nil
    end
    self.pen_down = false
    self.zoom_point_at=nil
    if self.zoom > 1 and changed and changed_tool ~= "eraser" then
        local c = self.content
        if not changed_box then
            self:_renderZoom(Screen.bb, not self.zoom_cache)
            Screen:refreshUI(c.x, c.y, c.w, c.h)
        else
            local x, y, w, h = Rect.clamp(changed_box.x, changed_box.y,
                changed_box.w, changed_box.h, c)
            if x then
                self:_scheduleReconcile(x,y,w,h)
            end
        end
        self.zoom_erase_dirty = false
    end
end

function ZoomCanvas:_zoomStylus(slot, tool)
    -- A pen sequence (including lift) starts a fresh quiet window. A retry
    -- timer must not flash immediately after the nib leaves the screen.
    if self.zoom_pan_needs_settle then self:_scheduleZoomPanSettle() end
    -- Finish a pending finger frame before putting ink at the new origin.
    -- A later pan callback must never overwrite the start of a pen stroke.
    if slot.id ~= -1 then self:_flushZoomPan() end
    if slot.id == -1 then
        local was_drawing = self.zoom_stroke ~= nil or self.zoom_erasing ~= nil
            or self.shape_gesture ~= nil or self.transform_gesture ~= nil
        self.pen_down=false
        self.pen_left_at=time.now()
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
    if not self.transform_gesture and self.lasso_menu and self.lasso_menu.dimen then
        local m=self.lasso_menu.dimen
        if x>=m.x and x<m.x+m.w and y>=m.y and y<m.y+m.h then return false end
    end
    local new_contact=not self.pen_down
    self.pen_down = true
    self.pen_left_at=nil
    UIManager:unschedule(self.reconcile_cb)
    local px, py = Zoom.toPage(x, y, c, self.zoom, self.zoom_x, self.zoom_y)
    if self.transform_gesture then self:_extendShapeTransform(px,py); return true end
    if self.shape_gesture then self:_extendShape(px,py); return true end
    if new_contact and self.selected_strokes then
        local selected=#self.selected_strokes==1 and self.selected_strokes[1]
        local handle=selected and self:_shapeHandleAt(selected,px,py)
        if handle then self:_beginShapeTransform(selected,handle,px,py); return true end
        self:_deselectLasso()
    end
    if tool=="shape" then self:_beginShape(px,py); return true end
    if tool ~= "pen" and tool ~= "highlighter" and tool ~= "eraser" and tool ~= "lasso" then return false end
    if tool == "eraser" then
        self.shape_snap:cancel()
        if self.zoom_stroke then self:_endZoomContact(); self.pen_down = true end
        if not self.zoom_erasing then
            self.document:beginBatch()
            self.zoom_erasing = true
        end
        self:_eraseAlong(px,py)
        return true
    end
    if self.zoom_erasing then self:_endZoomContact(); self.pen_down = true end
    if self.zoom_stroke and self.zoom_stroke.tool ~= tool then
        self:_endZoomContact()
        self.pen_down = true
    end
    local raw_pressure=slot.pressure
    if raw_pressure == nil and tool == "pen" and self.pen_style ~= "fineliner" and self.pressure_sensor then
        raw_pressure=self.pressure_sensor:read()
    end
    local pressure=require("penpressure").sample(tool == "pen" and self.pen_style or nil,
        self.zoom_stroke,px,py,raw_pressure,self.zoom_point_at and time.to_ms(time.now()-self.zoom_point_at))
    if not self.zoom_stroke then
        self.zoom_stroke = Stroke:new{tool=tool, pen_style=tool == "pen" and self.pen_style or nil, width=self:widthFor(tool),
            color=tool == "pen" and self:_penColor() or 0,
            tint=tool == "highlighter" and self.highlighter_color or nil}
        self:_beginLiveInk(self.zoom_stroke)
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
        self.zoom_point_at=time.now()
        self.shape_snap:moved(px, py)
    end
    local view = Screen.bb:viewport(c.x, c.y, c.w, c.h)
    local brush = self:_liveBrush(stroke)
    local scaled = {tool=brush.tool, pen_style=brush.pen_style, color=brush.color, tint=brush.tint,
        live_preview=brush.live_preview, width=brush.width * self.zoom}
    local x0, y0 = (lx - self.zoom_x) * self.zoom, (ly - self.zoom_y) * self.zoom
    local x1, y1 = (px - self.zoom_x) * self.zoom, (py - self.zoom_y) * self.zoom
    local rx, ry, rw, rh = Renderer.drawSegment(view, scaled, x0, y0, lp,
        x1, y1, pressure, {x=0,y=0,w=c.w,h=c.h},
        Screen.isColorEnabled and Screen:isColorEnabled(),
        self.zoom_x*self.zoom, self.zoom_y*self.zoom)
    if rx then
        self:_trackLiveInk(c.x+rx,c.y+ry,rw,rh)
        self:_queueZoomInk(c.x+rx, c.y+ry, rw, rh, "fast")
    end
    return true
end

return ZoomCanvas
