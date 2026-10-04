-- Converts KOReader stylus slots to canvas drawing gestures.
local Device = require("device")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Screen = Device.screen
local Input = Device.input

-- Stylus callbacks receive coordinates before GestureDetector applies the
-- screen's touch rotation. Finger gestures have already passed through it.
local function stylusScreenPoint(x, y)
    if not x or not y then return x, y end
    local mode = Screen.getTouchRotation and Screen:getTouchRotation()
    if mode == nil then return x, y end
    if mode == Screen.DEVICE_ROTATED_CLOCKWISE then
        return Screen:getWidth() - y, x
    elseif mode == Screen.DEVICE_ROTATED_UPSIDE_DOWN then
        return Screen:getWidth() - x, Screen:getHeight() - y
    elseif mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
        return y, Screen:getHeight() - x
    end
    return x, y
end

local StylusInput = {}

-- Stylus input -----------------------------------------------------------------

--[[--
Receives fully processed stylus slots, ahead of gesture detection.

Returning true "dominates" the event, keeping it out of the gesture engine --
otherwise every stroke would also register as a swipe or a tap and start
turning pages underneath the drawing.
--]]
function StylusInput:onStylusEvent(slot)
    if self:_isDisplayPaused() then return false end
    local raw_slot = slot
    self.sample_time=slot.timev
    -- Match the same transform KOReader applies to touch gestures. Make a
    -- private copy: the input subsystem may pass this slot on to gestures.
    if slot.x and slot.y then
        local x, y = stylusScreenPoint(slot.x, slot.y)
        if x ~= slot.x or y ~= slot.y then
            local mapped = {}
            for key, value in pairs(slot) do mapped[key] = value end
            mapped.x, mapped.y = x, y
            slot = mapped
        end
    end
    self:_debugEvent("stylus", raw_slot, slot.x, slot.y, slot.tool)
    -- Only draw when the notebook is the frontmost thing on screen.
    --
    -- This callback runs ahead of gesture detection and claims the event, so
    -- without this check the pen keeps drawing on the canvas underneath an open
    -- dialog -- and, worse, the dialog's own buttons never see the tap, so they
    -- cannot be pressed with the pen and tapping outside does not dismiss them.
    local top_widget = UIManager:getTopmostVisibleWidget()
    if self.owner and top_widget ~= self.owner and top_widget ~= self.lasso_menu then
        -- A tool popover is modal, but a stroke deliberately started on the
        -- visible page should dismiss it and keep this very first sample.
        -- Waiting for the later tap-to-close gesture loses the entire stroke.
        if not (top_widget and top_widget.dismissForDrawing
            and top_widget:dismissForDrawing(slot)) then
            if self.stroke or self.shape_gesture then self:_endStroke() end
            if self.zoom_erasing then self:_endZoomContact()
            elseif self.erasing then self:_endErase();self.erasing=false end
            return false
        end
    end

    -- Explicit finger tools are always rejected from the stylus callback
    local pen_release = slot.id == -1 and Input.pen_slot and slot.slot == Input.pen_slot
    if slot.tool == Input.TOOL_TYPE_FINGER and not pen_release then
        return false
    end

    -- Touchscreen panel slots (0..9) with no explicit stylus tool are palm contacts
    local from_panel = slot.slot and slot.slot < 10
    local is_pen = slot.tool == Input.TOOL_TYPE_PEN
        or slot.tool == Input.TOOL_TYPE_ERASER
        or slot.tool == Input.TOOL_TYPE_HIGHLIGHTER
    if from_panel and not is_pen and not pen_release then
        return false
    end

    local is_stylus = (Input.pen_slot and slot.slot == Input.pen_slot)
        or slot.tool == Input.TOOL_TYPE_PEN
        or slot.tool == Input.TOOL_TYPE_ERASER
        or slot.tool == Input.TOOL_TYPE_HIGHLIGHTER
        or pen_release

    if not is_stylus then
        return false
    end

    -- Proximity/tool frames have coordinates but no tracking contact yet.
    -- They must never stamp the initial pen dot (also applies at 2x zoom).
    if slot.id == nil and not self.pen_down then return true end

    -- KOReader may overwrite a persistent slot.tool with the barrel tool.
    -- Remember the physical Wacom end separately so releasing the button does
    -- not leave the pen stuck in that override until it exits proximity.
    local slot_tool = self.physical_pen_tool or slot.tool
    if self.physical_pen_tool == Input.TOOL_TYPE_PEN then
        if Input.stylus_eraser_active then slot_tool = Input.TOOL_TYPE_ERASER
        elseif Input.stylus_highlighter_active then slot_tool = Input.TOOL_TYPE_HIGHLIGHTER end
    end
    local tool = self:resolveTool(slot_tool)
    self:_debugEvent("resolved-tool", raw_slot, slot.x, slot.y, tool)
    if self.zoom > 1 then return self:_zoomStylus(slot, tool) end

    -- If tapping directly on the lasso menu buttons with the stylus, pass through to the menu
    if not self.transform_gesture and self.lasso_menu and self.lasso_menu.dimen and slot.x and slot.y then
        local md = self.lasso_menu.dimen
        if slot.x >= md.x and slot.x <= md.x + md.w and slot.y >= md.y and slot.y <= md.y + md.h then
            return false
        end
    end

    -- id == -1 marks the contact being released.
    if slot.id == -1 then
        -- Only claim the release if we were actually drawing. A lift-off that
        -- ends a tap on the toolbar has to reach the gesture engine, or the
        -- button never completes its tap.
        local was_drawing = self.stroke ~= nil or self.erasing or self.dragging_selection
            or self.shape_gesture ~= nil or self.transform_gesture ~= nil
            or self.text_at ~= nil or self.dismiss_contact
        self.dismiss_contact = nil
        self.pen_down = false
        self.pen_left_at = time.now()
        -- Forget where the eraser was, so the next sweep does not rub out the
        -- whole path back to wherever it was last lifted, and close the sweep's
        -- undo group.
        self.last_erase_x, self.last_erase_y = nil, nil
        self:_endErase()
        self.erasing = false
        self:_endStroke()
        return was_drawing
    end

    local new_contact = not self.pen_down
    self.pen_down = true
    self.pen_left_at = nil

    local x, y = slot.x, slot.y
    if not x or not y then return true end

    -- Anything outside the drawable area is not ours. Critically, it must NOT be
    -- dominated: returning true here would swallow the event before gesture
    -- detection ever sees it, and every toolbar button would stop responding to
    -- the pen while still working under a finger.
    --
    -- Ending the stroke as well means dragging off the canvas lifts the pen,
    -- rather than leaving a segment that jumps the gap when you come back.
    if not self:_withinContent(x, y, self:widthFor(tool)) then
        if self.stroke or self.dragging_selection or self.shape_gesture then self:_endStroke() end
        if self.erasing then self:_endErase();self.erasing=false end
        return false
    end

    local pressure=slot.pressure
    if pressure == nil and tool == "pen" and self.pen_style ~= "fineliner" and self.pressure_sensor then
        pressure=self.pressure_sensor:read()
    end
    local p=require("penpressure").sample(tool == "pen" and self.pen_style or nil,
        self.stroke,x,y,pressure,self.last_point_at and time.to_ms(time.now()-self.last_point_at))

    if self.dismiss_contact then return true end
    if new_contact and self.selected_strokes then
        local selected = self.selected_strokes
        local shape = #selected == 1 and selected[1]
        local handle = self:_shapeHandleAt(shape, x, y)
        if handle then
            self:_beginShapeTransform(shape, handle, x, y)
            return true
        end
        if shape and (shape.shape_kind == "rectangle" or shape.shape_kind == "square"
            or shape.shape_kind == "circle" or shape.shape_kind == "triangle" or shape.text) and math.abs(x-shape.x_max) <= Screen:scaleBySize(24)
            and math.abs(y-shape.y_max) <= Screen:scaleBySize(24) then
            self:_beginShape(x, y, shape)
            return true
        end
        if shape and (shape.text or shape.image_data) and self.selection_bbox then
            local b=self.selection_bbox
            if x>=b.x-25 and x<=b.x+b.w+25 and y>=b.y-25 and y<=b.y+b.h+25 then
                self.dragging_selection=true
                self:_useOpaqueTextDuringDrag()
                self.drag_start_x,self.drag_start_y=x,y
                self.drag_last_x,self.drag_last_y=x,y
                if self.lasso_menu then UIManager:close(self.lasso_menu); self.lasso_menu=nil end
                return true
            end
        end
        if self.erased_shape_selection then
            self.erased_shape_selection = nil
            self:_deselectLasso()
            self.dismiss_contact = true
            return true
        end
    end
    if self.transform_gesture then self:_extendShapeTransform(x, y); return true end
    if self.shape_gesture then self:_extendShape(x, y); return true end

    if tool == "eraser" then
        if self.stroke or self.dragging_selection or self.shape_gesture then self:_endStroke() end
        self.erasing = true
        self:_eraseAlong(x, y)
        return true
    end

    if self.erasing then
        self:_endErase()
        self.erasing = false
        self.last_erase_x, self.last_erase_y = nil, nil
    end

    if self.dragging_selection then
        self:_extendStroke(x, y, p)
    elseif not self.stroke then
        self:_beginStroke(tool, x, y, p)
    else
        -- The tool can change mid-contact (barrel button pressed while writing).
        -- Finish the current stroke and start a new one so each stroke stays
        -- homogeneous, which is what the undo and erase models assume.
        if self.stroke.tool ~= tool then
            self:_endStroke()
            self:_beginStroke(tool, x, y, p)
        else
            self:_extendStroke(x, y, p)
        end
    end
    return true
end

return StylusInput
