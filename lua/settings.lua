--[[--
The settings panel.

Written as its own widget rather than a ButtonDialog because the sizes are shown
as what they are -- a stroke of that thickness -- instead of a number. A number
tells you nothing about how a 24-pixel marker will look; a bar of it does, and
picking one is a single tap.

@module notebook.settings
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widgets = require("widgets")
local _ = require("i18n")
local Safe = require("safe")

local Screen = Device.screen

--[[--
How far the page behind the panel is taken down while it is open.

Light enough that what is underneath stays readable -- the panel is about the
page, and hiding it would be no help -- but enough that the panel reads as
something in front rather than as part of the drawing. On e-ink this is also the
cue that a tap outside will land somewhere that is not the notebook.
--]]
local BACKDROP_DIM = 0.12

-- Size presets per tool, in stroke-width pixels.
local PRESETS = {
    pen_width         = { 2, 3, 5, 8, 12 },
    highlighter_width = { 12, 20, 30, 45, 60 },
    eraser_size       = { 10, 18, 28, 40, 60 },
}

-- A sample cell is this wide; the bar inside it is drawn at the real width.
local CELL_W = Screen:scaleBySize(64)
local CELL_H = Screen:scaleBySize(64)

--[[--
One size choice, drawn as a bar of that exact thickness.

Very thick presets would overflow the cell, so the bar is capped -- the point is
to compare thicknesses at a glance, and past a certain size they are all
obviously "thick" anyway.
--]]
local SampleButton = InputContainer:extend{
    value = nil,
    -- "bar" for the drawing tools, "circle" for the eraser: an eraser is a
    -- round thing you press on the page, and showing it as a stripe misleads
    -- about what it will take away.
    shape = "bar",
    selected = false,
    callback = nil,
}

function SampleButton:init()
    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = CELL_W, h = CELL_H },
            VerticalSpan:new{ width = 0 },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function SampleButton:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)

    -- Drawn straight onto the frame the container just painted.
    local ink = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local cx = x + math.floor(self.dimen.w / 2)
    local cy = y + math.floor(self.dimen.h / 2)

    if self.shape == "circle" then
        -- eraser_size is already a radius, so it is drawn as one: halving it
        -- here would show a rubber half the size of the one you get.
        -- Capped so the largest preset still sits inside its cell.
        local r = math.min(self.value, math.floor(CELL_H / 2) - 4)
        bb:paintCircle(cx, cy, math.max(2, r), ink)
    else
        local thickness = math.min(self.value, math.floor(CELL_H / 2))
        local bar_w = math.floor(CELL_W * 0.6)
        bb:paintRect(cx - math.floor(bar_w / 2),
            cy - math.floor(thickness / 2),
            bar_w, math.max(1, thickness), ink)
    end
end

function SampleButton:onTap()
    if self.callback then self.callback(self.value) end
    return true
end

--- A plain tappable line of text, for the on/off choices.
local TextChoice = InputContainer:extend{
    text = nil,
    width = nil,
    selected = false,
    callback = nil,
}

function TextChoice:init()
    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.button,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = Screen:scaleBySize(44) },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", 18),
                fgcolor = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                max_width = self.width - 2 * Size.padding.button,
            },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function TextChoice:onTap()
    if self.callback then self.callback() end
    return true
end

-- The panel ---------------------------------------------------------------------

local SettingsDialog = InputContainer:extend{
    canvas = nil,
    -- Called with (key, value) when something is chosen.
    on_change = nil,
}

function SettingsDialog:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    local content = VerticalGroup:new{ align = "left" }
    local gap = VerticalSpan:new{ width = Size.padding.large }

    local function heading(text)
        return TextWidget:new{
            text = text,
            face = Font:getFace("cfont", 18),
        }
    end

    local function sizeRow(key, shape)
        local row = HorizontalGroup:new{ align = "center" }
        local current = self.canvas[key]
        for i, value in ipairs(PRESETS[key]) do
            if i > 1 then
                table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
            end
            table.insert(row, SampleButton:new{
                value = value,
                shape = shape,
                selected = value == current,
                callback = function() self:_choose(key, value) end,
            })
        end
        return row
    end

    --[[
    A label with a two-state switch under it, rather than one line whose text
    flips. A line that reads "Eraser removes whole strokes" is ambiguous: it
    could be stating the current setting or offering the alternative. Showing
    both choices with one of them filled in removes the question.
    ]]
    local function switchRow(current, options)
        local row = HorizontalGroup:new{ align = "center" }
        local cell_w = math.floor((5 * CELL_W + 4 * Size.padding.small
            - Size.padding.small) / 2)
        for i, opt in ipairs(options) do
            if i > 1 then
                table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
            end
            table.insert(row, TextChoice:new{
                text = opt.text,
                width = cell_w,
                selected = opt.value == current,
                callback = opt.callback,
            })
        end
        return row
    end

    --[[
    A close button, even though a tap outside also dismisses the panel.

    Tapping outside is the convention, not the discovery: someone who has not
    met it sees a panel with no way out and reasonably concludes they are stuck.
    The cost of the button is one corner of a row that was empty anyway.
    ]]
    local row_w = 5 * CELL_W + 4 * Size.padding.small
    local close = Widgets.iconButton("close", function() UIManager:close(self) end)
    local header = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = math.max(0, row_w - close:getSize().w) },
        close,
    }
    table.insert(content, header)
    table.insert(content, VerticalSpan:new{ width = Size.padding.small })

    table.insert(content, heading(_("Pen size")))
    table.insert(content, sizeRow("pen_width", "bar"))
    table.insert(content, gap)
    table.insert(content, heading(_("Marker size")))
    table.insert(content, sizeRow("highlighter_width", "bar"))
    table.insert(content, gap)
    table.insert(content, heading(_("Eraser size")))
    table.insert(content, sizeRow("eraser_size", "circle"))
    table.insert(content, gap)

    table.insert(content, heading(_("Eraser removes")))
    table.insert(content, switchRow(self.canvas.eraser_mode, {
        {
            text = _("Whole strokes"),
            value = "stroke",
            callback = function() self:_choose("eraser_mode", "stroke") end,
        },
        {
            text = _("Part of a stroke"),
            value = "area",
            callback = function() self:_choose("eraser_mode", "area") end,
        },
    }))
    table.insert(content, gap)

    table.insert(content, heading(_("Finger")))
    table.insert(content, switchRow(self.canvas.draw_with_finger, {
        {
            text = _("Turns pages"),
            value = false,
            callback = function() self:_choose("draw_with_finger", false) end,
        },
        {
            text = _("Draws"),
            value = true,
            callback = function() self:_choose("draw_with_finger", true) end,
        },
    }))

    self.panel = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        content,
    }

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.panel,
    }

    -- Tapping anywhere outside the panel dismisses it, like every other dialog.
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function SettingsDialog:_choose(key, value)
    if self.on_change then self.on_change(key, value) end
    -- The replacement panel repaints the whole screen as it opens, so the
    -- outgoing one must not also demand a flash on its way out: that would put
    -- a full-screen flash between every two taps in here.
    self.reopening = true
    UIManager:close(self)
    -- Reopen so the new choice is visible, and so several can be changed in a row.
    UIManager:show(SettingsDialog:new{
        canvas = self.canvas,
        on_change = self.on_change,
    })
end

function SettingsDialog:onTapClose(_, ges)
    if ges and ges.pos and self.panel.dimen
        and ges.pos:intersectWith(self.panel.dimen) then
        -- Inside the panel: let the choices handle it.
        return false
    end
    UIManager:close(self)
    return true
end

function SettingsDialog:onClose()
    UIManager:close(self)
    return true
end

--[[--
Paints the page behind at a lower contrast, then the panel over it.

Done here rather than with a widget of its own so that the dimming is part of
the same paint pass as the panel: the area is repainted from the notebook first,
by UIManager, and darkened once. A separate dimming widget would be painted
whenever *it* was dirty, and the page under it would fade a little further each
time the panel was reopened to show a new choice.
--]]
function SettingsDialog:paintTo(bb, x, y)
    bb:darkenRect(x, y, self.dimen.w, self.dimen.h, BACKDROP_DIM)
    InputContainer.paintTo(self, bb, x, y)
end

function SettingsDialog:onShow()
    -- The whole screen, not just the panel: the dimming covers all of it, and a
    -- region left out of the repaint would be the one part still at full
    -- contrast.
    UIManager:setDirty(self, "ui")
    return true
end

function SettingsDialog:onCloseWidget()
    if self.reopening then return end
    UIManager:setDirty(nil, "ui")
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(SettingsDialog, "settings")
