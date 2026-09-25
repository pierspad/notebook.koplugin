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

-- Size presets per tool, in stroke-width pixels.
local PRESETS = {
    pen_width         = { 2, 5, 9, 14, 22 },
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
    cell_width = CELL_W,
}

function SampleButton:init()
    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        -- These cells form one continuous ruler. Rounded inner corners create
        -- white wedges and make the row look narrower than its panel.
        radius = 0,
        margin = 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.cell_width, h = CELL_H },
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
        local bar_w = math.floor(self.cell_width * 0.6)
        bb:paintRect(cx - math.floor(bar_w / 2),
            cy - math.floor(thickness / 2),
            bar_w, math.max(1, thickness), ink)
    end
end

function SampleButton:onTap()
    if self.callback then self.callback(self.value) end
    return true
end

function SampleButton:setSelected(selected)
    self.selected = selected
    self.frame.background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
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

function TextChoice:setSelected(selected)
    self.selected = selected
    self.frame.background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local label = self.frame[1] and self.frame[1][1]
    if label then
        label.fgcolor = selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    end
end

-- The panel ---------------------------------------------------------------------

local SettingsDialog = InputContainer:extend{
    canvas = nil,
    -- Kept in this catalogue for the LocalSend selector used by this plugin.
    sharing_format_label = _("Sharing format"),
    -- Called with (key, value) when something is chosen.
    on_change = nil,
}

function SettingsDialog:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    local content = VerticalGroup:new{ align = "left" }

    local function heading(text)
        return TextWidget:new{
            text = text,
            face = Font:getFace("cfont", 18),
        }
    end

    --[[
    A label with a two-state switch under it, rather than one line whose text
    flips. A line that reads "Eraser removes whole strokes" is ambiguous: it
    could be stating the current setting or offering the alternative. Showing
    both choices with one of them filled in removes the question.
    ]]
    local function switchRow(key, current, options)
        local row = HorizontalGroup:new{ align = "center" }
        row.choices = {}
        local cell_w = math.floor((5 * CELL_W + 4 * Size.padding.small
            - Size.padding.small) / 2)
        for i, opt in ipairs(options) do
            if i > 1 then
                table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
            end
            local choice = TextChoice:new{
                text = opt.text,
                width = cell_w,
                selected = opt.value == current,
                callback = opt.callback,
            }
            row.choices[#row.choices + 1] = { widget = choice, value = opt.value }
            table.insert(row, choice)
        end
        self.choice_groups = self.choice_groups or {}
        self.choice_groups[key] = row.choices
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

    table.insert(content, heading(_("Finger")))
    table.insert(content, switchRow("draw_with_finger", self.canvas.draw_with_finger, {
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

    table.insert(content, VerticalSpan:new{ width = Size.padding.small })
    table.insert(content, heading(_("Pen button")))
    table.insert(content, switchRow("barrel_button_tool", self.canvas.barrel_button_tool, {
        {
            text = _("Highlighter"), value = "highlighter",
            callback = function() self:_choose("barrel_button_tool", "highlighter") end,
        },
        {
            text = _("Eraser"), value = "eraser",
            callback = function() self:_choose("barrel_button_tool", "eraser") end,
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
    local panel_size = self.panel:getSize()
    self.panel.dimen = Geom:new{
        x = math.floor((self.dimen.w - panel_size.w) / 2),
        y = math.floor((self.dimen.h - panel_size.h) / 2),
        w = panel_size.w, h = panel_size.h,
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

function SettingsDialog.choiceRowWidth()
    return #PRESETS.pen_width * (CELL_W + 2 * Size.border.thin)
end

function SettingsDialog.sizeChoices(key, current, callback, total_width)
    local row = HorizontalGroup:new{align="center"}
    row.choices = {}
    local presets = PRESETS[key]
    local base_outer = total_width and math.floor(total_width / #presets)
    for i, value in ipairs(presets) do
        local outer_width = base_outer and (i == #presets
            and total_width - base_outer * (#presets - 1) or base_outer)
        local button = SampleButton:new{
            value=value, shape=key == "eraser_size" and "circle" or "bar",
            selected=value == current,
            cell_width=outer_width and math.max(1, outer_width - 2 * Size.border.thin) or CELL_W,
        }
        button.callback = function(selected)
            callback(selected)
            for _, choice in ipairs(row.choices) do
                choice:setSelected(choice.value == selected)
            end
        end
        row.choices[#row.choices + 1] = button
        table.insert(row, button)
    end
    return row
end

function SettingsDialog:_choose(key, value)
    if self.on_change then self.on_change(key, value) end
    for _, choice in ipairs((self.choice_groups and self.choice_groups[key]) or {}) do
        choice.widget:setSelected(choice.value == value)
    end
    UIManager:setDirty(self, "ui", self.panel.dimen)
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

function SettingsDialog:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
end

function SettingsDialog:onShow()
    UIManager:setDirty(self, "ui", self.panel.dimen)
    return true
end

function SettingsDialog:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.panel.dimen)
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(SettingsDialog, "settings")
