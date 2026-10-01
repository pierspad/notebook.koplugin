-- Operation replay and repaint bounds. Document owns the stacks, revisions,
-- batching and dirty state; this module only applies an already recorded operation.
-- Lists crossing between history and live pages must remain independent.
local History = {}
local function copyList(list)
    local copy = {}
    for i, value in ipairs(list) do copy[i] = value end
    return copy
end

--- Applies the inverse of an operation.
function History.revert(doc, op)
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
        -- `removed` is in descending index order, so walking it backwards
        -- reinserts smallest index first: each stroke then lands where it was,
        -- because the ones before it are already back in front of it.
        local restored, read = {}, 1
        for i = #op.removed, 1, -1 do
            local entry = op.removed[i]
            while #restored < entry.index - 1 and read <= #page.strokes do
                restored[#restored + 1] = page.strokes[read]
                read = read + 1
            end
            restored[#restored + 1] = entry.stroke
        end
        for i = read, #page.strokes do restored[#restored + 1] = page.strokes[i] end
        page.strokes = restored
    elseif op.type == "move" then
        for _, stroke in ipairs(op.strokes) do stroke:translate(-op.dx, -op.dy) end
    elseif op.type == "list" then
        page.strokes = copyList(op.before)
    elseif op.type == "pages" then
        doc.pages = copyList(op.before)
    end
end

--- Reapplies an operation.
function History.reapply(doc, op)
    local page = doc.pages[op.page]
    if op.type == "pages" then page = nil end
    if op.type == "add" then
        table.insert(page.strokes, op.stroke)
    elseif op.type == "erase" then
        local removed = {}
        for _, entry in ipairs(op.removed) do removed[entry.stroke] = true end
        local write = 1
        for read = 1, #page.strokes do
            local stroke = page.strokes[read]
            if not removed[stroke] then
                page.strokes[write] = stroke
                write = write + 1
            end
        end
        for i = #page.strokes, write, -1 do page.strokes[i] = nil end
    elseif op.type == "move" then
        for _, stroke in ipairs(op.strokes) do stroke:translate(op.dx, op.dy) end
    elseif op.type == "list" then
        page.strokes = copyList(op.after)
    elseif op.type == "pages" then
        doc.pages = copyList(op.after)
    end
end

--- Returns the bounding box an operation affects, for a targeted repaint.
function History.bounds(op)
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
    elseif op.type == "move" then
        -- Called after the strokes have been shifted, so where they are now is
        -- only half of what has to be repainted; the other half is where they
        -- were, which is that box offset by the move either way.
        for _, stroke in ipairs(op.strokes) do add(stroke) end
        if bx0 ~= math.huge then
            local dx, dy = math.abs(op.dx), math.abs(op.dy)
            bx0, by0, bx1, by1 = bx0 - dx, by0 - dy, bx1 + dx, by1 + dy
        end
    end
    if bx0 == math.huge then return nil end
    return bx0, by0, bx1 - bx0, by1 - by0
end

return History
