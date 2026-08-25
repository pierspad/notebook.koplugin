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
local Safe = require("safe")

local Screen = Device.screen

local ROW_H = Screen:scaleBySize(52)
local ICON_SZ = Screen:scaleBySize(26)

-- One row -------------------------------------------------------------------------

local Row = InputContainer:extend{
    icon = nil,
    text = nil,
    width = nil,
    callback = nil,
}

function Row:init()
    local pad = Size.padding.large

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            CenterContainer:new{
                dimen = Geom:new{ w = ICON_SZ, h = ROW_H },
                IconWidget:new{ icon = self.icon, width = ICON_SZ, height = ICON_SZ },
            },
            HorizontalSpan:new{ width = pad },
            LeftContainer:new{
                -- Left-aligned: a column of centred labels of different lengths
                -- reads as ragged, and the eye has no edge to run down.
                dimen = Geom:new{ w = self.width - ICON_SZ - 3 * pad, h = ROW_H },
                TextWidget:new{
                    text = self.text,
                    face = Font:getFace("cfont", 19),
                    max_width = self.width - ICON_SZ - 3 * pad,
                },
            },
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
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
}

function ActionMenu:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    local width = math.floor(Screen:getWidth() * 0.62)
    local content = VerticalGroup:new{ align = "left" }

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

    for i, action in ipairs(self.actions or {}) do
        if i > 1 then
            table.insert(content, LineWidget:new{
                dimen = Geom:new{ w = width, h = Size.line.thin },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            })
        end
        table.insert(content, Row:new{
            icon = action.icon,
            text = action.text,
            width = width,
            callback = function()
                UIManager:close(self)
                action.callback()
            end,
        })
    end

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
