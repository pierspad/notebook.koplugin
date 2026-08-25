--[[--
The notebook document: pages of vector strokes, plus the undo history.

The vector stroke list is the single source of truth. Any bitmap the canvas
keeps is a cache derived from this and is never persisted.

History is an operation log rather than a stack of stroke lists. That costs
nothing extra today for undoing a pen stroke, but it is what lets the eraser
(which removes several strokes at once) and any future selection tool (move,
resize, delete) participate in the same undo system without reworking it.

@module notebook.document
--]]--

local Persist = require("persist")
local Stroke = require("stroke")
local Template = require("template")
local logger = require("logger")

-- Bump when the on-disk shape changes incompatibly.
local FORMAT_VERSION = 1
local CODEC = "bitser"
local MAX_HISTORY = 200

local Document = {}
Document.__index = Document

--- A fresh page. `template` is nil, meaning it follows the notebook's.
local function newPage()
    return { strokes = {} }
end

--- A shallow copy of a page list: the pages themselves are shared, not copied.
local function snapshot(pages)
    local copy = {}
    for i, page in ipairs(pages) do copy[i] = page end
    return copy
end

function Document:new(path)
    local o = {
        path = path,
        pages = { newPage() },
        current_page = 1,
        -- The notebook's background. Pages with none of their own follow it.
        template = Template.DEFAULT,
        -- Operation log. undo_stack holds applied operations, redo_stack holds
        -- operations that have been rolled back.
        undo_stack = {},
        redo_stack = {},
        dirty = false,
    }
    return setmetatable(o, self)
end

function Document:getPage()
    return self.pages[self.current_page]
end

function Document:pageCount()
    return #self.pages
end

-- Operations -----------------------------------------------------------------

--[[--
Groups everything until commitBatch into a single undoable operation.

A sweep of the eraser applies many times -- once per step along the path -- and
recording each one separately would fill the history with dozens of entries for
one gesture, each carrying a snapshot of the page. Undo would then have to be
pressed twenty times to take back one wipe.

Nesting is not supported; beginning a batch while one is open keeps the outer one.
--]]
function Document:beginBatch()
    if self._batch then return end
    local page = self:getPage()
    local before = {}
    for i, stroke in ipairs(page.strokes) do before[i] = stroke end
    self._batch = { page = self.current_page, before = before, changed = false }
end

--- Closes the batch, recording one operation if anything actually changed.
function Document:commitBatch(x, y, w, h)
    local batch = self._batch
    self._batch = nil
    if not batch or not batch.changed then return end

    self:_record{
        type = "list",
        page = batch.page,
        before = batch.before,
        after = self.pages[batch.page].strokes,
        bounds = x and { x = x, y = y, w = w, h = h } or nil,
    }
end

--- True while a batch is collecting changes.
function Document:_inBatch()
    return self._batch ~= nil
end

--- Records an operation and clears the redo branch.
function Document:_record(op)
    table.insert(self.undo_stack, op)
    if #self.undo_stack > MAX_HISTORY then
        table.remove(self.undo_stack, 1)
    end
    -- Any new edit invalidates the redo branch.
    if #self.redo_stack > 0 then
        self.redo_stack = {}
    end
    self.dirty = true
end

--- Adds a finished stroke to the current page.
function Document:addStroke(stroke)
    local page = self:getPage()
    table.insert(page.strokes, stroke)
    self:_record{ type = "add", page = self.current_page, stroke = stroke }
end

--[[--
Removes every stroke the eraser's path came near, in one pass.

The point-at-a-time version had to be called once per interpolated step along
the path -- a dozen times for one flick of the wrist -- and each call walked
every stroke on the page. Passing the path down instead means one walk, and a
continuous swept shape rather than a row of circles with gaps between them.
--]]
function Document:eraseAlongPath(path, r)
    local page = self:getPage()
    local removed = {}
    local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge

    for i = #page.strokes, 1, -1 do
        local stroke = page.strokes[i]
        if stroke:hitTestPath(path, r) then
            local sx, sy, sw, sh = stroke:getBounds()
            if sx < bx0 then bx0 = sx end
            if sy < by0 then by0 = sy end
            if sx + sw > bx1 then bx1 = sx + sw end
            if sy + sh > by1 then by1 = sy + sh end
            table.insert(removed, { index = i, stroke = stroke })
            table.remove(page.strokes, i)
        end
    end

    if #removed == 0 then return nil end

    if self._batch then
        self._batch.changed = true
        self.dirty = true
    else
        self:_record{ type = "erase", page = self.current_page, removed = removed }
    end
    return removed, bx0, by0, bx1 - bx0, by1 - by0
end

--[[--
Rubs out the area the eraser's path swept, splitting strokes, in one pass.

Two rectangles come back, and they are not the same thing. The first is what
changed on screen: the ink actually taken away, which is roughly the tip's own
footprint. The second is the box the undo record needs, because undoing puts the
split strokes back whole, and a stroke restored whole has to be repainted whole.

Using the second for both -- which is what this did -- meant a single dab of the
rubber on a long line repainted, from the vector model, everything the line
spanned. That is why the area eraser dragged: the erasing was cheap, and the
repaint behind it was the size of the page.

@treturn boolean,number,number,number,number,number,number,number,number
  changed, then x, y, w, h of the ink removed, then x, y, w, h for undo
--]]
function Document:eraseAreaAlongPath(path, r)
    local page = self:getPage()
    local strokes = page.strokes

    -- First pass: which strokes does the sweep touch at all? Rejection is by
    -- box, so this costs nothing for the strokes it misses -- which, for one
    -- sample of a moving tip, is nearly all of them. Nothing is allocated and
    -- no list is rebuilt unless something is actually hit.
    local hits, splits
    local dx0, dy0, dx1, dy1 = math.huge, math.huge, -math.huge, -math.huge
    local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge

    for i = 1, #strokes do
        local stroke = strokes[i]
        local fragments, ex, ey, ew, eh = stroke:splitAlongPath(path, r)
        if fragments then
            hits = hits or {}
            splits = splits or {}
            hits[#hits + 1] = i
            splits[#splits + 1] = fragments

            if ex < dx0 then dx0 = ex end
            if ey < dy0 then dy0 = ey end
            if ex + ew > dx1 then dx1 = ex + ew end
            if ey + eh > dy1 then dy1 = ey + eh end

            local sx, sy, sw, sh = stroke:getBounds()
            if sx < bx0 then bx0 = sx end
            if sy < by0 then by0 = sy end
            if sx + sw > bx1 then bx1 = sx + sw end
            if sy + sh > by1 then by1 = sy + sh end
        end
    end

    if not hits then return nil end

    if self._batch then
        -- The batch already holds the "before" snapshot it will undo to, so the
        -- page list is spliced in place: the alternative is rebuilding an array
        -- of every stroke on the page for each of the dozens of samples one
        -- sweep of the hand produces.
        for k = #hits, 1, -1 do
            local index = hits[k]
            table.remove(strokes, index)
            local fragments = splits[k]
            for f = #fragments, 1, -1 do
                table.insert(strokes, index, fragments[f])
            end
        end
        self._batch.changed = true
        self.dirty = true
    else
        local before, after = {}, {}
        for i = 1, #strokes do before[i] = strokes[i] end
        local k = 1
        for i = 1, #strokes do
            if hits[k] == i then
                for _, fragment in ipairs(splits[k]) do
                    after[#after + 1] = fragment
                end
                k = k + 1
            else
                after[#after + 1] = strokes[i]
            end
        end
        page.strokes = after
        self:_record{
            type = "list",
            page = self.current_page,
            before = before,
            after = after,
            bounds = { x = bx0, y = by0, w = bx1 - bx0, h = by1 - by0 },
        }
    end

    return true, dx0, dy0, dx1 - dx0, dy1 - dy0,
                 bx0, by0, bx1 - bx0, by1 - by0
end

-- Undo / redo ----------------------------------------------------------------

--- Applies the inverse of an operation.
local function revert(doc, op)
    local page = doc.pages[op.page]
    if op.type == "pages" then page = nil end
    if op.type == "add" then
        for i = #page.strokes, 1, -1 do
            if page.strokes[i] == op.stroke then
                table.remove(page.strokes, i)
                break
            end
        end
    elseif op.type == "erase" then
        -- Reinsert in ascending index order so each stroke lands where it was.
        for i = #op.removed, 1, -1 do
            local entry = op.removed[i]
            table.insert(page.strokes, math.min(entry.index, #page.strokes + 1), entry.stroke)
        end
    elseif op.type == "list" then
        page.strokes = op.before
    elseif op.type == "pages" then
        doc.pages = op.before
    end
end

--- Reapplies an operation.
local function reapply(doc, op)
    local page = doc.pages[op.page]
    if op.type == "pages" then page = nil end
    if op.type == "add" then
        table.insert(page.strokes, op.stroke)
    elseif op.type == "erase" then
        for _, entry in ipairs(op.removed) do
            for i = #page.strokes, 1, -1 do
                if page.strokes[i] == entry.stroke then
                    table.remove(page.strokes, i)
                    break
                end
            end
        end
    elseif op.type == "list" then
        page.strokes = op.after
    elseif op.type == "pages" then
        doc.pages = op.after
    end
end

--- Returns the bounding box an operation affects, for a targeted repaint.
local function opBounds(op)
    -- An area erase records the rectangle it touched, since reconstructing it
    -- from a whole-list snapshot would mean diffing the two lists.
    if op.bounds then
        return op.bounds.x, op.bounds.y, op.bounds.w, op.bounds.h
    end

    local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
    local function add(stroke)
        local x, y, w, h = stroke:getBounds()
        if x < bx0 then bx0 = x end
        if y < by0 then by0 = y end
        if x + w > bx1 then bx1 = x + w end
        if y + h > by1 then by1 = y + h end
    end
    if op.type == "add" then
        add(op.stroke)
    elseif op.type == "erase" then
        for _, entry in ipairs(op.removed) do add(entry.stroke) end
    end
    if bx0 == math.huge then return nil end
    return bx0, by0, bx1 - bx0, by1 - by0
end

function Document:canUndo() return #self.undo_stack > 0 end
function Document:canRedo() return #self.redo_stack > 0 end

--- Undoes the last operation. Returns the affected page and bounding box.
function Document:undo()
    local op = table.remove(self.undo_stack)
    if not op then return nil end
    revert(self, op)
    table.insert(self.redo_stack, op)
    self.dirty = true
    self:_clampPage()
    return op.page, opBounds(op)
end

--- Redoes the last undone operation. Returns the affected page and bounding box.
function Document:redo()
    local op = table.remove(self.redo_stack)
    if not op then return nil end
    reapply(self, op)
    table.insert(self.undo_stack, op)
    self.dirty = true
    self:_clampPage()
    return op.page, opBounds(op)
end

--- Keeps the current page inside the list after it has grown or shrunk.
function Document:_clampPage()
    self.current_page = math.max(1, math.min(self.current_page, #self.pages))
end

-- Pages ----------------------------------------------------------------------

--[[--
Adds a page at the end, which is what walking off the end of the notebook does.

Routed through insertPage so it is recorded like any other change to the page
list. A page that appeared because you swiped past the last one should be as
undoable as one you asked for from the overview; it was, after all, rather more
likely to be an accident.
--]]
function Document:addPage()
    return self:insertPage(#self.pages)
end

function Document:goToPage(n)
    if n < 1 or n > #self.pages then return false end
    self.current_page = n
    return true
end

--[[--
Records a change to the page list as one undoable operation.

The snapshots are arrays of page references, not deep copies, so a notebook of
two hundred pages costs two hundred pointers per operation and nothing else. It
also means undo restores the very same page objects, with whatever was written
on them still attached.
--]]
function Document:_recordPages(before, land_on)
    self:_record{
        type = "pages",
        page = land_on,
        before = before,
        after = snapshot(self.pages),
    }
    self.current_page = math.max(1, math.min(land_on, #self.pages))
end

--- Inserts a fresh page after `index`, and goes to it.
function Document:insertPage(index)
    index = math.max(0, math.min(index or self.current_page, #self.pages))
    local before = snapshot(self.pages)
    table.insert(self.pages, index + 1, newPage())
    self:_recordPages(before, index + 1)
    return index + 1
end

--- Copies page `index`, strokes and all, and goes to the copy.
function Document:duplicatePage(index)
    local source = self.pages[index]
    if not source then return nil end

    local copy = { template = source.template, strokes = {} }
    for i, stroke in ipairs(source.strokes) do copy.strokes[i] = stroke end

    local before = snapshot(self.pages)
    table.insert(self.pages, index + 1, copy)
    self:_recordPages(before, index + 1)
    return index + 1
end

--[[--
Removes a page.

Refuses to remove the last one: a notebook with no pages has nothing to draw on
and nothing to show, and every caller would then need its own special case for
a state that should not exist. Emptying the last page is what the reader
actually wants there, and that is undo-able on its own.
--]]
function Document:deletePage(index)
    if #self.pages <= 1 then return false end
    if not self.pages[index] then return false end

    local before = snapshot(self.pages)
    table.remove(self.pages, index)
    self:_recordPages(before, math.min(index, #self.pages))
    return true
end

-- Backgrounds ------------------------------------------------------------------

--- The background a page is drawn on: its own, or the notebook's.
function Document:templateFor(index)
    local page = self.pages[index or self.current_page]
    return (page and page.template) or self.template or Template.DEFAULT
end

--[[--
Sets the notebook's background.

Pages that follow the notebook change with it; a page given a background of its
own keeps it, because that was a deliberate choice and silently undoing it is
worse than leaving one page behind. `clear_overrides` is the explicit way to
say "no, all of them".
--]]
function Document:setTemplate(id, clear_overrides)
    if not Template.isKnown(id) then return false end
    self.template = id
    if clear_overrides then
        for _, page in ipairs(self.pages) do page.template = nil end
    end
    self.dirty = true
    return true
end

--- Sets one page's background. `nil` puts it back to following the notebook.
function Document:setPageTemplate(index, id)
    local page = self.pages[index]
    if not page then return false end
    if id ~= nil and not Template.isKnown(id) then return false end
    page.template = id
    self.dirty = true
    return true
end

--- True if any page has a background of its own.
function Document:hasPageTemplates()
    for _, page in ipairs(self.pages) do
        if page.template then return true end
    end
    return false
end

-- Persistence ----------------------------------------------------------------

function Document:save()
    if not self.path then return false, "no path" end

    local pages = {}
    for i, page in ipairs(self.pages) do
        local strokes = {}
        for j, stroke in ipairs(page.strokes) do
            strokes[j] = stroke:serialize()
        end
        pages[i] = { strokes = strokes, template = page.template }
    end

    local ok, err = Persist:new{ path = self.path, codec = CODEC }:save{
        version = FORMAT_VERSION,
        pages = pages,
        current_page = self.current_page,
        template = self.template,
    }
    if ok then
        self.dirty = false
    else
        logger.warn("Notebook: failed to save notebook:", err)
    end
    return ok, err
end

function Document:load()
    local data = Persist:new{ path = self.path, codec = CODEC }:load()
    if not data then return false end
    if data.version ~= FORMAT_VERSION then
        logger.warn("Notebook: unsupported notebook format version", data.version)
        return false
    end

    self.pages = {}
    for i, page in ipairs(data.pages or {}) do
        local strokes = {}
        for j, s in ipairs(page.strokes or {}) do
            strokes[j] = Stroke:deserialize(s)
        end
        -- A background this build does not know about is dropped rather than
        -- carried around: a notebook written by a newer version stays readable,
        -- and the page falls back to the notebook's.
        local template = Template.isKnown(page.template) and page.template or nil
        self.pages[i] = { strokes = strokes, template = template }
    end
    if #self.pages == 0 then self.pages = { newPage() } end

    self.template = Template.isKnown(data.template) and data.template or Template.DEFAULT
    self.current_page = math.min(data.current_page or 1, #self.pages)
    self.undo_stack, self.redo_stack = {}, {}
    self.dirty = false
    return true
end

return Document
