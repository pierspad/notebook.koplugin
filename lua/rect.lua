--[[--
Growing a rectangle to cover another one.

Six lines of min and max, which had been written four times: the pending refresh
the ink accumulates, the pending repaint the eraser accumulates, the region a
sweep touched for the undo record, and the area a clean-up pass covers. Four
copies of the same arithmetic is four places for an off-by-one to hide, and it
had already been transcribed slightly differently in two of them.

Kept free of any widget so the drawing path, which runs between pen samples, is
not importing the interface to add two numbers.

@module notebook.rect
--]]--

local Rect = {}

--[[--
Grows `box` to include x, y, w, h and returns it, creating it if it was nil.

Mutates the box it is given, because the callers keep one and add to it many
times between flushes; returning it as well is what lets `box = grow(box, ...)`
read the same whether or not there was one.
--]]
function Rect.grow(box, x, y, w, h)
    if not box then
        return { x = x, y = y, w = w, h = h }
    end
    local x1 = math.max(box.x + box.w, x + w)
    local y1 = math.max(box.y + box.h, y + h)
    box.x = math.min(box.x, x)
    box.y = math.min(box.y, y)
    box.w = x1 - box.x
    box.h = y1 - box.y
    return box
end

--- Clamps a rectangle to `bounds`, returning nil when nothing is left.
function Rect.clamp(x, y, w, h, bounds)
    local x0 = math.max(bounds.x, math.floor(x))
    local y0 = math.max(bounds.y, math.floor(y))
    local w0 = math.min(math.ceil(x + w), bounds.x + bounds.w) - x0
    local h0 = math.min(math.ceil(y + h), bounds.y + bounds.h) - y0
    if w0 <= 0 or h0 <= 0 then return nil end
    return x0, y0, w0, h0
end

return Rect
