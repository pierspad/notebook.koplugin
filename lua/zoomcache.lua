local Raster = require("raster")
-- Enlarged page cache and viewport copies. Interaction and refresh cadence
-- are owned by zoomcanvas.lua and zoomrefresh.lua respectively.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Renderer = require("renderer")
local Template = require("template")
local Rect = require("rect")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Screen = Device.screen
local ZoomCache = {}

function ZoomCache:_clearZoomCache()
    if self.zoom_cache then self.zoom_cache:free() end
    self.zoom_cache = nil
    self.zoom_cache_page = nil
    self.zoom_cache_revision = nil
    self.zoom_cache_key = nil
    self.zoom_cache_pending=nil
    self.zoom_cache_pending_revision=nil
end

function ZoomCache:_flushZoomCacheInk()
    local pending=self.zoom_cache_pending
    local revision=self.zoom_cache_pending_revision
    self.zoom_cache_pending=nil
    self.zoom_cache_pending_revision=nil
    if self.zoom_cache and pending then
        local c=self.content
        Renderer.drawPage(self.zoom_cache,{strokes=pending},self.zoom,-c.x*self.zoom,-c.y*self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
        self.zoom_cache_revision = revision
    end
end

-- Repair just the affected page rectangle, including pixels outside the
-- current viewport. A later pan must not resurrect ink removed by history.
function ZoomCache:_repairZoomCacheRegion(x, y, w, h)
    if not self.zoom_cache or self.zoom_cache_page ~= self.document:getPage() then return false end
    self:_flushZoomCacheInk()
    local c, scale = self.content, self.zoom
    local rx,ry,rw,rh = Rect.clamp((x-c.x)*scale,(y-c.y)*scale,w*scale,h*scale,
        {x=0,y=0,w=self.zoom_cache:getWidth(),h=self.zoom_cache:getHeight()})
    if rx then
        local view = self.zoom_cache:viewport(rx,ry,rw,rh)
        Raster.rect(view,0,0,rw,rh,Blitbuffer.COLOR_WHITE)
        self:_drawZoomPaper(view,{x=-rx,y=-ry,w=c.w*scale,h=c.h*scale})
        Renderer.drawPage(view,self.document:getPage(),scale,-c.x*scale-rx,-c.y*scale-ry,
            Screen.isColorEnabled and Screen:isColorEnabled())
    end
    self.zoom_cache_revision = self.document:getPage().revision or 0
    return true
end

function ZoomCache:_blitZoomCacheRegion(x, y, w, h)
    self:_flushZoomCacheInk()
    local c = self.content
    local source_x = math.floor((self.zoom_x-c.x)*self.zoom) + x-c.x
    local source_y = math.floor((self.zoom_y-c.y)*self.zoom) + y-c.y
    Screen.bb:blitFrom(self.zoom_cache, x, y, source_x, source_y, w, h)
end

function ZoomCache:_drawZoomPaper(bb, area)
    local background=self.document:getPage().background
    if background then require("pdfbackground").draw(bb,background,area)
    else Template.draw(bb,self.document:templateFor(),area,self.zoom) end
end

-- Page-space dirty bounds from the eraser are repaired in the enlarged cache
-- and copied only where they intersect the current viewport.
function ZoomCache:_flushZoomErase()
    UIManager:unschedule(self.zoom_erase_cb)
    self.zoom_erase_scheduled=false
    local dirty=self.zoom_erase_region
    if not dirty then return end
    self.zoom_erase_region=nil
    self.zoom_erase_dirty=false
    self.last_zoom_erase_refresh=time.now()
    local c, scale=self.content,self.zoom
    local function repair(bb, origin_x, origin_y)
        local x,y,w,h=Rect.clamp((dirty.x-origin_x)*scale,(dirty.y-origin_y)*scale,
            dirty.w*scale,dirty.h*scale,{x=0,y=0,w=bb:getWidth(),h=bb:getHeight()})
        if not x then return end
        local view=bb:viewport(x,y,w,h)
        Raster.rect(view,0,0,w,h,Blitbuffer.COLOR_WHITE)
        self:_drawZoomPaper(view,{x=(c.x-origin_x)*scale-x,y=(c.y-origin_y)*scale-y,
            w=c.w*scale,h=c.h*scale})
        Renderer.drawPage(view,self.document:getPage(),scale,-origin_x*scale-x,-origin_y*scale-y,
            Screen.isColorEnabled and Screen:isColorEnabled())
    end
    self:_flushZoomCacheInk()
    if self.zoom_cache then
        repair(self.zoom_cache,c.x,c.y)
        self.zoom_cache_revision = self.document:getPage().revision or 0
    end
    local x,y,w,h=Rect.clamp(c.x+(dirty.x-self.zoom_x)*scale,c.y+(dirty.y-self.zoom_y)*scale,
        dirty.w*scale,dirty.h*scale,c)
    if not x then return end
    if self.zoom_cache then self:_blitZoomCacheRegion(x,y,w,h)
    else repair(Screen.bb:viewport(c.x,c.y,c.w,c.h),self.zoom_x,self.zoom_y) end
    self:_refreshNow(x,y,w,h,"ui")
end

function ZoomCache:_renderZoom(bb, direct)
    self:_flushZoomCacheInk()
    local c = self.content
    local view = bb:viewport(c.x, c.y, c.w, c.h)
    local page = self.document:getPage()
    local background = page.background
    local key = table.concat({self.document:templateFor() or "", self.zoom,
        c.x,c.y,c.w,c.h, tostring(Screen.isColorEnabled and Screen:isColorEnabled()),
        background and background.file or "", background and background.page or ""}, "|")
    local editing=self.transform_gesture or self.shape_gesture or self.hidden_stroke
    if editing then direct=true end
    local draw_page=self:_visiblePage()
    -- Build the enlarged page once. Panning then copies a viewport instead of
    -- rasterizing every stroke and every paper line for each touch sample.
    if not direct and bb.getType and (not self.zoom_cache or self.zoom_cache_page ~= page
        or self.zoom_cache_revision ~= (page.revision or 0) or self.zoom_cache_key ~= key) then
        self:_clearZoomCache()
        local w, h = c.w * self.zoom, c.h * self.zoom
        self.zoom_cache = Blitbuffer.new(w, h, bb:getType())
        Raster.rect(self.zoom_cache,0, 0, w, h, Blitbuffer.COLOR_WHITE)
        self:_drawZoomPaper(self.zoom_cache, {x=0,y=0,w=w,h=h})
        Renderer.drawPage(self.zoom_cache, draw_page, self.zoom,
            -c.x * self.zoom, -c.y * self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
        self.zoom_cache_page = page
        self.zoom_cache_revision = page.revision or 0
        self.zoom_cache_key = key
    end
    if self.zoom_cache and not direct then
        view:blitFrom(self.zoom_cache, 0, 0,
            math.floor((self.zoom_x-c.x)*self.zoom),
            math.floor((self.zoom_y-c.y)*self.zoom), c.w, c.h)
    else
        -- Small in-memory test buffers do not implement getType.
        Raster.rect(view,0, 0, c.w, c.h, Blitbuffer.COLOR_WHITE)
        local area = {x=(c.x-self.zoom_x)*self.zoom,
            y=(c.y-self.zoom_y)*self.zoom, w=c.w*self.zoom, h=c.h*self.zoom}
        self:_drawZoomPaper(view, area)
        Renderer.drawPage(view, draw_page, self.zoom,
            -self.zoom_x*self.zoom, -self.zoom_y*self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
    end
    local shape_preview=self.transform_gesture and self.transform_gesture.preview or self.stroke
    if shape_preview then
        Renderer.drawPage(view,{strokes={shape_preview}},self.zoom,
            -self.zoom_x*self.zoom,-self.zoom_y*self.zoom,Screen.isColorEnabled and Screen:isColorEnabled())
    end
    if self.zoom_stroke then
        Renderer.drawPage(view, {strokes={self.zoom_stroke}}, self.zoom,
            -self.zoom_x * self.zoom, -self.zoom_y * self.zoom,
            Screen.isColorEnabled and Screen:isColorEnabled())
    end
end

return ZoomCache
