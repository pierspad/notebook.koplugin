#!/usr/bin/env luajit
--[[--
Tests for the gallery's painting and repainting contract.

The bugs these pin down were all invisible to the logic tests: the gallery
computed the right things and then failed to get them onto the panel. What is
checked here is therefore not what the gallery decides, but what it leaves
behind -- the pixels it covers, the widgets it marks for repainting, the
buffers it releases, and the work it refuses to do before the first paint.

Run with:  luajit spec/gallery.lua   (from the plugin directory)
--]]--

package.path = "./?.lua;./spec/?.lua;" .. package.path

local support = require("support")
local uistubs = require("uistubs")

-- Test framework ---------------------------------------------------------------

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local function assertEq(got, want, what)
    if got ~= want then
        error(string.format("%s: got %s, want %s", what or "value",
            tostring(got), tostring(want)), 2)
    end
end

local function assertTrue(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

-- A blitbuffer that only remembers the rectangles painted into it, so a
-- full-screen layout can be checked without allocating a full-screen grid.
local RectBB = {}
RectBB.__index = RectBB

function RectBB.new()
    return setmetatable({ rects = {} }, RectBB)
end

function RectBB:paintRect(x, y, w, h)
    table.insert(self.rects, { x = x, y = y, w = w, h = h })
end

RectBB.paintRoundedRect = RectBB.paintRect
RectBB.paintBorder = function() end
RectBB.paintCircle = function() end

--- True if (x, y) falls inside anything painted.
function RectBB:painted(x, y)
    for _, r in ipairs(self.rects) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            return true
        end
    end
    return false
end

--- The first point of the rectangle left unpainted, sampled on a grid.
function RectBB:firstGap(x, y, w, h, steps)
    steps = steps or 32
    for i = 0, steps do
        for j = 0, steps do
            local px = x + math.floor(i * (w - 1) / steps)
            local py = y + math.floor(j * (h - 1) / steps)
            if not self:painted(px, py) then return px, py end
        end
    end
    return nil
end

-- Fixture ------------------------------------------------------------------------

local ROOT = "/data/scribe"

--- A filesystem holding `n` notebooks at the root, plus one subfolder.
local function fixture(n)
    local fs = {
        ["/data"] = { mode = "directory", modification = 0 },
        [ROOT] = { mode = "directory", modification = 0 },
        [ROOT .. "/Trip"] = { mode = "directory", modification = 10 },
    }
    for i = 1, n do
        fs[ROOT .. "/note" .. i .. ".scribe"] =
            { mode = "file", modification = 100 + i, size = 10 }
    end
    fs[ROOT .. "/Trip/inner.scribe"] = { mode = "file", modification = 5, size = 10 }
    fs[ROOT .. "/export.pdf"] = { mode = "file", modification = 90, size = 10 }
    return fs
end

local function newGallery(n, fields)
    -- "safe" among them because it caches UIManager at load: left over from a
    -- previous test it would schedule into that test's recorder, not this one's.
    for _, name in ipairs{ "gallery", "library", "actionmenu", "export",
                           "document", "renderer", "stroke", "safe" } do
        package.loaded[name] = nil
    end
    local fs = fixture(n or 12)
    support.installStubs()
    local rec = uistubs.install(fs)
    local Gallery = require("gallery")
    return Gallery:new(fields or {}), rec
end

--- Every ImageWidget and IconWidget currently in a widget tree.
local function pictures(widget, found)
    found = found or {}
    if type(widget) ~= "table" then return found end
    for _, child in ipairs(widget) do pictures(child, found) end
    if widget.icon or widget.file then table.insert(found, widget) end
    return found
end

-- Painting ------------------------------------------------------------------------

io.write("gallery painting\n")

test("the gallery covers every pixel of the rectangle it was given", function()
    local gallery = newGallery(12)
    local bb = RectBB.new()
    gallery:paintTo(bb, 0, 0)
    local gx, gy = bb:firstGap(0, 0, gallery.dimen.w, gallery.dimen.h)
    assertTrue(gx == nil, string.format(
        "left unpainted at (%s, %s) -- whatever was on screen there stays",
        tostring(gx), tostring(gy)))
end)

test("a half-empty folder still covers the whole rectangle", function()
    -- The failure this pins down: fewer cards means a shorter layout, and the
    -- strip below it kept the previous screen -- a keyboard, or the last folder.
    local gallery = newGallery(1)
    local bb = RectBB.new()
    gallery:paintTo(bb, 0, 0)
    local gx, gy = bb:firstGap(0, 0, gallery.dimen.w, gallery.dimen.h)
    assertTrue(gx == nil, string.format("left unpainted at (%s, %s)",
        tostring(gx), tostring(gy)))
end)

--- The tappable widget whose subtree draws `icon`.
local function withIcon(w, icon)
    if type(w) ~= "table" then return nil end
    local function hasIcon(node)
        if type(node) ~= "table" then return false end
        if node.icon == icon then return true end
        for _, child in ipairs(node) do
            if hasIcon(child) then return true end
        end
        return false
    end
    if w.onTap and hasIcon(w) then return w end
    for _, child in ipairs(w) do
        local found = withIcon(child, icon)
        if found then return found end
    end
    return nil
end

test("there is always a way out, even at the top", function()
    -- Nothing else on this screen closes it. Until the launcher bar was
    -- understood, leaving meant tapping another tab -- and the bar cannot close
    -- a screen it did not open, so a device without it had no way out at all.
    local gallery, rec = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    assertEq(gallery.folder, "", "the fixture did not start at the top")

    local back = withIcon(gallery.header_row, "chevron.left")
    assertTrue(back ~= nil, "no back control at the top level")

    back.onTap()
    assertEq(rec.closed[#rec.closed], gallery, "the back arrow did not close it")
end)

test("inside a folder the same arrow goes up instead", function()
    local gallery, rec = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    gallery:_goTo("Trip")
    rec.closed = {}

    local back = withIcon(gallery.header_row, "chevron.left")
    assertTrue(back ~= nil, "no back control inside a folder")
    back.onTap()

    assertEq(gallery.folder, "", "the arrow did not go up a level")
    assertEq(#rec.closed, 0, "going up closed the notebooks instead")
end)

-- Repainting ----------------------------------------------------------------------

io.write("gallery repainting\n")

test("opening a folder marks something dirty, so the new cards get painted", function()
    local gallery, rec = newGallery(12)
    gallery:paintTo(RectBB.new(), 0, 0)
    rec.dirty = {}
    gallery:_goTo("Trip")
    local last = rec.lastDirty()
    assertTrue(last ~= nil, "no repaint was requested at all")
    assertTrue(last.widget ~= nil,
        "setDirty was called without a widget: UIManager repaints nothing and " ..
        "the panel is refreshed from an unchanged buffer")
end)

test("turning the page marks something dirty", function()
    local gallery, rec = newGallery(30)
    gallery:paintTo(RectBB.new(), 0, 0)
    rec.dirty = {}
    gallery:_turnPage(1)
    local last = rec.lastDirty()
    assertTrue(last ~= nil and last.widget ~= nil,
        "the second page is laid out but never painted")
end)

test("the card tap targets follow the cards after a rebuild", function()
    local gallery = newGallery(12)
    gallery:paintTo(RectBB.new(), 0, 0)
    gallery:_goTo("Trip")
    gallery:paintTo(RectBB.new(), 0, 0)
    local card
    local function findCard(w)
        if type(w) ~= "table" then return end
        if w.item and w.on_open then card = card or w end
        for _, child in ipairs(w) do findCard(child) end
    end
    findCard(gallery)
    assertTrue(card ~= nil, "no card in the tree")
    assertTrue(card.dimen.y > 0,
        "a card's gesture range is still at the top-left corner, so taps land " ..
        "on the wrong notebook")
end)

test("a wrapper put around the grid survives a rebuild", function()
    -- What the Simple UI launcher bar does: take our first child, wrap it, and
    -- store the result back. A layout that reassigns self[1] throws the bar away.
    local gallery = newGallery(12)
    local inner = gallery[1]
    local wrapper = { inner, wrapped = true }
    function wrapper:paintTo(bb, x, y) self[1]:paintTo(bb, x, y) end
    function wrapper:getSize() return self[1]:getSize() end
    function wrapper:free() self[1]:free() end
    gallery[1] = wrapper

    gallery:_rebuild()

    assertTrue(gallery[1] == wrapper,
        "the layout replaced the launcher bar's wrapper, so the bar is no " ..
        "longer painted even though it still answers taps")
    assertTrue(inner[1] ~= nil, "the new grid did not land inside the wrapper")
end)

-- Memory ---------------------------------------------------------------------------

io.write("gallery memory\n")

test("the previous cards are released when the grid is rebuilt", function()
    local gallery = newGallery(12)
    gallery:paintTo(RectBB.new(), 0, 0)
    local before = pictures(gallery)
    assertTrue(#before > 0, "no pictures in the first layout")
    gallery:_goTo("Trip")
    local freed = 0
    for _, p in ipairs(before) do
        if (p.freed or 0) > 0 then freed = freed + 1 end
    end
    assertEq(freed, #before, "pictures freed after rebuild")
end)

test("a PDF card's ribbon is released too", function()
    local gallery = newGallery(4)
    gallery:paintTo(RectBB.new(), 0, 0)
    local ribbon
    local function find(w)
        if type(w) ~= "table" then return end
        if w.ribbon then ribbon = ribbon or w.ribbon end
        for _, child in ipairs(w) do find(child) end
    end
    find(gallery)
    assertTrue(ribbon ~= nil, "no PDF card in the fixture")
    gallery:_goTo("Trip")
    assertTrue((ribbon.freed or 0) > 0,
        "the ribbon hangs off the card, outside the tree, so nothing frees it")
end)

test("closing the gallery releases its pictures", function()
    local gallery = newGallery(12)
    gallery:paintTo(RectBB.new(), 0, 0)
    local shown = pictures(gallery)
    gallery:onCloseWidget()
    for _, p in ipairs(shown) do
        assertTrue((p.freed or 0) > 0, "a picture survived the close")
    end
end)

-- Thumbnails -------------------------------------------------------------------------

io.write("gallery thumbnails\n")

test("opening a folder generates no thumbnails before the first paint", function()
    local _, rec = newGallery(12)
    assertEq(#rec.thumbnails, 0,
        "thumbnails rasterised during layout: the gallery is unusable until " ..
        "every notebook on the page has been loaded and drawn")
end)

test("thumbnails are generated afterwards, one tick at a time", function()
    local gallery, rec = newGallery(12)
    gallery:paintTo(RectBB.new(), 0, 0)
    rec.runTicks()
    assertTrue(#rec.thumbnails > 0, "no thumbnail was ever generated")
end)

test("a notebook that cannot produce a thumbnail is not retried forever", function()
    local gallery, rec = newGallery(12)
    -- Nothing generated: every notebook fails, as an unreadable one would.
    package.loaded["thumbnail"].get = function(path)
        table.insert(rec.thumbnails, path)
        return nil
    end
    gallery:paintTo(RectBB.new(), 0, 0)
    rec.runTicks()
    local first_round = #rec.thumbnails
    assertTrue(first_round > 0, "nothing was attempted")
    gallery:paintTo(RectBB.new(), 0, 0)
    rec.runTicks()
    assertEq(#rec.thumbnails, first_round,
        "the same failing notebooks were rasterised again")
end)

test("a notebook that failed once is tried again after it is written to", function()
    local gallery, rec = newGallery(12)
    package.loaded["thumbnail"].get = function(path)
        table.insert(rec.thumbnails, path)
        return nil
    end
    gallery:paintTo(RectBB.new(), 0, 0)
    rec.runTicks()
    local tried = rec.thumbnails[1]
    assertTrue(tried ~= nil, "nothing was attempted")

    rec.thumbnails = {}
    rec.fs[tried].modification = rec.fs[tried].modification + 60
    gallery:_rebuild()
    rec.runTicks()

    local retried = false
    for _, path in ipairs(rec.thumbnails) do
        if path == tried then retried = true end
    end
    assertTrue(retried, "the notebook stayed blank even after being written to")
end)

-- Choosing several things --------------------------------------------------------

io.write("gallery selection\n")

--- Every card in the tree, in order.
local function cards(widget, found)
    found = found or {}
    if type(widget) ~= "table" then return found end
    if widget.item and widget.on_open then table.insert(found, widget) end
    for _, child in ipairs(widget) do cards(child, found) end
    return found
end

--- The tappable widget whose label reads `text`, anywhere in a tree.
local function labelled(w, text)
    if type(w) ~= "table" then return nil end
    local function hasText(node)
        if type(node) ~= "table" then return false end
        if node.text == text then return true end
        for _, child in ipairs(node) do
            if hasText(child) then return true end
        end
        return false
    end
    if w.onTap and hasText(w) then return w end
    for _, child in ipairs(w) do
        local found = labelled(child, text)
        if found then return found end
    end
    return nil
end

test("holding a card starts choosing, with that card chosen", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    local first = cards(gallery)[1]
    assertTrue(gallery.selection == nil, "already choosing before the hold")

    first:onHold()
    assertTrue(gallery.selection ~= nil, "the hold did not start a selection")
    assertEq(gallery:_selectionCount(), 1, "chosen")
    assertTrue(gallery.selection[first.item.path] ~= nil, "the wrong item is chosen")
end)

test("a tap ticks and unticks once something is chosen", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    local list = cards(gallery)
    list[1]:onHold()

    -- The cards are rebuilt on every change, so they have to be found again.
    local second = cards(gallery)[2]
    second:onTap()
    assertEq(gallery:_selectionCount(), 2, "after ticking a second")

    local again
    for _, card in ipairs(cards(gallery)) do
        if card.item.path == second.item.path then again = card end
    end
    again:onTap()
    assertEq(gallery:_selectionCount(), 1, "after unticking it")
end)

test("unticking the last one leaves selection mode", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    local first = cards(gallery)[1]
    first:onHold()
    for _, card in ipairs(cards(gallery)) do
        if card.item.path == first.item.path then card:onTap() end
    end
    assertTrue(gallery.selection == nil,
        "still choosing, with nothing chosen and no way to tell")
end)

test("a tap opens as usual when nothing is being chosen", function()
    local gallery = newGallery(6)
    local opened
    gallery.on_open = function(name) opened = name end
    gallery:paintTo(RectBB.new(), 0, 0)
    for _, card in ipairs(cards(gallery)) do
        if not card.item.is_folder and not card.item.is_pdf then
            card:onTap()
            break
        end
    end
    assertTrue(opened ~= nil, "a plain tap no longer opens a notebook")
end)

test("chosen cards are marked and the others are marked as not chosen", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    cards(gallery)[1]:onHold()

    local marked, unmarked = 0, 0
    for _, card in ipairs(cards(gallery)) do
        if card.selected == true then marked = marked + 1
        elseif card.selected == false then unmarked = unmarked + 1 end
    end
    assertEq(marked, 1, "cards drawn as chosen")
    assertTrue(unmarked > 0, "the rest are not drawn as choosable")
end)

test("changing folder drops the selection", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    cards(gallery)[1]:onHold()
    gallery:_goTo("Trip")
    assertTrue(gallery.selection == nil,
        "the selection followed us into a folder its items are not in")
end)

test("select all takes the whole folder, not just the page on screen", function()
    local gallery = newGallery(40)
    gallery:paintTo(RectBB.new(), 0, 0)
    cards(gallery)[1]:onHold()
    assertTrue(#cards(gallery) < #gallery.items, "the fixture fits on one page")

    local select_all = labelled(gallery.header_row, "All")
    assertTrue(select_all ~= nil, "no select-all button in the header")
    select_all.onTap()

    assertEq(gallery:_selectionCount(), #gallery.items,
        "select all stopped at the page boundary")
end)

test("the actions are in the header, not behind another tap", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    cards(gallery)[1]:onHold()

    for _, text in ipairs{ "Move", "Delete" } do
        assertTrue(labelled(gallery.header_row, text) ~= nil,
            text .. " is not on screen while something is chosen")
    end
end)

test("only what applies to the chosen things is offered", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    -- Folders sort first, so the first card is one.
    local folder = cards(gallery)[1]
    assertTrue(folder.item.is_folder, "the fixture put a notebook first")
    folder:onHold()

    assertTrue(labelled(gallery.header_row, "Export PDF") == nil,
        "offered to export a folder")
    assertTrue(labelled(gallery.header_row, "Delete") ~= nil,
        "a folder can certainly be deleted")
end)

--[[
Sending leans on the LocalSend plugin, which is a separate thing the user may
never have installed. Scribe finds out by being handed a way to send, or not
being handed one, and what is offered has to follow that exactly: offering to
send with nothing to send through is a button that can only disappoint.

Checked against the list of actions rather than against the header, because the
header renders that list with its words or as bare icons depending on how many
of them fit -- so neither a label nor an icon is reliably there, and neither is
what is being decided here.
--]]
local function offers(gallery, text)
    for _, action in ipairs(gallery:_bulkActions(gallery:_selected())) do
        if action.text == text then return action end
    end
end

local function cardWhere(gallery, pred)
    for _, card in ipairs(cards(gallery)) do
        if pred(card.item) then return card end
    end
end

test("sending is not offered when there is nowhere to send", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()

    assertTrue(offers(gallery, "Send") == nil,
        "offered to send with no LocalSend plugin installed")
    assertTrue(offers(gallery, "Export PDF") ~= nil,
        "exporting should be unaffected by any of this")
end)

test("sending is offered once there is somewhere to send", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()

    assertTrue(offers(gallery, "Send") ~= nil,
        "a share hook was given and Send did not appear")
end)

test("a folder is not something that can be sent", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return it.is_folder end):onHold()

    assertTrue(offers(gallery, "Send") == nil, "offered to send a folder")
end)

test("a whole selection can be sent, not just one thing", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    local chosen = {}
    for _, card in ipairs(cards(gallery)) do
        if not card.item.is_folder then chosen[card.item.path] = card.item end
    end
    gallery.selection = chosen
    gallery:_layout()

    assertTrue(offers(gallery, "Send") ~= nil,
        "several things chosen and Send disappeared")
end)

test("a lone PDF is sent from where it lies, not staged first", function()
    local sent
    local gallery = newGallery(6, { on_share = function(p) sent = p end })
    gallery:paintTo(RectBB.new(), 0, 0)
    local pdf = cardWhere(gallery, function(it) return it.is_pdf end)
    assertTrue(pdf ~= nil, "the fixture has no exported PDF in it")

    gallery.selection = { [pdf.item.path] = pdf.item }
    gallery:_shareMany({ pdf.item })

    assertEq(sent, pdf.item.path, "sent something other than the PDF itself")
    assertTrue(gallery.selection == nil, "the selection outlived the send")
end)

--[[
The header gave up its icons when a sixth action was added: it fits by stepping
down from icon-and-word buttons to plain words, and one more button was enough
to push it over. Words alone where there had been recognisable buttons reads as
a fault rather than as a feature.
--]]
test("the actions keep their icons once there are a lot of them", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()

    assertTrue(withIcon(gallery.header_row, "notebook.export") ~= nil,
        "Export PDF lost its icon")
    assertTrue(withIcon(gallery.header_row, "notebook.delete") ~= nil,
        "Delete lost its icon")
end)

test("the header is the same height whether or not anything is chosen", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    local idle = gallery.header_row:getSize().h

    cardWhere(gallery, function(it) return not it.is_folder end):onHold()
    assertEq(gallery.header_row:getSize().h, idle,
        "the grid would jump every time something is ticked")
end)

--[[
The actions used to sit beside the title when there were few of them and drop to
a row of their own when there were many, so which of the two places to look for
them depended on what had been ticked. They now keep the second row at all
times, and only the control that ticks and unticks everything -- which is about
the selection rather than about what is in it -- stays up beside the count.
--]]
local function rowOf(gallery, text)
    for i, child in ipairs(gallery.header_row) do
        if labelled(child, text) then return i end
    end
end

test("the actions are on the second row, whatever is chosen", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    assertEq(rowOf(gallery, "New notebook"), 3, "row the ordinary actions are on")

    cardWhere(gallery, function(it) return not it.is_folder end):onHold()
    assertEq(rowOf(gallery, "Delete"), 3, "row the selection actions are on")
    assertEq(rowOf(gallery, "Export PDF"), 3, "row Export PDF is on")
end)

test("ticking everything stays up beside the count", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()

    assertEq(rowOf(gallery, "All"), 1, "row the select-all control is on")
end)

test("with everything ticked it offers to untick instead", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()

    local all = labelled(gallery.header_row, "All")
    all.onTap()
    assertEq(gallery:_selectionCount(), #gallery.items, "everything should be ticked")

    local none = labelled(gallery.header_row, "None")
    assertTrue(none ~= nil, "still offering to tick what is already ticked")
    none.onTap()
    assertEq(gallery:_selectionCount(), 0, "unticking everything")
end)

test("the buttons keep one size as things are ticked", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()
    -- One notebook chosen offers everything there is; ticking more takes
    -- actions away rather than adding them.
    local one = gallery.header_row[3]:getSize().h

    labelled(gallery.header_row, "All").onTap()
    assertEq(gallery.header_row[3]:getSize().h, one,
        "the lettering changed size as more was ticked")
end)

test("icons sit beside the words, not above them", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    cardWhere(gallery, function(it) return not it.is_folder end):onHold()

    local button = withIcon(gallery.header_row, "notebook.export")
    assertTrue(button ~= nil, "Export PDF has no icon at all")
    -- Side by side, a button is wider than it is tall; stacked it is not.
    local size = button:getSize()
    assertTrue(size.w > size.h,
        string.format("button is %dx%d -- the icon is above the label", size.w, size.h))
end)

test("the header keeps one height through every state", function()
    local gallery = newGallery(6, { on_share = function() end })
    gallery:paintTo(RectBB.new(), 0, 0)
    local idle = gallery.header_row:getSize().h

    cardWhere(gallery, function(it) return not it.is_folder end):onHold()
    assertEq(gallery.header_row:getSize().h, idle, "with one thing chosen")

    labelled(gallery.header_row, "All").onTap()
    assertEq(gallery.header_row:getSize().h, idle, "with everything chosen")

    gallery.selection = {}
    gallery:_layout()
    assertEq(gallery.header_row:getSize().h, idle, "choosing, with nothing ticked")
end)

--[[
Sorting. What the grid is ordered by is a property of the list, so its control
sits in the corner of the title row beside the count, not among the actions that
apply to what has been ticked.
--]]
test("the order is named on the button, not hidden behind it", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)

    assertTrue(labelled(gallery.header_row, "Last edited") ~= nil,
        "the header does not say what the grid is sorted by")
    assertEq(rowOf(gallery, "Last edited"), 1, "row the order control is on")
end)

test("choosing an order re-sorts the grid and is remembered", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    -- The fixture writes note1 oldest through note6 newest, so by name the
    -- first notebook is note1 and by recency it is note6.
    local function firstNotebook()
        for _, item in ipairs(gallery.items) do
            if not item.is_folder and not item.is_pdf then return item.name end
        end
    end
    assertEq(firstNotebook(), "note6", "the default order is most recent first")

    gallery.order = "name"
    gallery:_rebuild()
    assertEq(firstNotebook(), "note1", "sorted by name")

    gallery.order = "oldest"
    gallery:_rebuild()
    assertEq(firstNotebook(), "note1", "sorted by least recently edited")
end)

test("every order settles ties the same way, so the grid cannot shuffle", function()
    local Library = require("library")
    local a = { name = "b", modified = 5 }
    local b = { name = "a", modified = 5 }
    for _, key in ipairs(Library.ORDER_SEQUENCE) do
        local compare = Library.ORDERS[key].compare
        assertTrue(compare(a, b) ~= compare(b, a),
            key .. " puts two items written in the same second in no order at all")
    end
end)

test("the Select button starts choosing without holding anything", function()
    local gallery = newGallery(6)
    gallery:paintTo(RectBB.new(), 0, 0)
    local select = labelled(gallery.header_row, "Select")
    assertTrue(select ~= nil, "no way into choosing except a hold")

    select.onTap()
    assertTrue(gallery.selection ~= nil, "the button did not start a selection")
    assertEq(gallery:_selectionCount(), 0, "chosen to begin with")
    assertTrue(labelled(gallery.header_row, "Delete") == nil,
        "offered to delete an empty selection")

    cards(gallery)[1]:onTap()
    assertEq(gallery:_selectionCount(), 1, "a tap did not tick a card")
end)

-- Moving things about ----------------------------------------------------------------

io.write("moving things\n")

test("a notebook moved into a folder is there and not here", function()
    local gallery, rec = newGallery(4)
    local Library = require("library")
    local before = #gallery.items
    local item
    for _, candidate in ipairs(gallery.items) do
        if not candidate.is_folder and not candidate.is_pdf then item = candidate end
    end
    assertTrue(item ~= nil, "no notebook in the fixture")

    -- os.rename is what Library uses; the stub filesystem needs it honoured.
    local real_rename = os.rename
    os.rename = function(from, to)
        rec.fs[to] = rec.fs[from]
        rec.fs[from] = nil
        return true
    end
    gallery:_moveInto({ item }, "Trip")
    os.rename = real_rename

    assertEq(#gallery.items, before - 1, "items left in this folder")
    assertTrue(rec.fs["/data/scribe/Trip/" .. item.name .. ".scribe"] ~= nil,
        "the notebook did not land in the folder")
end)

test("a folder cannot be moved inside itself", function()
    newGallery(4)
    local Library = require("library")
    local moved, reason = Library.moveTo("Trip", "Trip")
    assertTrue(moved == nil, "the tree was allowed to swallow itself")
    assertEq(reason, "into_itself", "reason")
end)

-- Smoke ------------------------------------------------------------------------------

io.write("new screens load and build\n")

test("the background picker builds and offers every background", function()
    newGallery(4)
    local TemplatePicker = require("templatepicker")
    local Template = require("template")
    local picked
    local picker = TemplatePicker:new{
        title = "Paper",
        current = "blank",
        on_pick = function(id) picked = id end,
    }
    local samples = {}
    local function find(w)
        if type(w) ~= "table" then return end
        if w.id and w.callback then table.insert(samples, w) end
        for _, child in ipairs(w) do find(child) end
    end
    find(picker)
    assertEq(#samples, #Template.list(), "samples offered")

    samples[2]:onTap()
    assertEq(picked, Template.list()[2].id, "the background that was tapped")
end)

test("the settings panel offers a way out of itself", function()
    -- Tapping outside also closes it, but that is a convention, not something
    -- the panel tells you about: without a close button someone who has not met
    -- it has a panel in front of them and no visible way back.
    local _, rec = newGallery(0)
    local SettingsDialog = require("settings")
    local panel = SettingsDialog:new{
        canvas = {
            pen_width = 3, highlighter_width = 24, eraser_size = 12,
            eraser_mode = "stroke", draw_with_finger = false,
        },
        on_change = function() end,
    }

    local closer = withIcon(panel, "close")
    assertTrue(closer ~= nil, "no close button anywhere in the panel")

    local before = #rec.closed
    closer:onTap()
    assertEq(#rec.closed, before + 1, "tapping it did not close anything")
    assertEq(rec.closed[#rec.closed], panel, "it closed something else")
end)

test("the page overview builds and covers the screen", function()
    newGallery(4)
    local PagePanel = require("pagepanel")
    local Document = require("document")
    local doc = Document:new("/data/scribe/x.scribe")
    doc:insertPage(1)
    doc:insertPage(2)

    local panel = PagePanel:new{ document = doc }
    local bb = RectBB.new()
    panel:paintTo(bb, 0, 0)
    local gx, gy = bb:firstGap(0, 0, panel.dimen.w, panel.dimen.h)
    assertTrue(gx == nil, string.format("left unpainted at (%s, %s)",
        tostring(gx), tostring(gy)))

    local tiles = {}
    local function find(w)
        if type(w) ~= "table" then return end
        if w.index and w.on_open then table.insert(tiles, w) end
        for _, child in ipairs(w) do find(child) end
    end
    find(panel)
    assertEq(#tiles, 3, "page tiles shown")
end)

-- The launcher bar ---------------------------------------------------------------------

io.write("launcher bar\n")

--- Stands in for Simple UI: a settings store and a registry to inspect.
local function fakeSimpleUI(qa_list, configs)
    local registered
    package.loaded["infra/sui_store"] = {
        get = function(_, key)
            if key == "simpleui_qa_list" then return qa_list end
            return configs[key]
        end,
    }
    package.loaded["infra/sui_core"] = {
        BarInjection = {
            register = function(desc) registered = desc end,
        },
        getLivePlugin = function() return nil end,
    }
    package.loaded["launcherbar"] = nil
    local LauncherBar = require("launcherbar")
    LauncherBar.register("notebook_gallery")
    return registered
end

test("the notebooks tab is found by what it launches, not by its slot", function()
    local desc = fakeSimpleUI({ "custom_qa_3" }, {
        ["simpleui_qa_custom_qa_3"] = { label = "Notebook", plugin_key = "scribe" },
    })
    assertTrue(desc ~= nil, "nothing was registered with the bar")
    assertEq(desc.get_active_action(), "custom_qa_3",
        "the tab that opens the notebooks was not reported as the active one")
end)

test("a tab wired to the dispatcher action counts too", function()
    local desc = fakeSimpleUI({ "custom_qa_1" }, {
        ["simpleui_qa_custom_qa_1"] = { dispatcher_action = "notebook_open" },
    })
    assertEq(desc.get_active_action(), "custom_qa_1", "reported tab")
end)

test("no notebooks tab means no tab to mark, and no error", function()
    local desc = fakeSimpleUI({ "custom_qa_1" }, {
        ["simpleui_qa_custom_qa_1"] = { plugin_key = "calibre" },
    })
    assertTrue(desc.get_active_action() == nil, "marked somebody else's tab")
end)

test("the notebooks tab is marked while the screen is up", function()
    local marked
    local prev_restored
    package.loaded["screens/sui_bottombar"] = {
        setTempTabActive = function(_, id, active, prev)
            if active then marked = id else prev_restored = prev end
        end,
    }
    local desc = fakeSimpleUI({ "custom_qa_2" }, {
        ["simpleui_qa_custom_qa_2"] = { plugin_key = "scribe" },
    })

    local plugin = { active_action = "custom_qa_2" }
    local widget = { _navbar_prev_action = "home" }
    desc.on_inject(widget, { plugin = plugin })
    assertEq(marked, "custom_qa_2", "the tab that was marked")

    desc.on_close(widget, { plugin = plugin })
    assertEq(prev_restored, "home", "the tab handed back")
end)

test("the tab is not handed back when the reader has already moved on", function()
    local restored = false
    package.loaded["screens/sui_bottombar"] = {
        setTempTabActive = function(_, _, active) if not active then restored = true end end,
    }
    local desc = fakeSimpleUI({ "custom_qa_2" }, {
        ["simpleui_qa_custom_qa_2"] = { plugin_key = "scribe" },
    })

    -- The reader tapped Library: the bar has already changed hands.
    local plugin = { active_action = "home" }
    desc.on_close({ _navbar_prev_action = "home" }, { plugin = plugin })
    assertTrue(not restored,
        "restoring here would undo the tab the reader has just chosen")
end)

test("a Simple UI without a settings store is survived", function()
    package.loaded["infra/sui_store"] = nil
    local registered
    package.loaded["infra/sui_core"] = {
        BarInjection = { register = function(desc) registered = desc end },
    }
    package.loaded["launcherbar"] = nil
    local LauncherBar = require("launcherbar")
    LauncherBar.register("notebook_gallery")
    assertTrue(registered.get_active_action() == nil, "should simply mark nothing")
end)

test("creating a notebook asks for the name and the paper together", function()
    newGallery(4)
    local NewNotebook = require("newnotebook")
    local created
    local dialog = NewNotebook:new{
        name = "2026-08-21",
        on_create = function(name, paper) created = { name, paper } end,
    }

    local samples = {}
    local function find(w)
        if type(w) ~= "table" then return end
        if w.id and w.callback then table.insert(samples, w) end
        for _, child in ipairs(w) do find(child) end
    end
    find(dialog)
    assertTrue(#samples > 1, "the paper is not offered on the same screen")

    samples[3]:onTap()
    assertEq(dialog.paper, samples[3].id, "the paper that was tapped")

    dialog.input.getText = function() return "Trip notes" end
    dialog.input.onCloseKeyboard = function() end
    dialog:_submit()
    assertEq(created[1], "Trip notes", "name")
    assertEq(created[2], samples[3].id, "paper")
end)

test("the new notebook panel stays clear of the keyboard and the status bar", function()
    -- The bug this pins down left the screen unusable rather than untidy: the
    -- paper grid was sized to the width alone, the panel grew past the top of
    -- the keyboard, and Cancel and Create ended up underneath it. They could
    -- not be seen or tapped -- and a tap anywhere on the panel is not a tap
    -- outside it, so nothing closed the screen either.
    local _, rec = newGallery(4)
    local NewNotebook = require("newnotebook")
    local dialog = NewNotebook:new{ name = "Notebook 1", on_create = function() end }
    dialog:paintTo(RectBB.new(), 0, 0)

    local panel = dialog.panel.dimen
    assertTrue(panel ~= nil, "the panel was never painted")

    local keyboard_h = dialog.input:getKeyboardDimen().h
    local keyboard_top = rec.screen_h - keyboard_h
    assertTrue(panel.y + panel.h <= keyboard_top, string.format(
        "the panel runs %d px under the keyboard, taking its buttons with it",
        (panel.y + panel.h) - keyboard_top))
    assertTrue(panel.y > 0,
        "the panel is flush against the top of the screen, under the status bar")
end)

test("the gallery offers both kinds of new thing outright", function()
    local gallery = newGallery(4)
    gallery:paintTo(RectBB.new(), 0, 0)
    assertTrue(labelled(gallery.header_row, "New notebook") ~= nil,
        "no way to make a notebook without opening a menu first")
    assertTrue(labelled(gallery.header_row, "New folder") ~= nil,
        "no way to make a folder without opening a menu first")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
