-- Lasso selection, clipboard and drag lifecycle.
-- The installed methods share Canvas's document and repaint API, while the
-- clipboard stays on the Canvas class for the toolbar and tests.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Lasso = require("lasso")
local LassoMenu = require("lassomenu")
local Rect = require("rect")
local Renderer = require("renderer")
local Tuning = require("tuning")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local _ = require("i18n")

local Screen = Device.screen
local SelectionCanvas = {}

function SelectionCanvas.install(Canvas)
--[[--
Applies the movement gathered since the last one, and shows it.

The bounding box is carried rather than recomputed. It is the same rectangle
translated -- a selection that moves does not change shape -- so asking every
stroke in it where it now is would be work whose answer is already known.

`Rect.grow` mutates the box it is given, so the old one is copied before it is
grown over the new one; growing `self.selection_bbox` in place would leave the
selection believing it covers both where it is and where it was, and the dashed
frame would drift wider on every step.

Both boxes are padded by the margin the dashed frame is drawn at, and that is
not decoration. The frame sits *outside* the selection, so a region covering
only the selection's own bounds repaints everything except the frame around it
-- and the frame stays on the screen. At two pixels a step that went unnoticed,
because the next step painted over it; at a step of a whole interval the leftover
frames stand apart, and a drag across the page leaves a trail of dozens of them.
--]]

function Canvas:_dragStep()
    local dx, dy = self.drag_dx or 0, self.drag_dy or 0
    self.drag_dx, self.drag_dy = 0, 0
    if dx == 0 and dy == 0 then return end
    if not self.selected_strokes then return end

    local old_b = self.selection_bbox or Lasso.getSelectionBounds(self.selected_strokes)
    if not old_b then return end

    Lasso.translateStrokes(self.selected_strokes, dx, dy)
    -- The whole distance the selection has travelled since it was picked up:
    -- the drag arrives as dozens of steps, and one entry in the history that
    -- undoes all of them is what the hand did. Cleared when the drag ends, so
    -- a fresh one starts from nothing without either caller having to say so.
    self.drag_moved_dx = (self.drag_moved_dx or 0) + dx
    self.drag_moved_dy = (self.drag_moved_dy or 0) + dy
    local new_b = { x = old_b.x + dx, y = old_b.y + dy, w = old_b.w, h = old_b.h }
    self.selection_bbox = new_b

    local m = Tuning.frame_margin
    local box = Rect.grow(
        { x = old_b.x - m, y = old_b.y - m, w = old_b.w + 2 * m, h = old_b.h + 2 * m },
        new_b.x - m, new_b.y - m, new_b.w + 2 * m, new_b.h + 2 * m)
    self:_repaintRegion(box.x, box.y, box.w, box.h, true)
    Renderer.drawDashedRect(Screen.bb, new_b.x - 6, new_b.y - 6, new_b.w + 12, new_b.h + 12)
    self:_refreshNow(box.x, box.y, box.w, box.h)

    -- Everywhere the selection has been during this drag, for the one clean
    -- refresh that ends it; see _settleDrag.
    self.drag_touched = Rect.grow(self.drag_touched, box.x, box.y, box.w, box.h)
    self.last_drag_step = time.now()
end

function Canvas:_useOpaqueTextDuringDrag()
    if self.drag_text_backgrounds or not self.selected_strokes then return end
    local saved = {}
    for _, stroke in ipairs(self.selected_strokes) do
        if stroke.text then
            saved[stroke] = stroke.text_background == true
            stroke.text_background = true
        end
    end
    self.drag_text_backgrounds = next(saved) and saved or nil
end

function Canvas:_restoreTextAfterDrag()
    local saved = self.drag_text_backgrounds
    self.drag_text_backgrounds = nil
    for stroke, background in pairs(saved or {}) do
        stroke.text_background = background
    end
end

--[[--
Clears what the fast refreshes left behind, once the pen is up.

The copies of the selection trailing behind it are not drawn by anything: the
buffer holds one selection, in one place, and every step repaints the region it
came from. They are the panel. A fast refresh drives each pixel with a short
waveform that gets it close to the value asked for without settling it, which is
what makes it fast, and what it does not settle is a faint remainder of what was
there before. Ten steps, ten remainders.

They cannot be avoided during the drag: the refresh that does settle a pixel
takes long enough that using it here is the slow, lagging version this was
trying to get away from. So the drag keeps the fast one and pays for it once, at
the end, over everywhere it has been -- which is a single refresh of an area
that is already correct in the buffer, and takes the trail with it.
--]]
function Canvas:_settleDrag()
    local touched = self.drag_touched
    self.drag_touched = nil
    -- The cheap opaque representation is only a drag preview. Restore the
    -- document's real style before the one final, high-quality repaint.
    self:_restoreTextAfterDrag()
    if not touched then return end

    self:_repaintRegion(touched.x, touched.y, touched.w, touched.h, true)
    local b = self.selection_bbox
    if b then
        Renderer.drawDashedRect(Screen.bb, b.x - 6, b.y - 6, b.w + 12, b.h + 12)
    end
    self:_refreshNow(touched.x, touched.y, touched.w, touched.h, "ui")
end

--[[--
Moves the selection now if enough time has passed, or shortly if not.

The deferred call is what makes the last movement land. Without it a drag that
stops inside the interval -- which every drag does, since it ends when the pen
lifts -- would leave the final few pixels of travel applied to the strokes but
never drawn, and the selection would settle a fraction away from where it was
put down.
--]]
function Canvas:_maybeDragStep()
    local now = time.now()
    if not self.last_drag_step
        or time.to_ms(now - self.last_drag_step) >= Tuning.drag_repaint_ms then
        return self:_dragStep()
    end

    if not self.drag_step_scheduled then
        self.drag_step_scheduled = true
        local remaining = Tuning.drag_repaint_ms - time.to_ms(now - self.last_drag_step)
        UIManager:scheduleIn(math.max(1, remaining) / 1000, self.drag_step_cb)
    end
end

function Canvas:_showLassoMenu(selected)
    if self.lasso_menu then
        UIManager:close(self.lasso_menu)
        self.lasso_menu = nil
    end

    self.selected_strokes = selected
    local bbox = Lasso.getSelectionBounds(selected)
    self.selection_bbox = bbox

    -- Draw dashed selection outline
    if bbox then
        Renderer.drawDashedRect(Screen.bb, bbox.x - 6, bbox.y - 6, bbox.w + 12, bbox.h + 12)
        self:_refreshNow(bbox.x - 8, bbox.y - 8, bbox.w + 16, bbox.h + 16)
    end

    if #selected == 1 and selected[1].shape_kind then
        local shape = selected[1]
        local size = math.max(6, Screen:scaleBySize(12))
        local dirty
        for _, handle in ipairs(self:shapeHandles(shape)) do
            local hx, hy = math.floor(handle[2]), math.floor(handle[3])
            if handle[1] == "rotate" then
                local from = math.floor(shape.x_max+size/2)
                Screen.bb:paintRect(from, hy, math.max(0,hx-from-size/2), 1, Blitbuffer.COLOR_BLACK)
                Screen.bb:paintCircle(hx, hy, math.floor(size/2), Blitbuffer.COLOR_BLACK)
                Screen.bb:paintCircle(hx, hy, math.max(1,math.floor(size/2)-2), Blitbuffer.COLOR_WHITE)
                dirty = Rect.grow(dirty, from, hy-size, hx-from+size, size*2)
            else
                local left, top = math.floor(hx-size/2), math.floor(hy-size/2)
                Screen.bb:paintRect(left, top, size, size, Blitbuffer.COLOR_WHITE)
                Screen.bb:paintRect(left, top, size, 1, Blitbuffer.COLOR_BLACK)
                Screen.bb:paintRect(left, top+size-1, size, 1, Blitbuffer.COLOR_BLACK)
                Screen.bb:paintRect(left, top, 1, size, Blitbuffer.COLOR_BLACK)
                Screen.bb:paintRect(left+size-1, top, 1, size, Blitbuffer.COLOR_BLACK)
                dirty = Rect.grow(dirty, left, top, size, size)
            end
        end
        if dirty then self:_refreshNow(dirty.x, dirty.y, dirty.w, dirty.h, "ui") end
    end

    self.lasso_menu = LassoMenu:new{
        bbox = bbox or { x = self.content.x + 100, y = self.content.y + 100, w = 200, h = 100 },
        has_clipboard = Canvas.clipboard ~= nil and #Canvas.clipboard > 0,
        on_edit = #selected == 1 and selected[1].text and self.on_edit_text and function()
            local text = selected[1]
            self.lasso_menu = nil
            self.selected_strokes, self.selection_bbox = nil, nil
            self:on_edit_text(text)
        end or nil,
        on_cut = function()
            self.lasso_menu = nil
            --[[
            Copies, like the copy above, and for a reason cut makes easy to
            miss: the strokes it takes off the page are not gone, they are on
            the undo stack, and one press of undo puts those very objects back
            where they were. Holding the originals meant the clipboard went on
            following them -- move the restored writing and what came out of a
            later paste was where it had been moved to, not what had been cut.
            ]]
            Canvas.clipboard = Lasso.cloneStrokes(selected)
            local box = self.selection_bbox
            self.document:removeStrokes(selected)
            self.selected_strokes = nil
            self.selection_bbox = nil
            self:_repaintSelection(box)
            if self.on_change then self:on_change() end
            if self.owner and self.owner.onClipboardChanged then
                self.owner:onClipboardChanged(_("Cut") .. " → " .. _("Paste"))
            end
        end,
        on_copy = function()
            self.lasso_menu = nil
            Canvas.clipboard = Lasso.cloneStrokes(selected)
            self:_deselectLasso()
            if self.owner and self.owner.onClipboardChanged then
                self.owner:onClipboardChanged(_("Copy") .. " → " .. _("Paste"))
            end
        end,
        on_paste = function()
            self.lasso_menu = nil
            self:pasteClipboard()
        end,
        on_delete = function()
            self.lasso_menu = nil
            local box = self.selection_bbox
            self.document:removeStrokes(selected)
            self.selected_strokes = nil
            self.selection_bbox = nil
            self:_repaintSelection(box)
            if self.on_change then self:on_change() end
        end,
        on_close = function()
            self.lasso_menu = nil
            self:_deselectLasso()
        end,
    }
    UIManager:show(self.lasso_menu)
end

function Canvas.hasClipboard()
    return Canvas.clipboard ~= nil and #Canvas.clipboard > 0
end

function Canvas:pasteClipboard(dx, dy)
    if not Canvas.hasClipboard() then return false end
    dx, dy = dx or 40, dy or 40
    local pasted = {}
    local dirty
    self.document:beginBatch()
    for _, stroke in ipairs(Canvas.clipboard) do
        local copy = stroke:clone()
        copy:translate(dx, dy)
        pasted[#pasted + 1] = copy
        self.document:addStroke(copy)
        dirty = Rect.grow(dirty, copy:getBounds())
    end
    self.document:commitBatch()
    if dirty then self:_repaintRegion(dirty.x, dirty.y, dirty.w, dirty.h) end
    if self.on_change then self:on_change() end
    self:_showLassoMenu(pasted)
    return true
end

function Canvas:_deselectLasso()
    self.erased_shape_selection = nil
    self:_restoreTextAfterDrag()
    if not self.selected_strokes and not self.selection_bbox and not self.lasso_menu then return end
    if self.lasso_menu then
        UIManager:close(self.lasso_menu)
        self.lasso_menu = nil
    end
    local bx = self.selection_bbox
    self.selected_strokes = nil
    self.selection_bbox = nil
    self:_repaintSelection(bx)
end

--[[--
Repaints where a selection was, frame and all, or the page if it is not known.

The frame is drawn *outside* the box the selection occupies, so repainting the
box alone leaves the dashes standing around an empty rectangle. The slack is
the one the drag uses, which is now a number the reader can change: taking it
back to the ten that used to be written here would leave a ring of dashes
behind for anyone who had raised it.

Cut and delete used to repaint the whole drawing area instead. What they take
away is inside the selection by definition, so that was a full-page raster and
a full-page refresh -- the two operations that most obviously ought to be
instant were the two slowest things the lasso could do.
--]]
function Canvas:_repaintSelection(box)
    if not box then
        return self:_repaintRegion(self.content.x, self.content.y,
            self.content.w, self.content.h)
    end
    local m = Tuning.frame_margin
    self:_repaintRegion(box.x - m, box.y - m, box.w + 2 * m, box.h + 2 * m)
end

end

return SelectionCanvas
