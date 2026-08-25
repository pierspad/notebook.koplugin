--[[--
A square of paper, drawn as the paper it stands for.

"Dot grid" and "Narrow lined" are words you have to turn into a picture before
you can decide between them; a patch of the actual ruling is the decision. Used
both when creating a notebook and when changing the paper of one that exists, so
the same choice looks the same in both places.

@module notebook.papersample
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
local Template = require("template")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local COLUMNS = 3

-- One sample --------------------------------------------------------------------

local Sample = InputContainer:extend{
    id = nil,
    label = nil,
    width = nil,
    height = nil,
    selected = false,
    callback = nil,
}

function Sample:init()
    local label = TextWidget:new{
        text = self.label,
        face = Font:getFace("cfont", 16),
        max_width = self.width,
    }
    self.label_h = label:getSize().h + Size.padding.small

    self.paper_w = self.width - 2 * Size.border.thin
    self.paper_h = self.height - self.label_h - 2 * Size.border.thin

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = self.selected and Size.border.thick or Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            -- The paper itself is painted over this space; see paintTo.
            VerticalSpan:new{ width = self.paper_h },
            CenterContainer:new{
                dimen = Geom:new{ w = self.paper_w, h = self.label_h },
                label,
            },
        },
    }

    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

-- A sample is drawn larger than true scale, as though it were a corner of the
-- page seen close up. At true scale a box this size would hold two lines of
-- ruling, which is not enough to tell any two of these apart; magnified, the
-- differences between them are the whole content of the picture. The number is
-- the page height a sample pretends to be.
local SAMPLE_PAGE_H = 620

--- Paints the frame, then a magnified corner of the paper inside it.
function Sample:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)

    local inset = Size.border.thin
    local paper = {
        x = x + inset,
        y = y + inset,
        w = self.paper_w,
        h = self.paper_h,
    }
    -- Clipped to the paper. A checklist's box sits above the line it belongs to,
    -- so the topmost one reached past the sample and was drawn over the card's
    -- border and its label.
    Template.draw(bb, self.id, paper, self.paper_h / SAMPLE_PAGE_H, paper)

    if self.selected then
        -- A tick would need an icon and a place to put it; a heavier border
        -- reads immediately and cannot cover any of the sample.
        bb:paintBorder(x, y, self.dimen.w, self.dimen.h,
            Size.border.thick, Blitbuffer.COLOR_BLACK, Size.radius.button)
    end
end

function Sample:onTap()
    if self.callback then self.callback(self.id) end
    return true
end


-- A sample is this much taller than it is wide, so it reads as a page rather
-- than as a tile.
local CELL_RATIO = 1.15

-- No sample is useful below this: the ruling it is showing stops being legible.
local MIN_CELL_W = 48

--- How many rows of samples there are, for a caller budgeting height.
local function rows()
    return math.ceil(#Template.list() / COLUMNS)
end

--[[--
Every paper laid out as a grid of samples, sized to `width`.

Returned as a widget rather than shown, so the same grid can sit inside a dialog
that is asking for other things at the same time.

`max_height`, when given, is a hard ceiling: the samples shrink to fit it rather
than the grid growing past it. The screen that creates a notebook has a keyboard
across the bottom half, and a grid sized only to the width ran underneath it and
took the Cancel and Create buttons with it -- leaving a panel with no visible
way out of it at all.
--]]
local function grid(width, gap, current, on_pick, max_height)
    local cell_w = math.floor((width - (COLUMNS - 1) * gap) / COLUMNS)
    local cell_h = math.floor(cell_w * CELL_RATIO)

    if max_height then
        local n = rows()
        local fits = math.floor((max_height - (n - 1) * gap) / n)
        if fits < cell_h then
            -- Both dimensions, not just the height: a sample squashed in one
            -- direction stops looking like a piece of paper.
            cell_h = math.max(fits, math.floor(MIN_CELL_W * CELL_RATIO))
            cell_w = math.floor(cell_h / CELL_RATIO)
        end
    end

    local column = VerticalGroup:new{ align = "center" }
    local row
    for i, entry in ipairs(Template.list()) do
        if (i - 1) % COLUMNS == 0 then
            row = HorizontalGroup:new{ align = "top" }
            if i > 1 then
                table.insert(column, VerticalSpan:new{ width = gap })
            end
            table.insert(column, CenterContainer:new{
                dimen = Geom:new{ w = width, h = cell_h },
                row,
            })
        else
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        table.insert(row, Sample:new{
            id = entry.id,
            label = entry.name,
            width = cell_w,
            height = cell_h,
            selected = entry.id == current,
            callback = on_pick,
        })
    end
    return column
end

return {
    Sample = Sample,
    grid = grid,
    rows = rows,
    COLUMNS = COLUMNS,
}
