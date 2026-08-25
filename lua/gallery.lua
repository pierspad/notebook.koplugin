--[[--
The notebook gallery: a grid of cards, the way a bookshelf is.

A list of file names with dates beside them tells you nothing about what is in a
notebook. A page of handwriting is recognisable at a glance, so each card shows
its first page and you find the one you want by looking rather than by reading.

Folders are ordinary directories on disk, shown as cards of their own.

@module notebook.gallery
--]]--

local ActionMenu = require("actionmenu")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Document = require("document")
local Export = require("export")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Library = require("library")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local NewNotebook = require("newnotebook")
local Thumbnail = require("thumbnail")
local UIManager = require("ui/uimanager")
local Widgets = require("widgets")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local _ = require("i18n")
local Safe = require("safe")
local Share = require("share")
local T = require("ffi/util").template

local Screen = Device.screen

local COLUMNS = 3

-- Proportions of a notebook page, used for the thumbnail area of a card.
local PAGE_W, PAGE_H = 1860, 2480

-- One card ----------------------------------------------------------------------

--[[--
The notebook a card's picture comes from.

An exported PDF shows the notebook it came from. A generic document icon tells
you nothing about which export you are looking at, and the ribbon painted over
the corner already says it is a PDF.
--]]
local function pictureSource(item)
    if item.is_folder then return nil end
    if item.is_pdf then return (item.path:gsub("%.pdf$", ".scribe")) end
    return item.path
end

--[[--
Whether a card should be drawn as chosen, not chosen, or neither.

Written out rather than folded into an `and`/`or`: the obvious one-liner returns
nil for a card that is not chosen, because `x and false or nil` is nil, and the
cards that were merely unticked came out looking as though no selection was in
progress at all.
--]]
local function selectionMark(selection, item)
    if not selection then return nil end
    return selection[item.path] ~= nil
end

--- The area a card leaves for its picture, given the card's size.
local function thumbSize(card_w, card_h)
    return card_w - 2 * Size.border.thin,
           card_h - Screen:scaleBySize(40) - 2 * Size.border.thin
end

local Card = InputContainer:extend{
    item = nil,
    width = nil,
    height = nil,
    -- Path of an already-rendered thumbnail, or nil to show a placeholder.
    thumb = nil,
    -- nil outside selection mode; true or false while choosing.
    selected = nil,
    on_open = nil,
    on_hold = nil,
}

function Card:init()
    local label_h = Screen:scaleBySize(40)
    local thumb_w, thumb_h = thumbSize(self.width, self.height)

    local picture
    if self.item.is_folder then
        picture = IconWidget:new{
            icon = "notebook.folder",
            width = math.floor(thumb_h * 0.55),
            height = math.floor(thumb_h * 0.55),
        }
    elseif self.thumb then
        picture = ImageWidget:new{
            file = self.thumb,
            width = thumb_w,
            height = thumb_h,
        }
    else
        -- Nothing written yet, the notebook this PDF came from is gone, or the
        -- picture has not been drawn yet: show it as the blank page it is,
        -- rather than a broken image.
        picture = IconWidget:new{
            icon = "notebook.page",
            width = math.floor(thumb_h * 0.4),
            height = math.floor(thumb_h * 0.4),
        }
    end

    local caption = self.item.name

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        margin = 0,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = thumb_h },
                picture,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = thumb_w, h = label_h },
                TextWidget:new{
                    text = caption,
                    face = Font:getFace("cfont", 17),
                    max_width = thumb_w - 2 * Size.padding.small,
                },
            },
        },
    }
    if self.item.is_pdf then
        self.ribbon = TextWidget:new{
            text = _("PDF"),
            face = Font:getFace("cfont", 20),
            fgcolor = Blitbuffer.COLOR_WHITE,
            bold = true,
        }
    end

    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

--[[--
Puts back the rounded corners a full-bleed picture painted over.

The frame draws its rounded border first and the thumbnail is blitted into it
afterwards, as a plain rectangle filling the card's whole width. So the two top
corners -- the only ones the picture reaches -- came out square, while the
folder cards, whose icon is small and centred, and the bottom of every card,
which is the white caption strip, kept theirs. One card in a grid with two
corners of the wrong shape looks like a rendering fault, which is what it was.

Cheaper than clipping the image: the corner is a few dozen pixels, and the
alternative is a bounds test per pixel blitted.
--]]
local function restoreCorners(bb, x, y, w, h, r)
    if r < 1 then return end
    for dy = 0, r - 1 do
        -- How far in the card's edge sits on this row: the horizontal distance
        -- from the corner's centre out to the quarter circle.
        local o = r - dy - 0.5
        local dx = r - math.floor(math.sqrt(r * r - o * o) + 0.5)
        if dx > 0 then
            bb:paintRect(x, y + dy, dx, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - dx, y + dy, dx, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + h - 1 - dy, dx, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - dx, y + h - 1 - dy, dx, 1, Blitbuffer.COLOR_WHITE)
        end
    end
    bb:paintBorder(x, y, w, h, Size.border.thin, Blitbuffer.COLOR_BLACK, r)
end

--- Paints the card, the PDF ribbon over its corner, and the selection mark.
function Card:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)

    if self.ribbon then
        local pad = Size.padding.default
        local size = self.ribbon:getSize()
        bb:paintRect(x + Size.border.thin, y + Size.border.thin,
            size.w + 4 * pad, size.h + 2 * pad, Blitbuffer.COLOR_BLACK)
        self.ribbon:paintTo(bb,
            x + Size.border.thin + 2 * pad,
            y + Size.border.thin + pad)
    end

    -- After the ribbon, which is itself a square block laid over one corner.
    restoreCorners(bb, x, y, self.dimen.w, self.dimen.h, Size.radius.button)

    if self.selected ~= nil then
        -- A filled disc for chosen, an empty ring for not. On e-ink the two
        -- have to differ in how much black there is, not in a small detail like
        -- a tick, which vanishes at this size under a fast waveform.
        local r = Screen:scaleBySize(16)
        local pad = Size.padding.default
        local cx = x + self.dimen.w - r - pad
        local cy = y + r + pad
        bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
        if self.selected then
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK)
        else
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, 2)
        end
    end
end

--- The ribbon hangs off the card rather than sitting in it, so free it by hand.
function Card:free(full)
    InputContainer.free(self, full)
    if self.ribbon then self.ribbon:free(full) end
end

function Card:onTap()
    if self.on_open then self.on_open(self.item) end
    return true
end

function Card:onHold()
    if self.on_hold then self.on_hold(self.item) end
    return true
end

-- The gallery ---------------------------------------------------------------------

local Gallery = InputContainer:extend{
    -- Named so the Simple UI launcher can recognise us; see launcherbar.lua.
    name = "notebook_gallery",
    -- Folder currently shown, relative to the notebook root. "" is the root.
    folder = "",
    page = 1,
    -- Called with a notebook name and its folder when one should be opened.
    on_open = nil,
    -- Called with the path of a file to hand to LocalSend. Left nil when the
    -- LocalSend plugin is not installed, which is what keeps the Send action
    -- off the header rather than offering something that cannot work.
    on_share = nil,
    -- One of Library.ORDERS. Read from the settings on the way in and written
    -- back when it changes: which order you like is a preference, not a mode
    -- you should have to re-enter every time you open the notebooks.
    order = nil,
}

function Gallery:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true

    self.order = self.order
        or (G_reader_settings and G_reader_settings:readSetting("notebook_order"))
        or Library.DEFAULT_ORDER
    if not Library.ORDERS[self.order] then self.order = Library.DEFAULT_ORDER end

    -- Whatever an earlier send left staged in the cache and is now certainly
    -- finished with. Done here because opening the gallery is the one moment
    -- that is both frequent and not in the middle of anything.
    Share.sweep()

    -- Notebooks we have already tried, and failed, to draw a picture for.
    self.thumb_tried = {}
    -- Pictures still to be drawn, and what is already waiting in the queue.
    self.thumb_queue = {}
    self.thumb_queued = {}

    --[[
    A holder that never changes identity, with the grid inside it.

    The Simple UI launcher bar wraps us by taking our first child, putting the
    bar around it, and storing the result back as our first child. Laying out
    again by assigning a new widget to `self[1]` therefore threw that wrapper
    away, bar and all: the bar vanished from the screen while still answering
    taps, because Simple UI handles those elsewhere. Swapping what is inside a
    holder that stays put leaves whatever has been wrapped around it intact.
    --]]
    self.holder = WidgetContainer:new{}
    self[1] = self.holder

    self.items = Library.list(self.folder, self.order)
    self:_layout()

    self.ges_events = {
        GallerySwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

--[[--
Lays the grid out inside whatever rectangle we have been given.

Everything reads from self.dimen rather than the screen, because the launcher
bar shrinks us to the area above it and moves our top edge down. Measuring the
screen instead would put the last row of cards underneath the bar.
--]]
function Gallery:_layout()
    -- Release the widgets of the previous layout before dropping them.
    --
    -- Every card holds a picture, and an ImageWidget scaled to the card owns a
    -- blitbuffer it only gives back when freed. Laying out again without freeing
    -- -- which happens on every folder change, every page turn and every return
    -- from a notebook -- leaks one buffer per card, and the gallery gets slower
    -- until the process runs out of memory.
    self:_freeWidgets()

    local margin = Size.padding.large
    local avail_w = self.dimen.w - 2 * margin
    local card_w = math.floor((avail_w - (COLUMNS - 1) * margin) / COLUMNS)
    -- Taller than wide, echoing the page they show -- but only slightly. The
    -- ratio is what decides how many rows fit, and at 1.25 a Scribe screen took
    -- two rows and left the bottom third of the gallery empty.
    local card_h = math.floor(card_w * 1.1)

    local header = self:_buildHeader()
    local header_h = header:getSize().h
    local footer_h = self:_footerHeight()

    local grid_h = self.dimen.h - self:_topInset() - header_h - footer_h - 2 * margin
    local rows = math.max(1, math.floor((grid_h + margin) / (card_h + margin)))
    self.per_page = rows * COLUMNS
    self.page_count = math.max(1, math.ceil(#self.items / self.per_page))
    if self.page > self.page_count then self.page = self.page_count end

    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1

    -- Notebooks on this page whose picture still has to be drawn, collected
    -- while the cards are built and rendered afterwards; see _drawThumbnails.
    local missing = {}
    local thumb_w, thumb_h = thumbSize(card_w, card_h)

    for r = 0, rows - 1 do
        local row = HorizontalGroup:new{ align = "top" }
        local any = false
        for c = 0, COLUMNS - 1 do
            local idx = first + r * COLUMNS + c
            local item = self.items[idx]
            if item then
                any = true
                if c > 0 then
                    table.insert(row, HorizontalSpan:new{ width = margin })
                end
                local source = pictureSource(item)
                local thumb = source and Thumbnail.cached(source) or nil
                -- A notebook we failed to draw is worth another try once it has
                -- been written to, so what was tried is remembered against the
                -- notebook's modification time rather than just its name.
                if source and not thumb
                    and self.thumb_tried[source] ~= (Thumbnail.stamp(source) or true) then
                    table.insert(missing, source)
                end
                table.insert(row, Card:new{
                    item = item,
                    width = card_w,
                    height = card_h,
                    thumb = thumb,
                    selected = selectionMark(self.selection, item),
                    on_open = function(it) self:_tapped(it) end,
                    on_hold = function(it) self:_held(it) end,
                })
            end
        end
        if any then
            if r > 0 then
                table.insert(grid, VerticalSpan:new{ width = margin })
            end
            table.insert(grid, row)
        end
    end

    if #self.items == 0 then
        table.insert(grid, TextWidget:new{
            text = _("Nothing here yet — use New notebook to start one"),
            face = Font:getFace("cfont", 18),
        })
    end

    self.content = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = self:_topInset() },
        header,
        VerticalSpan:new{ width = margin },
        grid,
    }

    self.footer = self:_buildFooter()

    -- Sized to the whole rectangle we were given, not to the cards in it.
    --
    -- A frame with no width or height paints its background over its content
    -- and stops there, so a short page -- one row of cards, or an empty folder
    -- -- left the rest of the screen showing whatever was there before: the
    -- keyboard from the name dialog, or the previous folder's cards. Every
    -- pixel we cover is ours, and has to be painted.
    self.holder[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = margin,
        width = self.dimen.w,
        height = self.dimen.h,
        self.content,
    }

    self:_drawThumbnails(missing, thumb_w, thumb_h)
end

--- Frees the widgets of the current layout, if there is one.
function Gallery:_freeWidgets()
    if self.holder[1] then self.holder[1]:free() end
    if self.footer then self.footer:free() end
end

--[[--
Draws the pictures this screen is missing, one per tick.

Rendering a thumbnail means loading a whole notebook and rasterising a page of
it. Doing that while laying out meant the gallery could not appear until every
notebook on the screen had been read -- seconds of frozen panel on opening a
folder, with nothing to show that anything was happening. So the cards go up
immediately with a blank page on them and the pictures follow, one per tick, so
that taps and swipes are still answered while it happens.

The work is a queue on the gallery rather than a list captured by each run. It
used to be captured, with a token cancelling the run whenever a new layout
started -- and a layout starts for all sorts of reasons, including the one this
very code performs when it finishes. Whatever was left in a cancelled run was
dropped, which is why some cards kept their blank page while others filled in,
most visibly right after moving notebooks between folders.

Now a layout adds to the queue and the worker keeps going until it is empty.
Only leaving the folder, or the gallery, throws the work away -- and then it
ought to be thrown away.

Each picture is scheduled through `Safe.later`, never `UIManager:nextTick`, and
the difference is the difference between a slow screen and a dead device.
`handleInput` runs its tasks and repaints in a loop that only ends once nothing
more is due, and it reads input *after* that loop -- so a chain of tasks due
immediately means input is never read at all, for as long as the chain lasts.
With a folder of large notebooks on a device far slower than the one this was
written on, that is not a pause: it is a Kindle that has stopped answering, with
nothing to do but hold the power button. Scheduling a moment ahead instead lets
the loop settle between pictures, and a tap lands while they are still coming in.
--]]
function Gallery:_drawThumbnails(missing, w, h)
    for _, source in ipairs(missing) do
        if not self.thumb_queued[source] then
            self.thumb_queued[source] = true
            table.insert(self.thumb_queue, { source = source, w = w, h = h })
        end
    end

    if self.thumb_working or #self.thumb_queue == 0 then return end
    self.thumb_working = true

    local folder = self.folder
    local drew = false

    local function step()
        -- The folder changed, or the gallery is gone: these pictures belong to
        -- a screen nobody is looking at.
        if self.folder ~= folder or self.closed then
            self.thumb_working = false
            return
        end

        local job = table.remove(self.thumb_queue, 1)
        if not job then
            self.thumb_working = false
            if drew then
                self:_layout()
                self:_repaint()
            end
            return
        end

        -- Off the waiting list as it comes off the queue, not when it was put
        -- on: the flag is there to stop the same picture being queued twice
        -- while it waits, not to stop it ever being queued again. Left set, a
        -- notebook that failed once and was then written in never came back.
        self.thumb_queued[job.source] = nil
        self.thumb_tried[job.source] = Thumbnail.stamp(job.source) or true
        if Thumbnail.get(job.source, job.w, job.h, PAGE_W, PAGE_H) then
            drew = true
        end
        Safe.later("gallery:thumbnail", step)
    end

    Safe.later("gallery:thumbnail", step)
end

--- Forgets the pictures still waiting to be drawn.
function Gallery:_cancelThumbnails()
    self.thumb_queue = {}
    self.thumb_queued = {}
end

--[[--
A header button at the given level of detail.

A mode is either a font size -- the icon beside the label, both scaled to it --
or one of the two ways of giving up. The sizes come first and are tried largest
first, because shrinking a button is a much smaller loss than taking its icon or
its words away.
--]]
local ICON_TO_FONT = 26 / 17

local function headerButton(mode, text, icon, callback)
    if mode == "icons" and icon then
        return Widgets.iconButton(icon, callback)
    end
    if mode == "labels" then
        return Widgets.textButton{ text = text, callback = callback }
    end
    return Widgets.textButton{
        text = text,
        icon = icon,
        font_size = mode,
        icon_size = math.floor(mode * ICON_TO_FONT),
        callback = callback,
    }
end

-- Largest first. Below the smallest of these the words stop being readable at
-- arm's length, and giving something up beats shrinking further.
local HEADER_MODES = { 17, 16, 15, 14, 13, "labels", "icons" }

--[[--
What each listing order is called.

Written out as literals rather than built from the keys, because the catalogue
is checked against the literals in the source: a label assembled at runtime is
one the check cannot see, and it would report every one of these as a
translation for a string nothing says.
--]]
local ORDER_LABELS = {
    recent = _("Last edited"),
    oldest = _("Least recently edited"),
    name = _("Name (A to Z)"),
    name_desc = _("Name (Z to A)"),
}

--[[--
Assembles a header from a back arrow, a title, and a row of buttons.

The buttons are built and measured first, and the title is given whatever width
is left over. Laid out the other way round -- title first, buttons after -- the
row simply grew past the screen and the last button went off the right-hand
edge, where it is invisible and cannot be tapped. Nothing says it has happened:
a HorizontalGroup that does not fit neither wraps nor complains.

That was already true in English at the width of a Scribe, and every language
whose words for "New notebook" are longer than English's made it worse.

What the row gives up, and in what order, matters. Dropping the icons is the
cheapest change to describe and the worst one to look at: what had been a strip
of recognisable buttons becomes a strip of plain words, and it reads as though
something broke rather than as though something was added.

So the height goes before the icons do. A set of buttons that will not fit
beside the title gets a row of its own underneath, at the full width of the
screen and still drawn the way it was -- which is nearly always enough, because
the title is what was taking the room. Only if a full-width row of them still
does not fit does the old ladder apply: labels first, then icons alone, which
always fit.

The header is then padded to the height of two rows whether it uses them or
not. Without that the grid moves up and down as the buttons come and go -- the
selection header needs the second row and the ordinary one does not -- and a
page of cards that jumps every time you tick something is worse to use than one
that starts a little lower.

@tparam function make called with the mode; returns the title text, the back
  arrow, and the list of buttons that follow the title
@treturn widget the assembled header, always the same height
--]]
function Gallery:_fitHeader(make)
    local gap = Size.padding.large
    local pad = Size.padding.small
    -- The grid inside the holder is inset by a margin on each side.
    local avail = self.dimen.w - 2 * gap

    --- Width of the buttons laid out with a gap before each.
    local function widthOf(buttons)
        local w = 0
        for _, button in ipairs(buttons) do
            w = w + button:getSize().w + gap
        end
        return w
    end

    --[[
    The largest the actions can be drawn and still fit on their row.

    Eight of them at the size a menu uses are wider than a Scribe, so the row is
    built at each size in turn until one fits. Only if the smallest still does
    not -- a language far wider than any we ship, or a much narrower screen --
    are the icons dropped, and then the words.
    --]]
    local title, back, buttons, corner, widest
    for i, mode in ipairs(HEADER_MODES) do
        if i > 1 then
            back:free()
            if corner then corner:free() end
            for _, button in ipairs(buttons) do button:free() end
        end
        title, back, buttons, corner, widest = make(mode)
        --[[
        Sized for the most it will ever hold, not for what it holds now.

        Which actions apply depends on what has been ticked, so sizing to the
        buttons actually built would resize them as you tick -- five large ones
        becoming seven small ones and back. A header whose lettering changes
        size under your finger is worse to read than one that settled on a size
        and kept it.
        --]]
        for _, button in ipairs(widest or {}) do button:free() end
        if widthOf(widest or buttons) <= avail then break end
    end

    -- The title row: what you are looking at, and the one control that is about
    -- the row itself rather than about what is in the grid.
    local top = HorizontalGroup:new{ align = "center" }
    table.insert(top, back)
    table.insert(top, HorizontalSpan:new{ width = gap })
    table.insert(top, TextWidget:new{
        text = title,
        face = Font:getFace("tfont", 22),
        max_width = math.max(
            avail - back:getSize().w - gap
                  - (corner and corner:getSize().w + gap or 0),
            Screen:scaleBySize(40)),
    })
    if corner then
        table.insert(top, HorizontalSpan:new{ width = gap })
        table.insert(top, corner)
    end

    local bottom = HorizontalGroup:new{ align = "center" }
    for _, button in ipairs(buttons) do
        if #bottom > 0 then
            table.insert(bottom, HorizontalSpan:new{ width = gap })
        end
        table.insert(bottom, button)
    end

    --[[
    The height the header occupies, whether it needs all of it or not.

    The actions keep a row of their own at all times, even while it is empty --
    which it is with nothing chosen. They used to appear beside the title when
    there were few of them and drop to their own row when there were many, and
    a strip of controls that moves between two places depending on what you have
    ticked is harder to use than one that is always in the same place.

    So the row is measured from a button at the largest size rather than from
    the buttons actually in it: that is the tallest one can be, and it is the
    same answer whichever size was settled on and whatever is on the row. The
    grid below starts at the same place with something ticked and with nothing
    ticked.
    --]]
    local probe = headerButton(HEADER_MODES[1], "X", "notebook.page", function() end)
    local action_h = probe:getSize().h
    probe:free()

    --[[
    Built complete rather than grown after measuring.

    A VerticalGroup measures itself once and remembers where each child goes.
    Adding one afterwards leaves it painting past the end of that list: the
    screen never appears, and it takes the plugin down with it.
    --]]
    local header = VerticalGroup:new{
        align = "left",
        top,
        -- The same gap above the actions and below them, so the row reads as a
        -- band of its own rather than as something stuck to the title.
        VerticalSpan:new{ width = pad },
        bottom,
        VerticalSpan:new{ width = pad + math.max(0, action_h - bottom:getSize().h) },
    }

    self.header_row = header
    return header
end

--- A header button at the given level of detail; see _fitHeader.

function Gallery:_buildHeader()
    if self.selection then return self:_buildSelectionHeader() end

    return self:_fitHeader(function(mode)
        --[[
        The back arrow is always there, and always means "out of here".

        Inside a folder it goes up one. At the top it closes the notebooks,
        which until now had no control at all: you left by tapping another tab
        on the launcher bar, and if that bar is not installed there was nothing
        to tap. Worse, a screen this one covers the whole panel with is one the
        launcher bar itself cannot close -- it only knows how to close its own
        -- so leaving had to be something the reader could always do from here.
        --]]
        local back = Widgets.iconButton("chevron.left", function()
            if self.folder ~= "" then
                return self:_goTo(Library.parentOf(self.folder) or "")
            end
            self:onClose()
        end)

        -- Two buttons rather than a plus that opens a menu of two. The menu was
        -- one tap of ceremony in front of the two things anybody comes here to
        -- do, and it hid both behind a symbol that says neither.
        local buttons = {
            headerButton(mode, _("New notebook"), "notebook.page",
                function() self:_createNotebook() end),
            headerButton(mode, _("New folder"), "notebook.folder",
                function() self:_createFolder() end),
        }

        --[[
        A way into choosing that does not depend on a hold.

        Holding works with the pen and is unreliable with a finger, and not
        because of anything here: the gesture detector never emits a hold once
        the contact has moved or once a second contact -- a hand on the glass --
        has voided the gesture. A finger wobbles and a hand rests, so the hold
        that works every time with a nib fails often enough with a fingertip to
        feel broken. A button cannot fail, and it also says that choosing
        several things is possible at all, which a hold never did.
        --]]
        if #self.items > 0 then
            table.insert(buttons, headerButton(mode, _("Select"),
                "notebook.duplicate", function()
                    self.selection = {}
                    self:_layout()
                    self:_repaint()
                end))
        end

        local title = self.folder ~= "" and self.folder:match("[^/]+$")
            or _("Notebooks")
        return title, back, buttons, self:_orderButton()
    end)
end

--[[--
The header while things are being chosen.

Only three controls, and one of them opens a menu. Bulk actions do not all apply
to everything that can be chosen -- a folder cannot be exported, a PDF export
should not be duplicated away from the notebook it came from -- so which ones
are offered depends on what is in the selection, and a row of buttons that
appear and disappear as you tick things is harder to read than a single button
that opens the list that applies.
--]]
function Gallery:_buildSelectionHeader()
    local chosen = self:_selected()
    local count = #chosen

    -- Fitted the same way as the ordinary header, and with more reason to be:
    -- how many buttons this row carries depends on what has been chosen, so the
    -- widest version of it is not something that can be checked once and then
    -- relied on.
    return self:_fitHeader(function(mode)
        local back = Widgets.iconButton("chevron.left", function()
            self:_endSelection()
        end)

        -- Ticking everything is about the selection itself rather than about
        -- what is in it, so it sits up beside the count it changes rather than
        -- among the actions that apply to what has been ticked.
        local all = #chosen == #self.items and _("None") or _("All")
        local corner = Widgets.textButton{ text = all, callback = function()
            if not self.selection then return end
            if #self:_selected() == #self.items then
                for _, item in ipairs(self.items) do
                    self.selection[item.path] = nil
                end
            else
                for _, item in ipairs(self.items) do
                    self.selection[item.path] = item
                end
            end
            self:_layout()
            self:_repaint()
        end }

        local buttons = {}
        for _, action in ipairs(self:_bulkActions(chosen)) do
            table.insert(buttons, headerButton(mode, action.text,
                action.icon, action.callback))
        end

        -- The most this header can ever carry: one notebook chosen, which is
        -- the case that offers everything at once. Built only to be measured.
        local widest = {}
        for _, action in ipairs(self:_bulkActions({
            { name = "", path = "", is_folder = false, is_pdf = false },
        })) do
            table.insert(widest, headerButton(mode, action.text,
                action.icon, action.callback))
        end

        local title = count == 1 and _("1 selected") or T(_("%1 selected"), count)
        return title, back, buttons, corner, widest
    end)
end

-- The page counter's typeface, in one place: the height reserved for it below
-- the cards and the height it actually paints at have to be the same number,
-- and they were not -- the strip left for it was shorter than the line of text,
-- so the counter was drawn partly off the bottom of the screen.
local FOOTER_FONT_SIZE = 17

function Gallery:_buildFooter()
    if self.page_count <= 1 then return nil end
    return TextWidget:new{
        text = T(_("Page %1 of %2"), self.page, self.page_count),
        face = Font:getFace("cfont", FOOTER_FONT_SIZE),
    }
end

--- How much room the page counter needs, measured rather than guessed at.
function Gallery:_footerHeight()
    local sizer = TextWidget:new{
        text = "0",
        face = Font:getFace("cfont", FOOTER_FONT_SIZE),
    }
    local h = sizer:getSize().h
    sizer:free()
    return h + Size.padding.small
end

--[[--
Paints where we are told to, not where we think we are.

An earlier version added self.dimen.y to the offset. That is wrong: when the
launcher bar wraps us, its container is what positions us and already passes the
right coordinates -- so adding our own y again drew everything twice, at two
different offsets. A widget paints at the origin it is given.
--]]
function Gallery:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)

    if self.footer then
        -- Placed by its own height, not by a guess at it. The guess was 18
        -- scaled pixels, and the line of text is taller than that, so "Page 1
        -- of 2" was drawn half off the bottom of the screen.
        local size = self.footer:getSize()
        self.footer:paintTo(bb,
            x + math.floor((self.dimen.w - size.w) / 2),
            y + self.dimen.h - size.h - Size.padding.small)
    end
end

-- Navigation ----------------------------------------------------------------------

--[[--
Height to leave clear at the top.

Only needed when we own the whole screen: the system status bar is drawn over
us there. Under the launcher bar our top edge already sits below its top bar, so
reserving more would just waste a strip.

Note that scaled sizes are multiplied by the panel's density, so this is far
larger in pixels than it reads here.
--]]
function Gallery:_topInset()
    if self.dimen.y and self.dimen.y > 0 then return 0 end
    return Screen:scaleBySize(12)
end

--- Called by the launcher bar after it resizes us.
function Gallery:_recalculateDimen()
    self:_layout()
end

--[[--
Asks for the new layout to be put on the panel.

`setDirty(nil, ...)` does not do this. It marks no widget as needing to be
painted, so UIManager repaints nothing and then refreshes the panel from a
buffer that still holds the previous screen: the folder you opened never
appears, the page you swiped to never arrives, and since a card's tap target
only moves when the card is painted, every tap after that lands somewhere else.
That is the whole of the gallery "freezing".

Naming ourselves would not be right either: when the Simple UI bar has wrapped
us, the widget on UIManager's stack is its container and not us, and only
widgets on the stack can be marked. "all" covers both cases.
--]]
function Gallery:_repaint(mode)
    UIManager:setDirty("all", mode or "ui")
end

--- Rebuilds the grid after the contents change.
function Gallery:_rebuild()
    self.items = Library.list(self.folder, self.order)
    self:_layout()
    self:_repaint()
end

function Gallery:_goTo(folder)
    self:_cancelThumbnails()
    -- A selection belongs to the folder it was made in: its items are not in
    -- the new one, so carrying it across would leave a count with nothing
    -- behind it and bulk actions aimed at things that are no longer on screen.
    self.selection = nil
    self.folder = folder
    self.page = 1
    self:_rebuild()
end

function Gallery:_turnPage(delta)
    local target = self.page + delta
    if target < 1 or target > self.page_count then return end
    self.page = target
    self:_layout()
    self:_repaint()
end

function Gallery:onGallerySwipe(_, ges)
    local dir = ges.direction
    if dir == "west" then
        self:_turnPage(1)
    elseif dir == "east" then
        self:_turnPage(-1)
    else
        return false
    end
    return true
end

function Gallery:onClose()
    UIManager:close(self)
    return true
end

function Gallery:_open(item)
    if item.is_folder then
        return self:_goTo(item.rel)
    end
    if item.is_pdf then
        return self:_openPDF(item)
    end
    if self.on_open then self.on_open(item.name, self.folder) end
end

--[[--
Opens an exported PDF in the reader, and gets out of the way.

Staying on the stack underneath it was tried, so that closing the document would
reveal the notebooks again. It works, and it is also exactly the hazard Simple
UI warns about in its own source: a fullscreen screen left behind goes on
covering the file manager while the bar runs actions against it, so tapping
Library does something and shows nothing. Leaving one there to save a tap is not
worth breaking the bar for -- and the way back is the notebooks tab, which is on
the bar and now lights up when you are here.
--]]
function Gallery:_openPDF(item)
    UIManager:close(self)
    require("apps/reader/readerui"):showReader(item.path)
end

-- Actions --------------------------------------------------------------------------

--[[--
Shows a message that goes away on its own.

Every message here is an acknowledgement -- something worked, or a name was
refused -- not a question. Leaving one up until it is tapped means an e-ink
panel sitting on a box that has already been read, and on a device where a tap
costs a refresh, dismissing it by hand is a chore rather than a choice.
--]]
local NOTICE_SECONDS = 3

function Gallery:_error(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = NOTICE_SECONDS })
end

local function nameError(reason)
    if reason == "empty" then return _("The name cannot be empty.") end
    if reason == "slash" then return _("The name cannot contain slashes.") end
    if reason == "exists" then return _("Something with that name is already here.") end
    if reason == "too_long" then return _("That name is too long.") end
    return _("That name cannot be used.")
end

function Gallery:_askName(title, initial, commit)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    commit(name)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Gallery:_addMenu()
    UIManager:show(ActionMenu:new{
        title = _("Add"),
        actions = {
            { icon = "notebook.page", text = _("New notebook"),
              callback = function() self:_createNotebook() end },
            { icon = "notebook.folder", text = _("New folder"),
              callback = function() self:_createFolder() end },
        },
    })
end

--[[--
Creates a notebook: its name and its paper, asked for together.

It used to be two screens, a name then a paper, which made the paper feel like
an afterthought to a decision already taken. The notebook is written to disk as
soon as it is created rather than when it is first drawn on, so it is there in
the gallery whether or not anything was written in it -- an empty notebook you
made on purpose is not the same thing as one that never existed.
--]]
function Gallery:_createNotebook()
    UIManager:show(NewNotebook:new{
        name = Library.suggestName(self.folder),
        on_create = function(name, paper)
            local ok, reason = Library.validateName(name)
            if not ok then return self:_error(nameError(reason)) end
            if Library.exists(name, self.folder) then
                return self:_error(nameError("exists"))
            end
            if self.on_open then self.on_open(name, self.folder, paper) end
        end,
    })
end

function Gallery:_createFolder()
    self:_askName(_("New folder"), "", function(name)
        local ok, reason = Library.createFolder(name, self.folder)
        if not ok then return self:_error(nameError(reason)) end
        self:_rebuild()
    end)
end

-- Choosing several things ------------------------------------------------------------

--[[--
What a tap and a hold do depends on whether anything is being chosen.

Outside selection, a tap opens and a hold offers what can be done to one thing.
Inside it, a tap ticks and unticks, because that is the only thing a tap can
usefully mean once a selection exists -- and opening a notebook from under a
half-made selection would throw the selection away.
--]]
function Gallery:_tapped(item)
    if not self.selection then return self:_open(item) end
    if self.selection[item.path] then
        self.selection[item.path] = nil
        -- Unticking the last one leaves selection mode: an empty selection is a
        -- mode with nothing in it and no way to tell you are still in it.
        if self:_selectionCount() == 0 then return self:_endSelection() end
    else
        self.selection[item.path] = item
    end
    self:_layout()
    self:_repaint()
end

function Gallery:_held(item)
    if self.selection then
        -- Already choosing: a hold is just another way to tick.
        return self:_tapped(item)
    end
    self.selection = { [item.path] = item }
    self:_layout()
    self:_repaint()
end

function Gallery:_endSelection()
    self.selection = nil
    self:_layout()
    self:_repaint()
end

function Gallery:_selectionCount()
    local n = 0
    for _ in pairs(self.selection or {}) do n = n + 1 end
    return n
end

--- The chosen items, in the order they appear on screen.
function Gallery:_selected()
    local chosen = {}
    for _, item in ipairs(self.items) do
        if self.selection[item.path] then table.insert(chosen, item) end
    end
    return chosen
end

--- The chosen things that can be sent: anything that is a file.
local function sendable(items)
    local out = {}
    for _, item in ipairs(items) do
        if not item.is_folder then table.insert(out, item) end
    end
    return out
end

--- The chosen notebooks: not folders, and not exported PDFs.
local function notebooksOnly(items)
    local out = {}
    for _, item in ipairs(items) do
        if not item.is_folder and not item.is_pdf then table.insert(out, item) end
    end
    return out
end

--[[--
The actions that apply to what has been chosen, as a list.

Returned rather than shown, because they are laid out along the header where
they can be seen. They used to sit behind a button marked "Actions", which meant
that the answer to "what can I do with these?" was always one tap away and never
on screen -- and moving something to a folder, which is the reason most
selections get made, was the least discoverable thing in the plugin.

Which ones appear still depends on what is in the selection: a folder cannot be
exported, and an exported PDF should not be duplicated away from the notebook it
came from. With exactly one thing chosen, the actions that only make sense for
one thing are there too.
--]]
function Gallery:_bulkActions(chosen)
    -- Nothing chosen yet, which happens on the way in through the Select
    -- button. Offering Delete with an empty selection would be offering to
    -- delete nothing, worded as though it might do something.
    if #chosen == 0 then return {} end

    local notebooks = notebooksOnly(chosen)
    local actions = {}

    if #chosen == 1 then
        local item = chosen[1]
        table.insert(actions, {
            icon = "notebook.open", text = _("Open"),
            callback = function()
                self:_endSelection()
                self:_open(item)
            end,
        })
        if not item.is_pdf then
            table.insert(actions, {
                icon = "notebook.rename", text = _("Rename"),
                callback = function() self:_renameOne(item) end,
            })
        end
    end

    table.insert(actions, {
        icon = "notebook.folder", text = _("Move"),
        callback = function() self:_moveSelection(chosen) end,
    })

    -- Only with the LocalSend plugin installed. Folders are not offered: a
    -- notebook has to be rendered before it can go anywhere, and rendering
    -- everything under a folder the reader merely ticked is a lot of work
    -- nobody asked for.
    if self.on_share and #sendable(chosen) > 0 then
        table.insert(actions, {
            icon = "notebook.share", text = _("Send"),
            callback = function() self:_shareMany(sendable(chosen)) end,
        })
    end

    if #notebooks > 0 then
        table.insert(actions, {
            icon = "notebook.duplicate", text = _("Duplicate"),
            callback = function()
                for _, item in ipairs(notebooks) do
                    Library.duplicate(item.name, self.folder)
                end
                self:_endSelection()
                self:_rebuild()
            end,
        })
        table.insert(actions, {
            icon = "notebook.export", text = _("Export PDF"),
            callback = function() self:_exportMany(notebooks) end,
        })
    end

    table.insert(actions, {
        icon = "notebook.delete", text = _("Delete"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = #chosen == 1
                    and T(_("Delete '%1'?\n\nThis cannot be undone."), chosen[1].name)
                    or T(_("Delete %1 items?\n\nFolders are deleted with everything in them. This cannot be undone."), #chosen),
                ok_text = _("Delete"),
                ok_callback = function() self:_deleteMany(chosen) end,
            })
        end,
    })

    return actions
end

--[[--
The control that changes the order, in the corner of the title row.

Up there rather than among the actions below, for the same reason ticking
everything is: it is about the list you are looking at, not about the things in
it. Its label is the order in force, so what the grid is sorted by is on screen
without opening anything -- a plain "Sort" button answers the question only
after you have tapped it.
--]]
function Gallery:_orderButton()
    return Widgets.textButton{
        text = ORDER_LABELS[self.order],
        icon = "notebook.refresh",
        font_size = 15,
        icon_size = 22,
        callback = function() self:_chooseOrder() end,
    }
end

function Gallery:_chooseOrder()
    local actions = {}
    for _, key in ipairs(Library.ORDER_SEQUENCE) do
        table.insert(actions, {
            -- The one in force is marked rather than left out: a list that
            -- silently omits where you already are makes you count entries to
            -- work out what changed.
            icon = key == self.order and "notebook.open" or "notebook.page",
            text = ORDER_LABELS[key],
            callback = function()
                if key == self.order then return end
                self.order = key
                if G_reader_settings then
                    G_reader_settings:saveSetting("notebook_order", key)
                end
                self:_endSelection()
                self:_rebuild()
            end,
        })
    end
    UIManager:show(ActionMenu:new{ title = _("Sort by"), actions = actions })
end

function Gallery:_renameOne(item)
    self:_askName(item.is_folder and _("Rename folder") or _("Rename notebook"),
        item.name, function(new_name)
            local ok, reason
            if item.is_folder then
                ok, reason = Library.renameFolder(item.rel, new_name)
            else
                ok, reason = Library.rename(item.name, new_name, self.folder)
                if ok then Thumbnail.forget(item.path) end
            end
            if not ok then return self:_error(nameError(reason)) end
            self:_endSelection()
            self:_rebuild()
        end)
end

--[[--
Hands what has been chosen to LocalSend.

A notebook means nothing to a phone -- .scribe is this plugin's own format -- so
it is rendered to a PDF on the way out. An exported PDF is already readable and
goes as it is.

One PDF on its own is sent straight from where it lies. Anything else is staged
into a directory and the directory is what goes: LocalSend's send flow takes one
path, and choosing the target device once per notebook would not be sending a
selection so much as sending several times over.

The staged copies are meant to be temporary and are not deleted here; see
share.lua for why, and for what does delete them.

Rendered one per tick, like the Export action and for the same reason: a dozen
notebooks back to back would freeze the screen for the whole run.
--]]
function Gallery:_shareMany(chosen)
    self:_endSelection()

    if #chosen == 1 and chosen[1].is_pdf then
        return self.on_share(chosen[1].path)
    end

    local staging = Share.stagingDir()
    if not staging then
        return UIManager:show(InfoMessage:new{
            text = _("There is nowhere to prepare the files for sending."),
            timeout = NOTICE_SECONDS,
        })
    end

    local working = InfoMessage:new{
        text = #chosen == 1 and T(_("Preparing '%1'…"), chosen[1].name)
                             or T(_("Preparing %1 items…"), #chosen),
    }
    UIManager:show(working)

    local i, done, failed, last_out = 0, 0, 0, nil
    local function step()
        i = i + 1
        local item = chosen[i]

        if not item then
            UIManager:close(working)
            if done == 0 then
                Library.deleteTree(staging)
                return UIManager:show(InfoMessage:new{
                    text = _("Nothing could be prepared for sending."),
                    timeout = NOTICE_SECONDS,
                })
            end
            if failed > 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("Sending %1; %2 could not be read."), done, failed),
                    timeout = NOTICE_SECONDS,
                })
            end
            -- One file staged on its own goes as a file rather than as a
            -- directory holding one thing, which is what the other device
            -- would otherwise be asked to accept.
            return self.on_share(done == 1 and last_out or staging)
        end

        local out = staging .. "/" .. item.name .. ".pdf"
        local ok
        if item.is_pdf then
            ok = Library.copyFile(item.path, out)
        else
            local doc = Document:new(item.path)
            ok = doc:load() and Export.toPDF(doc, out)
        end
        if ok then
            done, last_out = done + 1, out
        else
            failed = failed + 1
        end

        Safe.later("gallery:share", step)
    end

    -- A tick later, so the message is on screen before the first render blocks.
    Safe.later("gallery:share", step)
end

function Gallery:_deleteMany(chosen)
    for _, item in ipairs(chosen) do
        if item.is_folder then
            Library.deleteFolder(item.rel)
        else
            Library.deletePath(item.path)
            Thumbnail.forget(item.path)
        end
    end
    self:_endSelection()
    self:_rebuild()
end

--[[--
Exports several notebooks, one per tick.

Rendering a notebook to PDF takes long enough to notice, and a dozen of them
back to back would freeze the panel for the whole run with nothing to show for
it. One per tick keeps the screen answering, and the message says which one is
being worked on so the wait is legible rather than mysterious.
--]]
function Gallery:_exportMany(notebooks)
    self:_endSelection()

    local working = InfoMessage:new{
        text = #notebooks == 1 and T(_("Exporting '%1'…"), notebooks[1].name)
                                or T(_("Exporting %1 notebooks…"), #notebooks),
    }
    UIManager:show(working)

    local i, done, failed, last_path = 0, 0, 0, nil
    local function step()
        i = i + 1
        local item = notebooks[i]
        if not item then
            UIManager:close(working)
            self:_rebuild()
            local text
            if failed == 0 and done == 1 then
                text = T(_("Exported to:\n%1"), last_path)
            elseif failed == 0 then
                text = T(_("Exported %1 notebooks."), done)
            else
                text = T(_("Exported %1 of %2; %3 could not be read."),
                    done, #notebooks, failed)
            end
            return UIManager:show(InfoMessage:new{
                text = text,
                timeout = NOTICE_SECONDS,
            })
        end

        local doc = Document:new(item.path)
        if doc:load() then
            local out = Library.abs(self.folder) .. "/" .. item.name .. ".pdf"
            if Export.toPDF(doc, out) then
                done, last_path = done + 1, out
            else
                failed = failed + 1
            end
        else
            failed = failed + 1
        end
        Safe.later("gallery:export", step)
    end

    Safe.later("gallery:export", step)
end

--[[--
Moves everything chosen into a folder picked from the whole tree.

The list is every folder there is, not just the ones in view, because the point
of moving something is usually to get it out of where you are looking.
--]]
function Gallery:_moveSelection(chosen)
    local actions = {
        { icon = "notebook.folder", text = _("Notebooks (top level)"),
          callback = function() self:_moveInto(chosen, "") end },
    }

    for _, folder in ipairs(Library.allFolders()) do
        -- Indented so a tree that is more than one deep can still be read.
        local label = string.rep("   ", folder.depth) .. folder.name
        table.insert(actions, {
            icon = "notebook.folder", text = label,
            callback = function() self:_moveInto(chosen, folder.rel) end,
        })
    end

    UIManager:show(ActionMenu:new{ title = _("Move to"), actions = actions })
end

function Gallery:_moveInto(chosen, target)
    local moved, refused = 0, 0
    for _, item in ipairs(chosen) do
        local rel = item.rel or Library.relOf(item.path)
        if rel and Library.moveTo(rel, target) then
            if not item.is_folder then Thumbnail.forget(item.path) end
            moved = moved + 1
        else
            refused = refused + 1
        end
    end

    self:_endSelection()
    self:_rebuild()

    if refused > 0 then
        -- The one case that reaches here is a folder being moved into itself.
        self:_error(T(_("Moved %1; %2 could not be moved there."), moved, refused))
    end
end

--[[--
Gives the cards' buffers back when the gallery goes away.

Also stops any thumbnail run still in flight: it would go on loading notebooks
and rasterising pages for a screen nobody is looking at.
--]]
function Gallery:onCloseWidget()
    self.closed = true
    self:_cancelThumbnails()
    self:_freeWidgets()
end

function Gallery:onShow()
    self:_layout()
    return true
end

-- Every way the event loop can enter this screen, behind a pcall and a
-- watchdog; see safe.lua. A fault here closes the notebook plugin, not KOReader.
return Safe.widget(Gallery, "gallery")
