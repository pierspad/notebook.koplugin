-- Toolbar widgets and layout; notebook.lua owns the screen lifecycle.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Canvas = require("canvas")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Toolbar = {}

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

function ToolButton:setIcon(name)
    if self.icon==name then return end
    self.icon=name
    self.icon_normal:free();self.icon_inverted:free()
    self.icon_normal=IconWidget:new{icon=name,width=self.icon_size,height=self.icon_size,invert=false}
    self.icon_inverted=IconWidget:new{icon=name,width=self.icon_size,height=self.icon_size,invert=true}
    self.holder[1]=self.selected and self.icon_inverted or self.icon_normal
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

function Toolbar:_actionButton(opts)
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
function Toolbar:_buildPageButton()
    local sizer = TextWidget:new{
        text = "888/888",
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

function Toolbar:_buildToolbar()
    local gap = Size.padding.small
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
    -- Back + tools + undo/redo/refresh + zoom + paste + previous/next + settings.
    local n_cells = #TOOLS + 9
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
    self.zoom_button = self:_actionButton{
        icon = "notebook.zoom-in", icon_size = icon_size, width = unit,
        callback = function() self:_toggleZoom() end,
    }

    local spacers = {}
    local function betweenGroups()
        local spacer = HorizontalSpan:new{ width = gap }
        spacers[#spacers + 1] = spacer
        return spacer
    end
    local clock_inset = HorizontalSpan:new{width=0}
    self.clock_inset = clock_inset
    self.toolbar_content = HorizontalGroup:new{
        align = "center",
        clock_inset,
        CenterContainer:new{
            dimen = Geom:new{w=clock_w, h=self.next_page_button:getSize().h},
            self.clock_text,
        },
        betweenGroups(),
        -- Leaving is a "back" arrow on the left, where every other back control
        -- lives, rather than a Close button at the far right.
        self:_actionButton{
            icon = "chevron.first", icon_size = icon_size, width = unit,
            callback = function() self:_close() end,
        },
        tool_group,
        betweenGroups(),
        self.prev_page_button,
        self.page_button,
        self.next_page_button,
        betweenGroups(),
        self.undo_button,
        self.redo_button,
        -- Clears accumulated e-ink ghosting on demand.
        self:_actionButton{
            icon = "notebook.refresh", icon_size = icon_size, width = unit,
            callback = function() self:_refreshScreen() end,
        },
        self.paste_button,
        self.zoom_button,
        betweenGroups(),
        self:_actionButton{
            icon = "appbar.settings", icon_size = icon_size, width = unit,
            callback = function() self:_showSettings() end,
        },
    }

    local remaining = math.max(0, avail - self.toolbar_content:getSize().w)
    -- Distribute spare pixels over the four requested group boundaries.
    -- Giving the first few spans the remainder keeps their widths within 1px.
    local each = math.floor(remaining / #spacers)
    for i, spacer in ipairs(spacers) do
        spacer.width = gap + each + (i <= remaining % #spacers and 1 or 0)
    end
    -- Borrow from the clock/back gap: every button retains its exact position
    -- and size, including on narrow portrait layouts.
    local inset = math.min(Size.padding.small, math.floor(spacers[1].width / 2))
    clock_inset.width = inset
    spacers[1].width = spacers[1].width - inset
    self.toolbar_content:resetLayout()

    self.toolbar = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = Size.padding.small,
        width = self.dimen.w,
        self.toolbar_content,
    }
    local toolbar_sz = self.toolbar:getSize()
    self.toolbar.dimen = Geom:new{ x = 0, y = 0, w = toolbar_sz.w, h = toolbar_sz.h }
    self:_updatePageText()
end

Toolbar.tools = TOOLS
return Toolbar
