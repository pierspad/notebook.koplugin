--[[--
Headless renderer: builds the notebook screen and writes it to a PNG.

Driving the emulator's window turned out to be unreliable (SDL under XWayland
does not receive synthetic pointer events), and layout bugs -- a toolbar that
overflows the screen and takes its last buttons out of reach -- are invisible
in unit tests but obvious in a picture. So this paints the real widgets into a
real blitbuffer and dumps the result, with no window and no input.

Run it from the emulator's koreader directory:

    SDL_VIDEODRIVER=dummy ./luajit plugins/notebook.koplugin/spec/render.lua /tmp/out.png

@module notebook.spec.render
--]]--

local out_path = arg[1] or "/tmp/scribe-render.png"

require("setupkoenv")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
-- Font handling asks CanvasContext what kind of device this is, and it is not
-- wired up to Device until someone does it. reader.lua does this too.
require("document/canvascontext"):init(Device)

-- The plugin's own modules are only on the path while the plugin loader is
-- running, so put them there by hand.
package.path = "plugins/notebook.koplugin/?.lua;" .. package.path

local Blitbuffer = require("ffi/blitbuffer")
local Document = require("document")
local Notebook = require("notebook")
local Stroke = require("stroke")

local Screen = Device.screen
local w, h = Screen:getWidth(), Screen:getHeight()

-- Build a page with something on it, so the canvas is not just blank paper.
local doc = Document:new("/tmp/scribe-render.scribe")

local function addStroke(tool, width, pts)
    local s = Stroke:new{ tool = tool, width = width, color = 0 }
    for i = 1, #pts, 2 do
        s:addPoint(pts[i], pts[i + 1], 1)
    end
    doc:addStroke(s)
end

local mid = math.floor(h / 2)
addStroke("pen", 3, {
    math.floor(w * 0.1), mid,
    math.floor(w * 0.25), mid - 60,
    math.floor(w * 0.4), mid + 40,
    math.floor(w * 0.55), mid - 30,
})
addStroke("highlighter", 24, {
    math.floor(w * 0.1), mid,
    math.floor(w * 0.6), mid,
})

local notebook = Notebook:new{ document = doc }

local bb = Blitbuffer.new(w, h, Screen.bb:getType())
bb:fill(Blitbuffer.COLOR_WHITE)
notebook:paintTo(bb, 0, 0)

-- Report the toolbar geometry: an overflow here is exactly the kind of bug that
-- silently makes the last control untappable.
local tb = notebook.toolbar:getSize()
io.write(string.format("screen      : %dx%d\n", w, h))
io.write(string.format("toolbar     : %dx%d\n", tb.w, tb.h))
if tb.w > w then
    io.write(string.format("OVERFLOW    : toolbar is %d px wider than the screen\n", tb.w - w))
else
    io.write(string.format("fits        : %d px to spare\n", w - tb.w))
end
io.write(string.format("canvas area : y=%d h=%d\n",
    notebook.canvas.content.y, notebook.canvas.content.h))

bb:writePNG(out_path)
io.write("wrote       : " .. out_path .. "\n")
