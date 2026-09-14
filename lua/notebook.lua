--[[--
The notebook screen: a toolbar plus the drawing canvas.

Geometry is laid out explicitly rather than with layout groups. The canvas
paints straight into the framebuffer at absolute coordinates, so it needs to
know its rectangle in screen space up front -- and it must agree exactly with
where the toolbar is, or ink would end up underneath it.

@module notebook.notebook
--]]--

local ActionMenu = require("actionmenu")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Canvas = require("canvas")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local PagePanel = require("pagepanel")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local SettingsDialog = require("settings")
local Tuning = require("tuning")
local TuningDock = require("tuningdock")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Safe = require("safe")

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
}

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
    }
    self:_loadSettings()

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

-- Toolbar ------------------------------------------------------------------------

-- The tools, in the order they appear in the selector.
local TOOLS = {
    { tool = "pen",         icon = "notebook.pen" },
    { tool = "highlighter", icon = "notebook.marker" },
    { tool = "eraser",      icon = "notebook.eraser" },
    { tool = "lasso",       icon = "notebook.lasso" },
}

--[[--
A tappable icon that can show itself as selected.

KOReader's Button draws either an icon or text, but has no notion of being
"on", and ToggleSwitch shows the selected item properly but only handles text.
This is the small piece in between: an icon that inverts to white-on-black when
chosen, which is the one styling that stays legible on e-ink at a glance.
--]]
local ToolButton = InputContainer:extend{
    icon = nil,
    size = nil,
    selected = false,
    callback = nil,
}

function ToolButton:init()
    -- Both states are built once and swapped, rather than rebuilt on selection.
    -- An IconWidget renders and caches its bitmap when first painted, so
    -- flipping `invert` on an existing one changes nothing on screen -- which is
    -- exactly how a stale highlight ends up stuck on the previous tool.
    local function icon(invert)
        return IconWidget:new{
            icon = self.icon,
            width = self.icon_size,
            height = self.icon_size,
            -- The icons are black on transparent, so inverting gives a white
            -- glyph to sit on the selected block.
            invert = invert,
        }
    end
    self.icon_normal = icon(false)
    self.icon_inverted = icon(true)

    self.holder = CenterContainer:new{
        dimen = Geom:new{ w = self.size, h = self.icon_size },
        self.selected and self.icon_inverted or self.icon_normal,
    }
    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.button,
        self.holder,
    }
    self[1] = self.frame

    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function ToolButton:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

function ToolButton:setSelected(selected)
    if self.selected == selected then return false end
    self.selected = selected
    self.holder[1] = selected and self.icon_inverted or self.icon_normal
    self.frame.background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    return true
end

function ToolButton:onTap()
    if self.callback then self.callback() end
    return true
end

function Notebook:_actionButton(opts)
    return Button:new{
        text = opts.text,
        icon = opts.icon,
        icon_width = opts.icon_size,
        icon_height = opts.icon_size,
        width = opts.width,
        enabled_func = opts.enabled_func,
        callback = opts.callback,
        bordersize = Size.border.thin,
        margin = 0,
        -- Rounded to match the tool selector, so the row reads as one control
        -- strip rather than a mix of styles.
        radius = Size.radius.button,
        padding = Size.padding.button,
    }
end

--[[--
Builds the toolbar.

Widths are worked out from the screen width and the pieces are sized to fit,
rather than laid out and hoped for. A horizontal group that overflows does not
wrap or complain -- it just runs off the edge, taking the last controls with it,
and they become untappable without any visible sign of why.
--]]
--[[--
Wraps the page counter in something tappable.

Sized for a count in the hundreds rather than for the text it holds right now.
A tap target computed from "3 / 4" would be a different shape once the notebook
reached "12 / 140", and its gesture range is worked out once, when the toolbar
is built -- so a target that grew with the text would drift away from where it
is actually being drawn.
--]]
function Notebook:_buildPageButton()
    local sizer = TextWidget:new{
        text = "  888 / 888  ",
        face = Font:getFace("cfont", 18),
    }
    local size = sizer:getSize()
    sizer:free()

    local btn = InputContainer:extend{}:new{}
    btn.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.button,
        CenterContainer:new{
            dimen = Geom:new{ w = size.w, h = size.h },
            self.page_text,
        },
    }
    btn[1] = btn.frame
    btn.dimen = btn.frame:getSize()
    btn.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = btn.dimen } },
    }
    local notebook = self
    btn.onTap = function()
        notebook:_showPages()
        return true
    end
    return btn
end

--- Opens the page overview.
function Notebook:_finishInteraction()
    self.canvas:_endStroke()
    self.canvas:_endErase()
    self.canvas.erasing = false
    self.canvas.last_erase_x, self.canvas.last_erase_y = nil, nil
    self.canvas:_deselectLasso()
end

function Notebook:_showPages()
    self:_finishInteraction()
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

function Notebook:_buildToolbar()
    local gap = Size.padding.large
    local n_gaps = 4

    -- The page counter is text, so its width is whatever the font makes it.
    -- Build it first and measure, rather than guessing and overflowing.
    self.page_text = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 18),
    }
    self:_updatePageText()
    self.page_button = self:_buildPageButton()
    local page_text_w = self.page_button:getSize().w

    self.clock_text = TextWidget:new{text=os.date("%H:%M"), face=Font:getFace("cfont", 18)}
    local clock_w = self.clock_text:getSize().w + gap
    -- Back + four tools + undo/redo/refresh + previous/next + settings.
    local n_cells = 11
    local cell_overhead = 2 * (Size.border.thin + Size.padding.button)
    local avail = self.dimen.w - 2 * Size.padding.small
    local flexible = avail - n_gaps * gap - page_text_w - clock_w - n_cells * cell_overhead
    local unit = math.floor(flexible / n_cells)
    local icon_size = math.floor(unit * 0.55)

    -- The tools sit in a row of icon cells; the active one is drawn as a solid
    -- black block with the glyph reversed out of it, which is unmistakable at a
    -- glance on e-ink where subtler cues simply vanish.
    self.tool_buttons = {}
    local tool_group = HorizontalGroup:new{ align = "center" }
    for i, spec in ipairs(TOOLS) do
        local btn = ToolButton:new{
            icon = spec.icon,
            size = unit,
            icon_size = icon_size,
            selected = i == 1,
            callback = function() self:_selectTool(i) end,
            hold_callback = spec.tool == "pen" and function() self:_showPenOptions() end or nil,
        }
        self.tool_buttons[i] = btn
        table.insert(tool_group, btn)
    end
    self.tool_group = tool_group

    self.undo_button = self:_actionButton{
        icon = "notebook.undo", icon_size = icon_size, width = unit,
        callback = function() self:_undo() end,
        enabled_func = function() return self.document:canUndo() end,
    }
    self.redo_button = self:_actionButton{
        icon = "notebook.redo", icon_size = icon_size, width = unit,
        callback = function() self:_redo() end,
        enabled_func = function() return self.document:canRedo() end,
    }

    self.prev_page_button = self:_actionButton{
        icon = "chevron.left", icon_size = icon_size, width = unit,
        callback = function() self:_turnPage(-1) end,
        enabled_func = function() return self.document.current_page > 1 end,
    }
    self.next_page_button = self:_actionButton{
        icon = "chevron.right", icon_size = icon_size, width = unit,
        callback = function() self:_turnPage(1) end,
    }

    self.toolbar_content = HorizontalGroup:new{
        align = "center",
        -- Leaving is a "back" arrow on the left, where every other back control
        -- lives, rather than a Close button at the far right.
        self:_actionButton{
            icon = "chevron.first", icon_size = icon_size, width = unit,
            callback = function() self:_close() end,
        },
        HorizontalSpan:new{ width = gap },
        tool_group,
        HorizontalSpan:new{ width = gap },
        self.undo_button,
        self.redo_button,
        -- Clears accumulated e-ink ghosting on demand.
        self:_actionButton{
            icon = "notebook.refresh", icon_size = icon_size, width = unit,
            callback = function() self:_refreshScreen() end,
        },
        HorizontalSpan:new{ width = gap },
        self.prev_page_button,
        self.page_button,
        self.next_page_button,
        CenterContainer:new{
            dimen=Geom:new{w=clock_w, h=self.next_page_button:getSize().h},
            self.clock_text,
        },
        HorizontalSpan:new{ width = gap },
        self:_actionButton{
            icon = "appbar.settings", icon_size = icon_size, width = unit,
            callback = function() self:_showSettings() end,
        },
    }

    local remaining = math.max(0, avail - self.toolbar_content:getSize().w)
    table.insert(self.toolbar_content, 12, HorizontalSpan:new{width=remaining})
    self.toolbar_content:resetLayout()

    self.toolbar = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = Size.padding.small,
        width = self.dimen.w,
        self.toolbar_content,
    }
    local toolbar_sz = self.toolbar:getSize()
    self.toolbar.dimen = Geom:new{ x = 0, y = TOP_INSET, w = toolbar_sz.w, h = toolbar_sz.h }
    self:_updatePageText()
end

function Notebook:_selectTool(index)
    self:_finishInteraction()
    self.canvas.tool = TOOLS[index].tool
    for i, btn in ipairs(self.tool_buttons) do
        btn:setSelected(i == index)
    end
    self:_refreshToolbar()
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

-- Settings ---------------------------------------------------------------------

--- Persists a canvas setting and applies it immediately.
function Notebook:_setSetting(key, value)
    self.canvas[key] = value
    G_reader_settings:saveSetting(SETTING_PREFIX .. key, value)
end

function Notebook:_showPenOptions()
    self:_finishInteraction()
    local actions = {}
    for _, option in ipairs({
        { "pen_style", "fineliner", _("Fineliner"), "notebook.fineliner", _("Pen type") },
        { "pen_style", "fountain", _("Fountain pen"), "notebook.fountain" },
        { "pen_style", "pencil", _("Pencil"), "notebook.pencil" },
        { "line_style", "line", _("Hold to straighten: line"), "notebook.line", _("Hold effect") },
        { "line_style", "arrow", _("Hold to straighten: arrow"), "notebook.arrow" },
    }) do
        local key, value, label = option[1], option[2], option[3]
        table.insert(actions, {
            icon = option[4],
            section = option[5],
            text = (self.canvas[key] == value and "✓ " or "") .. label,
            callback = function()
                self:_setSetting(key, value)
                self:_selectTool(1)
            end,
        })
    end
    UIManager:show(ActionMenu:new{ title = _("Pen and shapes"), actions = actions })
end

function Notebook:_showSettings()
    self:_finishInteraction()
    UIManager:show(SettingsDialog:new{
        canvas = self.canvas,
        on_change = function(key, value) self:_setSetting(key, value) end,
    })
end

--- Reads the stored settings onto a freshly built canvas.
function Notebook:_loadSettings()
    -- No fallback to the keys written under the old name: they are moved onto
    -- these once, when the plugin loads. See Library.migrateSettings.
    local function get(key, default)
        local value = G_reader_settings:readSetting(SETTING_PREFIX .. key)
        if value == nil then return default end
        return value
    end
    local canvas = self.canvas
    local style = get("pen_style", "fineliner")
    canvas.pen_style = (style == "fountain" or style == "pencil") and style or "fineliner"
    canvas.line_style = get("line_style", "line") == "arrow" and "arrow" or "line"
    canvas.pen_width         = get("pen_width", canvas.pen_width)
    canvas.highlighter_width = get("highlighter_width", canvas.highlighter_width)
    canvas.eraser_size       = get("eraser_size", canvas.eraser_size)
    canvas.eraser_mode       = get("eraser_mode", canvas.eraser_mode)
    canvas.draw_with_finger  = get("draw_with_finger", canvas.draw_with_finger)
end

function Notebook:_updatePageText()
    self.page_text:setText(string.format("  %d / %d  ",
        self.document.current_page, self.document:pageCount()))
end

function Notebook:_refreshToolbar()
    self:_updatePageText()
    self.undo_state = self.document:canUndo()
    self.redo_state = self.document:canRedo()
    UIManager:setDirty(self, "ui", self.toolbar.dimen)
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
    local page, x, y, w, h = self.document:undo()
    if not page then return end
    self:_afterHistoryChange(page, x, y, w, h)
end

function Notebook:_redo()
    self:_finishInteraction()
    local page, x, y, w, h = self.document:redo()
    if not page then return end
    self:_afterHistoryChange(page, x, y, w, h)
end

function Notebook:_afterHistoryChange(page, x, y, w, h)
    if page ~= self.document.current_page then
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

function Notebook:onShow()
    self.canvas:start()
    self.clock_tick = self.clock_tick or function()
        -- Never interrupt ink with a clock refresh or redraw a hidden notebook.
        if UIManager:getTopmostVisibleWidget() == self and not self.canvas.pen_down
            and not self.canvas.stroke and not self.canvas.erasing and not self.canvas.dragging_selection then
            self.clock_text:setText(os.date("%H:%M"))
            local r = self.clock_text.dimen
            if r then UIManager:setDirty(self, "ui", r) end
        end
        UIManager:scheduleIn(60 - os.time() % 60, self.clock_tick)
    end
    Safe.onShutdown("notebook:clock", function() UIManager:unschedule(self.clock_tick) end)
    UIManager:unschedule(self.clock_tick)
    UIManager:scheduleIn(60 - os.time() % 60, self.clock_tick)
    return true
end

function Notebook:onCloseWidget()
    Safe.clearShutdown("notebook:clock")
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
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
return Safe.widget(Notebook, "notebook", false)
