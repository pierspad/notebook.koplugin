-- A thumbnail tile shared by navigation and export selection.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Renderer = require("renderer")
local Size = require("ui/size")
local Template = require("template")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local PageTile = InputContainer:extend{
    document = nil,
    index = nil,
    width = nil,
    height = nil,
    current = false,
    on_open = nil,
    on_hold = nil,
}

function PageTile:init()
    local number = TextWidget:new{
        text = (self.selected == nil and "" or (self.selected and "☑ " or "☐ ")) .. tostring(self.index),
        face = Font:getFace("cfont", 16),
    }
    self.label_h = number:getSize().h + Size.padding.small
    self.paper_w = self.width - 2 * Size.border.thin
    self.paper_h = self.height - self.label_h - 2 * Size.border.thin

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = self.paper_h },
            CenterContainer:new{
                dimen = Geom:new{ w = self.paper_w, h = self.label_h },
                number,
            },
        },
    }

    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

--- Paints the tile, then the page itself, shrunk to fit inside it.
function PageTile:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)

    local page = self.document.pages[self.index]
    if not page then return end

    local inset = Size.border.thin
    local px, py = x + inset, y + inset
    -- Strokes are stored in the coordinate space of the panel, so that is what
    -- has to be fitted into the tile.
    local scale = math.min(self.paper_w / Screen:getWidth(),
                           self.paper_h / Screen:getHeight())

    local paper = { x = px, y = py, w = self.paper_w, h = self.paper_h }
    --[[
    The background starts at the origin the strokes are in, not at the corner
    of the tile.

    A stroke is stored in the coordinates the canvas received it in, so every
    point carries the height of the toolbar above the drawing area in its y.
    Ruling the tile from its own top left put the lines a scaled toolbar's
    height above the writing that had been done on them, and every tile in the
    overview showed handwriting floating between the lines it was sitting on
    while it was written. The thumbnails on the gallery cards already do this;
    see Document:contentOrigin and Thumbnail.get.
    ]]
    local origin_x, origin_y = self.document:contentOrigin()
    local ruling = {
        x = px + origin_x * scale,
        y = py + origin_y * scale,
        w = self.paper_w,
        h = self.paper_h,
    }
    -- Clipped to the paper: a checklist's boxes hang above their line and would
    -- otherwise be drawn over the tile's border and the tile beside it.
    Template.draw(bb, self.document:templateFor(self.index), ruling, scale, paper)
    if page.background then
        local size=self.document.page_size or {w=self.paper_w/scale,h=self.paper_h/scale}
        require("pdfbackground").draw(bb,page.background,
            {x=ruling.x,y=ruling.y,w=size.w*scale,h=size.h*scale},paper)
    end
    Renderer.drawPage(bb, page, scale, px, py)

    if self.current then
        bb:paintBorder(x, y, self.dimen.w, self.dimen.h,
            Size.border.thick, Blitbuffer.COLOR_BLACK, Size.radius.button)
    end
end

function PageTile:onTap()
    if self.on_open then self.on_open(self.index) end
    return true
end

function PageTile:onHold()
    if self.on_hold then self.on_hold(self.index) end
    return true
end

return PageTile
