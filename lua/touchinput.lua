-- Finger gestures and palm rejection for the canvas.
local Device = require("device")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local TouchInput = {}

-- Touch input --------------------------------------------------------------------

--[[--
Drawing with a finger, which is also the only way to draw in the emulator --
SDL synthesises finger touches, never stylus events, so without this path none
of the drawing code could be exercised off-device.

These go through the ordinary gesture engine rather than the stylus callback,
so they arrive already coalesced into pan events. The tool is always whatever
is selected on screen: a finger has no barrel button to override it with.
--]]
function TouchInput:_touchPoint(ges)
    local pos = ges.pos
    if not pos then return nil end
    return pos.x, pos.y
end

--[[--
Whether a touch should be acted on at all.

Anything arriving while the pen is on the panel, or just after it left, is
almost certainly the side of a hand. Swallowing it (returning true from the
handler) rather than passing it on matters: left to the gesture engine it
becomes a swipe, and the page turns underneath the writing.
--]]
function TouchInput:_touchIsPalm()
    if self.pen_down then return true end
    if self.pen_left_at
        and time.to_ms(time.now() - self.pen_left_at) < Tuning.palm_grace_ms then
        return true
    end
    return false
end

--[[--
The drawing area belongs to the canvas, whether or not it draws.

Every touch inside it is answered here and goes no further. That is the whole of
palm rejection: a hand resting on the page is a contact like any other, and an
unanswered contact travels on to become a tap on whatever is underneath -- which
is how resting a palm pressed toolbar buttons and repainted pieces of the screen
under the ink.
--]]
function TouchInput:onTouchStart(_, ges)
    self:_debugEvent("touch-start", nil, ges and ges.pos and ges.pos.x,
        ges and ges.pos and ges.pos.y, self.tool)
    if self.zoom > 1 then
        if self:_touchIsPalm() then return true end
        self.zoom_touch_x, self.zoom_touch_y = self:_touchPoint(ges)
        self.zoom_touch_moved = false
        return true
    end
    if self:_touchIsPalm() then return true end

    local x, y = self:_touchPoint(ges)
    if not x then return true end

    self.touch_start_x = x
    self.touch_start_y = y
    self.touch_last_x = x
    self.touch_last_y = y

    -- A resting hand must not move or dismiss a pen selection.
    if self.selected_strokes and not self.draw_with_finger then return true end

    if self.selected_strokes and #self.selected_strokes == 1 then
        local shape = self.selected_strokes[1]
        local handle = self:_shapeHandleAt(shape, x, y)
        if handle then self:_beginShapeTransform(shape, handle, x, y); return true end
    end

    -- If lasso selection is active, finger touching inside selection initiates drag/move
    if self.tool == "lasso" and self.selected_strokes and self.selection_bbox then
        if self.lasso_menu and self.lasso_menu.dimen then
            local md = self.lasso_menu.dimen
            if x >= md.x and x <= md.x + md.w and y >= md.y and y <= md.y + md.h then
                return false
            end
        end

        local b = self.selection_bbox
        if x >= b.x - 30 and x <= b.x + b.w + 30 and y >= b.y - 30 and y <= b.y + b.h + 30 then
            self.dragging_selection = true
            self:_useOpaqueTextDuringDrag()
            self.drag_start_x, self.drag_start_y = x, y
            self.drag_last_x, self.drag_last_y = x, y
            if self.lasso_menu then
                UIManager:close(self.lasso_menu)
                self.lasso_menu = nil
            end
            return true
        else
            -- Tapped outside selection -> deselect
            self:_deselectLasso()
        end
    end

    if not self.draw_with_finger then
        return true
    end

    if not self:_withinContent(x, y, self:widthFor(self.tool)) then return true end

    if self.tool == "eraser" then
        self:_eraseAlong(x, y)
    else
        self:_beginStroke(self.tool, x, y, 1)
    end
    return true
end

function TouchInput:onTouchPan(_, ges)
    self:_debugEvent("touch-pan", nil, ges and ges.pos and ges.pos.x,
        ges and ges.pos and ges.pos.y, self.tool)
    if self.zoom > 1 then
        if self:_touchIsPalm() then return true end
        local x, y = self:_touchPoint(ges)
        if x and self.zoom_touch_x then
            self:_zoomPan(x - self.zoom_touch_x, y - self.zoom_touch_y)
            self.zoom_touch_moved = true
        end
        self.zoom_touch_x, self.zoom_touch_y = x, y
        return true
    end
    if self:_touchIsPalm() then return true end

    local x, y = self:_touchPoint(ges)
    if not x then return true end

    self.touch_last_x = x
    self.touch_last_y = y

    if self.transform_gesture then self:_extendShapeTransform(x, y); return true end

    if self.dragging_selection then
        self:_extendStroke(x, y, 1)
        return true
    end

    if not self.draw_with_finger then
        return true
    end

    if not self:_withinContent(x, y, self:widthFor(self.tool)) then
        if self.stroke or self.shape_gesture or self.text_at then self:_endStroke() end
        return true
    end

    if self.tool == "eraser" then
        self:_eraseAlong(x, y)
    elseif self.stroke or self.shape_gesture then
        self:_extendStroke(x, y, 1)
    else
        self:_beginStroke(self.tool, x, y, 1)
    end
    return true
end

function TouchInput:onTouchRelease(_, ges)
    self:_debugEvent("touch-release", nil, ges and ges.pos and ges.pos.x,
        ges and ges.pos and ges.pos.y, self.tool)
    if self.zoom > 1 then
        self:_flushZoomPan()
        self.zoom_touch_x, self.zoom_touch_y = nil, nil
        if self.zoom_pan_needs_settle then self:_scheduleZoomPanSettle() end
        return true
    end
    local start_x = self.touch_start_x
    local start_y = self.touch_start_y
    local end_x = self.touch_last_x or (ges and ges.pos and ges.pos.x)
    local end_y = self.touch_last_y or (ges and ges.pos and ges.pos.y)
    self.touch_start_x, self.touch_start_y = nil, nil
    self.touch_last_x, self.touch_last_y = nil, nil

    if self:_touchIsPalm() then return true end

    if self.transform_gesture then self:_endShapeTransform(); return true end

    if self.dragging_selection then
        self:_endStroke()
        return true
    end

    if self.draw_with_finger then
        self.last_erase_x, self.last_erase_y = nil, nil
        self:_endErase()
        if self.stroke or self.shape_gesture or self.text_at then self:_endStroke() end
        return true
    end

    if self.selected_strokes then return true end

    -- Slower horizontal pan drags also turn pages reliably
    if not self.pen_down and start_x and end_x and self.on_page_swipe then
        local dx = end_x - start_x
        local dy = (end_y and start_y) and math.abs(end_y - start_y) or 0
        local min_dist = Screen:scaleBySize(60)
        if math.abs(dx) >= min_dist and math.abs(dx) > 1.2 * dy then
            self.on_page_swipe(dx < 0 and 1 or -1)
            return true
        end
    end

    return true
end

--- Horizontal finger swipes turn the page, the way they do in the reader.
function TouchInput:onPageSwipe(_, ges)
    if self.zoom > 1 then
        if self:_touchIsPalm() then return true end
        local first, last = ges.pos, ges.end_pos
        if first and last and not self.zoom_touch_moved then
            self:_zoomPan(last.x-first.x, last.y-first.y)
        end
        self:_flushZoomPan()
        self.zoom_touch_x, self.zoom_touch_y = nil, nil
        if self.zoom_pan_needs_settle then self:_scheduleZoomPanSettle() end
        return true
    end
    if self.selected_strokes or self.dragging_selection then return true end
    if self:_touchIsPalm() then return true end
    -- A swipe while drawing with a finger is part of the drawing, not a gesture.
    if self.draw_with_finger and self.stroke then return true end
    if not self.on_page_swipe then return false end

    local dir = ges.direction
    if dir == "west" or dir == "northwest" or dir == "southwest" then
        self.on_page_swipe(1)
        return true
    elseif dir == "east" or dir == "northeast" or dir == "southeast" then
        self.on_page_swipe(-1)
        return true
    end

    if ges.pos and ges.end_pos then
        local dx = ges.end_pos.x - ges.pos.x
        local dy = math.abs(ges.end_pos.y - ges.pos.y)
        if math.abs(dx) >= Screen:scaleBySize(40) and math.abs(dx) > dy then
            self.on_page_swipe(dx < 0 and 1 or -1)
            return true
        end
    end

    return false
end

function TouchInput:onPageMultiSwipe(_, ges)
    return self:onPageSwipe(_, ges)
end

function TouchInput:onPageTwoFingerSwipe(_, ges)
    return self:onPageSwipe(_, ges)
end

return TouchInput
