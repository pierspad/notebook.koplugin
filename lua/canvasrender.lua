-- Pixel rendering; dirty-region refresh scheduling lives in canvasrefresh.lua.
-- Owns full-page rendering and the shared region repaint path.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Template = require("template")

local Screen = Device.screen
local CanvasRender = {}

--- Repaints a region from the vector model.
-- With `defer_refresh`, the pixels are restored but nothing is sent to the
-- panel: the caller is about to refresh a region that covers this one anyway,
-- and two overlapping refreshes would flicker.
function CanvasRender:_repaintRegion(x, y, w, h, defer_refresh)
    if self.zoom > 1 then
        local sx,sy=self:_viewPoint(x,y)
        return self:_repaintScreenRegion(sx,sy,w*self.zoom,h*self.zoom,defer_refresh)
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
    for _,stroke in ipairs(self:_visiblePage().strokes) do
        if stroke ~= self.hidden_stroke then Renderer.drawStroke(bb,stroke,nil, Screen.isColorEnabled and Screen:isColorEnabled()) end
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
    else Template.draw(bb, self.document:templateFor(), self.content, 1, clip) end
end

return CanvasRender
