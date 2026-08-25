--[[--
Test doubles for the KOReader modules the plugin depends on.

The point of these is to let the pure logic — stroke geometry, the undo model,
the rasterizer's coverage and dirty rects — be tested on a desktop in
milliseconds, with no device, no emulator and no framebuffer. Anything that
genuinely needs a screen is out of scope here and gets verified in the emulator.

@module notebook.spec.support
--]]--

local support = {}

-- A blitbuffer stand-in that records pixels in a plain grid, so tests can assert
-- on what was actually painted rather than on which calls were made.
local FakeBB = {}
FakeBB.__index = FakeBB

function FakeBB.new(w, h)
    local o = setmetatable({ w = w, h = h, px = {} }, FakeBB)
    for y = 0, h - 1 do
        o.px[y] = {}
        for x = 0, w - 1 do
            o.px[y][x] = 255 -- white paper
        end
    end
    return o
end

function FakeBB:set(x, y, v)
    x, y = math.floor(x), math.floor(y)
    if x < 0 or y < 0 or x >= self.w or y >= self.h then return end
    self.px[y][x] = v
end

function FakeBB:get(x, y)
    if x < 0 or y < 0 or x >= self.w or y >= self.h then return nil end
    return self.px[y][x]
end

function FakeBB:paintRect(x, y, w, h, value)
    local v = type(value) == "table" and value.a or value
    for j = y, y + h - 1 do
        for i = x, x + w - 1 do
            self:set(i, j, v)
        end
    end
end

function FakeBB:paintCircle(cx, cy, r, value)
    local v = type(value) == "table" and value.a or value
    for j = cy - r, cy + r do
        for i = cx - r, cx + r do
            local dx, dy = i - cx, j - cy
            if dx * dx + dy * dy <= r * r then
                self:set(i, j, v)
            end
        end
    end
end

--- Plain write, matching blitbuffer's setPixel.
function FakeBB:setPixel(x, y, color)
    local v = type(color) == "table" and color.a or color
    self:set(x, y, v)
end

--- Multiply blend, matching blitbuffer's setPixelMultiply semantics.
function FakeBB:setPixelMultiply(x, y, color)
    local v = type(color) == "table" and color.a or color
    local cur = self:get(x, y)
    if cur then self:set(x, y, math.floor(cur * v / 255)) end
end

function FakeBB:darkenRect(x, y, w, h, by)
    for j = y, y + h - 1 do
        for i = x, x + w - 1 do
            local cur = self:get(i, j)
            if cur then self:set(i, j, math.max(0, cur - by)) end
        end
    end
end

--- Draws a hollow rectangle, matching blitbuffer's paintBorder.
function FakeBB:paintBorder(x, y, w, h, thickness, value)
    self:paintRect(x, y, w, thickness, value)
    self:paintRect(x, y + h - thickness, w, thickness, value)
    self:paintRect(x, y, thickness, h, value)
    self:paintRect(x + w - thickness, y, thickness, h, value)
end

--- Clears the entire buffer to a given color.
function FakeBB:fill(color)
    local v = type(color) == "table" and color.a or color
    for y = 0, self.h - 1 do
        for x = 0, self.w - 1 do
            self.px[y][x] = v
        end
    end
end

--- Returns a color object exposing :getColor8().a and .a.
function FakeBB:getPixel(x, y)
    local v = self:get(x, y) or 255
    return {
        a = v,
        getColor8 = function(s) return s end,
    }
end

--- Counts pixels darker than white.
function FakeBB:inkedCount()
    local n = 0
    for y = 0, self.h - 1 do
        for x = 0, self.w - 1 do
            if self.px[y][x] < 255 then n = n + 1 end
        end
    end
    return n
end

support.FakeBB = FakeBB

--- Installs stubs for the KOReader modules the plugin requires.
-- @tparam table store optional table used as the fake filesystem for Persist
function support.installStubs(store)
    store = store or {}

    package.loaded["ffi/blitbuffer"] = {
        Color8 = function(v) return { a = v, getColor8 = function(s) return s end } end,
        new = function(w, h, bb_type) return support.FakeBB.new(w, h) end,
        COLOR_WHITE = 255,
        COLOR_BLACK = 0,
        COLOR_GRAY_E = 0xEE,
        COLOR_GRAY_D = 0xDD,
        COLOR_LIGHT_GRAY = 0xCC,
        COLOR_GRAY = 0xAA,
        COLOR_DARK_GRAY = 0x88,
        COLOR_GRAY_5 = 0x55,
        TYPE_BB8 = 1,
    }

    package.loaded["gettext"] = setmetatable({}, {
        __call = function(_, text) return text end,
    })
    package.loaded["i18n"] = package.loaded["gettext"]

    package.loaded["logger"] = setmetatable({}, {
        __index = function() return function() end end,
    })

    -- Persist round-trips through an in-memory table. Note this keeps live
    -- references rather than copying, so tests that care about true
    -- serialization must deep-copy explicitly.
    local Persist = {}
    Persist.__index = Persist
    function Persist:new(o)
        return setmetatable({ path = o.path }, Persist)
    end
    function Persist:save(t)
        store[self.path] = t
        return true
    end
    function Persist:load()
        return store[self.path]
    end
    package.loaded["persist"] = Persist

    return store
end

return support
