--[[--
The page overview: every page of the notebook at a glance.

A notebook you can only walk through one page at a time is a scroll, not a
notebook. This is the part that makes it a book: see all the pages, go straight
to one, put a new one in the middle, throw one away.

Reached by tapping the page counter in the toolbar. That was already the place
you look to find out where you are, and the toolbar has no room for another
button without shrinking the ones that are there.

The pages are drawn straight into the panel at a reduced scale rather than
rasterised into images first. They are already in memory -- unlike the gallery's
notebooks, which have to be read off disk -- so there is nothing to cache, no
buffers to own, and nothing that has to happen before the panel can appear.

@module notebook.pagepanel
--]]--

local ActionMenu = require("actionmenu")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Renderer = require("renderer")
local Size = require("ui/size")
local Template = require("template")
local TemplatePicker = require("templatepicker")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widgets = require("widgets")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("i18n")
local Safe = require("safe")
local T = require("ffi/util").template

local Screen = Device.screen

local COLUMNS = 3

-- One page ------------------------------------------------------------------------

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
        text = tostring(self.index),
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
    -- Clipped to the paper: a checklist's boxes hang above their line and would
    -- otherwise be drawn over the tile's border and the tile beside it.
    Template.draw(bb, self.document:templateFor(self.index), paper, scale, paper)
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

-- The panel -------------------------------------------------------------------------

local PagePanel = InputContainer:extend{
    document = nil,
    -- Called when the notebook has been changed and the page behind us with it.
    on_change = nil,
    -- Called with a page number when the reader wants to go there.
    on_goto = nil,
}

function PagePanel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.page = 1
    self:_layout()

    self.ges_events = {
        PanelSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function PagePanel:_layout()
    if self.holder and self.holder[1] then self.holder[1]:free() end
    self.holder = self.holder or WidgetContainer:new{}
    self[1] = self.holder

    local margin = Size.padding.large
    local avail_w = self.dimen.w - 2 * margin
    local tile_w = math.floor((avail_w - (COLUMNS - 1) * margin) / COLUMNS)
    local tile_h = math.floor(tile_w * 1.25)

    local header = self:_buildHeader()
    local rows_h = self.dimen.h - header:getSize().h - 3 * margin
    local rows = math.max(1, math.floor((rows_h + margin) / (tile_h + margin)))
    self.per_page = rows * COLUMNS

    local count = self.document:pageCount()
    self.page_count = math.max(1, math.ceil(count / self.per_page))
    if self.page > self.page_count then self.page = self.page_count end

    -- Opening the panel should show the page you are on, not always the first.
    if not self._placed then
        self.page = math.ceil(self.document.current_page / self.per_page)
        self._placed = true
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
                    current = index == self.document.current_page,
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
        },
    }
end

function PagePanel:_buildHeader()
    local row = HorizontalGroup:new{ align = "center" }
    table.insert(row, TextWidget:new{
        text = T(_("Pages (%1)"), self.document:pageCount()),
        face = Font:getFace("tfont", 22),
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.large })
    table.insert(row, Widgets.textButton{
        text = _("New page"), icon = "notebook.page",
        callback = function() self:_insertAfter(self.document.current_page) end,
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.large })
    table.insert(row, Widgets.textButton{
        text = _("Notebook background"), icon = "notebook.page",
        callback = function() self:_pickNotebookTemplate() end,
    })
    table.insert(row, HorizontalSpan:new{ width = Size.padding.large })
    -- A left chevron, the same one every other screen leaves by: an open-book
    -- glyph on a button that closes the page said the opposite of what it does.
    table.insert(row, Widgets.textButton{
        text = _("Done"), icon = "chevron.left",
        callback = function() self:onClose() end,
    })
    return row
end

-- Actions ---------------------------------------------------------------------------

function PagePanel:_refresh()
    self:_layout()
    UIManager:setDirty("all", "ui")
    if self.on_change then self.on_change() end
end

function PagePanel:_goToPage(index)
    UIManager:close(self)
    if self.on_goto then self.on_goto(index) end
end

function PagePanel:_insertAfter(index)
    local n = self.document:insertPage(index)
    self:_refresh()
    return n
end

function PagePanel:_actions(index)
    local actions = {
        { icon = "notebook.open", text = _("Go to this page"),
          callback = function() self:_goToPage(index) end },
        { icon = "notebook.page", text = _("Insert a page after this one"),
          callback = function() self:_insertAfter(index) end },
        { icon = "notebook.duplicate", text = _("Duplicate"),
          callback = function()
              self.document:duplicatePage(index)
              self:_refresh()
          end },
        { icon = "notebook.page", text = _("Background of this page"),
          callback = function() self:_pickPageTemplate(index) end },
    }

    -- Offered only when there is more than one page: a notebook always has at
    -- least one, so on the last page the entry would exist purely to refuse.
    if self.document:pageCount() > 1 then
        table.insert(actions, {
            icon = "notebook.delete", text = _("Delete"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete page %1 and everything on it?"), index),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self.document:deletePage(index)
                        self:_refresh()
                    end,
                })
            end,
        })
    end

    UIManager:show(ActionMenu:new{
        title = T(_("Page %1"), index),
        actions = actions,
    })
end

function PagePanel:_pickPageTemplate(index)
    local page = self.document.pages[index]
    UIManager:show(TemplatePicker:new{
        title = T(_("Background of page %1"), index),
        current = self.document:templateFor(index),
        on_pick = function(id)
            self.document:setPageTemplate(index, id)
            self:_refresh()
        end,
        extra = page and page.template and {
            text = _("Follow the notebook again"),
            callback = function()
                self.document:setPageTemplate(index, nil)
                self:_refresh()
            end,
        } or nil,
    })
end

--[[--
Changes the notebook's background.

Pages that were given a background of their own keep it, which is the right
default -- that was a deliberate choice -- but it does mean one tap does not
always change everything. So when, and only when, such a page exists, the picker
carries a second line that says so and offers to sweep them all.
--]]
function PagePanel:_pickNotebookTemplate()
    local function show(clear_overrides)
        UIManager:show(TemplatePicker:new{
            title = clear_overrides and _("Background for every page")
                                    or _("Notebook background"),
            current = self.document.template,
            on_pick = function(id)
                self.document:setTemplate(id, clear_overrides)
                self:_refresh()
            end,
            extra = (not clear_overrides and self.document:hasPageTemplates()) and {
                text = _("Some pages have their own — change those too"),
                callback = function() show(true) end,
            } or nil,
        })
    end
    show(false)
end

-- Navigation --------------------------------------------------------------------------

function PagePanel:_turnPage(delta)
    local target = self.page + delta
    if target < 1 or target > self.page_count then return end
    self.page = target
    self:_layout()
    UIManager:setDirty("all", "ui")
end

function PagePanel:onPanelSwipe(_, ges)
    if ges.direction == "west" then
        self:_turnPage(1)
    elseif ges.direction == "east" then
        self:_turnPage(-1)
    else
        return false
    end
    return true
end

function PagePanel:onClose()
    UIManager:close(self, "ui")
    return true
end

function PagePanel:onCloseWidget()
    if self.holder and self.holder[1] then self.holder[1]:free() end
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(PagePanel, "page overview")
