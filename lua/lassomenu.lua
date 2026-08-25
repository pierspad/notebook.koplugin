--[[--
Floating interactive toolbar displayed directly above/below lasso-selected strokes.

Offers Cut, Copy, Paste, Delete, and Deselect actions, and allows moving the selection.

@module notebook.lassomenu
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
local UIManager = require("ui/uimanager")
local _ = require("i18n")
local Safe = require("safe")

local Screen = Device.screen

local BTN_H = Screen:scaleBySize(44)
local ICON_SZ = Screen:scaleBySize(22)

-- A single button in the floating bar
local FloatingButton = InputContainer:extend{
    icon = nil,
    text = nil,
    callback = nil,
}

function FloatingButton:init()
    local pad = Size.padding.default
    local children = { HorizontalSpan:new{ width = pad } }

    if self.icon then
        table.insert(children, CenterContainer:new{
            dimen = Geom:new{ w = ICON_SZ, h = BTN_H },
            IconWidget:new{ icon = self.icon, width = ICON_SZ, height = ICON_SZ },
        })
        table.insert(children, HorizontalSpan:new{ width = Size.padding.small })
    end

    if self.text then
        table.insert(children, TextWidget:new{
            text = self.text,
            face = Font:getFace("cfont", 17),
        })
        table.insert(children, HorizontalSpan:new{ width = pad })
    end

    local btn_group = HorizontalGroup:new{ align = "center" }
    for _, child in ipairs(children) do
        table.insert(btn_group, child)
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = Size.padding.button,
        btn_group,
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function FloatingButton:onTap()
    if self.callback then self.callback() end
    return true
end

-- The floating lasso toolbar
local LassoMenu = InputContainer:extend{
    bbox = nil, -- { x, y, w, h }
    on_cut = nil,
    on_copy = nil,
    on_paste = nil,
    on_delete = nil,
    on_close = nil,
    has_clipboard = false,
}

function LassoMenu:init()
    local buttons = HorizontalGroup:new{ align = "center" }
    local pad = Size.padding.small

    -- 1. Taglia (Cut)
    table.insert(buttons, FloatingButton:new{
        icon = "notebook.cut",
        text = _("Cut"),
        callback = function()
            UIManager:close(self)
            if self.on_cut then self.on_cut() end
        end,
    })
    table.insert(buttons, HorizontalSpan:new{ width = pad })

    -- 2. Copia (Copy)
    table.insert(buttons, FloatingButton:new{
        icon = "notebook.copy",
        text = _("Copy"),
        callback = function()
            UIManager:close(self)
            if self.on_copy then self.on_copy() end
        end,
    })
    table.insert(buttons, HorizontalSpan:new{ width = pad })

    -- 3. Incolla (Paste - if clipboard has items)
    if self.has_clipboard then
        table.insert(buttons, FloatingButton:new{
            icon = "notebook.paste",
            text = _("Paste"),
            callback = function()
                UIManager:close(self)
                if self.on_paste then self.on_paste() end
            end,
        })
        table.insert(buttons, HorizontalSpan:new{ width = pad })
    end

    -- 4. Elimina (Delete)
    table.insert(buttons, FloatingButton:new{
        icon = "notebook.delete",
        text = _("Delete"),
        callback = function()
            UIManager:close(self)
            if self.on_delete then self.on_delete() end
        end,
    })
    table.insert(buttons, HorizontalSpan:new{ width = pad })

    -- 5. Chiudi (Deselect)
    table.insert(buttons, FloatingButton:new{
        icon = "close",
        text = _("Close"),
        callback = function()
            UIManager:close(self)
            if self.on_close then self.on_close() end
        end,
    })

    self.content_frame = FrameContainer:new{
        bordersize = 0,
        margin = 0,
        padding = 0,
        buttons,
    }

    local menu_sz = self.content_frame:getSize()

    -- Position floating menu right above the selection bbox (or below if too high)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local top_margin = Screen:scaleBySize(90)

    local mx = math.floor(self.bbox.x + (self.bbox.w - menu_sz.w) / 2)
    if mx < Size.padding.default then mx = Size.padding.default end
    if mx + menu_sz.w > screen_w - Size.padding.default then
        mx = screen_w - menu_sz.w - Size.padding.default
    end

    local my = self.bbox.y - menu_sz.h - Size.padding.default
    if my < top_margin then
        my = self.bbox.y + self.bbox.h + Size.padding.default
    end
    if my + menu_sz.h > screen_h - Size.padding.default then
        my = screen_h - menu_sz.h - Size.padding.default
    end

    self.dimen = Geom:new{ x = mx, y = my, w = menu_sz.w, h = menu_sz.h }
    self[1] = self.content_frame

    --[[
    The range is the placed rectangle, not a fresh one of the same size.

    A gesture range is matched against the touch's position on the screen, so a
    Geom left at the origin is a live tap zone in the top left corner of the
    panel -- which is where the tool buttons are. Landing there matched this
    menu, and a Tap that this class does not handle is passed down to its
    children, where the first thing with an onTap is Cut. Selecting something
    and then reaching for the pen button cut the selection instead.

    self.dimen and nothing else, because paintTo places the frame by it: one
    rectangle, so where the menu is drawn and where it answers cannot drift
    apart.
    --]]
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function LassoMenu:paintTo(bb, x, y)
    self.content_frame:paintTo(bb, self.dimen.x, self.dimen.y)
end

return Safe.widget(LassoMenu, "lassomenu")
