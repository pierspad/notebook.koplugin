-- Enlarged page cache and viewport copies. Interaction and refresh cadence
-- are owned by zoomcanvas.lua and zoomrefresh.lua respectively.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Renderer = require("renderer")
local Template = require("template")
local Screen = Device.screen
local ZoomCache = {}

function ZoomCache:_clearZoomCache()
    if self.zoom_cache then self.zoom_cache:free() end
    self.zoom_cache = nil
    self.zoom_cache_page = nil
end

function ZoomCache:_blitZoomCacheRegion(x, y, w, h)
    local c = self.content
    local source_x = math.floor((self.zoom_x-c.x)*self.zoom) + x-c.x
    local source_y = math.floor((self.zoom_y-c.y)*self.zoom) + y-c.y
    Screen.bb:blitFrom(self.zoom_cache, x, y, source_x, source_y, w, h)
end

function ZoomCache:_renderZoom(bb, direct)
    local c = self.content
    local view = bb:viewport(c.x, c.y, c.w, c.h)
    local page = self.document:getPage()
    -- Build the enlarged page once. Panning then copies a viewport instead of
    -- rasterizing every stroke and every paper line for each touch sample.
    if not direct and bb.getType and (not self.zoom_cache or self.zoom_cache_page ~= page) then
        self:_clearZoomCache()
        local w, h = c.w * self.zoom, c.h * self.zoom
        self.zoom_cache = Blitbuffer.new(w, h, bb:getType())
        self.zoom_cache:paintRect(0, 0, w, h, Blitbuffer.COLOR_WHITE)
        Template.draw(self.zoom_cache, self.document:templateFor(),
            {x=0, y=0, w=w, h=h}, self.zoom)
        Renderer.drawPage(self.zoom_cache, page, self.zoom,
            -c.x * self.zoom, -c.y * self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
        self.zoom_cache_page = page
    end
    if self.zoom_cache and not direct then
        view:blitFrom(self.zoom_cache, 0, 0,
            math.floor((self.zoom_x-c.x)*self.zoom),
            math.floor((self.zoom_y-c.y)*self.zoom), c.w, c.h)
    else
        -- Small in-memory test buffers do not implement getType.
        view:paintRect(0, 0, c.w, c.h, Blitbuffer.COLOR_WHITE)
        local area = {x=(c.x-self.zoom_x)*self.zoom,
            y=(c.y-self.zoom_y)*self.zoom, w=c.w*self.zoom, h=c.h*self.zoom}
        Template.draw(view, self.document:templateFor(), area, self.zoom)
        Renderer.drawPage(view, page, self.zoom,
            -self.zoom_x*self.zoom, -self.zoom_y*self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
    end
    if self.zoom_stroke then
        Renderer.drawPage(view, {strokes={self.zoom_stroke}}, self.zoom,
            -self.zoom_x * self.zoom, -self.zoom_y * self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
    end
end

return ZoomCache
