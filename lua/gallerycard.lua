-- Gallery card presentation and pixel rendering, independent of gallery actions.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local _ = require("i18n")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local function isExport(item) return item.is_export or item.is_pdf or item.is_xopp end
local function thumbSize(card_w, card_h)
    return card_w - 2 * Size.border.thin,
           card_h - Screen:scaleBySize(40) - 2 * Size.border.thin
end

local Card = InputContainer:extend{
    item = nil,
    width = nil,
    height = nil,
    -- Path of an already-rendered thumbnail, or nil to show a placeholder.
    thumb = nil,
    -- nil outside selection mode; true or false while choosing.
    selected = nil,
    on_open = nil,
    on_hold = nil,
}

function Card:init()
    local label_h = Screen:scaleBySize(40)
    local thumb_w, thumb_h = thumbSize(self.width, self.height)

    local picture
    if self.item.is_folder then
        picture = IconWidget:new{
            icon = "notebook.folder",
            width = math.floor(thumb_h * 0.55),
            height = math.floor(thumb_h * 0.55),
        }
    elseif self.thumb then
        picture = ImageWidget:new{
            file = self.thumb,
            width = thumb_w,
            height = thumb_h,
        }
    else
        -- Nothing written yet, the notebook this PDF came from is gone, or the
        -- picture has not been drawn yet: show it as the blank page it is,
        -- rather than a broken image.
        picture = IconWidget:new{
            icon = "notebook.page",
            width = math.floor(thumb_h * 0.4),
            height = math.floor(thumb_h * 0.4),
        }
    end

    local caption = self.item.name

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = thumb_h },
                picture,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = label_h },
                TextWidget:new{
                    text = caption,
                    face = Font:getFace("cfont", 17),
                    max_width = thumb_w - 2 * Size.padding.small,
                },
            },
        },
    }
    if isExport(self.item) then
        self.ribbon = TextWidget:new{
            text = self.item.is_svg and _("SVG") or (self.item.is_xopp and _("XOPP") or _("PDF")),
            face = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_WHITE,
            bold = true,
        }
    end

    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

--[[--
Puts back the rounded corners a full-bleed picture painted over.

The frame draws its rounded border first and the thumbnail is blitted into it
afterwards, as a plain rectangle filling the card's whole width. So the two top
corners -- the only ones the picture reaches -- came out square, while the
folder cards, whose icon is small and centred, and the bottom of every card,
which is the white caption strip, kept theirs. One card in a grid with two
corners of the wrong shape looks like a rendering fault, which is what it was.

Cheaper than clipping the image: the corner is a few dozen pixels, and the
alternative is a bounds test per pixel blitted.
--]]
local function restoreCorners(bb, x, y, w, h, r)
    if r < 1 then return end
    for dy = 0, r - 1 do
        -- How far in the card's edge sits on this row: the horizontal distance
        -- from the corner's centre out to the quarter circle.
        local o = r - dy - 0.5
        local dx = r - math.floor(math.sqrt(r * r - o * o) + 0.5)
        if dx > 0 then
            bb:paintRect(x, y + dy, dx, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - dx, y + dy, dx, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + h - 1 - dy, dx, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - dx, y + h - 1 - dy, dx, 1, Blitbuffer.COLOR_WHITE)
        end
    end
    bb:paintBorder(x, y, w, h, Size.border.thin, Blitbuffer.COLOR_BLACK, r)
end

--- Paints the card, the PDF ribbon over its corner, and the selection mark.
function Card:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)

    if self.ribbon then
        local pad = Size.padding.default
        local size = self.ribbon:getSize()
        bb:paintRect(x + Size.border.thin, y + Size.border.thin,
            size.w + 4 * pad, size.h + 2 * pad, Blitbuffer.COLOR_BLACK)
        self.ribbon:paintTo(bb,
            x + Size.border.thin + 2 * pad,
            y + Size.border.thin + pad)
    end

    -- After the ribbon, which is itself a square block laid over one corner.
    restoreCorners(bb, x, y, self.dimen.w, self.dimen.h, Size.radius.button)

    if self.selected ~= nil then
        -- A filled disc for chosen, an empty ring for not. On e-ink the two
        -- have to differ in how much black there is, not in a small detail like
        -- a tick, which vanishes at this size under a fast waveform.
        local r = Screen:scaleBySize(16)
        local pad = Size.padding.default
        local cx = x + self.dimen.w - r - pad
        local cy = y + r + pad
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
        if self.selected then
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK)
        else
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, 2)
        end
    end
end

--- The ribbon hangs off the card rather than sitting in it, so free it by hand.
function Card:free(full)
    InputContainer.free(self, full)
    if self.ribbon then self.ribbon:free(full) end
end

function Card:onTap()
    if self.on_open then self.on_open(self.item) end
    return true
end

function Card:onHold()
    if self.on_hold then self.on_hold(self.item) end
    return true
end

Card.thumbSize = thumbSize
return Card
