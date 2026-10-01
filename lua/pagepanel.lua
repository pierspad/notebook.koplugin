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
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TemplatePicker = require("templatepicker")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widgets = require("widgets")
local _ = require("i18n")
local Safe = require("safe")
local T = require("ffi/util").template



-- One page ------------------------------------------------------------------------

local PagePanel = require("pagegrid"):extend{
    document = nil,
    -- Called when the notebook has been changed and the page behind us with it.
    on_change = nil,
    -- Called with a page number when the reader wants to go there.
    on_goto = nil,
}

--[[--
The sizes the header is tried at, largest first, then without the words.

The same ladder the gallery goes down, and for the same reason: the row has a
fixed width and its labels do not. Three buttons and a title fit across a
Scribe in English and across nothing narrower -- an Elipsa is four hundred
pixels short of it -- and a HorizontalGroup that does not fit is not wrapped or
scrolled, it is cut off at the right. The button on the right is Done, so what
was being cut off was the way out of the overview.
--]]
local HEADER_MODES = { 17, 16, 15, 14, 13, "icons" }

function PagePanel:_buildHeader()
    local gap = Size.padding.large
    local avail = self.dimen.w - 2 * gap

    local row
    for i, mode in ipairs(HEADER_MODES) do
        if row then
            for _, child in ipairs(row) do
                if child.free then child:free() end
            end
        end

        -- Words go last, and only when no size fits: an icon alone says less
        -- than a small word, so shrinking is always the better trade.
        local words = mode ~= "icons"
        local font = words and mode or 13
        local icon = words and math.floor(mode * 1.5) or 26

        local function button(text, glyph, callback)
            return Widgets.textButton{
                text = words and text or "",
                icon = glyph, font_size = font, icon_size = icon,
                callback = callback,
            }
        end

        row = HorizontalGroup:new{ align = "center" }
        table.insert(row, TextWidget:new{
            text = T(_("Pages (%1)"), self.document:pageCount()),
            face = Font:getFace("tfont", words and 22 or 18),
        })
        table.insert(row, HorizontalSpan:new{ width = gap })
        table.insert(row, button(_("New page"), "notebook.page", function()
            self:_insertAfter(self.document.current_page)
        end))
        table.insert(row, HorizontalSpan:new{ width = gap })
        table.insert(row, button(_("Notebook background"), "notebook.page", function()
            self:_pickNotebookTemplate()
        end))
        table.insert(row, HorizontalSpan:new{ width = gap })
        -- A left chevron, the same one every other screen leaves by: an
        -- open-book glyph on a button that closes the page said the opposite
        -- of what it does.
        table.insert(row, button(_("Done"), "chevron.left", function()
            self:onClose()
        end))

        if row:getSize().w <= avail or i == #HEADER_MODES then
            return row
        end
    end
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
    self.reveal = n
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
              self.reveal = self.document:duplicatePage(index)
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

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(PagePanel, "page overview")
