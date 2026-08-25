--[[--
Stand-ins for the KOReader widget layer, so the gallery can be laid out,
painted and driven on a desktop.

These are deliberately faithful on the two points the gallery's bugs turned on:

  * `FrameContainer` paints its background over `self.width`/`self.height` when
    they are given, and only over its content's size when they are not -- which
    is what decides whether a screen is fully covered or only partly.
  * `UIManager:setDirty` only marks a widget for repainting when it is actually
    given one; `setDirty(nil, ...)` refreshes the panel from an unchanged
    buffer, exactly as the real one does.

Everything else is the smallest thing that lets a layout be built and measured.

@module notebook.spec.uistubs
--]]--

local stubs = {}

-- Widget base -----------------------------------------------------------------

local Widget = {}

function Widget:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Widget:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function Widget:getSize()
    return self.dimen or { x = 0, y = 0, w = 0, h = 0 }
end

function Widget:paintTo() end
function Widget:free() self.freed = (self.freed or 0) + 1 end
function Widget:handleEvent() return false end

local function containerFree(self, full)
    for _, child in ipairs(self) do
        if child.free then child:free(full) end
    end
end

-- Containers ------------------------------------------------------------------

local WidgetContainer = Widget:extend{}

function WidgetContainer:getSize()
    if self.dimen then return self.dimen end
    if self[1] then return self[1]:getSize() end
    return { x = 0, y = 0, w = 0, h = 0 }
end

function WidgetContainer:paintTo(bb, x, y)
    if self[1] then self[1]:paintTo(bb, x, y) end
end

WidgetContainer.free = containerFree

local InputContainer = WidgetContainer:extend{}

function InputContainer:paintTo(bb, x, y)
    if not self.dimen then
        local size = self[1] and self[1]:getSize() or { w = 0, h = 0 }
        self.dimen = { x = x, y = y, w = size.w, h = size.h }
    else
        self.dimen.x = x
        self.dimen.y = y
    end
    if self[1] then self[1]:paintTo(bb, x, y) end
end

local CenterContainer = WidgetContainer:extend{}

function CenterContainer:getSize()
    return self.dimen
end

function CenterContainer:paintTo(bb, x, y)
    if not self[1] then return end
    local content = self[1]:getSize()
    self[1]:paintTo(bb,
        x + math.floor((self.dimen.w - content.w) / 2),
        y + math.floor((self.dimen.h - content.h) / 2))
end

local LeftContainer = CenterContainer:extend{}

function LeftContainer:paintTo(bb, x, y)
    if not self[1] then return end
    local content = self[1]:getSize()
    self[1]:paintTo(bb, x, y + math.floor((self.dimen.h - content.h) / 2))
end

--- Mirrors the real FrameContainer's sizing and background rule.
local FrameContainer = WidgetContainer:extend{
    margin = 0,
    bordersize = 1,
    padding = 0,
}

function FrameContainer:getSize()
    local content = self[1] and self[1]:getSize() or { w = 0, h = 0 }
    return {
        w = content.w + (self.margin + self.bordersize) * 2 + self.padding * 2,
        h = content.h + (self.margin + self.bordersize) * 2 + self.padding * 2,
    }
end

function FrameContainer:paintTo(bb, x, y)
    local my_size = self:getSize()
    self.dimen = { x = x, y = y, w = my_size.w, h = my_size.h }
    local container_width = self.width or my_size.w
    local container_height = self.height or my_size.h
    if self.background then
        bb:paintRect(x, y, container_width, container_height, self.background)
    end
    if self[1] then
        self[1]:paintTo(bb,
            x + self.margin + self.bordersize + self.padding,
            y + self.margin + self.bordersize + self.padding)
    end
end

-- Groups ----------------------------------------------------------------------

--[[--
A vertical group, including the part of it that bites.

The real one measures itself once, remembers where every child goes, and paints
by walking the children and those remembered positions together. A child added
after the first measurement therefore has no position, and painting indexes past
the end of the list -- the screen does not appear and the widget takes the whole
plugin down with it.

Modelled here rather than recomputed on demand, which is the comfortable version
and hides exactly that mistake.
--]]
local VerticalGroup = Widget:extend{}

function VerticalGroup:getSize()
    if not self._size then
        self._size = { w = 0, h = 0 }
        self._offsets = {}
        for i, child in ipairs(self) do
            local size = child:getSize()
            self._offsets[i] = { x = size.w, y = self._size.h }
            self._size.h = self._size.h + size.h
            self._size.w = math.max(self._size.w, size.w)
        end
    end
    return self._size
end

function VerticalGroup:paintTo(bb, x, y)
    self:getSize()
    for i, child in ipairs(self) do
        child:paintTo(bb, x, y + self._offsets[i].y)
    end
end

function VerticalGroup:resetLayout()
    self._size = nil
    self._offsets = {}
end

function VerticalGroup:free(full)
    self:resetLayout()
    containerFree(self, full)
end

local HorizontalGroup = Widget:extend{}

function HorizontalGroup:getSize()
    local w, h = 0, 0
    for _, child in ipairs(self) do
        local size = child:getSize()
        w = w + size.w
        h = math.max(h, size.h)
    end
    return { w = w, h = h }
end

function HorizontalGroup:paintTo(bb, x, y)
    for _, child in ipairs(self) do
        child:paintTo(bb, x, y)
        x = x + child:getSize().w
    end
end

HorizontalGroup.free = containerFree

--[[--
The screen these tests lay out on, and how sizes scale on it.

A Kindle Scribe, with the density it really has. Both matter, and neither is a
detail: KOReader scales every padding, border and font by the panel's density,
so a stub that returned sizes unscaled laid out screens that were proportionally
nothing like the device. Panels came out comfortably inside a screen they run
off the edge of in reality -- which is exactly the bug class these tests exist
to catch, waved through because the stub made everything fit.
--]]
local SCREEN_W, SCREEN_H = 1860, 2480
local SCALE = 3.1

local function scaled(n)
    return math.floor(n * SCALE)
end

-- Leaves ----------------------------------------------------------------------

local function leaf(defaults)
    local L = Widget:extend(defaults or {})
    function L:getSize()
        return { w = self.width or self.w or 0, h = self.height or self.h or 0 }
    end
    return L
end

local TextWidget = leaf()

function TextWidget:getSize()
    -- Proportioned like real text at this density: a line is about as tall as
    -- its point size scaled, and a character about half that wide. The exact
    -- metrics do not matter, but the order of magnitude does -- a row of
    -- buttons either fits across the screen or it does not.
    local h = math.floor((self.face or 20) * SCALE)
    return { w = #tostring(self.text or "") * math.floor(h / 2), h = h }
end

function TextWidget:setText(text) self.text = text end

-- Screen ----------------------------------------------------------------------

--[[--
Installs the widget layer.

@tparam table fs the in-memory filesystem for the lfs stub
@treturn table a handle exposing the recorded UIManager traffic
--]]
function stubs.install(fs)
    fs = fs or {}

    local recorder = {
        dirty = {},          -- every setDirty call, in order
        shown = {},
        closed = {},
        ticks = {},
        thumbnails = {},     -- notebooks whose thumbnail was generated
        fs = fs,
    }

    package.loaded["ui/geometry"] = {
        new = function(_, o)
            o = o or {}
            o.x = o.x or 0
            o.y = o.y or 0
            o.w = o.w or 0
            o.h = o.h or 0
            function o:copy()
                return package.loaded["ui/geometry"]:new{ x = self.x, y = self.y, w = self.w, h = self.h }
            end
            return o
        end,
    }

    package.loaded["ui/gesturerange"] = {
        new = function(_, o) return o end,
    }

    package.loaded["ui/widget/widget"] = Widget
    package.loaded["ui/widget/container/widgetcontainer"] = WidgetContainer
    package.loaded["ui/widget/container/inputcontainer"] = InputContainer
    package.loaded["ui/widget/container/centercontainer"] = CenterContainer
    package.loaded["ui/widget/container/leftcontainer"] = LeftContainer
    package.loaded["ui/widget/container/framecontainer"] = FrameContainer
    package.loaded["ui/widget/verticalgroup"] = VerticalGroup
    package.loaded["ui/widget/horizontalgroup"] = HorizontalGroup
    -- A vertical span is sized by `width`, which is its *height*: the real
    -- widget is a Widget with a width field and a getSize that reports it as h.
    -- Modelled here rather than left as a generic leaf, which reported a height
    -- of zero and so made padding measure as though it were not there.
    local VerticalSpan = Widget:extend{ width = 0 }
    function VerticalSpan:getSize() return { w = 0, h = self.width or 0 } end
    package.loaded["ui/widget/verticalspan"] = VerticalSpan
    package.loaded["ui/widget/horizontalspan"] = leaf()
    package.loaded["ui/widget/linewidget"] = leaf()
    package.loaded["ui/widget/textwidget"] = TextWidget
    package.loaded["ui/widget/iconwidget"] = leaf()
    package.loaded["ui/widget/imagewidget"] = leaf()
    package.loaded["ui/widget/infomessage"] = leaf()
    package.loaded["ui/widget/confirmbox"] = leaf()
    package.loaded["ui/widget/inputdialog"] = leaf()
    package.loaded["ui/widget/button"] = leaf()

    package.loaded["ui/font"] = {
        getFace = function(_, _, size) return size or 20 end,
    }

    -- The same numbers KOReader's own Size module uses, scaled the way it
    -- scales them.
    package.loaded["ui/size"] = {
        border = { thin = scaled(0.5), window = scaled(1.5), default = scaled(1),
                   thick = scaled(2) },
        padding = { small = scaled(2), large = scaled(10), default = scaled(5),
                    button = scaled(2), fullscreen = scaled(15) },
        radius = { button = scaled(2), window = scaled(7), default = scaled(2) },
        line = { thin = scaled(1), medium = scaled(2) },
        span = { horizontal_default = scaled(3) },
    }

    package.loaded["device"] = {
        screen = {
            getWidth = function() return SCREEN_W end,
            getHeight = function() return SCREEN_H end,
            scaleBySize = function(_, n) return scaled(n) end,
        },
        isTouchDevice = function() return true end,
        input = {},
    }

    package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
    package.loaded["i18n"] = package.loaded["gettext"]
    --[[
    A text field that knows how tall its keyboard is, because the real one does
    and because that number decides a layout: the screen that names a notebook
    has to fit above the keyboard, and a stub that pretended there was no
    keyboard would let a panel that runs underneath it pass the tests.

    A third of the screen is what KOReader's own keyboard comes to in portrait.
    --]]
    local InputText = leaf{ height = scaled(60) }
    function InputText:getKeyboardDimen()
        return { w = SCREEN_W, h = math.floor(SCREEN_H / 3) }
    end
    function InputText:getText() return self.text or "" end
    function InputText:onShowKeyboard() end
    function InputText:onCloseKeyboard() end
    package.loaded["ui/widget/inputtext"] = InputText
    package.loaded["ffi/util"] = {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    }

    -- Monotonic-ish time, in whatever unit the caller likes: the plugin only
    -- ever subtracts one of these from another and asks for milliseconds.
    package.loaded["ui/time"] = {
        now = function() return os.clock() * 1000 end,
        to_ms = function(t) return t end,
    }

    package.loaded["ui/widget/buttondialog"] = InputContainer:extend{}

    package.loaded["ffi/blitbuffer"] = {
        COLOR_WHITE = 0xff,
        COLOR_BLACK = 0x00,
        Color8 = function(c) return c end,
    }

    package.loaded["datastorage"] = {
        getDataDir = function() return "/data" end,
    }

    package.loaded["ui/uimanager"] = {
        setDirty = function(_, widget, mode, region)
            table.insert(recorder.dirty, { widget = widget, mode = mode, region = region })
        end,
        show = function(_, widget)
            table.insert(recorder.shown, widget)
            if widget.onShow then widget:onShow() end
        end,
        close = function(_, widget) table.insert(recorder.closed, widget) end,
        nextTick = function(_, fn) table.insert(recorder.ticks, fn) end,
        scheduleIn = function(_, _, fn) table.insert(recorder.ticks, fn) end,
        unschedule = function() end,
        getTopmostVisibleWidget = function() return nil end,
    }

    -- In-memory filesystem ------------------------------------------------------

    local function normalize(path)
        return (path:gsub("/+$", ""))
    end

    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(path, what)
            local entry = fs[normalize(path)]
            if not entry then return nil end
            if what then return entry[what] end
            return entry
        end,
        dir = function(path)
            path = normalize(path)
            local names = { ".", ".." }
            for p in pairs(fs) do
                local rest = p:match("^" .. path:gsub("%p", "%%%0") .. "/(.+)$")
                if rest and not rest:find("/") then table.insert(names, rest) end
            end
            table.sort(names)
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
        mkdir = function(path)
            fs[normalize(path)] = { mode = "directory", modification = 0 }
            return true
        end,
        rmdir = function(path)
            fs[normalize(path)] = nil
            return true
        end,
    }

    --[[--
    A rename that moves a directory and everything under it.

    Modelled because the plugin moves its own folder on first run, and without
    this the rename went to the real `os.rename`, failed against a path that
    exists only in this table, and the test passed by taking the failure branch
    -- that is, by testing the opposite of what it said.

    `recorder.rename_fails` makes it fail on purpose, which is the branch a
    device with a read-only filesystem or an unexpected leftover folder takes.
    --]]
    local real_rename = os.rename
    recorder.restoreRename = function() os.rename = real_rename end

    os.rename = function(from, to)
        if recorder.rename_fails then return nil, "refused by the test" end
        from, to = normalize(from), normalize(to)
        if not fs[from] then return real_rename(from, to) end

        local moved = {}
        for path, entry in pairs(fs) do
            if path == from or path:sub(1, #from + 1) == from .. "/" then
                moved[to .. path:sub(#from + 1)] = entry
                fs[path] = nil
            end
        end
        for path, entry in pairs(moved) do fs[path] = entry end
        return true
    end

    --- Records generation instead of rasterising: the cost is what matters here.
    package.loaded["thumbnail"] = {
        stamp = function(path)
            local entry = fs[normalize(path)]
            return entry and entry.modification or nil
        end,
        cached = function(path)
            local entry = fs[normalize(path) .. ".thumb"]
            return entry and (normalize(path) .. ".thumb") or nil
        end,
        get = function(path)
            table.insert(recorder.thumbnails, path)
            fs[normalize(path) .. ".thumb"] = { mode = "file", modification = 1 }
            return normalize(path) .. ".thumb"
        end,
        forget = function(path) fs[normalize(path) .. ".thumb"] = nil end,
    }

    --- Runs every queued tick, including ones queued by the ticks themselves.
    function recorder.runTicks(limit)
        local n = 0
        while #recorder.ticks > 0 do
            n = n + 1
            if n > (limit or 500) then error("tick queue never drained") end
            local fn = table.remove(recorder.ticks, 1)
            fn()
        end
        return n
    end

    function recorder.lastDirty()
        return recorder.dirty[#recorder.dirty]
    end

    recorder.screen_w, recorder.screen_h = SCREEN_W, SCREEN_H
    return recorder
end

return stubs
