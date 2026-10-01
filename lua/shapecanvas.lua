-- Explicit geometric tools and selection handles.
-- Installed on Canvas at load time; owns shape creation, preview and resize.
local Device = require("device")
local Rect = require("rect")
local Shape = require("shape")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local ShapeCanvas = {}

-- Binary contour feedback is legible under the fast waveform and avoids
-- rasterizing a large fill on every movement. The stored shape stays intact.
function ShapeCanvas:_drawShapePreview(shape)
    local preview=setmetatable({color=0,filled=false,tool="pen",pen_style="fineliner"}, {__index=shape})
    self:_drawViewStroke(preview)
end

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
    if not gesture or (x==(gesture.next_x or gesture.paint_x)
        and y==(gesture.next_y or gesture.paint_y)) then return end
    gesture.next_x, gesture.next_y = x, y
    local interval=0.05
    local elapsed=gesture.last_paint and time.to_ms(time.now()-gesture.last_paint)/1000 or interval
    if elapsed>=interval then
        self:_paintShape()
    elseif not gesture.scheduled then
        gesture.scheduled=true
        UIManager:scheduleIn(interval-elapsed,self.shape_preview_cb)
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
            original and original.color or self.shape_color,
            original ~= nil and original.filled == true or (original == nil and self.shape_fill == true))
    end
    if clean and original and not original.text then
        clean.tool,clean.pen_style,clean.tint=original.tool,original.pen_style,original.tint
    end
    local old = self.stroke
    self.stroke = nil
    if old then
        local bx, by, bw, bh = self:_viewBounds(old)
        -- getBounds can reach beyond the drawing area at the initial point.
        bx, by, bw, bh = Rect.clamp(bx, by, bw, bh, self.content)
        if bx then
            Screen.bb:blitFrom(gesture.background, bx, by, bx, by, bw, bh)
            self:_accumulate(bx, by, bw, bh)
        end
    end
    self.stroke = clean
    if clean then
        self:_drawShapePreview(clean)
        self:_accumulate(self:_viewBounds(clean))
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
    if stroke and gesture.background then
        local x,y,w,h=self:_viewBounds(stroke)
        x,y,w,h=Rect.clamp(x,y,w,h,self.content)
        if x then
            Screen.bb:blitFrom(gesture.background,x,y,x,y,w,h)
            self:_drawViewStroke(stroke)
            self:_accumulate(x,y,w,h)
        end
    end
    if gesture.background then gesture.background:free(); gesture.background = nil end
    self.shape_gesture, self.stroke = nil, nil
    self.refresh_mode = stroke and (stroke.tool == "highlighter"
        or stroke.pen_style == "pencil" or stroke.color ~= 0) and "ui" or "fast"
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
            -- The final pixels already contain the exact stored shape. Repainting
            -- it from the document here made pen-up look frozen, especially
            -- for a large, thick figure.
        end
        if self.zoom>1 then self:_clearZoomCache() end
        self:_scheduleCleanScreen()
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

local function shapeHandles(shape,scale)
    local l, t, r, b = shape.x_min, shape.y_min, shape.x_max, shape.y_max
    local mx, my = (l+r)/2, (t+b)/2
    local gap = Screen:scaleBySize(42)/(scale or 1)
    return {
        {"nw",l,t}, {"n",mx,t}, {"ne",r,t},
        {"w",l,my}, {"e",r,my},
        {"sw",l,b}, {"s",mx,b}, {"se",r,b},
        {"rotate",r+gap,my},
    }
end

function ShapeCanvas:_shapeHandleAt(shape, x, y)
    if not shape or not shape.shape_kind then return nil end
    local radius = Screen:scaleBySize(18)/self.zoom
    for _, handle in ipairs(shapeHandles(shape,self.zoom)) do
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
    if not gesture or (x==(gesture.next_x or gesture.paint_x)
        and y==(gesture.next_y or gesture.paint_y)) then return end
    gesture.next_x, gesture.next_y = x, y
    local interval = 0.05
    local elapsed = gesture.last_paint and time.to_ms(time.now()-gesture.last_paint)/1000 or interval
    if elapsed >= interval then
        self:_paintShapeTransform()
    elseif not gesture.scheduled then
        gesture.scheduled=true
        UIManager:scheduleIn(interval-elapsed,self.transform_preview_cb)
    end
end

function ShapeCanvas:_paintShapeTransform()
    local gesture=self.transform_gesture
    if not gesture or not gesture.next_x then return end
    UIManager:unschedule(self.transform_preview_cb)
    gesture.scheduled=nil
    gesture.last_paint=time.now()
    local x,y=gesture.next_x,gesture.next_y
    if x==gesture.paint_x and y==gesture.paint_y then return end
    gesture.paint_x,gesture.paint_y=x,y
    local next_shape = Shape.transform(gesture.original, gesture.handle, x, y, gesture.x, gesture.y)
    -- The snapshot was taken after removing the original figure. During a
    -- drag only the previous preview needs clearing; including the original
    -- bounding box makes every rotation repaint most of the page.
    local dirty = gesture.preview and Rect.grow(nil, self:_viewBounds(gesture.preview)) or nil
    dirty = Rect.grow(dirty, self:_viewBounds(next_shape))
    local rx, ry, rw, rh = Rect.clamp(dirty.x, dirty.y, dirty.w, dirty.h, self.content)
    if rx then
        Screen.bb:blitFrom(gesture.background, rx, ry, rx, ry, rw, rh)
        self:_drawShapePreview(next_shape)
        self:_refreshNow(rx, ry, rw, rh, "fast")
    end
    gesture.preview = next_shape
end

function ShapeCanvas:_endShapeTransform()
    UIManager:unschedule(self.transform_preview_cb)
    local gesture = self.transform_gesture
    if not gesture then return end
    self.transform_gesture = nil
    local moved = gesture.next_x and (gesture.next_x ~= gesture.x or gesture.next_y ~= gesture.y)
    local shape = moved and Shape.transform(gesture.original, gesture.handle,
        gesture.next_x, gesture.next_y, gesture.x, gesture.y) or gesture.original

    -- The background snapshot already contains every other stroke and the
    -- paper, with the selected figure removed. Finalizing only needs to clear
    -- the last preview and draw the final figure, just like first creation.
    local dirty = gesture.preview and Rect.grow(nil, self:_viewBounds(gesture.preview)) or nil
    dirty = Rect.grow(dirty, self:_viewBounds(shape))
    local rx, ry, rw, rh = Rect.clamp(dirty.x, dirty.y, dirty.w, dirty.h, self.content)
    if rx and gesture.background then
        Screen.bb:blitFrom(gesture.background, rx, ry, rx, ry, rw, rh)
        self:_drawViewStroke(shape)
        self:_refreshNow(rx, ry, rw, rh, shape.color == 0 and shape.tool ~= "highlighter"
            and shape.pen_style ~= "pencil" and "fast" or "ui")
    end
    if gesture.background then gesture.background:free() end
    if moved then
        self.document:replaceStroke(gesture.original, shape)
        if self.on_change then self:on_change() end
        UIManager:unschedule(self.autosave_cb)
        UIManager:scheduleIn(2.5, self.autosave_cb)
    end
    if self.zoom>1 and moved then
        self:_clearZoomCache()
    end
    self:_scheduleCleanScreen()
    if not self.stopping then self:_showLassoMenu({shape}) end
end

function ShapeCanvas:shapeHandles(shape)
    return shapeHandles(shape,self.zoom)
end

return ShapeCanvas
