-- Shared fullscreen thumbnail layout and pagination, without editing/export policy.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local PageTile = require("pagetile")
local COLUMNS = 3
local PageGrid = InputContainer:extend{}
function PageGrid:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.page = 1
    -- Open on the page being read, not on the first one; see _layout.
    self.reveal = self.document.current_page
    self:_layout()

    self.ges_events = {
        PanelSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function PageGrid:_layout()
    if self.holder and self.holder[1] then self.holder[1]:free() end
    self.holder = self.holder or WidgetContainer:new{}
    self[1] = self.holder

    local margin = Size.padding.large
    local avail_w = self.dimen.w - 2 * margin
    local tile_w = math.floor((avail_w - (COLUMNS - 1) * margin) / COLUMNS)
    local tile_h = math.floor(tile_w * 1.25)

    local header = self:_buildHeader()
    local footer = self._buildFooter and self:_buildFooter()
    local footer_h = footer and footer:getSize().h + margin or 0
    local rows_h = self.dimen.h - header:getSize().h - footer_h - 3 * margin
    local rows = math.max(1, math.floor((rows_h + margin) / (tile_h + margin)))
    self.per_page = rows * COLUMNS

    local count = self.document:pageCount()
    self.page_count = math.max(1, math.ceil(count / self.per_page))
    if self.page > self.page_count then self.page = self.page_count end

    --[[
    Bring the page that was asked for into view, if one was.

    Set when the panel opens, so it shows the page you are on rather than
    always the first, and again whenever an action moves the notebook to a page
    of its own making. Adding a page from the last tile of a full screen puts
    the new one on the next screen, and without this the grid stayed where it
    was: the button did nothing anyone could see, and the page it had just made
    was somewhere off to the right.

    Cleared once used, because turning the grid by hand goes through `_layout`
    too -- and a grid that jumped back to the current page every time it was
    swiped could not be paged through at all.
    ]]
    if self.reveal then
        self.page = math.max(1, math.min(math.ceil(self.reveal / self.per_page),
            self.page_count))
        self.reveal = nil
    end

    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1

    for r = 0, rows - 1 do
        local row = HorizontalGroup:new{ align = "top" }
        local any = false
        for c = 0, COLUMNS - 1 do
            local index = first + r * COLUMNS + c
            if index <= count then
                any = true
                if c > 0 then
                    table.insert(row, HorizontalSpan:new{ width = margin })
                end
                table.insert(row, PageTile:new{
                    document = self.document,
                    index = index,
                    width = tile_w,
                    height = tile_h,
                    current = not self.isSelected and index == self.document.current_page,
                    selected = self.isSelected and self:isSelected(index),
                    on_open = function(i) self:_goToPage(i) end,
                    on_hold = function(i) self:_actions(i) end,
                })
            end
        end
        if any then
            if r > 0 then table.insert(grid, VerticalSpan:new{ width = margin }) end
            table.insert(grid, row)
        end
    end

    self.holder[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = margin,
        width = self.dimen.w,
        height = self.dimen.h,
        VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = margin },
            grid,
            VerticalSpan:new{ width = footer and math.max(margin, rows_h - grid:getSize().h + margin) or 0 },
            footer,
        },
    }
end

function PageGrid:_turnPage(delta)
    if self.closed then return end
    local target = self.page + delta
    if target < 1 or target > self.page_count then return end
    self.page = target
    self:_layout()
    UIManager:setDirty("all", "ui")
end

function PageGrid:onPanelSwipe(_, ges)
    if ges.direction == "west" then
        self:_turnPage(1)
    elseif ges.direction == "east" then
        self:_turnPage(-1)
    else
        return false
    end
    return true
end

function PageGrid:onClose()
    UIManager:close(self, "ui")
    return true
end

function PageGrid:onCloseWidget()
    if self.closed then return end
    self.closed=true
    if self.on_closed then self.on_closed() end
    if self.holder and self.holder[1] then self.holder[1]:free() end
end

return PageGrid
