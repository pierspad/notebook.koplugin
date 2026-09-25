--[[--
The menu of things you can do to a notebook: an icon and a label per row.

KOReader's ButtonDialog only draws text, and a column of words all set in the
same weight is slow to scan -- you read every line to find the one you want. An
icon beside each is recognised without reading, and the label is still there for
the ones that are not obvious.

@module notebook.actionmenu
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
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Safe = require("safe")

local Screen = Device.screen

local ROW_H = Screen:scaleBySize(52)
local ICON_SZ = Screen:scaleBySize(26)

local function actionIsSelected(action)
    if type(action.selected) == "function" then
        -- Do not use Lua's `condition and value or fallback` idiom here:
        -- `false` is a meaningful result, and that idiom would replace it with
        -- the (truthy) function itself, making every selectable row look on.
        return action.selected() == true
    end
    return action.selected == true
end

-- Colour samples are painted directly. Rasterising a white SVG on some
-- Kindle/KOReader combinations flattens its transparent canvas to white, which
-- is why a selected circular swatch used to appear as a square.
local ColorSwatch = Widget:extend{
    color = "black",
    selected = false,
}

local SWATCH_COLORS = {
    black = Blitbuffer.ColorRGB32(0x00, 0x00, 0x00, 0xFF),
    red = Blitbuffer.ColorRGB32(0xE5, 0x39, 0x35, 0xFF),
    orange = Blitbuffer.ColorRGB32(0xFB, 0x8C, 0x00, 0xFF),
    yellow = Blitbuffer.ColorRGB32(0xFD, 0xD8, 0x35, 0xFF),
    green = Blitbuffer.ColorRGB32(0x43, 0xA0, 0x47, 0xFF),
    blue = Blitbuffer.ColorRGB32(0x1E, 0x88, 0xE5, 0xFF),
    purple = Blitbuffer.ColorRGB32(0x8E, 0x24, 0xAA, 0xFF),
    white = Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF),
}

local function swatchColor(color)
    local rgb = SWATCH_COLORS[color] or SWATCH_COLORS.black
    if Screen:isColorEnabled() then return rgb end
    return rgb:getColor8()
end

function ColorSwatch:init()
    self.dimen = Geom:new{ w = ICON_SZ, h = ICON_SZ }
end

function ColorSwatch:paintTo(bb, x, y)
    local cx, cy = x + math.floor(ICON_SZ / 2), y + math.floor(ICON_SZ / 2)
    local outer, inner = math.floor(ICON_SZ * 0.36), math.floor(ICON_SZ * 0.27)
    local color = swatchColor(self.color)
    if self.selected then
        bb:paintCircle(cx, cy, outer,
            self.color == "black" and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
    end
    bb:paintCircle(cx, cy, self.selected and inner or outer, color)
    if self.color == "white" and not self.selected then
        bb:paintCircle(cx, cy, outer, Blitbuffer.COLOR_BLACK)
        bb:paintCircle(cx, cy, inner, color)
    end
end

-- One row -------------------------------------------------------------------------

local Row = InputContainer:extend{
    icon = nil,
    text = nil,
    width = nil,
    callback = nil,
    icon_selected = nil,
    swatch = nil,
    icon_text = nil,
}

function Row:init()
    local pad = Size.padding.large
    self:_buildIcon()
    self.icon_holder = CenterContainer:new{
        dimen = Geom:new{ w = ICON_SZ, h = ROW_H },
        self.icon_widget,
    }
    self.label = TextWidget:new{
        text = self.text,
        bold = self.selected,
        fgcolor = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        face = Font:getFace("cfont", 19),
        max_width = self.width - ICON_SZ - 3 * pad,
    }

    self.frame = FrameContainer:new{
        background = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            self.icon_holder,
            HorizontalSpan:new{ width = pad },
            LeftContainer:new{
                -- Left-aligned: a column of centred labels of different lengths
                -- reads as ragged, and the eye has no edge to run down.
                dimen = Geom:new{ w = self.width - ICON_SZ - 3 * pad, h = ROW_H },
                self.label,
            },
            HorizontalSpan:new{ width = pad },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Row:_buildIcon()
    if self.swatch then
        self.icon_widget = ColorSwatch:new{ color = self.swatch, selected = self.selected }
    elseif self.icon_text then
        self.icon_widget = TextWidget:new{
            text = self.icon_text,
            face = Font:getFace(self.icon_font or "cfont", self.icon_size or 21),
            bold = self.icon_bold,
            fgcolor = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            max_width = ICON_SZ,
        }
    else
        self.icon_widget = IconWidget:new{
            icon = self.selected and self.icon_selected or self.icon,
            width = ICON_SZ, height = ICON_SZ,
            invert = self.selected and not self.icon_selected,
        }
    end
end

function Row:setSelected(selected)
    if self.selected == selected then return end
    self.selected = selected
    self.frame.background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    self.label.fgcolor = selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    self.label.bold = selected
    self:_buildIcon()
    self.icon_holder[1] = self.icon_widget
end

function Row:onTap()
    if self.callback then self.callback() end
    return true
end

-- The menu --------------------------------------------------------------------------

local ActionMenu = InputContainer:extend{
    title = nil,
    -- { { icon = "...", text = "...", callback = function() end }, ... }
    actions = nil,
    disable_double_tap = false,
    -- Optional canvas behind a tool popover. Starting a stroke on the page
    -- dismisses the popover without throwing away that first contact.
    draw_target = nil,
}

function ActionMenu:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    local width = self.width or math.floor(Screen:getWidth() * 0.62)
    local content = VerticalGroup:new{ align = "left" }
    self.action_rows = {}

    if self.title then
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = width, h = ROW_H },
            TextWidget:new{
                text = self.title,
                face = Font:getFace("tfont", 20),
                max_width = width - 2 * Size.padding.large,
            },
        })
        table.insert(content, LineWidget:new{
            dimen = Geom:new{ w = width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        })
    end

    local i = 1
    while i <= #(self.actions or {}) do
        local action = self.actions[i]
        if action.section then
            table.insert(content, CenterContainer:new{
                dimen = Geom:new{w=width, h=math.floor(ROW_H * 0.7)},
                TextWidget:new{text=action.section, face=Font:getFace("cfont", 17), bold=true},
            })
        end
        if i > 1 then
            table.insert(content, LineWidget:new{
                dimen = Geom:new{ w = width, h = Size.line.thin },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            })
        end
        local pair = action.swatch and self.actions[i + 1] and self.actions[i + 1].swatch
        local function makeRow(item)
        local row = Row:new{
            icon = item.icon,
            icon_selected = item.icon_selected,
            swatch = item.swatch,
            icon_text = item.icon_text,
            icon_font = item.icon_font,
            icon_size = item.icon_size,
            icon_bold = item.icon_bold,
            text = item.text,
            selected = actionIsSelected(item),
            width = pair and math.floor(width / 2) or width,
            callback = function()
                item.callback()
                self:_refreshRows()
            end,
        }
        self.action_rows[#self.action_rows + 1] = { row = row, action = item }
        return row
        end
        if pair then
            table.insert(content, HorizontalGroup:new{align="center", makeRow(action), makeRow(self.actions[i + 1])})
            i = i + 2
        else
            table.insert(content, makeRow(action))
            i = i + 1
        end
    end

    if self.footer then table.insert(content, self.footer) end

    self.panel = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        content,
    }

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.panel,
    }

    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if self.draw_target then
        self.ges_events.DrawOutside = {
            GestureRange:new{ ges = "touch", range = self.dimen },
        }
    end
    if self.tool_buttons then
        self.ges_events.ToolHold = {}
        self.ges_events.ToolDoubleTap = { event = "ToolDoubleTap" }
        for _, button in ipairs(self.tool_buttons) do
            self.ges_events.ToolHold[#self.ges_events.ToolHold + 1] =
                GestureRange:new{ ges = "hold", range = button.dimen }
            self.ges_events.ToolDoubleTap[#self.ges_events.ToolDoubleTap + 1] =
                GestureRange:new{ ges = "double_tap", range = button.dimen }
        end
    end
end

function ActionMenu:_isDrawableOutside(pos)
    if not self.draw_target or not pos then return false end
    local d = self.panel.dimen
    if d and pos.x >= d.x and pos.x <= d.x + d.w
        and pos.y >= d.y and pos.y <= d.y + d.h then
        return false
    end
    return self.draw_target:_withinContent(pos.x, pos.y,
        self.draw_target:widthFor(self.draw_target.tool))
end

-- Called directly by the canvas's raw stylus path, before KOReader turns the
-- contact into a gesture. Returning true lets that same sample become the
-- first point of the stroke after the menu has closed.
function ActionMenu:dismissForDrawing(slot)
    if not slot or slot.id == -1 then return false end
    local pos = slot.x and slot.y and { x = slot.x, y = slot.y }
    if not self:_isDrawableOutside(pos) then return false end
    UIManager:close(self)
    return true
end

-- Finger input already arrives as a gesture, so explicitly seed the canvas
-- with the touch that dismissed the menu. Pan and release events then reach
-- the canvas normally because the modal popover is gone.
function ActionMenu:onDrawOutside(_, ges)
    if not ges or not self:_isDrawableOutside(ges.pos) then return false end
    UIManager:close(self)
    self.draw_target:onTouchStart(nil, ges)
    return true
end

function ActionMenu:_refreshRows()
    for _, item in ipairs(self.action_rows) do
        item.row:setSelected(actionIsSelected(item.action))
    end
    UIManager:setDirty(self, "ui", self.panel.dimen)
end

function ActionMenu:_toolAt(pos)
    if not pos then return end
    for i, button in ipairs(self.tool_buttons or {}) do
        local d = button.dimen
        if pos.x >= d.x and pos.x <= d.x + d.w and pos.y >= d.y and pos.y <= d.y + d.h then
            return i
        end
    end
end

function ActionMenu:onToolHold(_, ges)
    local index = self:_toolAt(ges and ges.pos)
    if index and self.on_tool_options then self.on_tool_options(index) end
    return index ~= nil
end

function ActionMenu:onToolDoubleTap(_, ges)
    return self:onToolHold(nil, ges)
end

function ActionMenu:paintTo(bb, x, y)
    if not self.anchor then return InputContainer.paintTo(self, bb, x, y) end
    local sz = self.panel:getSize()
    local px = math.max(0, math.min(self.anchor.x, Screen:getWidth()-sz.w))
    local py = math.max(0, math.min(self.anchor.y+self.anchor.h, Screen:getHeight()-sz.h))
    self.panel:paintTo(bb, px, py)
end

function ActionMenu:onTapClose(_, ges)
    if ges and ges.pos and self.panel.dimen
        and ges.pos:intersectWith(self.panel.dimen) then
        -- Inside the panel: let the rows handle it.
        return false
    end
    UIManager:close(self)
    return true
end

function ActionMenu:onClose()
    UIManager:close(self)
    return true
end

function ActionMenu:onShow()
    UIManager:setDirty(self, "ui", self.panel.dimen)
    return true
end

function ActionMenu:onCloseWidget()
    -- What was underneath may have been painted outside UIManager's accounting,
    -- so ask for the area back rather than assuming it will be restored.
    UIManager:setDirty(nil, "ui")
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(ActionMenu, "action menu")
