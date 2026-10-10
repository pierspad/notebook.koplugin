-- Responsive gallery header, sort control and update entry point.
local ActionMenu = require("actionmenu")
local T = require("ffi/util").template
local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Library = require("library")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Updater = require("updater")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widgets = require("widgets")
local _ = require("i18n")
local Screen = Device.screen
return function(Gallery)
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
    local version = TextWidget:new{
        text = require("_meta").version,
        face = Font:getFace("cfont", 12),
    }
    self.version_text = version
    local updates
    updates = headerButton("labels", _("Updates"), nil, function()
        Updater.showMenu(self, updates.dimen)
    end)
    self.updates_button = updates
    local version_w = version:getSize().w + gap + updates:getSize().w
    local top = HorizontalGroup:new{ align = "center" }
    table.insert(top, back)
    table.insert(top, HorizontalSpan:new{ width = gap })
    local title_width = math.max(
        avail - back:getSize().w - gap
              - (corner and corner:getSize().w + gap or 0) - version_w - gap,
        Screen:scaleBySize(40))
    table.insert(top, type(title) == "function" and title(title_width) or TextWidget:new{
        text = title,
        face = Font:getFace("tfont", 22),
        max_width = title_width,
    })
    if corner then
        table.insert(top, HorizontalSpan:new{ width = gap })
        table.insert(top, corner)
    end

    local used = 0
    for _, widget in ipairs(top) do used = used + widget:getSize().w end
    table.insert(top, HorizontalSpan:new{width=math.max(gap, avail-used-version_w)})
    table.insert(top, version)
    table.insert(top, HorizontalSpan:new{width=gap})
    table.insert(top, updates)

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

-- Keep the newest contiguous suffix of the path. Ellipsis opens the omitted
-- ancestors; even a single very long folder keeps a bounded, tappable label.
function Gallery:_breadcrumbs(width)
    local parts, path = {}, ""
    for name in self.folder:gmatch("[^/]+") do
        path = path == "" and name or path .. "/" .. name
        parts[#parts + 1] = { name = name, path = path }
    end
    local function button(part, limit)
        return Widgets.textButton{
            text = part.name, width = limit, font_size = 17,
            callback = function() self:_goTo(part.path) end,
        }
    end
    local row = HorizontalGroup:new{ align = "center" }
    local separator = TextWidget:new{ text = " / ", face = Font:getFace("cfont", 17) }
    local sep_w = separator:getSize().w
    local overflow = Widgets.textButton{ text = "…", callback = function()
        local actions = {}
        for i = 1, row.first_visible - 1 do
            local part = parts[i]
            actions[#actions + 1] = {
                text = part.path, callback = function() self:_goTo(part.path) end,
            }
        end
        UIManager:show(ActionMenu:new{ title = _("Notebooks"), actions = actions })
    end }
    local reserve = #parts > 1 and overflow:getSize().w + sep_w or 0
    local probe = button(parts[#parts])
    local padding = 2 * Size.padding.button + 2 * Size.border.thin
    local last_w = math.min(probe:getSize().w, math.max(padding + 1, width - reserve))
    probe:free()
    local visible = { button(parts[#parts], math.max(1, last_w - padding)) }
    local used, first = visible[1]:getSize().w, #parts
    for i = #parts - 1, 1, -1 do
        local candidate = button(parts[i])
        local extra = i > 1 and reserve or 0
        if used + sep_w + candidate:getSize().w + extra > width then
            candidate:free()
            break
        end
        table.insert(visible, 1, candidate)
        used, first = used + sep_w + candidate:getSize().w, i
    end
    row.first_visible = first
    if first > 1 then table.insert(row, overflow) else overflow:free() end
    separator:free()
    for _, crumb in ipairs(visible) do
        if #row > 0 then
            table.insert(row, TextWidget:new{ text = " / ", face = Font:getFace("cfont", 17) })
        end
        table.insert(row, crumb)
    end
    return row
end

--- A header button at the given level of detail; see _fitHeader.

function Gallery:_buildHeader()
    if self.selection then return self:_buildSelectionHeader() end

    return self:_fitHeader(function(mode)
        local back = Widgets.iconButton(self.folder ~= "" and "chevron.first" or "chevron.left", function()
            if self.folder ~= "" then return self:_goTo("") end
            self:onClose()
        end)

        -- Direct creation saves the extra tap of the old Add menu.
        local buttons = {
            headerButton(mode, _("New notebook"), "notebook.page", function() self:_createNotebook() end),
            headerButton(mode, _("New folder"), "notebook.folder", function() self:_createFolder() end),
            headerButton(mode, _("Annotate PDF"), "notebook.export", function() self:_importPDF() end),
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

        local title = self.folder ~= "" and function(width)
            return self:_breadcrumbs(width)
        end or _("Notebooks")
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

end
