--[[--
A single vector stroke: the atomic unit of a notebook page.

Points are kept in a flat array with a stride of 3 (x, y, pressure) rather than
a table per point. A long handwritten page holds tens of thousands of points, and
one table per point costs both memory and GC pressure we cannot afford on device.

Coordinates are stored in page space, not screen space. On a blank notebook the
two currently coincide, but keeping them distinct is what will later allow the
same stroke to be anchored to a document page across zoom changes.

@module notebook.stroke
--]]--

local Stroke = {}
Stroke.__index = Stroke

local STRIDE = 3

--[[--
Points per chunk of the coarse index.

A stroke's own bounding box is a poor filter for the eraser: one long diagonal
line has a box the size of the page, so every sweep anywhere fell through to a
distance test on every one of its points -- tens of thousands of square roots
per contact, several times a second, which is what made rubbing out part of a
stroke drag behind the hand.

Splitting the point list into short runs and keeping a box per run turns that
into a handful of rectangle tests plus the points of the one or two runs the
rubber is actually over. Small enough that a run's box is tight; large enough
that the index costs a fraction of the points it covers.
--]]
local CHUNK = 24

-- Below this many points a stroke is walked whole; see chunkIndex.
local INDEX_MIN = 3 * CHUNK

--- Creates an empty stroke.
-- @tparam table opts tool, width and color of the stroke
function Stroke:new(opts)
    opts = opts or {}
    local o = {
        tool = opts.tool or "pen",
        -- Nominal stroke width in pixels, before pressure modulation.
        width = opts.width or 3,
        -- Grayscale level, 0 = black .. 255 = white.
        color = opts.color or 0,
        -- Highlighter tint; nil means the renderer's default.
        tint = opts.tint,
        pts = {},
        n = 0,
        -- Bounding box, kept up to date as points come in so that neither
        -- rendering nor hit-testing ever has to walk the whole point list.
        x_min = math.huge, y_min = math.huge,
        x_max = -math.huge, y_max = -math.huge,
    }
    return setmetatable(o, self)
end

--- Appends a point.
-- @tparam number x
-- @tparam number y
-- @tparam number pressure normalized 0..1
function Stroke:addPoint(x, y, pressure)
    local i = self.n * STRIDE
    self.pts[i + 1] = x
    self.pts[i + 2] = y
    self.pts[i + 3] = pressure or 1
    self.n = self.n + 1
    self.chunks = nil

    if x < self.x_min then self.x_min = x end
    if y < self.y_min then self.y_min = y end
    if x > self.x_max then self.x_max = x end
    if y > self.y_max then self.y_max = y end
end

--[[--
Copies points `from`..`to` of `src` onto the end of this stroke.

Used when a run of points is known to survive the eraser whole, so there is no
reason to test any of them one at a time -- or to go through addPoint, which is
the same three writes with a function call and a bounds comparison around each.
--]]
function Stroke:appendRange(src, from, to)
    local pts, spts = self.pts, src.pts
    local o = self.n * STRIDE
    local x_min, y_min = self.x_min, self.y_min
    local x_max, y_max = self.x_max, self.y_max
    for i = from, to do
        local s = (i - 1) * STRIDE
        local x, y = spts[s + 1], spts[s + 2]
        pts[o + 1] = x
        pts[o + 2] = y
        pts[o + 3] = spts[s + 3]
        o = o + STRIDE
        if x < x_min then x_min = x end
        if y < y_min then y_min = y end
        if x > x_max then x_max = x end
        if y > y_max then y_max = y end
    end
    self.n = self.n + (to - from + 1)
    self.x_min, self.y_min, self.x_max, self.y_max = x_min, y_min, x_max, y_max
    self.chunks = nil
end

--[[--
The coarse index over the point list, built on demand.

Each entry is a run of at most CHUNK consecutive points and the box that covers
them. Runs overlap by one point so that the *segments* between points are
covered too, not just the vertices: an eraser passing through the gap between
two far-apart samples has to be seen by the run that spans it.

Short strokes get no index and this returns nil: below a couple of runs the
index costs more to build and walk than the points it would let us skip, and
most of a page of handwriting is short strokes. It is the long ones -- whose
own bounding box is useless because it covers half the page -- that need it.
--]]
function Stroke:chunkIndex()
    local chunks = self.chunks
    if chunks then return chunks end
    if self.n < INDEX_MIN then return nil end

    chunks = {}
    local pts, n = self.pts, self.n
    local i = 1
    while i <= n do
        local last = math.min(i + CHUNK, n)
        local x0, y0 = math.huge, math.huge
        local x1, y1 = -math.huge, -math.huge
        for j = i, last do
            local o = (j - 1) * STRIDE
            local x, y = pts[o + 1], pts[o + 2]
            if x < x0 then x0 = x end
            if y < y0 then y0 = y end
            if x > x1 then x1 = x end
            if y > y1 then y1 = y end
        end
        chunks[#chunks + 1] = { i, last, x0, y0, x1, y1 }
        i = last + 1
        -- The next run starts after this one ends, but the segment joining them
        -- was already inside this run's box, because the runs share a point.
        if last < n then i = last end
    end
    self.chunks = chunks
    return chunks
end

--- Returns the point at 1-based index i as x, y, pressure.
function Stroke:getPoint(i)
    local o = (i - 1) * STRIDE
    return self.pts[o + 1], self.pts[o + 2], self.pts[o + 3]
end

--- Updates the point at 1-based index i.
function Stroke:setPoint(i, x, y, pressure)
    if i < 1 or i > self.n then return end
    local o = (i - 1) * STRIDE
    self.pts[o + 1] = x
    self.pts[o + 2] = y
    if pressure then self.pts[o + 3] = pressure end
    self.chunks = nil
end

--- Translates all points by (dx, dy).
function Stroke:translate(dx, dy)
    local n = self.n
    local pts = self.pts
    for i = 1, n do
        local o = (i - 1) * STRIDE
        pts[o + 1] = pts[o + 1] + dx
        pts[o + 2] = pts[o + 2] + dy
    end
    self.x_min = self.x_min + dx
    self.x_max = self.x_max + dx
    self.y_min = self.y_min + dy
    self.y_max = self.y_max + dy
    self.chunks = nil
end

--- Returns the number of points.
function Stroke:count()
    return self.n
end

--- Returns the bounding box inflated by the stroke's maximum half-width.
-- The inflation matters: the geometric bounding box of the *points* is smaller
-- than the area the rendered stroke actually covers.
-- @treturn number,number,number,number x, y, w, h
function Stroke:getBounds()
    if self.n == 0 then return 0, 0, 0, 0 end
    local pad = math.ceil(self.width / 2) + 1
    local x = self.x_min - pad
    local y = self.y_min - pad
    return x, y, (self.x_max + pad) - x, (self.y_max + pad) - y
end

--- Squared distance from (px, py) to the segment (x0,y0)-(x1,y1).
local function distToSegmentSq(px, py, x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len_sq = dx * dx + dy * dy
    if len_sq == 0 then
        local ax, ay = px - x0, py - y0
        return ax * ax + ay * ay
    end
    -- Projection of the point onto the segment, clamped to its extent.
    local t = ((px - x0) * dx + (py - y0) * dy) / len_sq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local cx, cy = x0 + t * dx, y0 + t * dy
    local ex, ey = px - cx, py - cy
    return ex * ex + ey * ey
end

--[[--
Returns true if any part of this stroke falls within radius r of (px, py).

Tests against the stroke's *segments*, not just its recorded points. The
digitizer samples a fast stroke sparsely -- points can be tens of pixels apart --
so testing vertices alone leaves gaps the eraser silently falls through, and the
faster you write the worse it gets.

Working from the vector geometry rather than the rendered pixels is what makes
whole-stroke erasing possible.
--]]
function Stroke:hitTest(px, py, r)
    -- Reject on the bounding box first; most strokes on a page miss entirely.
    local bx, by, bw, bh = self:getBounds()
    if px < bx - r or px > bx + bw + r or py < by - r or py > by + bh + r then
        return false
    end

    local r2 = r * r
    if self.n == 1 then
        local x, y = self:getPoint(1)
        local dx, dy = x - px, y - py
        return dx * dx + dy * dy <= r2
    end

    -- Runs whose box the rubber does not reach are skipped whole; only the one
    -- or two runs it is actually over are walked point by point.
    local pts = self.pts
    local chunks = self:chunkIndex()
    if not chunks then
        local o = 0
        local x0, y0 = pts[1], pts[2]
        for _ = 2, self.n do
            o = o + STRIDE
            local x1, y1 = pts[o + 1], pts[o + 2]
            if distToSegmentSq(px, py, x0, y0, x1, y1) <= r2 then return true end
            x0, y0 = x1, y1
        end
        return false
    end

    for k = 1, #chunks do
        local c = chunks[k]
        if px >= c[3] - r and px <= c[5] + r
           and py >= c[4] - r and py <= c[6] + r then
            local o = (c[1] - 1) * STRIDE
            local x0, y0 = pts[o + 1], pts[o + 2]
            for i = c[1] + 1, c[2] do
                o = (i - 1) * STRIDE
                local x1, y1 = pts[o + 1], pts[o + 2]
                if distToSegmentSq(px, py, x0, y0, x1, y1) <= r2 then
                    return true
                end
                x0, y0 = x1, y1
            end
        end
    end
    return false
end

--[[--
Splits the stroke around a circular area, returning the surviving fragments.

This is what makes an area eraser possible on vector data: instead of dropping
a whole stroke because it was touched, the points inside the circle are removed
and each surviving run of points becomes a stroke of its own. Rubbing out the
middle of a line therefore leaves two lines, as it would on paper.

Returns nil if the circle misses the stroke entirely (the common case, so the
caller can skip work), or a list of fragments -- possibly empty, when the whole
stroke fell inside the circle.
--]]
--[[--
The eraser's path, as the reader actually moved it.

The digitizer reports the tip a few times per contact, far apart when the hand
is moving quickly. Erasing at those points alone skips the gaps between them, so
a brisk sweep leaves the line standing; erasing at points interpolated between
them means walking the whole page's strokes once per step, which is what made a
sweep lag behind the hand and land where the tip used to be.

So the path is passed down whole -- a flat array of x, y, x, y -- and everything
below measures against the polyline itself. One pass over the strokes per event,
and no gaps, because a polyline has none.
--]]

--- Squared distance from a point to a polyline given as a flat x, y array.
local function distToPathSq(px, py, path)
    local n = #path
    if n == 2 then
        local dx, dy = px - path[1], py - path[2]
        return dx * dx + dy * dy
    end
    -- The overwhelmingly common case: one segment, from the last reported
    -- position of the tip to this one. Worth not entering a loop for.
    if n == 4 then
        return distToSegmentSq(px, py, path[1], path[2], path[3], path[4])
    end
    local best = math.huge
    for i = 1, n - 3, 2 do
        local d = distToSegmentSq(px, py, path[i], path[i + 1],
            path[i + 2], path[i + 3])
        if d < best then best = d end
    end
    return best
end

--- The bounding box of a path, grown by r.
local function pathBounds(path, r)
    local x0, y0 = math.huge, math.huge
    local x1, y1 = -math.huge, -math.huge
    for i = 1, #path - 1, 2 do
        local x, y = path[i], path[i + 1]
        if x < x0 then x0 = x end
        if y < y0 then y0 = y end
        if x > x1 then x1 = x end
        if y > y1 then y1 = y end
    end
    return x0 - r, y0 - r, x1 + r, y1 + r
end

--[[--
The first point of this stroke within r of the path, or nil.

Rejects on the stroke's own box first, then on the box of each run of points --
so for the strokes a single sample of a moving rubber does not touch, which is
nearly all of them on a written page, the answer is reached without measuring a
single distance, and without allocating anything.
--]]
function Stroke:_firstPointOnPath(path, r)
    local px0, py0, px1, py1 = pathBounds(path, r)
    local bx, by, bw, bh = self:getBounds()
    if px1 < bx or px0 > bx + bw or py1 < by or py0 > by + bh then
        return nil
    end

    local r2 = r * r
    local pts = self.pts
    local chunks = self:chunkIndex()

    if not chunks then
        local o = 0
        for i = 1, self.n do
            if distToPathSq(pts[o + 1], pts[o + 2], path) <= r2 then return i end
            o = o + STRIDE
        end
        return nil
    end

    for k = 1, #chunks do
        local c = chunks[k]
        if px1 >= c[3] and px0 <= c[5] and py1 >= c[4] and py0 <= c[6] then
            for i = c[1], c[2] do
                local o = (i - 1) * STRIDE
                if distToPathSq(pts[o + 1], pts[o + 2], path) <= r2 then return i end
            end
        end
    end
    return nil
end

--- True if this stroke comes within r of anywhere on the path.
function Stroke:hitTestPath(path, r)
    if #path < 2 then return false end

    -- Two tests, because either shape can pass close to the other without any
    -- of its own recorded points being near: a long stroke crossing a short
    -- eraser path, and the reverse.
    if self:_firstPointOnPath(path, r) then return true end

    for i = 1, #path - 1, 2 do
        if self:hitTest(path[i], path[i + 1], r) then return true end
    end
    return false
end

--[[--
Splits this stroke around a whole eraser path, rather than one point of it.

Same shape as splitAround, and the same rules about what is kept, but measured
against the polyline so a fast sweep takes out a continuous piece instead of a
dotted line of bites.
--]]
--
-- Also reports the box the removed points occupied, inflated to cover the ink
-- they were drawn with. That box is what the screen has to be repainted over,
-- and it is a tiny fraction of the stroke's own bounding box -- which is what
-- used to be repainted, so rubbing a corner of a long line cost a repaint of
-- everything between its two ends.
--
-- @treturn table,number,number,number,number fragments and x, y, w, h
function Stroke:splitAlongPath(path, r)
    if #path < 2 then return nil end

    -- Settle first whether anything is taken at all. Almost always nothing is,
    -- and that answer costs no allocation -- where building the surviving
    -- fragments, only to find they are the whole stroke again, would copy every
    -- point of it for each of the dozens of samples one sweep produces.
    local first = self:_firstPointOnPath(path, r)
    if not first then return nil end

    local px0, py0, px1, py1 = pathBounds(path, r)
    local r2 = r * r
    local pts = self.pts
    local chunks = self:chunkIndex()
    local fragments = {}
    local current
    local rx0, ry0, rx1, ry1 = math.huge, math.huge, -math.huge, -math.huge

    local function fragment()
        if current then return current end
        current = Stroke:new{
            tool = self.tool,
            width = self.width,
            color = self.color,
            tint = self.tint,
        }
        table.insert(fragments, current)
        return current
    end

    --- Tests points `from`..`to` one at a time, keeping what the rubber missed.
    local function sift(from, to)
        for i = from, to do
            local o = (i - 1) * STRIDE
            local x, y = pts[o + 1], pts[o + 2]
            if distToPathSq(x, y, path) <= r2 then
                current = nil
                if x < rx0 then rx0 = x end
                if y < ry0 then ry0 = y end
                if x > rx1 then rx1 = x end
                if y > ry1 then ry1 = y end
            else
                fragment():addPoint(x, y, pts[o + 3])
            end
        end
    end

    -- Everything before the first point the rubber reaches survives by
    -- definition, so it is copied rather than measured all over again.
    if first > 1 then
        fragment():appendRange(self, 1, first - 1)
    end

    if not chunks then
        sift(first, self.n)
    else
        -- Walked once, in order, with a cursor rather than a list of spans:
        -- runs the rubber cannot be over are copied wholesale, the rest are
        -- sifted point by point. The cursor is what keeps the point two runs
        -- share from being copied twice.
        local next_i = first
        for k = 1, #chunks do
            local c = chunks[k]
            if c[2] >= next_i
               and px1 >= c[3] and px0 <= c[5] and py1 >= c[4] and py0 <= c[6] then
                if c[1] > next_i then
                    fragment():appendRange(self, next_i, c[1] - 1)
                end
                sift(math.max(next_i, c[1]), c[2])
                next_i = c[2] + 1
            end
        end
        if next_i <= self.n then
            fragment():appendRange(self, next_i, self.n)
        end
    end

    if rx0 == math.huge then return nil end

    local kept = {}
    for _, frag in ipairs(fragments) do
        if frag:count() > 1 then
            table.insert(kept, frag)
        end
    end

    local pad = math.ceil(self.width / 2) + 1
    return kept, rx0 - pad, ry0 - pad,
        (rx1 + pad) - (rx0 - pad), (ry1 + pad) - (ry0 - pad)
end


--- Flattens the stroke into a plain table suitable for serialization.
function Stroke:serialize()
    return {
        tool = self.tool,
        width = self.width,
        color = self.color,
        n = self.n,
        pts = self.pts,
    }
end

--- Rebuilds a stroke from serialized data.
function Stroke:deserialize(data)
    local o = Stroke:new{ tool = data.tool, width = data.width, color = data.color }
    o.pts = data.pts
    o.n = data.n
    -- Recompute bounds rather than trusting the file.
    for i = 1, o.n do
        local x, y = o:getPoint(i)
        if x < o.x_min then o.x_min = x end
        if y < o.y_min then o.y_min = y end
        if x > o.x_max then o.x_max = x end
        if y > o.y_max then o.y_max = y end
    end
    return o
end

return Stroke
