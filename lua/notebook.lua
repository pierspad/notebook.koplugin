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
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local SettingsDialog = require("settings")
local Tuning = require("tuning")
local TuningDock = require("tuningdock")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Safe = require("safe")

local Screen = Device.screen

-- InputDialog still owns keyboard input and cursor movement, but its ordinary
-- textbox would duplicate the live text already painted on the page. Keep the
-- editor functional while making that redundant copy invisible.
local CanvasTextInput = InputText:extend{
    skip_paint = true,
    bordersize = 0,
    padding = 0,
    margin = 0,
}

-- The page itself is the text editor. Keep InputDialog's keyboard/focus logic
-- and formatting buttons, but remove its title and opaque full-width panel.
local CanvasTextDialog = InputDialog:extend{}
function CanvasTextDialog:init()
    InputDialog.init(self)
    if self.dialog_frame then
        self.dialog_frame.background = nil
        self.dialog_frame.bordersize = 0
    end
    if self.vgroup then
        self.vgroup[1] = VerticalSpan:new{ width = 0 }
        self.vgroup:resetLayout()
    end
    -- ButtonTable normally paints one white slab (plus separators) across the
    -- page. Make only its button frames transparent and disable its LineWidget
    -- separators. Clearing every `background` recursively is unsafe: a
    -- LineWidget still calls paintRect and a nil colour crashes on the device.
    if self.button_table then
        for _, row in ipairs(self.button_table.buttons_layout or {}) do
            for _, button in ipairs(row) do
                if button.frame then
                    -- Controls need a stable surface over arbitrary PDF
                    -- artwork. Keep each key white and outlined, while the
                    -- dialog and text preview themselves remain transparent.
                    button.frame.background = Blitbuffer.COLOR_WHITE
                    button.frame.bordersize = Size.border.thin
                end
            end
        end
        local function hideSeparators(widget)
            if type(widget) ~= "table" then return end
            if widget.style == "solid" and widget.dimen and not widget.frame then
                widget.style = "none"
            end
            for _, child in ipairs(widget) do hideSeparators(child) end
        end
        hideSeparators(self.button_table.container)
    end
end

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

-- Toolbar ------------------------------------------------------------------------

-- The tools, in the order they appear in the selector.
local TOOLS = {
    { tool = "pen",         icon = "notebook.pen" },
    { tool = "highlighter", icon = "notebook.marker" },
    { tool = "eraser",      icon = "notebook.eraser" },
    { tool = "lasso",       icon = "notebook.lasso" },
    { tool = "shape",       icon = "notebook.shape" },
    { tool = "text",        icon = "notebook.text" },
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
        DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
    }
end

function ToolButton:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

function ToolButton:onDoubleTap()
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
    -- Back + tools + undo/redo/refresh + paste + previous/next + settings.
    local n_cells = #TOOLS + 8
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
            hold_callback = function() self:_openToolOptions(i) end,
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
    self.paste_button = self:_actionButton{
        icon = "notebook.paste", icon_size = icon_size, width = unit,
        callback = function() self.canvas:pasteClipboard() end,
        enabled_func = function() return Canvas.hasClipboard() end,
    }

    self.toolbar_content = HorizontalGroup:new{
        align = "center",
        -- Keep one live notebook clock in the corner KOReader reserves for its
        -- transient clock. When the system overlay appears it occupies the same
        -- place, and when it hides during writing the notebook clock remains.
        CenterContainer:new{
            dimen = Geom:new{w=clock_w, h=self.next_page_button:getSize().h},
            self.clock_text,
        },
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
        self.paste_button,
        self.prev_page_button,
        self.page_button,
        self.next_page_button,
        HorizontalSpan:new{ width = gap },
        self:_actionButton{
            icon = "appbar.settings", icon_size = icon_size, width = unit,
            callback = function() self:_showSettings() end,
        },
    }

    local remaining = math.max(0, avail - self.toolbar_content:getSize().w)
    table.insert(self.toolbar_content, 14, HorizontalSpan:new{width=remaining})
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
    self.canvas:_debugEvent("select-tool", nil, nil, nil, self.canvas.tool)
    for i, btn in ipairs(self.tool_buttons) do
        btn:setSelected(i == index)
    end
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

-- Settings ---------------------------------------------------------------------

--- Persists a canvas setting and applies it immediately.
function Notebook:_setSetting(key, value)
    self.canvas[key] = value
    self.canvas:_debugEvent("setting:" .. key, nil, nil, nil, value)
    G_reader_settings:saveSetting(SETTING_PREFIX .. key, value)
end

function Notebook:_colorActions(key, index)
    local actions = {}
    for i, option in ipairs({
        {0, _("Black"), "black"}, {255, _("White"), "white"},
        {0x1E53935, _("Red"), "red"}, {0x11E88E5, _("Blue"), "blue"},
        {0x1FB8C00, _("Orange"), "orange"}, {0x143A047, _("Green"), "green"},
        {0x1FDD835, _("Yellow"), "yellow"}, {0x18E24AA, _("Purple"), "purple"},
    }) do
        local value = option[1]
        actions[#actions + 1] = {
            swatch = option[3], section = i == 1 and _("Color") or nil,
            text = option[2], selected = function() return self.canvas[key] == value end,
            callback = function()
                self:_setSetting(key, value)
                self:_selectTool(index)
            end,
        }
    end
    return actions
end

function Notebook:_showPenOptions()
    self:_finishInteraction()
    local actions = {}
    for _index, option in ipairs({
        { "pen_style", "fineliner", _("Fineliner"), "notebook.fineliner" },
        { "pen_style", "fountain", _("Fountain pen"), "notebook.fountain" },
        { "pen_style", "pencil", _("Pencil"), "notebook.pencil" },
    }) do
        local key, value, label = option[1], option[2], option[3]
        table.insert(actions, {
            icon = option[4],
            section = option[5],
            text = label,
            selected = function() return self.canvas[key] == value end,
            callback = function()
                self:_setSetting(key, value)
                self:_selectTool(1)
            end,
        })
    end
    for _, action in ipairs(self:_colorActions("pen_color", 1)) do actions[#actions + 1] = action end
    self:_showToolMenu(1, _("Pen type"), actions, "pen_width")
end

function Notebook:_showToolMenu(index, title, actions, key)
    self:_finishInteraction()
    local menu
    local menu_width = math.min(self.dimen.w - 2 * Size.border.window,
        math.max(key and SettingsDialog.choiceRowWidth() or 0, Screen:scaleBySize(340)))
    local footer = key and SettingsDialog.sizeChoices(key, self.canvas[key], function(value)
        self:_setSetting(key, value)
        self.canvas.tool = TOOLS[index].tool
        if menu then UIManager:setDirty(menu, "ui", menu.panel.dimen) end
    end, menu_width)
    menu = ActionMenu:new{
        title=title, actions=actions, footer=footer,
        width=menu_width,
        anchor=self.tool_buttons[index].dimen,
        tool_buttons=self.tool_buttons,
        on_tool_options=function(next_index)
            UIManager:close(menu)
            self:_openToolOptions(next_index)
        end,
        draw_target=self.canvas,
        disable_double_tap=false,
    }
    UIManager:show(menu)
end

function Notebook:_showToolOptions(index)
    local tool = TOOLS[index].tool
    if tool == "pen" then return self:_showPenOptions() end
    if tool == "highlighter" then
        local colors = self:_colorActions("highlighter_color", index)
        return self:_showToolMenu(index, _("Marker size"), colors, "highlighter_width")
    end
    local actions = {}
    if tool == "eraser" then
        for _index, option in ipairs({{"stroke", _("Whole strokes")}, {"area", _("Part of a stroke")}}) do
            local value = option[1]
            table.insert(actions, {icon="notebook.eraser",
                text=option[2], selected=function() return self.canvas.eraser_mode == value end,
                callback=function() self:_setSetting("eraser_mode", value) end})
        end
        return self:_showToolMenu(index, _("Eraser size"), actions, "eraser_size")
    end
    if tool == "shape" then
        for _index, option in ipairs({
            {"square", _("Square")}, {"rectangle", _("Rectangle")},
            {"circle", _("Circle")}, {"triangle", _("Triangle")},
        }) do
            local kind = option[1]
            table.insert(actions, {icon="notebook." .. kind,
                text=option[2], selected=function() return self.canvas.shape_kind == kind end,
                callback=function() self:_setSetting("shape_kind", kind) end})
        end
        local colors = self:_colorActions("shape_color", index)
        for _, action in ipairs(colors) do actions[#actions + 1] = action end
        return self:_showToolMenu(index, _("Shapes"), actions)
    end
    if tool == "text" then
        for _index, option in ipairs({{18, _("Small"), "a", 15}, {26, _("Medium"), "A", 20},
                                  {36, _("Large"), "A", 25}}) do
            table.insert(actions, {icon_text=option[3], icon_size=option[4], text=option[2],
                selected=function() return self.canvas.text_size == option[1] end,
                callback=function() self:_setSetting("text_size", option[1]) end})
        end
        for _index, option in ipairs({{"sans", _("Sans-serif"), "E", "cfont"},
                                  {"serif", _("Serif"), "E", "ffont"},
                                  {"mono", _("Monospace"), "M", "infont"}}) do
            table.insert(actions, {icon_text=option[3], icon_font=option[4], icon_size=18, text=option[2],
                selected=function() return (self.canvas.text_font or "sans") == option[1] end,
                callback=function() self:_setSetting("text_font", option[1]) end})
        end
        for _index, option in ipairs({{"text_bold", _("Bold"), "B", true},
                                  {"text_italic", _("Italic"), "I"},
                                  {"text_underline", _("Underline"), "U̲"}}) do
            table.insert(actions, {icon_text=option[3], icon_bold=option[4], text=option[2],
                selected=function() return self.canvas[option[1]] == true end,
                callback=function()
                    self:_setSetting(option[1], not self.canvas[option[1]])
                end})
        end
        for _index, option in ipairs({
            { true, _("White"), "notebook.page", _("Background") },
            { false, _("Transparent"), "texture-box" },
        }) do
            local value = option[1]
            table.insert(actions, {
                icon=option[3], text=option[2], section=option[4],
                selected=function() return self.canvas.text_background == value end,
                callback=function() self:_setSetting("text_background", value) end,
            })
        end
        return self:_showToolMenu(index, _("Text options"), actions)
    end
end

function Notebook:_insertText(x, y)
    self:_editText(nil, x, y)
end

function Notebook:_editText(original, x, y)
    x, y = x or original.x_min, y or original.y_min
    local function textOption(key, fallback)
        if original and original[key] ~= nil then return original[key] end
        local value=self.canvas[key]
        return value ~= nil and value or fallback
    end
    local style = {
        font_family = original and original.font_family or self.canvas.text_font or "sans",
        text_bold = textOption("text_bold",false),
        text_italic = textOption("text_italic",false),
        text_underline = textOption("text_underline",false),
        text_background = textOption("text_background",false),
    }
    local size = original and original.font_size or self.canvas.text_size
    local width = original and (original.x_max-original.x_min)
        or math.max(80, math.min(Screen:scaleBySize(600), self.canvas.content.x+self.canvas.content.w-x))
    local preview
    local dialog
    self.canvas.hidden_stroke = original

    local function redraw(value)
        local dirty = nil
        if preview then dirty=require("rect").grow(dirty, preview:getBounds()) end
        if original then dirty=require("rect").grow(dirty, original:getBounds()) end
        -- The page is the editor preview. Mirror the real Unicode cursor from
        -- the hidden input widget so arrow-key edits remain understandable.
        local shown=value
        local input=dialog and dialog._input_widget
        if input and input.charlist and input.charpos then
            local before,after={},{}
            for i=1,input.charpos-1 do before[#before+1]=input.charlist[i] end
            for i=input.charpos,#input.charlist do after[#after+1]=input.charlist[i] end
            shown=table.concat(before).."│"..table.concat(after)
        elseif shown=="" then
            shown="│"
        end
        -- Live editing favours the cheaper opaque blit. The stored style is
        -- applied on commit, so transparent text becomes transparent as soon
        -- as the user confirms it.
        local preview_style={}
        for key,value in pairs(style) do preview_style[key]=value end
        preview_style.text_background=true
        preview=require("textobject").create(shown,x,y,width,size,preview_style)
        dirty=require("rect").grow(dirty,preview:getBounds())
        self.canvas.text_preview=preview
        self.canvas:_repaintRegion(dirty.x,dirty.y,dirty.w,dirty.h,true)
        self.canvas:_refreshNow(dirty.x,dirty.y,dirty.w,dirty.h,"ui")
    end

    local function currentText() return dialog and dialog:getInputText() or (original and original.text or "") end
    local function restyle(fn) fn(); redraw(currentText()) end
    local families={"sans","serif","mono"}
    local function cancel()
        UIManager:close(dialog)
        local dirty = nil
        if preview then dirty=require("rect").grow(dirty,preview:getBounds()) end
        if original then dirty=require("rect").grow(dirty,original:getBounds()) end
        self.canvas.hidden_stroke=nil; self.canvas.text_preview=nil
        if dirty then self.canvas:_repaintRegion(dirty.x,dirty.y,dirty.w,dirty.h) end
    end
    local function commit()
        local value = dialog:getInputText()
        UIManager:close(dialog)
        self.canvas.hidden_stroke=nil; self.canvas.text_preview=nil
        if not value or value == "" then
            if preview then self.canvas:_repaintRegion(preview:getBounds()) end
            return
        end
        local stroke = require("textobject").create(value,x,y,width,size,style)
        if original then self.document:replaceStroke(original,stroke) else self.document:addStroke(stroke) end
        self.canvas:_repaintRegion(stroke:getBounds())
        self.canvas:_showLassoMenu({stroke})
        self:_onDocumentChanged()
    end
    dialog = CanvasTextDialog:new{
        -- Kept for accessibility/introspection; CanvasTextDialog removes the
        -- visible title bar so it does not cover the page.
        title = original and _("Edit text") or _("Insert text"),
        input = original and original.text or "", allow_newline=true,
        inputtext_class=CanvasTextInput,
        condensed=true, text_height=1, input_padding=0, input_margin=0,
        width=math.floor(Screen:getWidth()*0.96), button_padding=0,
        input_face=Font:getFace("cfont",size),
        strike_callback=function()
            if dialog then redraw(dialog:getInputText()) end
        end,
        buttons = {
            {
                {text="✕", callback=cancel},
                {text="Aa", text_font_bold=false, callback=function() restyle(function()
                    local at=1; for i,v in ipairs(families) do if v==style.font_family then at=i end end
                    style.font_family=families[at%#families+1]
                end) end},
                {text="B", text_font_bold=true,
                    checked_func=function() return style.text_bold end,
                    callback=function() restyle(function() style.text_bold=not style.text_bold end) end},
                {text="I", text_font_face="NotoSans-Italic.ttf", text_font_bold=false,
                    checked_func=function() return style.text_italic end,
                    callback=function() restyle(function() style.text_italic=not style.text_italic end) end},
                {text="U̲", text_font_bold=false,
                    checked_func=function() return style.text_underline end,
                    callback=function() restyle(function() style.text_underline=not style.text_underline end) end},
                {text="A−", callback=function() restyle(function() size=math.max(10,size-2) end) end},
                {text="A+", callback=function() restyle(function() size=math.min(96,size+2) end) end},
                {text="✓", is_enter_default=true, callback=commit},
            },
        },
    }
    redraw(original and original.text or "")
    if dialog.movable then
        dialog.movable.anchor=function()
            local px,py,pw,ph=preview:getBounds()
            return Geom:new{x=px,y=py,w=pw,h=ph}
        end
    end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
    canvas.shape_kind        = get("shape_kind", "rectangle")
    canvas.shape_color       = get("shape_color", 0)
    canvas.pen_width         = get("pen_width", canvas.pen_width)
    local pen_color = get("pen_color", 0)
    canvas.pen_color = type(pen_color) == "number" and pen_color or 0
    canvas.highlighter_width = get("highlighter_width", canvas.highlighter_width)
    local marker_color = get("highlighter_color", canvas.highlighter_color)
    -- The former default yellow was stored before it appeared in the palette.
    canvas.highlighter_color = marker_color == 0x1FFFF66 and 0x1FDD835 or marker_color
    canvas.eraser_size       = get("eraser_size", canvas.eraser_size)
    canvas.eraser_mode       = get("eraser_mode", canvas.eraser_mode)
    canvas.draw_with_finger  = get("draw_with_finger", canvas.draw_with_finger)
    canvas.text_size         = get("text_size", 26)
    canvas.text_font         = get("text_font", "sans")
    canvas.text_bold         = get("text_bold", false)
    canvas.text_italic       = get("text_italic", false)
    canvas.text_underline    = get("text_underline", false)
    canvas.text_background   = get("text_background", false)
    canvas.share_format      = get("share_format", "pdf") == "xopp" and "xopp" or "pdf"
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
    self.clock_tick = self.clock_tick or Safe.wrap("notebook:clock", function()
        -- Do not gate this on getTopmostVisibleWidget(): KOReader may report a
        -- canvas child or a transient overlay even while this screen is shown,
        -- which left the displayed time frozen at the opening minute.
        self.clock_text:setText(os.date("%H:%M"))
        UIManager:setDirty(self, "ui", self.toolbar.dimen)
        UIManager:scheduleIn(math.max(1, 60 - os.time() % 60), self.clock_tick)
    end)
    Safe.onShutdown("notebook:clock", function() UIManager:unschedule(self.clock_tick) end)
    UIManager:unschedule(self.clock_tick)
    self.clock_text:setText(os.date("%H:%M"))
    UIManager:setDirty(self, "ui", self.toolbar.dimen)
    UIManager:scheduleIn(math.max(1, 60 - os.time() % 60), self.clock_tick)
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
