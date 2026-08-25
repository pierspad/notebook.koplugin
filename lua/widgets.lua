--[[--
The small controls this plugin builds by hand, in one place.

There were three of these: one in the gallery, one in the page overview, one in
the background picker. They were the same widget written three times, which is
three places to fix when a button is the wrong size and three chances for two of
them to end up looking different from the third.

Nothing here is a general-purpose widget. It is what a plugin needs that
KOReader's Button does not offer -- an icon beside a label rather than one or
the other -- kept together so it stays consistent.

@module notebook.widgets
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
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen

local Widgets = {}

--- Wraps `content` in a tappable rounded frame.
local function tappable(content, callback)
    local btn = InputContainer:extend{}:new{}
    btn.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.button,
        content,
    }
    btn[1] = btn.frame
    btn.dimen = btn.frame:getSize()
    btn.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = btn.dimen } },
    }
    btn.onTap = function()
        callback()
        return true
    end
    return btn
end

--[[--
A button showing a label with an icon beside it.

`font_size` and `icon_size` are there because a header has a fixed width and a
variable number of buttons in it: with eight of them at the size a menu uses,
the row is wider than a Scribe. Shrinking both together is what keeps the icons
on the same line as the words, which is where they belong -- an icon stacked
above its label reads as a toolbar tile, and these are not tiles.

@tparam table opts text, icon, font_size, icon_size, width (optional, for a
  fixed size), and callback
--]]
function Widgets.textButton(opts)
    local label = HorizontalGroup:new{ align = "center" }
    if opts.icon then
        local size = Screen:scaleBySize(opts.icon_size or 26)
        table.insert(label, IconWidget:new{
            icon = opts.icon, width = size, height = size,
        })
        table.insert(label, HorizontalSpan:new{ width = Size.padding.small })
    end
    table.insert(label, TextWidget:new{
        text = opts.text,
        face = Font:getFace("cfont", opts.font_size or 17),
        max_width = opts.width,
    })

    local content = label
    if opts.width then
        content = CenterContainer:new{
            dimen = Geom:new{ w = opts.width, h = label:getSize().h },
            label,
        }
    end
    return tappable(content, opts.callback)
end

--- A button showing an icon alone, in a square cell.
function Widgets.iconButton(icon, callback)
    local size = Screen:scaleBySize(40)
    return tappable(CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        IconWidget:new{ icon = icon, width = size, height = size },
    }, callback)
end

return Widgets
