-- Pixel rendering; dirty-region refresh scheduling lives in canvasrefresh.lua.
-- Owns full-page rendering and the shared region repaint path.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Template = require("template")

local Screen = Device.screen
local CanvasRender = {}

local function bufferSize(bb)
    return bb.getWidth and bb:getWidth() or 0,
        bb.getHeight and bb:getHeight() or 0
end

local function bufferBPP(bb)
    local kind = bb.getType and bb:getType()
    return kind and Blitbuffer.TYPE_TO_BPP and Blitbuffer.TYPE_TO_BPP[kind] or 8
end

local function contentBounds(bb, content)
    local w, h = bufferSize(bb)
    local x, y, cw, ch = Rect.clamp(content.x, content.y, content.w, content.h,
        { x = 0, y = 0, w = w, h = h })
    if not x then return nil end
    return { x = x, y = y, w = cw, h = ch }
end

local function copyBounds(bb, bounds)
    if not bounds then return nil end
    local kind = bb.getType and bb:getType() or Blitbuffer.TYPE_BB8
    local copy = Blitbuffer.new(bounds.w, bounds.h, kind)
    copy:blitFrom(bb, 0, 0, bounds.x, bounds.y, bounds.w, bounds.h)
    return copy
end

local function sameBounds(a, b)
    return a and b and a.x == b.x and a.y == b.y
        and a.w == b.w and a.h == b.h
end

local function backgroundKey(self, page, bb, bpp)
    local background = page.background
    local content = self.content
    local w, h = bufferSize(bb)
    return table.concat({ tostring(page), self.document:templateFor() or "",
        require("paperoptions").key(self.document.paper_options),
        background and background.file or "", background and background.page or "",
        content.x, content.y, content.w, content.h, w, h, bpp }, "|")
end

--- Repaints a region from the vector model.
-- With `defer_refresh`, the pixels are restored but nothing is sent to the
-- panel: the caller is about to refresh a region that covers this one anyway,
-- and two overlapping refreshes would flicker.
function CanvasRender:_repaintRegion(x, y, w, h, defer_refresh)
    if self.zoom > 1 then
        if not (self.hidden_stroke or self.shape_gesture or self.transform_gesture) then
            self:_repairZoomCacheRegion(x,y,w,h)
        end
        local sx,sy=self:_viewPoint(x,y)
        return self:_repaintScreenRegion(sx,sy,w*self.zoom,h*self.zoom,defer_refresh)
    end
    local drawable = contentBounds(Screen.bb, self.content)
    if not drawable then return end
    x, y, w, h = Rect.clamp(x, y, w, h, drawable)
    if not x then return end

    local clip = { x = x, y = y, w = w, h = h }
    local page = self.document:getPage()
    local background_bounds = self.background_cache_bounds
    local valid_background = self.background_cache
        and self.background_cache_key == backgroundKey(self, page, Screen.bb, bufferBPP(Screen.bb))
        and background_bounds
        and x >= background_bounds.x and y >= background_bounds.y
        and x + w <= background_bounds.x + background_bounds.w
        and y + h <= background_bounds.y + background_bounds.h
    if valid_background then
        Screen.bb:blitFrom(self.background_cache, x, y,
            x - background_bounds.x, y - background_bounds.y, w, h)
    else
        Screen.bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
        self:_drawTemplate(Screen.bb, clip)
    end
    -- Rejected first by bounding box, then per run of points inside the stroke:
    -- a line that merely crosses this region is not rasterised end to end.
    for _, stroke in ipairs(page.strokes) do
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
    local bpp = bufferBPP(bb)
    local bounds = contentBounds(bb, self.content)
    local cache_key = backgroundKey(self, page, bb, bpp)
    -- Two most recently rendered pages bound bitmap memory regardless of
    -- notebook length. Never cache temporary selection/preview pixels.
    local stable = not (self.hidden_stroke or self.stroke or self.transform_gesture
        or self.shape_gesture or self.text_preview or self.selected_strokes
        or self.document._batch)
    self.page_render_cache = self.page_render_cache or {}
    -- At most 12 MiB of page snapshots, also on RGB framebuffers.
    local snapshot_bytes = bounds and bounds.w * bounds.h * bpp / 8 or 0
    local cache_limit = snapshot_bytes > 0
        and math.min(2, math.floor(12 * 1024 * 1024 / snapshot_bytes)) or 0
    stable = stable and bounds ~= nil and cache_limit > 0
    local key = cache_key .. "|" .. tostring(page.revision or 0)
        .. "|" .. tostring(Screen.isColorEnabled and Screen:isColorEnabled())
        .. "|" .. self.dimen.w .. "|" .. self.dimen.h .. "|" .. bpp
        .. "|" .. x .. "|" .. y .. "|" .. self.content.x .. "|" .. self.content.y
        .. "|" .. self.content.w .. "|" .. self.content.h
        .. "|" .. (bounds and bounds.x or "") .. "|" .. (bounds and bounds.y or "")
        .. "|" .. (bounds and bounds.w or "") .. "|" .. (bounds and bounds.h or "")
    local cached, cached_index
    if stable then
        for i, entry in ipairs(self.page_render_cache) do
            if entry.key == key then
                cached, cached_index = entry, i
                break
            end
        end
    end
    -- A page snapshot already includes its paper. Still rebuild a changed
    -- background cache: partial eraser repaints restore pixels from it.
    if not cached or not self.background_cache or self.background_cache_key ~= cache_key
        or not sameBounds(self.background_cache_bounds, bounds) then
        if self.background_cache and self.background_cache_key == cache_key
            and sameBounds(self.background_cache_bounds, bounds) then
            bb:blitFrom(self.background_cache, bounds.x, bounds.y,
                0, 0, bounds.w, bounds.h)
        else
            bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
            self:_drawTemplate(bb)
            if self.background_cache then self.background_cache:free() end
            self.background_cache = copyBounds(bb, bounds)
            self.background_cache_key=cache_key
            self.background_cache_bounds = bounds
        end
    end
    if cached then
        bb:blitFrom(cached.bb, cached.bounds.x, cached.bounds.y,
            0, 0, cached.bounds.w, cached.bounds.h)
        table.remove(self.page_render_cache,cached_index)
        table.insert(self.page_render_cache,1,cached)
        return
    end
    for _,stroke in ipairs(self:_visiblePage().strokes) do
        if stroke ~= self.hidden_stroke then Renderer.drawStroke(bb,stroke,nil, Screen.isColorEnabled and Screen:isColorEnabled()) end
    end
    if stable then
        for i = #self.page_render_cache, 1, -1 do
            if self.page_render_cache[i].page == page then
                table.remove(self.page_render_cache,i).bb:free()
            end
        end
        while #self.page_render_cache >= cache_limit do
            table.remove(self.page_render_cache).bb:free()
        end
        table.insert(self.page_render_cache,1,{
            key=key, page=page, bb=copyBounds(bb, bounds), bounds=bounds,
        })
    end
    local preview=self.transform_gesture and self.transform_gesture.preview or self.stroke
    if preview then Renderer.drawStroke(bb,preview,nil,Screen.isColorEnabled and Screen:isColorEnabled()) end
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
    else Template.draw(bb, self.document:templateFor(), self.content, 1, clip, self.document.paper_options) end
end

return CanvasRender
