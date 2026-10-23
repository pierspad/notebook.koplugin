-- KOReader stylus event bridge. Owns the temporary Wacom slot and
-- keyboard/touch handlers; the canvas owns drawing and session lifecycle.
--
-- KOReader's input handlers and stylus callback are shared with KOReader
-- itself (input inhibition during suspend) and with any other plugin that
-- wraps them. Unwrapping is only possible while our closure is still the
-- outermost one; otherwise another wrapper holds it, and may later even put it
-- back. Every closure installed here therefore belongs to a *session*, and
-- once that session is stopped the closure is an inert pass-through to the
-- handler it captured: it never faults, never redirects slots and never
-- swallows a key (sleep cover and power events included).
local Device = require("device")
local Safe = require("safe")
local Input = Device.input
local StylusBridge = {}

local EV_ABS = 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local ABS_MT_SLOT, ABS_MT_LAST = 47, 61
local BTN_TOOL_PEN, BTN_TOOL_RUBBER = 320, 321
local BTN_TOUCH, BTN_STYLUS = 330, 331

-- Returns true when the event was consumed for the pen slot.
local function touchActive(self, session, this, ev)
    if ev.type ~= EV_ABS then return false end
    local code = ev.code
    -- Each device retains its own current slot across frames.
    -- Wacom ABS_X/Y must not redirect a later slotless MT frame.
    if ev.fd and code >= ABS_MT_SLOT and code <= ABS_MT_LAST then
        session.panel_fds[ev.fd] = true
    end
    if code == ABS_MT_SLOT then
        session.panel_slot = ev.value
    elseif code > ABS_MT_SLOT and code <= ABS_MT_LAST then
        this:setupSlotData(session.panel_slot)
    end
    if code ~= ABS_X and code ~= ABS_Y and code ~= ABS_PRESSURE then return false end
    -- The panel may report legacy axes as well as MT axes.
    -- Identify the digitizer by its tool proximity event's fd.
    if ev.fd and (session.panel_fds[ev.fd] or session.pen_fd and ev.fd ~= session.pen_fd) then
        return true
    end
    this:setupSlotData(this.pen_slot)
    this:setCurrentMtSlotChecked(code == ABS_X and "x" or code == ABS_Y and "y" or "pressure", ev.value)
    return true
end

local function keyActive(self, session, this, ev)
    local code = ev.code
    if code == BTN_STYLUS then -- including SDL input paths
        self.barrel_down = ev.value == 1
    elseif code == BTN_TOOL_PEN or code == BTN_TOOL_RUBBER then
        if ev.fd then session.pen_fd = ev.fd end
        self.physical_pen_tool = ev.value == 1
            and (code == BTN_TOOL_PEN and this.TOOL_TYPE_PEN or this.TOOL_TYPE_ERASER) or nil
    elseif code == BTN_TOUCH then
        if ev.fd and (not session.pen_fd or ev.fd ~= session.pen_fd) then return true end
        this:setupSlotData(this.pen_slot)
        this:setCurrentMtSlot("id", ev.value == 1 and this.pen_slot or -1)
        return true
    end
    -- Everything else, power keys and sleep cover first of all, is KOReader's.
    return false
end

-- A handler that is active only for its session. A fault in it ends the
-- session instead of propagating out of input polling, where it would take
-- KOReader down with it.
local function sessionHandler(self, session, orig, active)
    return function(this, ev)
        if session.active then
            local ok, consumed = pcall(active, self, session, this, ev)
            if not ok then
                session.active = false
                Safe.report("canvas:input-bridge", consumed)
            elseif consumed then
                return
            end
        end
        return orig(this, ev)
    end
end

-- Puts `orig` back wherever our handler is visible to KOReader: directly, or
-- parked by Input:inhibitInput while the device is suspending.
local function unhook(name, parked, handler, orig)
    if Input[parked] == handler then Input[parked] = orig end
    if Input[name] == handler then Input[name] = orig end
end

function StylusBridge.start(self)
    if self.stylus_callback then return end
    local session = {active = true, panel_fds = {}}
    self.bridge_session = session
    if Input and Input.pen_slot and Input.wacom_protocol then
        self.pressure_sensor = require("pressure").open()
        session.orig_pen_slot = Input.pen_slot
        -- Move pen_slot out of the capacitive multi-touch panel's slot range (0..9)
        Input.pen_slot = 15
        session.panel_slot = Input.main_finger_slot or 0

        -- On Notebook: ensure all single-touch Wacom digitizer events route strictly to pen_slot
        if Input.handleTouchEv then
            session.orig_touch = Input.handleTouchEv
            session.touch = sessionHandler(self, session, session.orig_touch, touchActive)
            Input.handleTouchEv = session.touch
        end
        if Input.handleKeyBoardEv then
            session.orig_key = Input.handleKeyBoardEv
            session.key = sessionHandler(self, session, session.orig_key, keyActive)
            Input.handleKeyBoardEv = session.key
        end
    end
    local previous = Input.stylus_callback
    session.previous_stylus_callback = previous
    local protected = Safe.wrap("canvas:stylus", function(_, slot)
        return self:onStylusEvent(slot)
    end)
    self.stylus_callback = function(input, slot)
        if session.active then return protected(input, slot) end
        -- Restored by someone else after we stopped: behave as what we replaced.
        if previous then
            local ok, claimed = pcall(previous, input, slot)
            return ok and claimed or false
        end
        return false
    end
    Input:registerStylusCallback(self.stylus_callback)
end

function StylusBridge.stop(self)
    if self.pressure_sensor then self.pressure_sensor:close(); self.pressure_sensor = nil end
    local session = self.bridge_session
    self.bridge_session = nil
    if session then session.active = false end

    if self.stylus_callback and Input and (Input.stylus_callback == self.stylus_callback
        or Safe.failed and Input.stylus_callback == nil) then
        local previous = session and session.previous_stylus_callback
        if previous then Input:registerStylusCallback(previous)
        elseif Input.unregisterStylusCallback then Input:unregisterStylusCallback()
        else Input:registerStylusCallback(nil) end
    end
    self.stylus_callback = nil
    if not session or not Input then return end
    if session.touch then unhook("handleTouchEv", "_abs_ev_handler", session.touch, session.orig_touch) end
    if session.key then unhook("handleKeyBoardEv", "_key_ev_handler", session.key, session.orig_key) end
    if session.orig_pen_slot then
        Input.pen_slot = session.orig_pen_slot
        Input.cur_slot = Input.main_finger_slot or 0
    end
end

return StylusBridge
