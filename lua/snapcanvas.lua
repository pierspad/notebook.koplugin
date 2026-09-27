-- Replaces a held freehand stroke with its recognized geometry. The timer and
-- recognition rules live in shapesnap.lua; this module only updates pixels.
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")

local Screen = Device.screen
local SnapCanvas = {}

local function zoomBounds(self, stroke)
    local x, y, w, h = stroke:getBounds()
    if not x then return nil end
    local c = self.content
    return c.x+(x-self.zoom_x)*self.zoom,
        c.y+(y-self.zoom_y)*self.zoom, w*self.zoom, h*self.zoom
end

function SnapCanvas:_applyShapeSnap(clean, raw)
    if self.stroke ~= raw and self.zoom_stroke ~= raw then return end
    self:_restoreLiveInk()
    if self.zoom > 1 and self.zoom_stroke == raw then
        self:_clearZoomInk()
        self.zoom_stroke = clean
        local dirty = Rect.grow(nil, zoomBounds(self, raw))
        dirty = Rect.grow(dirty, zoomBounds(self, clean))
        local c = self.content
        local x, y, w, h = Rect.clamp(dirty.x, dirty.y, dirty.w, dirty.h, c)
        if not x then return end
        if self.zoom_cache and self.zoom_cache_page == self.document:getPage() then
            self:_blitZoomCacheRegion(x, y, w, h)
            local view = Screen.bb:viewport(c.x, c.y, c.w, c.h)
            Renderer.drawPage(view, {strokes={clean}}, self.zoom,
                -self.zoom_x*self.zoom, -self.zoom_y*self.zoom,
                Screen.isColorEnabled and Screen:isColorEnabled())
        else
            -- A framebuffer without an enlarged cache still has the ordinary
            -- renderer, used by the emulator and small test buffers.
            self:_renderZoom(Screen.bb, true)
        end
        Screen:refreshUI(x, y, w, h)
        return
    end
    if self.stroke ~= raw then return end
    local bx, by, bw, bh = raw:getBounds()
    self.stroke = clean
    if bx then
        self:_repaintRegion(bx, by, bw, bh, true)
        self:_accumulate(bx, by, bw, bh)
    end
    local nx, ny, nw, nh = clean:getBounds()
    if nx then
        Renderer.drawStroke(Screen.bb, clean, self.content,
            Screen.isColorEnabled and Screen:isColorEnabled())
        self:_accumulate(nx, ny, nw, nh)
    end
    -- Replacing pixels needs a grayscale waveform: fast ink updates leave
    -- remnants of the old shaft and cannot resolve pencil/color detail.
    local mode = self.refresh_mode
    self.refresh_mode = "ui"
    self:_flush()
    self.refresh_mode = mode
end

return SnapCanvas
