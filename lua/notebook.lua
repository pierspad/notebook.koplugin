--[[--
The notebook screen: a toolbar plus the drawing canvas.

Geometry is laid out explicitly rather than with layout groups. The canvas
paints straight into the framebuffer at absolute coordinates, so it needs to
know its rectangle in screen space up front -- and it must agree exactly with
where the toolbar is, or ink would end up underneath it.

@module notebook.notebook
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Canvas = require("canvas")
local Device = require("device")
local Geom = require("ui/geometry")
local PagePanel = require("pagepanel")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Tuning = require("tuning")
local TuningDock = require("tuningdock")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Safe = require("safe")

local Toolbar = require("notebooktoolbar")
local TOOLS = Toolbar.tools

local Screen = Device.screen

-- Height left clear at the top of the screen (0 to maximize space at the top).
local TOP_INSET = 0

-- Prefix every stored canvas setting is kept under. Declared here rather than
-- beside the settings below because `init` reads it, and a local is not in
-- scope above its own declaration.
local SETTING_PREFIX = "notebook_"

--[[--
The title that opens the tuning dock.

A notebook rather than a hidden gesture or a file on the device: it is made and
unmade from the gallery, with no SSH and nothing to remember, and a multi-tap
gesture on this digitizer is the kind of thing that fires by itself. The
notebook that carries the dock is also the notebook whose pages have the odd
geometry, which keeps both facts in one place.
--]]
local TUNING_TITLE = "_tuning_"

local Notebook = InputContainer:extend{
    document = nil,
    title = nil,
    disable_double_tap = false,
}

for name, method in pairs(Toolbar) do
    if type(method) == "function" then Notebook[name] = method end
end

function Notebook:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self._navbar_skip_inject = true

    self:_buildToolbar()

    local toolbar_h = self.toolbar:getSize().h + TOP_INSET

    -- The tuning dock takes a band off the bottom, by the same mechanism the
    -- toolbar takes one off the top: `content` is what the canvas will accept
    -- ink into, so shortening it is all there is to it.
    local dock_h = 0
    if self.title == TUNING_TITLE then
        Tuning.load()
        dock_h = math.floor(self.dimen.h * TuningDock.HEIGHT_RATIO)
    end

    self.canvas = Canvas:new{
        document = self.document,
        owner = self,
        content = Geom:new{
            x = 0,
            y = toolbar_h,
            w = self.dimen.w,
            h = self.dimen.h - toolbar_h - dock_h,
        },
        on_change = function() self:_onDocumentChanged() end,
        on_page_swipe = function(delta) self:_turnPage(delta) end,
        on_text = function(_, x, y) self:_insertText(x, y) end,
        on_edit_text = function(_, stroke) self:_editText(stroke) end,
    }
    self:_loadSettings()
    self.document.page_size={w=self.canvas.content.w,h=self.canvas.content.h}

    if dock_h > 0 then
        self.tuning_dock = TuningDock:new{
            width = self.dimen.w,
            height = dock_h,
            canvas = self.canvas,
            owner = self,
            tab = G_reader_settings:readSetting(SETTING_PREFIX .. "tuning_tab"),
            on_tab = function(id)
                G_reader_settings:saveSetting(SETTING_PREFIX .. "tuning_tab", id)
            end,
        }
    end

    -- Both children are listed so that events reach them: a container only
    -- dispatches to its numbered children, and painting them by hand in
    -- paintTo is not enough to make their buttons tappable.
    -- The toolbar comes first so it gets a chance at a tap before the canvas.
    self[1] = self.toolbar
    self[2] = self.canvas
    if self.tuning_dock then
        -- Listed so taps reach it, and first because it is in front of
        -- everything it overlaps. Where it lands is its own business -- see
        -- its paintTo -- because the container would otherwise paint it at the
        -- origin, on top of the toolbar.
        self.tuning_dock.paint_offset_y = self.dimen.h - self.tuning_dock.height
        table.insert(self, 1, self.tuning_dock)
    end
end

--- Opens the page overview.
function Notebook:_finishInteraction()
    if self.canvas.zoom > 1 then self.canvas:_endZoomContact() end
    self.canvas:_endStroke()
    self.canvas:_endErase()
    self.canvas.erasing = false
    self.canvas.last_erase_x, self.canvas.last_erase_y = nil, nil
    self.canvas:_deselectLasso()
end

function Notebook:_showPages()
    self:_finishInteraction()
    if self.canvas.zoom > 1 then
        self.canvas:setZoom(1)
        self.zoom_button:setIcon("notebook.zoom-in", self.zoom_button.width)
    end
    UIManager:show(PagePanel:new{
        document = self.document,
        on_goto = function(index)
            self.document:goToPage(index)
            self:_fullRepaint()
        end,
        -- A page added, removed or re-papered changes what is behind the panel,
        -- and the toolbar's counter with it.
        on_change = function()
            self:_updatePageText()
        end,
    }, "ui")
end

function Notebook:_selectTool(index)
    self:_finishInteraction()
    if self.canvas.zoom > 1 and TOOLS[index].tool ~= "pen"
        and TOOLS[index].tool ~= "highlighter" and TOOLS[index].tool ~= "eraser"
        and TOOLS[index].tool ~= "shape" then
        self.canvas:setZoom(1)
        self.zoom_button:setIcon("notebook.zoom-in", self.zoom_button.width)
    end
    self.canvas.tool = TOOLS[index].tool
    self.canvas:_debugEvent("select-tool", nil, nil, nil, self.canvas.tool)
    for i, btn in ipairs(self.tool_buttons) do
        btn:setSelected(i == index)
    end
    self:_refreshToolbar()
end

function Notebook:_toggleZoom()
    self:_finishInteraction()
    local scale = self.canvas.zoom == 1 and 2 or 1
    if scale > 1 and self.canvas.tool ~= "pen" and self.canvas.tool ~= "highlighter"
        and self.canvas.tool ~= "eraser" and self.canvas.tool ~= "shape" then
        self:_selectTool(1)
    end
    self.canvas:setZoom(scale)
    self.zoom_button:setIcon(scale == 1 and "notebook.zoom-in" or "notebook.zoom-out", self.zoom_button.width)
    self:_refreshToolbar()
end

function Notebook:_openToolOptions(index)
    -- A menu describes the tool that is active. Long/double-tapping another
    -- icon therefore selects that tool first, instead of leaving two mutually
    -- contradictory highlights on screen.
    self:_selectTool(index)
    self:_showToolOptions(index)
end

--[[--
Clears accumulated e-ink ghosting.

Writing leans on fast, non-flashing waveforms, and those leave faint traces of
what used to be on screen -- erased strokes in particular. A full refresh
flashes the panel and resets it. It is deliberately manual rather than automatic
on a timer: a flash in the middle of writing would be far more annoying than the
ghosting it removes.
--]]
function Notebook:_refreshScreen()
    UIManager:setDirty(self, "full")
end

function Notebook:_updatePageText()
    self.page_text:setText(string.format("%d/%d",
        self.document.current_page, self.document:pageCount()))
end

function Notebook:_refreshToolbar()
    self:_updatePageText()
    self.undo_state = self.document:canUndo()
    self.redo_state = self.document:canRedo()
    if self.canvas:_isDisplayPaused() then return end
    self.toolbar:paintTo(Screen.bb,self.toolbar.dimen.x,self.toolbar.dimen.y)
    UIManager:setDirty(nil,"ui",self.toolbar.dimen)
end

function Notebook:onClipboardChanged(message)
    self:_refreshToolbar()
    if message then
        local notice = InfoMessage:new{
            text = message, timeout = 2, show_icon = false,
            force_one_line = true, modal = false, dismissable = false,
            alignment = "center",
        }
        notice.movable.anchor = function()
            local size = notice.movable:getSize()
            return Geom:new{
                x = math.floor((Screen:getWidth() - size.w) / 2),
                y = Screen:getHeight() - Size.padding.large,
            }
        end
        UIManager:show(notice)
    end
end

--[[--
Called after every edit.

Refreshing the toolbar here unconditionally would put a repaint on the end of
every single stroke -- one per letter when writing -- and it lands just as the
pen is coming back down. Since the only thing that can actually change is
whether undo and redo are available, check that first and stay quiet when
nothing has.
--]]
function Notebook:_onDocumentChanged()
    local can_undo = self.document:canUndo()
    local can_redo = self.document:canRedo()
    if can_undo == self.undo_state and can_redo == self.redo_state then
        return
    end
    self:_refreshToolbar()
end

-- Actions --------------------------------------------------------------------------

function Notebook:_undo()
    self:_finishInteraction()
    self.canvas:_debugEvent("undo", nil, nil, nil, self.canvas.tool)
    local page, x, y, w, h = self.document:undo()
    if not page then return end
    self:_afterHistoryChange(page, x, y, w, h)
end

function Notebook:_redo()
    self:_finishInteraction()
    self.canvas:_debugEvent("redo", nil, nil, nil, self.canvas.tool)
    local page, x, y, w, h = self.document:redo()
    if not page then return end
    self:_afterHistoryChange(page, x, y, w, h)
end

function Notebook:_afterHistoryChange(page, x, y, w, h)
    if page ~= self.document.current_page then
        if self.canvas.zoom > 1 then
            self.canvas:setZoom(1)
            self.zoom_button:setIcon("notebook.zoom-in", self.zoom_button.width)
        end
        -- The change belongs to another page; go there and repaint everything.
        self.document:goToPage(page)
        self:_fullRepaint()
        return
    end
    if x then
        self.canvas:_repaintRegion(x, y, w, h)
    else
        -- No rectangle means the operation was not confined to one -- a page
        -- inserted or removed, or a whole-list change that did not record its
        -- bounds. Repaint everything rather than quietly repainting nothing,
        -- which is what used to happen and left the screen showing the state
        -- before the undo.
        self:_fullRepaint()
        return
    end
    self:_refreshToolbar()
end

function Notebook:_turnPage(delta)
    self:_finishInteraction()
    if self.canvas.zoom > 1 then
        self.canvas:setZoom(1)
        self.zoom_button:setIcon("notebook.zoom-in", self.zoom_button.width)
    end
    self.canvas:_debugEvent("turn-page", nil, nil, nil, delta)
    local target = self.document.current_page + delta
    if target < 1 then return end
    if target > self.document:pageCount() then
        -- Walking off the end adds a page, the way a paper notebook works.
        self.document:addPage()
    else
        self.document:goToPage(target)
    end
    self:_fullRepaint()
end

function Notebook:_fullRepaint()
    self:_updatePageText()
    UIManager:setDirty(self, "ui")
end

function Notebook:_close()
    self:_finishInteraction()
    local saved, err = self.document:save()
    if not saved then
        UIManager:show(InfoMessage:new{
            text = _("Could not save the notebook. It has been left open.")
                .. "\n\n" .. tostring(err or ""),
        })
        return
    end
    -- Closed with an explicit full refresh. The canvas painted straight into the
    -- framebuffer, bypassing UIManager's bookkeeping, so UIManager has no idea
    -- how much of the screen we actually dirtied; without this, ink can be left
    -- sitting on the panel over whatever is underneath.
    UIManager:close(self, "full")
end

-- Widget ---------------------------------------------------------------------------

-- An existing zoom contact belongs to the canvas through its release, even
-- over a toolbar button (which otherwise consumes hold_release first).
function Notebook:propagateEvent(event)
    if event.handler == "onGesture" and self.canvas and self.canvas.zoom > 1
        and self.canvas.zoom_touch_active and self.canvas:handleEvent(event) then
        return true
    end
    return InputContainer.propagateEvent(self, event)
end

function Notebook:paintTo(bb, x, y)
    -- Fill the top band with solid white so no status bar stripes or ghosting appear
    bb:paintRect(x, y, self.dimen.w, TOP_INSET, Blitbuffer.COLOR_WHITE)
    self.canvas:paintTo(bb, x, y)
    -- Toolbar last, so it sits above the ink, and below the band reserved for
    -- the system status bar.
    self.toolbar:paintTo(bb, x, y + TOP_INSET)
    self.toolbar.dimen.x = x
    self.toolbar.dimen.y = y + TOP_INSET
    -- Painted here as well as listed as a child: this widget paints its
    -- children by hand, in the order they have to be drawn, which is not the
    -- order they have to be offered taps in. Being in the list is what makes
    -- the dock tappable; being here is what makes it visible. Last, so the
    -- band sits over the ink it covers rather than under it.
    if self.tuning_dock then
        self.tuning_dock:paintTo(bb, x, y)
    end
    self.dimen.x, self.dimen.y = x, y
end

function Notebook:_scheduleClock()
    UIManager:unschedule(self.clock_tick)
    UIManager:scheduleIn(math.max(1, 60 - os.time() % 60), self.clock_tick)
end

function Notebook:onSuspend()
    if self.closed then return end
    self.suspended = true
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
    if self.resume_cb then UIManager:unschedule(self.resume_cb) end
    self.canvas:pause()
    if self.document.dirty then self.document:save() end
end

function Notebook:onResume()
    -- With a delayed/locked screensaver, Resume comes before cover dismissal.
    if self.closed or Device.screen_saver_mode or Device.screen_saver_lock then return end
    if not self.suspended then return end
    if self.resume_cb then UIManager:unschedule(self.resume_cb) end
    self.suspended = nil
    self.canvas:resume()
    self:_finishInteraction()
    -- The forthcoming full repaint includes the finished ink and any menu
    -- cleanup; do not flash again for pre-sleep reconciliation debt.
    UIManager:unschedule(self.canvas.reconcile_cb)
    self.canvas.reconcile, self.canvas.reconcile_color, self.canvas.reconcile_full = nil, nil, nil
    if self.document.dirty then
        UIManager:unschedule(self.canvas.autosave_cb)
        UIManager:scheduleIn(2.5, self.canvas.autosave_cb)
    end
    self.clock_text:setText(os.date("%H:%M"))
    if self.clock_tick then self:_scheduleClock() end
    UIManager:setDirty(self, "full")
end

function Notebook:onOutOfScreenSaver()
    if self.closed then return end
    -- KOReader clears its screensaver flags *after* broadcasting this event.
    self.resume_cb = self.resume_cb or Safe.wrap("notebook:resume", function() self:onResume() end)
    UIManager:unschedule(self.resume_cb)
    UIManager:scheduleIn(0.05, self.resume_cb)
end

function Notebook:onShow()
    self.canvas:start()
    self.clock_tick = self.clock_tick or Safe.wrap("notebook:clock", function()
        if self.closed or self.suspended or self.canvas:_isDisplayPaused() then return end
        -- Do not gate this on getTopmostVisibleWidget(): KOReader may report a
        -- canvas child or a transient overlay even while this screen is shown,
        -- which left the displayed time frozen at the opening minute.
        self.clock_text:setText(os.date("%H:%M"))
        self.toolbar:paintTo(Screen.bb,self.toolbar.dimen.x,self.toolbar.dimen.y)
        UIManager:setDirty(nil,"ui",self.toolbar.dimen)
        self:_scheduleClock()
    end)
    Safe.onShutdown("notebook:clock", function()
        UIManager:unschedule(self.clock_tick)
        if self.resume_cb then UIManager:unschedule(self.resume_cb) end
    end)
    UIManager:unschedule(self.clock_tick)
    self.clock_text:setText(os.date("%H:%M"))
    UIManager:setDirty(self, "ui", self.toolbar.dimen)
    self:_scheduleClock()
    return true
end

function Notebook:onCloseWidget()
    self.closed = true
    Safe.clearShutdown("notebook:clock")
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
    if self.resume_cb then UIManager:unschedule(self.resume_cb) end
    self.canvas:stop()
    if self.document.dirty then
        self.document:save()
    end
    if self.on_closed then self.on_closed() end
end

--- Physical back / close gestures.
function Notebook:onClose()
    self:_close()
    return true
end

--[[--
Protected, but without the watchdog -- and for the canvas's sake, not its own.

Every touch that reaches the canvas passes through this container first, so a
count hook here is a count hook around finger drawing, and hooks take LuaJIT off
its compiled traces. The toolbar taps would be safer for it; the ink would be
slower. The pcall, which is what keeps a fault out of the event loop, costs
nothing and stays.
--]]
require("notebooksettings")(Notebook, TOOLS, SETTING_PREFIX)

return Safe.widget(Notebook, "notebook", false)
