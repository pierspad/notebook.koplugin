--[[--
Drives the canvas the way a hand would, against the real framework.

Draw, highlight, erase both ways, undo, redo, save, load, export. Nothing is
asserted about how any of it looks: the point is that the real code paths run
against a real blitbuffer, where a blitbuffer call with the wrong arguments, or
a method that only the test stubs happen to have, is an error rather than a
silent pass.

Run it from the emulator's koreader directory, with the plugin copied into
plugins/:

    SDL_VIDEODRIVER=dummy ./luajit plugins/notebook.koplugin/spec/exercise.lua

@module notebook.spec.exercise
--]]--

require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = "plugins/notebook.koplugin/?.lua;" .. package.path

local Canvas = require("canvas")
local Document = require("document")
local Export = require("export")
local Geom = require("ui/geometry")
local Screen = Device.screen
local W, H = Screen:getWidth(), Screen:getHeight()

local steps, failures = 0, 0
local function step(name, fn)
    steps = steps + 1
    local ok, err = pcall(fn)
    if ok then
        io.write("  ok   ", name, "\n")
    else
        failures = failures + 1
        io.write("  FAIL ", name, "\n         ", tostring(err), "\n")
    end
end

local path = "/tmp/scribe-exercise.scribe"
local doc = Document:new(path)
local canvas = Canvas:new{
    document = doc,
    content = Geom:new{ x = 0, y = 200, w = W, h = H - 200 },
}

--- Writes a wiggly line, the way a word arrives: many samples, close together.
local function write(tool, x0, y0, length)
    canvas.tool = tool
    canvas:_beginStroke(tool, x0, y0, 1)
    for i = 1, length do
        canvas:_extendStroke(x0 + i * 3, y0 + math.floor(math.sin(i / 6) * 40), 1)
    end
    canvas:_endStroke()
end

step("a page of handwriting", function()
    for row = 0, 9 do
        write("pen", 100, 400 + row * 120, 300)
    end
    assert(#doc:getPage().strokes == 10, "strokes on the page")
end)

step("a highlight over it, twice", function()
    write("highlighter", 100, 500, 200)
    write("highlighter", 100, 500, 200)
end)

step("rubbing out part of a stroke", function()
    canvas.eraser_mode = "area"
    local before = #doc:getPage().strokes
    for i = 0, 40 do
        canvas:_eraseAlong(300 + i * 8, 520)
    end
    canvas:_endErase()
    canvas.last_erase_x, canvas.last_erase_y = nil, nil
    assert(#doc:getPage().strokes > before, "the strokes were not split")
end)

step("rubbing out whole strokes", function()
    canvas.eraser_mode = "stroke"
    for i = 0, 40 do
        canvas:_eraseAlong(200 + i * 8, 1000)
    end
    canvas:_endErase()
    canvas.last_erase_x, canvas.last_erase_y = nil, nil
end)

step("undo, all the way back", function()
    local n = 0
    while doc:canUndo() and n < 100 do
        doc:undo()
        n = n + 1
    end
    assert(n > 0, "nothing was undoable")
end)

step("redo, all the way forward", function()
    local n = 0
    while doc:canRedo() and n < 100 do
        doc:redo()
        n = n + 1
    end
    assert(n > 0, "nothing was redoable")
end)

step("repainting a region from the model", function()
    canvas:_repaintRegion(300, 400, 400, 400)
    canvas:_repaintRegion(0, 200, W, H - 200)
end)

step("painting the whole page", function()
    canvas:paintTo(Screen.bb, 0, 0)
end)

step("pages, saved and loaded back", function()
    doc:addPage()
    write("pen", 200, 600, 100)
    assert(doc:save())
    local again = Document:new(path)
    assert(again:load(), "the notebook did not load")
    assert(again:pageCount() == doc:pageCount(), "page count survived")
end)

step("export to PDF", function()
    local ok, err = Export.toPDF(doc, "/tmp/scribe-exercise.pdf")
    assert(ok, tostring(err))
end)

io.write(string.format("\n%d steps, %d failed\n", steps, failures))
os.exit(failures == 0 and 0 or 1)
