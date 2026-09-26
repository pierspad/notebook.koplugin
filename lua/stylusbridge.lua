-- KOReader stylus event bridge. Owns the temporary Wacom slot and
-- keyboard/touch handlers; the canvas owns drawing and session lifecycle.
local Device = require("device")
local Safe = require("safe")
local Input = Device.input
local StylusBridge = {}

function StylusBridge.start(self)
    if Input and Input.pen_slot and Input.wacom_protocol then
        self.pressure_sensor = require("pressure").open()
        self.orig_pen_slot = Input.pen_slot
        -- Move pen_slot out of the capacitive multi-touch panel's slot range (0..9)
        Input.pen_slot = 15
        self.panel_slot = Input.main_finger_slot or 0

        -- On Notebook: ensure all single-touch Wacom digitizer events route strictly to pen_slot
        if not self.orig_handleTouchEv and Input.handleTouchEv then
            self.orig_handleTouchEv = Input.handleTouchEv
            Input.handleTouchEv = function(this, ev)
                if ev.type == 3 then -- EV_ABS
                    -- Each device retains its own current slot across frames.
                    -- Wacom ABS_X/Y must not redirect a later slotless MT frame.
                    if ev.code == 47 then -- ABS_MT_SLOT
                        self.panel_slot = ev.value
                    elseif ev.code >= 48 and ev.code <= 61 then -- ABS_MT_*
                        this:setupSlotData(self.panel_slot)
                    end
                    if ev.code == 0 then -- ABS_X
                        this:setupSlotData(this.pen_slot)
                        this:setCurrentMtSlotChecked("x", ev.value)
                        return
                    elseif ev.code == 1 then -- ABS_Y
                        this:setupSlotData(this.pen_slot)
                        this:setCurrentMtSlotChecked("y", ev.value)
                        return
                    elseif ev.code == 24 then -- ABS_PRESSURE
                        this:setupSlotData(this.pen_slot)
                        this:setCurrentMtSlotChecked("pressure", ev.value)
                        return
                    end
                end
                return self.orig_handleTouchEv(this, ev)
            end
        end

        if not self.orig_handleKeyBoardEv and Input.handleKeyBoardEv then
            self.orig_handleKeyBoardEv = Input.handleKeyBoardEv
            Input.handleKeyBoardEv = function(this, ev)
                if ev.code == 331 then -- BTN_STYLUS, including SDL input paths
                    self.barrel_down = ev.value == 1
                end
                if ev.code == 320 or ev.code == 321 then -- BTN_TOOL_PEN/RUBBER
                    self.physical_pen_tool = ev.value == 1
                        and (ev.code == 320 and this.TOOL_TYPE_PEN or this.TOOL_TYPE_ERASER) or nil
                end
                if ev.code == 330 then -- BTN_TOUCH
                    this:setupSlotData(this.pen_slot)
                    if ev.value == 1 then
                        this:setCurrentMtSlot("id", this.pen_slot)
                    else
                        this:setCurrentMtSlot("id", -1)
                    end
                    return
                end
                return self.orig_handleKeyBoardEv(this, ev)
            end
        end
    end
    self.previous_stylus_callback = Input.stylus_callback
    self.stylus_callback = Safe.wrap("canvas:stylus", function(_, slot)
        return self:onStylusEvent(slot)
    end)
    Input:registerStylusCallback(self.stylus_callback)
end

function StylusBridge.stop(self)
    if self.pressure_sensor then self.pressure_sensor:close(); self.pressure_sensor = nil end

    if self.stylus_callback and (Input.stylus_callback == self.stylus_callback
        or Safe.failed and Input.stylus_callback == nil) then
        Input:registerStylusCallback(self.previous_stylus_callback)
    end
    self.stylus_callback = nil
    self.previous_stylus_callback = nil
    if self.orig_handleTouchEv and Input then
        Input.handleTouchEv = self.orig_handleTouchEv
        self.orig_handleTouchEv = nil
    end
    if self.orig_handleKeyBoardEv and Input then
        Input.handleKeyBoardEv = self.orig_handleKeyBoardEv
        self.orig_handleKeyBoardEv = nil
    end
    if self.orig_pen_slot and Input then
        Input.pen_slot = self.orig_pen_slot
        Input.cur_slot = Input.main_finger_slot or 0
        self.orig_pen_slot = nil
    end
end

return StylusBridge
