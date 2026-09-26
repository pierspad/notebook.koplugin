-- Explicit geometric tools and selection handles.
-- Installed on Canvas at load time; owns shape creation, preview and resize.
local Device = require("device")
local Rect = require("rect")
local Renderer = require("renderer")
local Shape = require("shape")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local ShapeCanvas = {}

function ShapeCanvas:_beginShape(x, y, original)
    UIManager:unschedule(self.reconcile_cb)
    self.shape_gesture = {x=x, y=y, original=original,
        kind=original and original.shape_kind or self.shape_kind or "rectangle"}
    self:_deselectLasso()
    if original then self:_repaintRegion(original:getBounds()) end
    -- One immutable raster snapshot per gesture replaces rerendering all the
    -- underlying vector ink on every preview frame (about 5 MB on a Scribe).
    self.shape_gesture.background = Screen.bb:copy()
    self.refresh_mode = "fast"
end

function ShapeCanvas:_extendShape(x, y)
    local gesture = self.shape_gesture
    gesture.next_x, gesture.next_y = x, y
    local spacing = Screen:scaleBySize(24)
    local px, py = gesture.paint_x or gesture.x, gesture.paint_y or gesture.y
    local dx, dy = x-px, y-py
    if dx*dx+dy*dy >= spacing*spacing then
        self:_paintShape()
    else
        -- Trailing debounce: a slow stream of one-pixel samples must not make
        -- us repaint a page-sized preview over and over. It still catches up
        -- shortly after the nib pauses, and release always paints the endpoint.
        UIManager:unschedule(self.shape_preview_cb)
        gesture.scheduled = true
        UIManager:scheduleIn(0.12, self.shape_preview_cb)
    end
end

function ShapeCanvas:_paintShape()
    local gesture = self.shape_gesture
    if not gesture or not gesture.next_x then return end
    gesture.last_paint = time.now()
    UIManager:unschedule(self.shape_preview_cb)
    gesture.scheduled = nil
    local x, y = gesture.next_x, gesture.next_y
    gesture.paint_x, gesture.paint_y = x, y
    gesture.next_x, gesture.next_y = nil, nil
    local original = gesture.original
    local x0, y0 = gesture.x, gesture.y
    if original then x0, y0 = original.x_min, original.y_min end
    local clean
    if original and original.text then
        clean=require("textobject").create(original.text,x0,y0,math.max(40,x-x0),
            original.font_size,{font_family=original.font_family,text_bold=original.text_bold,
                text_italic=original.text_italic,text_underline=original.text_underline})
    else
        clean = Shape.create(gesture.kind, x0, y0, x, y,
            original and original.width or self.pen_width,
            original and original.color or self.shape_color)
    end
    local old = self.stroke
    self.stroke = nil
    if old then
        local bx, by, bw, bh = old:getBounds()
        -- getBounds can reach beyond the drawing area at the initial point.
        bx, by, bw, bh = Rect.clamp(bx, by, bw, bh, self.content)
        if bx then
            Screen.bb:blitFrom(gesture.background, bx, by, bx, by, bw, bh)
            self:_accumulate(bx, by, bw, bh)
        end
    end
    self.stroke = clean
    if clean then
        Renderer.drawStroke(Screen.bb, clean, self.content, Screen.isColorEnabled and Screen:isColorEnabled())
        self:_accumulate(clean:getBounds())
    end
    self:_flush()
end

-- Preserve selected RGB ink and legacy white; pencil's softer gray remains
-- the default only while black is selected.
function ShapeCanvas:_penColor()
    if self.pen_color == 255 or self.pen_color > 0xFFFFFF then return self.pen_color end
    return self.pen_style == "pencil" and 96 or self.pen_color
end

function ShapeCanvas:_endShape()
    UIManager:unschedule(self.shape_preview_cb)
    self:_paintShape()
    local gesture, stroke = self.shape_gesture, self.stroke
    if gesture.background then gesture.background:free(); gesture.background = nil end
    self.shape_gesture, self.stroke = nil, nil
    self:_flush()
    if stroke and stroke.x_max-stroke.x_min >= 4 and stroke.y_max-stroke.y_min >= 4 then
        if gesture.original then
            self.document:replaceStroke(gesture.original, stroke)
            -- The preview background still contains the old shape. Clean the
            -- union once after a resize; repainting old and new separately did
            -- the same expensive vector pass twice.
            local dirty = Rect.grow(nil, gesture.original:getBounds())
            dirty = Rect.grow(dirty, stroke:getBounds())
            self:_repaintRegion(dirty.x, dirty.y, dirty.w, dirty.h)
        else
            self.document:addStroke(stroke)
            -- The final preview is already the exact stored shape. Repainting
            -- it from the document here made pen-up look frozen, especially
            -- for a large, thick figure.
        end
        if not self.stopping then
            self:_showLassoMenu({stroke})
            UIManager:unschedule(self.autosave_cb)
            UIManager:scheduleIn(2.5, self.autosave_cb)
        end
        if self.on_change then self:on_change() end
    else
        if stroke then self:_repaintRegion(stroke:getBounds()) end
        if gesture.original then self:_repaintRegion(gesture.original:getBounds()) end
    end
end

local function shapeHandles(shape)
    local l, t, r, b = shape.x_min, shape.y_min, shape.x_max, shape.y_max
    local mx, my = (l+r)/2, (t+b)/2
    local gap = Screen:scaleBySize(42)
    return {
        {"nw",l,t}, {"n",mx,t}, {"ne",r,t},
        {"w",l,my}, {"e",r,my},
        {"sw",l,b}, {"s",mx,b}, {"se",r,b},
        {"rotate",r+gap,my},
    }
end

function ShapeCanvas:_shapeHandleAt(shape, x, y)
    if not shape or not shape.shape_kind then return nil end
    local radius = Screen:scaleBySize(18)
    for _, handle in ipairs(shapeHandles(shape)) do
        if math.abs(x-handle[2]) <= radius and math.abs(y-handle[3]) <= radius then
            return handle[1]
        end
    end
end

function ShapeCanvas:_beginShapeTransform(shape, handle, x, y)
    self.transform_gesture = {original=shape, handle=handle, x=x, y=y}
    self:_deselectLasso()
    self:_repaintRegion(shape:getBounds())
    self.transform_gesture.background = Screen.bb:copy()
end

function ShapeCanvas:_extendShapeTransform(x, y)
    local gesture = self.transform_gesture
    if not gesture then return end
    gesture.next_x, gesture.next_y = x, y
    local px, py = gesture.paint_x or gesture.x, gesture.paint_y or gesture.y
    local spacing = Screen:scaleBySize(12)
    if (x-px)^2 + (y-py)^2 < spacing*spacing then return end
    gesture.paint_x, gesture.paint_y = x, y
    local next_shape = Shape.transform(gesture.original, gesture.handle, x, y, gesture.x, gesture.y)
    -- The snapshot was taken after removing the original figure. During a
    -- drag only the previous preview needs clearing; including the original
    -- bounding box makes every rotation repaint most of the page.
    local dirty = gesture.preview and Rect.grow(nil, gesture.preview:getBounds()) or nil
    dirty = Rect.grow(dirty, next_shape:getBounds())
    local rx, ry, rw, rh = Rect.clamp(dirty.x, dirty.y, dirty.w, dirty.h, self.content)
    if rx then
        Screen.bb:blitFrom(gesture.background, rx, ry, rx, ry, rw, rh)
        Renderer.drawStroke(Screen.bb, next_shape, self.content,
            Screen.isColorEnabled and Screen:isColorEnabled())
        self:_refreshNow(rx, ry, rw, rh, next_shape.color == 0 and "fast" or "ui")
    end
    gesture.preview = next_shape
end

function ShapeCanvas:_endShapeTransform()
    local gesture = self.transform_gesture
    if not gesture then return end
    self.transform_gesture = nil
    local moved = gesture.next_x and (gesture.next_x ~= gesture.x or gesture.next_y ~= gesture.y)
    local shape = moved and Shape.transform(gesture.original, gesture.handle,
        gesture.next_x, gesture.next_y, gesture.x, gesture.y) or gesture.original

    -- The background snapshot already contains every other stroke and the
    -- paper, with the selected figure removed. Finalizing only needs to clear
    -- the last preview and draw the final figure, just like first creation.
    local dirty = gesture.preview and Rect.grow(nil, gesture.preview:getBounds()) or nil
    dirty = Rect.grow(dirty, shape:getBounds())
    local rx, ry, rw, rh = Rect.clamp(dirty.x, dirty.y, dirty.w, dirty.h, self.content)
    if rx and gesture.background then
        Screen.bb:blitFrom(gesture.background, rx, ry, rx, ry, rw, rh)
        Renderer.drawStroke(Screen.bb, shape, self.content,
            Screen.isColorEnabled and Screen:isColorEnabled())
        self:_refreshNow(rx, ry, rw, rh, shape.color == 0 and "fast" or "ui")
    end
    if gesture.background then gesture.background:free() end
    if moved then
        self.document:replaceStroke(gesture.original, shape)
        if self.on_change then self:on_change() end
        UIManager:unschedule(self.autosave_cb)
        UIManager:scheduleIn(2.5, self.autosave_cb)
    end
    self:_showLassoMenu({shape})
end

function ShapeCanvas:shapeHandles(shape)
    return shapeHandles(shape)
end

return ShapeCanvas
