--[[--
The background chooser.

Shown as a grid of samples of the paper itself rather than a list of names.
"Dot grid" and "Narrow lined" are words you have to translate into a picture
before you can decide; a square of the actual ruling is the decision. It is the
same reasoning as the stroke-width samples in the settings panel, and it matters
more here, because the difference between two rulings is exactly the kind of
thing a name cannot carry.

@module notebook.templatepicker
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local PaperSample = require("papersample")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widgets = require("widgets")
local Safe = require("safe")

local Screen = Device.screen


-- The picker ---------------------------------------------------------------------

local TemplatePicker = InputContainer:extend{
    title = nil,
    -- Background currently in force, drawn as chosen.
    current = nil,
    -- Called with the chosen id. The picker closes itself first.
    on_pick = nil,
    -- Optional extra row under the samples: { text = ..., callback = ... }.
    extra = nil,
}

function TemplatePicker:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.modal = true

    local width = math.floor(Screen:getWidth() * 0.86)
    local gap = Size.padding.large

    local content = VerticalGroup:new{ align = "center" }

    table.insert(content, VerticalSpan:new{ width = gap })
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = width, h = Screen:scaleBySize(44) },
        TextWidget:new{
            text = self.title,
            face = Font:getFace("tfont", 20),
            max_width = width - 2 * gap,
        },
    })

    table.insert(content, VerticalSpan:new{ width = gap })
    local samples = PaperSample.grid(width - 2 * gap, gap, self.current,
        function(id) self:_pick(id) end)
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = width, h = samples:getSize().h },
        samples,
    })

    if self.extra then
        table.insert(content, VerticalSpan:new{ width = gap })
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = width, h = Screen:scaleBySize(46) },
            self:_extraButton(width - 2 * gap),
        })
    end

    table.insert(content, VerticalSpan:new{ width = gap })

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

function TemplatePicker:_extraButton(width)
    local picker = self
    return Widgets.textButton{
        text = self.extra.text,
        width = width,
        callback = function()
            UIManager:close(picker)
            picker.extra.callback()
        end,
    }
end

function TemplatePicker:_pick(id)
    UIManager:close(self)
    if self.on_pick then self.on_pick(id) end
end

function TemplatePicker:onTapClose(_, ges)
    if ges and ges.pos and self.panel.dimen
        and ges.pos:intersectWith(self.panel.dimen) then
        return false
    end
    UIManager:close(self)
    if self.on_cancel then self.on_cancel() end
    return true
end

function TemplatePicker:onClose()
    UIManager:close(self)
    if self.on_cancel then self.on_cancel() end
    return true
end

function TemplatePicker:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function TemplatePicker:onCloseWidget()
    -- What was underneath may have been painted outside UIManager's accounting.
    UIManager:setDirty("all", "ui")
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(TemplatePicker, "paper picker")
