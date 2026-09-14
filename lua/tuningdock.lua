--[[--
The tuning dock.

A band along the bottom of the screen, with the page still above it, shown only
inside a notebook called `_tuning_`.

Not a dialog, and that is the whole point. What is being tuned here is how the
pen feels, and a modal panel cannot be used to tune it: while it is open you
cannot draw, so the loop is change a number, close, draw, reopen -- and by the
time you are drawing you are comparing against a memory of thirty seconds ago.
With the band open you change a number and put a line down an inch higher, and
the difference is in the same hand.

Steppers rather than sliders, deliberately. Dragging a slider on E-Ink fires a
burst of partial refreshes, which is exactly the phenomenon being measured: the
instrument would contaminate the reading. And a slider gives you "about 47" when
what you need is the number to type into the source. A tap is one step, one
refresh, one exact value.

Built from `Tuning.tabs`, so adding a knob later is a line in `tuning.lua` and
nothing here.

@module notebook.tuningdock
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
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Safe = require("safe")

local Screen = Device.screen

--[[--
How much of the screen the band takes.

A third. Less and the five rows of the longest tab do not fit without
scrolling, and a dock you have to scroll costs the tap it was meant to save.
More and there is not enough page left to write the sentence you are judging.
--]]
local HEIGHT_RATIO = 0.34

--- A tappable label, which is every control in here.
local Tappable = InputContainer:extend{
    text = nil,
    width = nil,
    selected = false,
    callback = nil,
    hold_callback = nil,
    -- Set by the dock from the size it settled on; see TuningDock:_build.
    cell_h = nil,
    font_size = nil,
}

function Tappable:init()
    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.small,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.cell_h or Screen:scaleBySize(40) },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", self.font_size or 16),
                fgcolor = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                max_width = self.width,
            },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

function Tappable:onHold()
    if self.hold_callback then
        self.hold_callback()
    elseif self.callback then
        self.callback()
    end
    return true
end

-- The dock ---------------------------------------------------------------------

local TuningDock = InputContainer:extend{
    width = nil,
    height = nil,
    -- Only for the eraser_mode row, which is a canvas setting rather than a
    -- tuning parameter. Absent in the test bench, and then the row is absent too.
    canvas = nil,
    -- Called with the tab id when it changes, so the owner can remember it.
    on_tab = nil,
    tab = nil,
    owner = nil,
}

TuningDock.HEIGHT_RATIO = HEIGHT_RATIO

function TuningDock:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.tab = self.tab or Tuning.tabs[1].id
    self:_build()
end

--[[--
How far a tap on plus moves the value.

Times ten on a hold, because a range like reconcile_delay_ms is 200 to 5000 in
steps of 100, and crossing it a tap at a time is forty-eight taps.
--]]
function TuningDock:step(key, direction, fast)
    local s = Tuning.spec[key]
    if not s then return end
    local mult = fast and 10 or 1
    Tuning.set(key, Tuning[key] + direction * s.step * mult)
    self:_refresh()
end

function TuningDock:setTab(id)
    for _, tab in ipairs(Tuning.tabs) do
        if tab.id == id then
            self.tab = id
            if self.on_tab then self.on_tab(id) end
            self:_refresh()
            return
        end
    end
    -- An id from a stored preference that no longer names a tab: leave the dock
    -- on the one it is on rather than showing an empty band.
end

function TuningDock:resetTab()
    for _, tab in ipairs(Tuning.tabs) do
        if tab.id == self.tab then
            for _, key in ipairs(tab.keys) do Tuning.reset(key) end
        end
    end
    self:_refresh()
end

function TuningDock:resetAll()
    Tuning.resetAll()
    self:_refresh()
end

--[[--
Sets the eraser mode (stroke or area), only if a canvas is present.
--]]
function TuningDock:setEraserMode(value)
    if not self.canvas then return end
    if value == "stroke" or value == "area" then
        self.canvas.eraser_mode = value
        if self.owner and self.owner._setSetting then
            self.owner:_setSetting("eraser_mode", value)
        else
            G_reader_settings:saveSetting("notebook_eraser_mode", value)
        end
        self:_refresh()
    end
end

--[[--
Writes the changed parameters to the log.

The log is the one channel that already exists -- `tools/restart.sh --log` reads
it -- and it is also the only one that survives the device being picked up and
put down. What it cannot do is be seen from the device, hence the confirmation.
--]]
function TuningDock:dump()
    local text = Tuning.dump()
    io.write("\nnotebook tuning:\n", text, "\n\n")
    io.flush()
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = "Tuning written to the log", timeout = 2 })
end

--[[--
The sizes the rows are tried at, tallest first.

The band is a fixed fraction of the screen and the tabs are not all the same
length: five parameters plus the banner, the tabs and the commands is eight
rows, and at the size a control wants to be that is taller than a third of a
Scribe. What ran off the bottom was the last two parameters of the two longest
tabs -- present in the tree, painted past the edge of the screen, and therefore
neither visible nor tappable, which is the worst of the three ways a control
can be missing.

Shrinking is the right trade here and not everywhere: these rows are a word and
a number, read from a hand's length away by someone who is about to tap them,
not body text.
--]]
local ROW_SIZES = {
    { cell = 40, font = 16 },
    { cell = 34, font = 15 },
    { cell = 28, font = 14 },
    { cell = 24, font = 13 },
}

function TuningDock:_build()
    --[[
    The tree this replaces is let go of first.

    Every tap on plus or minus rebuilds the band, and a tuning session is
    hundreds of them: the widgets hold rendered text, and dropping the last lot
    on the floor for the collector to find leaves that many bitmaps alive in a
    plugin whose whole purpose is to be run while watching how the device
    behaves under memory pressure.
    ]]
    if self.frame then self.frame:free() end

    local inner_w = self.width - 2 * Size.padding.large
    -- What the frame around the content leaves for the content itself.
    local room = self.height - 2 * Size.padding.large - 2 * Size.border.thin

    local content
    for i, size in ipairs(ROW_SIZES) do
        if content then content:free() end
        self.cell_h = Screen:scaleBySize(size.cell)
        self.font_size = size.font

        content = VerticalGroup:new{ align = "left" }

        -- The banner. Fixed, unerasable, and shown exactly in the condition it
        -- warns about: a notebook that is named _tuning_ whether or not that
        -- was meant.
        table.insert(content, TextWidget:new{
            text = "Test notebook - rename it if you are not tuning",
            face = Font:getFace("cfont", self.font_size - 1),
            max_width = inner_w,
        })

        table.insert(content, self:_tabRow(inner_w))
        table.insert(content, self:_commandRow(inner_w))

        for _, tab in ipairs(Tuning.tabs) do
            if tab.id == self.tab then
                for _, key in ipairs(tab.keys) do
                    table.insert(content, self:_paramRow(key, inner_w))
                end
                if tab.id == "eraser" and self.canvas then
                    table.insert(content, self:_eraserModeRow(inner_w))
                end
            end
        end

        if content:getSize().h <= room or i == #ROW_SIZES then break end
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = 0,
        padding = Size.padding.large,
        content,
    }
    self[1] = self.frame
end

function TuningDock:_tabRow(inner_w)
    local row = HorizontalGroup:new{ align = "center" }
    local n = #Tuning.tabs
    local cell = math.floor((inner_w - (n - 1) * Size.padding.small) / n)
    for i, tab in ipairs(Tuning.tabs) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
        end
        local id = tab.id
        table.insert(row, Tappable:new{
            cell_h = self.cell_h, font_size = self.font_size,
            text = tab.label,
            width = cell,
            selected = id == self.tab,
            callback = function() self:setTab(id) end,
        })
    end
    return row
end

function TuningDock:_commandRow(inner_w)
    local row = HorizontalGroup:new{ align = "center" }
    local commands = {
        { text = "Reset tab", fn = function() self:resetTab() end },
        { text = "Reset all", fn = function() self:resetAll() end },
        { text = "Dump",      fn = function() self:dump() end },
    }
    local cell = math.floor((inner_w - 2 * Size.padding.small) / 3)
    for i, c in ipairs(commands) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
        end
        table.insert(row, Tappable:new{
            cell_h = self.cell_h, font_size = self.font_size,
            text = c.text, width = cell, callback = c.fn })
    end
    return row
end

--[[--
One parameter: `[-]  name  value  [+]`.

The name is shown as it is written in the source, underscores and all, because
what this panel is for is finding a number to type into that source: a prettier
label would be one more thing to translate back by hand at the end.
--]]
function TuningDock:_paramRow(key, inner_w)
    local btn_w = Screen:scaleBySize(64)
    local label_w = inner_w - 2 * btn_w - 2 * Size.padding.small
    local changed = Tuning[key] ~= Tuning.spec[key].default
    local row = HorizontalGroup:new{ align = "center" }

    table.insert(row, Tappable:new{
        cell_h = self.cell_h, font_size = self.font_size,
        text = "-", width = btn_w,
        callback = function() self:step(key, -1) end,
        hold_callback = function() self:step(key, -1, true) end,
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
    table.insert(row, CenterContainer:new{
        dimen = Geom:new{ w = label_w, h = self.cell_h },
        TextWidget:new{
            -- A star on anything that is no longer at its default, so what has
            -- to be written down at the end can be seen at a glance.
            text = string.format("%s%s  %s", changed and "* " or "",
                key, tostring(Tuning[key])),
            face = Font:getFace("cfont", self.font_size),
            max_width = label_w,
        },
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
    table.insert(row, Tappable:new{
        cell_h = self.cell_h, font_size = self.font_size,
        text = "+", width = btn_w,
        callback = function() self:step(key, 1) end,
        hold_callback = function() self:step(key, 1, true) end,
    })
    return row
end

--[[--
The eraser's mode, which is not a tuning parameter.

It is a reader-facing setting with its own key and its own place in the settings
panel, and it does not belong in `tuning.lua` among the numbers. It is here
anyway because the eraser cannot be judged without switching between the two
modes, and walking out to the settings panel to do it costs the whole point of
an in-place dock.
--]]
function TuningDock:_eraserModeRow(inner_w)
    local row = HorizontalGroup:new{ align = "center" }
    local cell = math.floor((inner_w - Size.padding.small) / 2)
    local modes = {
        { text = "erase: whole strokes", value = "stroke" },
        { text = "erase: part of a stroke", value = "area" },
    }
    for i, m in ipairs(modes) do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = Size.padding.small })
        end
        local value = m.value
        table.insert(row, Tappable:new{
            cell_h = self.cell_h, font_size = self.font_size,
            text = m.text,
            width = cell,
            selected = self.canvas.eraser_mode == value,
            callback = function()
                self:setEraserMode(value)
            end,
        })
    end
    return row
end

--[[--
Rebuilds the band and repaints it, and nothing else.

The page above is not in the dirty rectangle: what was written up there while
tuning has to stay legible across a hundred taps down here, and asking for it to
be repainted would flash it every time.
--]]
function TuningDock:_refresh()
    self:_build()
    UIManager:setDirty(self.owner or "all", function()
        return "ui", self.dimen
    end)
end

--[[--
Paints the band where it belongs, not where the container would put it.

The owner paints its children from the origin, and this one goes at the bottom.
Carrying the offset here rather than painting the dock by hand from the owner
keeps it a child in both senses -- painted by the container, reached by taps --
instead of a widget the owner has to remember twice.
--]]
function TuningDock:paintTo(bb, x, y)
    y = y + (self.paint_offset_y or 0)
    -- Recorded after the offset, because this is the rectangle taps are matched
    -- against and the one _refresh asks to be repainted.
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

--[[--
Protected like every other screen, and like the canvas without the watchdog.

Every other screen this wraps is a dialog: it is on top when it is on screen,
so its handlers run only when the reader is looking at it. This one is not. It
is a permanent child of the notebook, and the first one, so *every* event the
notebook sees passes through here before it reaches the toolbar or the page --
including the stream of contacts a hand makes while writing.

The watchdog costs a `jit.off` and a counting hook per event, which is why the
canvas gave it up: see the note above Safe.watched. A widget on the same path
cannot keep it either.
--]]
return Safe.widget(TuningDock, "tuningdock", false)
