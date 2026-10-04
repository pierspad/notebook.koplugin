--[[--
The notebook gallery: a grid of cards, the way a bookshelf is.

A list of file names with dates beside them tells you nothing about what is in a
notebook. A page of handwriting is recognisable at a glance, so each card shows
its first page and you find the one you want by looking rather than by reading.

Folders are ordinary directories on disk, shown as cards of their own.

@module notebook.gallery
--]]--

local ActionMenu = require("actionmenu")
local Updater = require("updater")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Document = require("document")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Library = require("library")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local NewNotebook = require("newnotebook")
local Thumbnail = require("thumbnail")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("i18n")
local Safe = require("safe")
local Share = require("share")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template

local Screen = Device.screen

local COLUMNS = 3

local function isExport(item)
    return item.is_export or item.is_pdf or item.is_xopp
end

-- One card ----------------------------------------------------------------------

--[[--
The notebook a card's picture comes from.

An exported PDF shows the notebook it came from. A generic document icon tells
you nothing about which export you are looking at, and the ribbon painted over
the corner already says it is a PDF.
--]]
local function pictureSource(item)
    if item.is_folder then return nil end
    if isExport(item) then return (item.path:gsub("%.[^./]+$", ".scribe")) end
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
local Card = require("gallerycard")
local thumbSize = Card.thumbSize

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
        GalleryPan = { GestureRange:new{ ges = "pan", range = self.dimen } },
        GalleryPanRelease = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
        GalleryHoldPan = { GestureRange:new{ ges = "hold_pan", range = self.dimen } },
        GalleryHoldRelease = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
    }
end

--[[--
Lays the grid out inside whatever rectangle we have been given.

Everything reads from self.dimen rather than the screen, because the launcher
bar shrinks us to the area above it and moves our top edge down. Measuring the
screen instead would put the last row of cards underneath the bar.
--]]
function Gallery:_layout()
    self:_listenForSelectionPen()
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
A header button at the given level of detail.

A mode is either a font size -- the icon beside the label, both scaled to it --
or one of the two ways of giving up. The sizes come first and are tried largest
first, because shrinking a button is a much smaller loss than taking its icon or
its words away.
--]]
require("galleryheader")(Gallery)

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

--[[--
Rebuilds the grid after the contents change.

Nothing to rebuild once the gallery is gone, and the two callers that can
arrive after it has are the reason this is checked here rather than at each of
them. Exporting and sharing work through a list one tick at a time, and the
reader is free to leave the gallery while that is running -- it can take a
while, which is exactly why it is spread over ticks. Finishing after that used
to relist the folder, build a screenful of cards nobody would see, and then
mark the whole stack dirty, so a book being read was repainted from underneath
by a screen that had been closed minutes earlier. The files still get written;
it is only the screen that is no longer anyone's business.
--]]
function Gallery:_rebuild()
    if self.closed then return end
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

-- Test the swept segment, so fast drags also select cards between samples.
local function crossesCard(a, b, r)
    local lo, hi = 0, 1
    for _, axis in ipairs({ {a.x, b.x-a.x, r.x, r.x+r.w},
                              {a.y, b.y-a.y, r.y, r.y+r.h} }) do
        local p, d, mn, mx = unpack(axis)
        if d == 0 then
            if p < mn or p > mx then return false end
        else
            local t0, t1 = (mn-p)/d, (mx-p)/d
            if t0 > t1 then t0, t1 = t1, t0 end
            lo, hi = math.max(lo,t0), math.min(hi,t1)
            if lo > hi then return false end
        end
    end
    return true
end

-- The raw pen stream avoids gesture thresholds and hold-to-pan conversion.
function Gallery:_listenForSelectionPen()
    local input = Device.input
    if not input or not input.registerStylusCallback then return end
    if not self.selection then
        if self.selection_pen_cb and input.stylus_callback == self.selection_pen_cb then
            input:registerStylusCallback(self.previous_selection_callback)
            self.previous_selection_callback = nil
        end
        return
    end
    self.selection_pen_cb = self.selection_pen_cb or Safe.wrap("gallery:stylus", function(_, slot)
        if UIManager:getTopmostVisibleWidget() ~= self or not self.selection then return false end
        if slot.id == -1 then
            local active = self.selection_drag ~= nil
            self:onGalleryPanRelease()
            return active
        end
        if not slot.x or not slot.y then return false end
        local pos = {x=slot.x, y=slot.y}
        if not self.selection_drag then
            local over_card = false
            for _, card in ipairs(self.cards or {}) do
                if crossesCard(pos, pos, card.dimen) then over_card = true; break end
            end
            if not over_card then return false end
            self.selection_drag = pos
            self.selection_pen_start = pos
            self.selection_pen_moved = false
            return true
        end
        local start = self.selection_pen_start
        if start and not self.selection_pen_moved then
            local dx, dy = pos.x-start.x, pos.y-start.y
            if dx*dx+dy*dy < Screen:scaleBySize(6)^2 then return true end
            self.selection_pen_moved = true
        end
        return self:onGalleryPan(nil, {pos=pos})
    end)
    if input.stylus_callback ~= self.selection_pen_cb then
        self.previous_selection_callback = input.stylus_callback
        input:registerStylusCallback(self.selection_pen_cb)
    end
    Safe.onShutdown(self, function()
        if input.stylus_callback == self.selection_pen_cb
            or Safe.failed and input.stylus_callback == nil then
            input:registerStylusCallback(self.previous_selection_callback)
        end
        self.closed = true
        self:_cancelThumbnails()
    end)
end

function Gallery:onGalleryHoldPan(_, ges)
    return self:onGalleryPan(nil, ges)
end

function Gallery:onGalleryHoldRelease()
    return self:onGalleryPanRelease()
end

function Gallery:onGalleryPan(_, ges)
    if not self.selection or not ges or not ges.pos then return false end
    local previous = self.selection_drag or ges.start_pos or ges.pos
    self.selection_drag = {x=ges.pos.x, y=ges.pos.y}
    for _, card in ipairs(self.cards or {}) do
        if not self.selection[card.item.path] and crossesCard(previous, ges.pos, card.dimen) then
            self.selection[card.item.path] = card.item
            card.selected = true
            -- Reuse the loaded thumbnail; update only this card's region.
            UIManager:setDirty(self, "ui", card.dimen)
        end
    end
    return true
end

function Gallery:onGalleryPanRelease()
    if not self.selection_drag then return false end
    local start, moved = self.selection_pen_start, self.selection_pen_moved
    self.selection_drag, self.selection_pen_start, self.selection_pen_moved = nil, nil, nil
    if start and not moved then
        for _, card in ipairs(self.cards or {}) do
            if crossesCard(start, start, card.dimen) then self:_tapped(card.item); return true end
        end
    end
    self:_layout()
    self:_repaint()
    return true
end

function Gallery:onGallerySwipe(_, ges)
    if self.selection then return true end
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
    if Updater.installing or Updater.installed then
        return self:_error(_("Restart KOReader after the update finishes before opening a notebook."))
    end
    if item.is_folder then
        return self:_goTo(item.rel)
    end
    if item.is_pdf then
        return self:_openPDF(item)
    end
    if item.is_svg then
        return self:_error(_("Open this SVG file in a browser or vector editor."))
    end
    if item.is_xopp then
        return self:_error(_("Open this XOPP file with Xournal++."))
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

function Gallery:_askName(title, initial, commit, presets)
    local dialog
    local args = {
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
    if presets then
        local row = {}
        for _, name in ipairs(presets) do
            row[#row + 1] = {text=name, callback=function()
                UIManager:close(dialog)
                commit(name)
            end}
        end
        table.insert(args.buttons, 1, row)
    end
    dialog = InputDialog:new(args)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Gallery:_exportMenu(notebooks, selected_pages)
    local actions = {
        {icon="notebook.export", text=_("PDF"), callback=function() self:_exportMany(notebooks,"pdf",selected_pages) end},
        {icon="notebook.export", text=_("SVG (ink only)"), callback=function() self:_exportMany(notebooks,"svg",selected_pages) end},
        {icon="notebook.export", text=_("Xournal++"), callback=function() self:_exportMany(notebooks,"xopp",selected_pages) end},
    }
    if #notebooks==1 and not selected_pages then
        actions[#actions+1]={icon="notebook.page",text=_("Choose pages…"),callback=function()
            local doc=Document:new(notebooks[1].path)
            if not doc:load() then return self:_error(_("Could not read notebook.")) end
            require("exportpagesdialog").show(doc,function(indices) self:_exportMenu(notebooks,indices) end)
        end}
    end
    UIManager:show(ActionMenu:new{
        title = selected_pages and _("Export selected pages") or _("Export"),
        actions = actions,
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

function Gallery:_importPDF()
    local PathChooser=require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory=false,
        path=G_reader_settings:readSetting("notebook_pdf_folder") or "/mnt/us/documents",
        onConfirm=function(path)
            if not path:lower():match("%.pdf$") then return self:_error(_("Choose a PDF file.")) end
            local ok,count,sizes=pcall(require("pdfbackground").inspect,path)
            if not ok or count<1 then return self:_error(_("Could not open this PDF.")) end
            G_reader_settings:saveSetting("notebook_pdf_folder",path:match("^(.*)/"))
            local name=Library.uniqueName(path:match("([^/]+)$"):sub(1,-5),self.folder)
            if not Library.ensureDir(".pdfs") then return self:_error(_("Could not create the notebook folder.")) end
            local source=Library.abs(".pdfs/"..os.time().."-"..name..".pdf")
            local suffix=0
            while lfs.attributes(source) do
                suffix=suffix+1
                source=Library.abs(".pdfs/"..os.time().."-"..suffix.."-"..name..".pdf")
            end
            if not Library.copyFile(path,source) then return self:_error(_("Could not open this PDF.")) end
            local doc=Document:new(Library.pathFor(name,self.folder))
            doc.pages={}
            for i=1,count do
                doc.pages[i]={strokes={},background={file=source,page=i,size=sizes[i]}}
            end
            if not doc:save() then os.remove(source); return self:_error(_("Could not save the notebook.")) end
            self:_rebuild()
            if self.on_open then self.on_open(name,self.folder) end
        end,
    })
end

function Gallery:_createFolder()
    self:_askName(_("New folder"), "", function(name)
        local ok, reason = Library.createFolder(name, self.folder)
        if not ok then return self:_error(nameError(reason)) end
        self:_rebuild()
    end, {_("Work"), _("Personal"), os.date("%Y-%m")})
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
        if not item.is_folder and not isExport(item) then table.insert(out, item) end
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
        if not isExport(item) then
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
        table.insert(actions, {icon="notebook.export", text=_("Export"),
            callback=function() self:_exportMenu(notebooks) end})
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

function Gallery:_deleteMany(chosen)
    for _, item in ipairs(chosen) do
        if item.is_folder then
            Library.deleteFolder(item.rel)
        else
            Library.deletePath(item.path)
            Thumbnail.forget(item.path)
        end
    end
    self.selection, self.selection_drag = nil, nil
    self:_rebuild()
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
    Safe.clearShutdown(self)
    if Device.input and Device.input.stylus_callback == self.selection_pen_cb
        and self.selection_pen_cb then
        Device.input:registerStylusCallback(self.previous_selection_callback)
    end
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
require("gallerythumbnails")(Gallery)
require("galleryexport")(Gallery, isExport, notebooksOnly)

return Safe.widget(Gallery, "gallery")
