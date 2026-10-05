-- luacheck: globals G_defaults
-- Run in a KOReader runtime with SDL_VIDEODRIVER=dummy and Kindle dimensions.
require("setupkoenv")
local plugin, output, sample = assert(arg[1]), assert(arg[2]), arg[3]
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(output .. "/settings.lua")
dofile(plugin .. "/../tools/emulator-display.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local Screen, SDL = Device.screen, require("ffi/SDL3")
assert(Screen:getWidth() == 1860 and Screen:getHeight() == 2480)
local bb = Screen.bb
Screen:resize(500, 650)
assert(Screen.bb == bb and Screen:getWidth() == 1860 and Screen:getHeight() == 2480,
    "window resizing changed notebook coordinates")
assert(SDL.win_w == 500 and SDL.win_h == 650)
assert(SDL.w / SDL.win_w == 3.72 and SDL.h / SDL.win_h > 3.81,
    "pointer coordinates lost framebuffer scaling")
local load = dofile(plugin .. "/loader.lua")(plugin)
load("pluginicons")()
local doc = load("document"):new(sample or (output .. "/sample.scribe"))
if sample then
    assert(doc:load())
    -- Canvas teardown may autosave metadata; never write into the supplied sample.
    doc.path = output .. "/sample-copy.scribe"
else
    local stroke=load("stroke"):new{tool="pen",width=12}
    stroke:addPoint(1800,2400);stroke:addPoint(1840,2400)
    doc:addStroke(stroke)
end
local notebook = load("notebook"):new{document=doc,title="Kindle example"}
notebook:paintTo(Screen.bb, 0, 0)
assert(not load("safe").failed)
if sample then
    for _,page in ipairs(doc.pages) do
        for _,stroke in ipairs(page.strokes) do
            assert(stroke.x_max <= Screen:getWidth() and stroke.y_max <= Screen:getHeight(),
                "Kindle example is clipped")
        end
    end
end
if not sample then
    assert(Screen.bb:getPixel(1820,2400):getColor8().a < 128,
        "lower-right stroke was clipped after resizing the window")
end
Screen.bb:writePNG(output .. "/kindle-notebook.png")
notebook.canvas:stop()
print("emulator display: fixed 1860x2480 framebuffer, window resize and pointer scaling passed")
