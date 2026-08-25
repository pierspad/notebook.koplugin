--[[--
Creating a notebook: its name and its paper, in one screen.

It used to be two: type a name, then pick the paper. Two steps for one decision,
and the second one arrived after the first had already been committed to, which
made the paper feel like an afterthought rather than part of what a notebook is.

The keyboard takes the lower half of the panel, so everything else sits at the
top and the layout is worked out from what is left. That is also why this is
built here rather than on InputDialog: the dialog does not take a widget of its
own, and the paper has to be shown as paper -- a list of names would defeat the
point of choosing it at all.

@module notebook.newnotebook
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
local InputText = require("ui/widget/inputtext")
local PaperSample = require("papersample")
local Size = require("ui/size")
local Template = require("template")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widgets = require("widgets")
local _ = require("i18n")
local Safe = require("safe")

local Screen = Device.screen

-- Height left clear at the top of the screen for the system status bar, the
-- same band the notebook keeps clear. Without it the panel is flush against the
-- top edge, with the clock and the battery sitting on its border.
local TOP_INSET = Screen:scaleBySize(34)

local NewNotebook = InputContainer:extend{
    -- Sits underneath VirtualKeyboard on the window stack, so UIManager requires
    -- is_always_active = true to deliver touch events (buttons, samples) here.
    is_always_active = true,
    -- Name offered to begin with, already selected in the field.
    name = nil,
    -- Called with the name and the paper when the reader is done.
    on_create = nil,
}

function NewNotebook:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.modal = true
    self.paper = Template.DEFAULT

    local gap = Size.padding.large
    local width = math.floor(Screen:getWidth() * 0.86)
    local inner = width - 2 * gap

    self.input = InputText:new{
        text = self.name or "",
        hint = _("Notebook name"),
        face = Font:getFace("cfont", 20),
        width = inner,
        parent = self,
        focused = true,
        scroll = false,
        cursor_at_end = true,
        enter_callback = function() self:_submit() end,
    }

    local title_h = Screen:scaleBySize(46)
    local buttons_h = Screen:scaleBySize(52)

    --[[
    What is left for the samples once everything else has had its share.

    The keyboard is up the whole time this screen is, and it takes the bottom
    of the panel with it: sized to the width alone, the grid pushed the Cancel
    and Create buttons underneath it, where they cannot be tapped and cannot be
    seen -- and since a tap inside the panel is not a tap outside it, there was
    then no way to leave this screen at all.

    The keyboard's height is known before it is shown, because the text field
    builds it when it is built, so this does not have to be guessed at.
    --]]
    local keyboard = self.input:getKeyboardDimen()
    local keyboard_h = (keyboard and keyboard.h) or 0
    local fixed = 5 * gap + title_h + self.input:getSize().h + buttons_h
        + 2 * Size.border.window
    local room = Screen:getHeight() - TOP_INSET - keyboard_h - gap - fixed

    self.content = VerticalGroup:new{ align = "center" }
    table.insert(self.content, VerticalSpan:new{ width = gap })
    table.insert(self.content, CenterContainer:new{
        dimen = Geom:new{ w = width, h = title_h },
        TextWidget:new{
            text = _("New notebook"),
            face = Font:getFace("tfont", 22),
            max_width = inner,
        },
    })
    table.insert(self.content, VerticalSpan:new{ width = gap })
    table.insert(self.content, CenterContainer:new{
        dimen = Geom:new{ w = width, h = self.input:getSize().h },
        self.input,
    })
    table.insert(self.content, VerticalSpan:new{ width = gap })

    self.samples = PaperSample.grid(inner, gap, self.paper, function(id)
        self:_choose(id)
    end, room)
    table.insert(self.content, CenterContainer:new{
        dimen = Geom:new{ w = width, h = self.samples:getSize().h },
        self.samples,
    })

    table.insert(self.content, VerticalSpan:new{ width = gap })
    table.insert(self.content, CenterContainer:new{
        dimen = Geom:new{ w = width, h = buttons_h },
        self:_buttons(inner, gap),
    })
    table.insert(self.content, VerticalSpan:new{ width = gap })

    self.panel = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        self.content,
    }

    -- Held to the top of the screen, because the keyboard owns the bottom of
    -- it -- but below the status bar, not underneath it. Centring the panel in
    -- a box one inset taller than itself is what puts the inset above it.
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.dimen.w,
            h = self.panel:getSize().h + 2 * TOP_INSET,
        },
        self.panel,
    }

    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device.hasKeys and Device:hasKeys() and Device.input and Device.input.group and Device.input.group.Back then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

function NewNotebook:_buttons(width, gap)
    local row = HorizontalGroup:new{ align = "center" }
    local button_w = math.floor((width - gap) / 2)

    table.insert(row, Widgets.textButton{
        text = _("Cancel"),
        width = button_w,
        callback = function() self:_close() end,
    })
    table.insert(row, HorizontalSpan:new{ width = gap })
    table.insert(row, Widgets.textButton{
        text = _("Create"),
        width = button_w,
        callback = function() self:_submit() end,
    })
    return row
end

--[[--
Marks the chosen paper.

The samples are rebuilt rather than repainted in place: a sample draws its own
state, and the cheapest correct way to change which one is chosen is to build
the row again from the new answer.
--]]
function NewNotebook:_choose(id)
    if self.paper == id then return end
    self.paper = id
    for _, sample in ipairs(self:_sampleWidgets()) do
        sample.selected = sample.id == id
    end
    UIManager:setDirty(self, "ui", self.panel.dimen)
end

function NewNotebook:_sampleWidgets(node, found)
    node = node or self.samples
    found = found or {}
    if type(node) ~= "table" then return found end
    if node.id and node.callback then table.insert(found, node) end
    for _, child in ipairs(node) do self:_sampleWidgets(child, found) end
    return found
end

function NewNotebook:_submit()
    local name = self.input:getText()
    self:_close()
    if self.on_create then self.on_create(name, self.paper) end
end

function NewNotebook:_close()
    self.input:onCloseKeyboard()
    UIManager:close(self)
end

function NewNotebook:onTapClose(_, ges)
    if ges and ges.pos and self.panel.dimen
        and ges.pos:intersectWith(self.panel.dimen) then
        return false
    end
    self:_close()
    return true
end

function NewNotebook:onClose()
    self:_close()
    return true
end

--- InputText closes its dialog through this when the keyboard asks it to.
function NewNotebook:onCloseDialog()
    self:_close()
end

function NewNotebook:onShow()
    UIManager:setDirty(self, "ui")
    self.input:onShowKeyboard()
    return true
end

function NewNotebook:onCloseWidget()
    UIManager:setDirty("all", "ui")
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(NewNotebook, "new notebook")
