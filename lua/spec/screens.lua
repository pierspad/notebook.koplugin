--[[--
Every screen the plugin puts up, built at real device geometry, checked for
anything that lands off the screen or under the keyboard, and dumped as a PNG.

The unit tests cannot see these bugs, and for a long time neither could anyone
else until the device showed them: a HorizontalGroup that does not fit neither
wraps nor complains, it just runs off the edge taking its last button with it,
and a panel that is taller than the space above the keyboard hides its own
Cancel button. Both had happened. Both are obvious here, in numbers, in a
second, at whatever size and density the device really has.

Run it from the emulator's koreader directory, with the plugin copied into
plugins/, at the geometry you care about:

    SDL_VIDEODRIVER=dummy EMULATE_READER_W=1860 EMULATE_READER_H=2480 \
        EMULATE_READER_DPI=300 ./luajit plugins/notebook.koplugin/spec/screens.lua

Add LANGUAGE=it to check a translation: the labels are longer in every language
than they are in English, and that is exactly what pushes a row over the edge.

@module notebook.spec.screens
--]]--

require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = "plugins/notebook.koplugin/?.lua;" .. package.path

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local W, H = Screen:getWidth(), Screen:getHeight()

local out_dir = arg[1] or "/tmp"
local problems = 0

--- Paints one widget and reports where its visible parts ended up.
local function check(name, widget, panel_field)
    local bb = Blitbuffer.new(W, H, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)

    local ok, err = pcall(function() widget:paintTo(bb, 0, 0) end)
    if not ok then
        problems = problems + 1
        io.write(string.format("%-14s PAINT ERROR: %s\n", name, tostring(err)))
        return
    end

    local d = (panel_field and widget[panel_field] and widget[panel_field].dimen)
        or widget.dimen
    local note = ""
    if d then
        if d.x < 0 or d.y < 0 or d.x + d.w > W or d.y + d.h > H then
            problems = problems + 1
            note = "  OFF SCREEN"
        end
        io.write(string.format("%-14s x=%-5d y=%-5d w=%-5d h=%-5d%s\n",
            name, d.x or 0, d.y or 0, d.w or 0, d.h or 0, note))
    else
        io.write(string.format("%-14s no dimen after painting\n", name))
    end

    bb:writePNG(out_dir .. "/screen-" .. name .. ".png")
end

-- The gallery, over the notebook folder as it really is.
local Gallery = require("gallery")
local gallery = Gallery:new{}
check("gallery", gallery)
do
    local Size = require("ui/size")
    local avail = W - 2 * Size.padding.large
    local row = gallery.header_row:getSize().w
    io.write(string.format("               header row %d of %d available%s\n",
        row, avail, row > avail and "   TOO WIDE" or ""))
    if row > avail then problems = problems + 1 end
    local footer = gallery.footer
    if footer then
        io.write(string.format("               footer %d tall, bottom at %d of %d\n",
            footer:getSize().h, H, H))
    end
end

-- Creating a notebook, which is the one with a keyboard under it.
local NewNotebook = require("newnotebook")
local nn = NewNotebook:new{ name = "Notebook 1", on_create = function() end }
check("newnotebook", nn, "panel")
local kb = nn.input:getKeyboardDimen()
local pd = nn.panel.dimen
if kb and pd and pd.y + pd.h > H - kb.h then
    problems = problems + 1
    io.write(string.format("               OVERLAP: %d px under the keyboard\n",
        (pd.y + pd.h) - (H - kb.h)))
end

-- A notebook, its page overview, its settings and its paper picker.
local Document = require("document")
local doc = Document:new("/tmp/screens.scribe")
doc:insertPage(1)
doc:insertPage(2)

local Notebook = require("notebook")
local notebook = Notebook:new{ document = doc, title = "Notebook 1" }
check("notebook", notebook)

local PagePanel = require("pagepanel")
check("pagepanel", PagePanel:new{ document = doc })

local SettingsDialog = require("settings")
check("settings", SettingsDialog:new{
    canvas = notebook.canvas,
    on_change = function() end,
}, "panel")

local TemplatePicker = require("templatepicker")
check("paperpicker", TemplatePicker:new{
    title = "Paper", current = "blank", on_pick = function() end,
}, "panel")

local ActionMenu = require("actionmenu")
check("actionmenu", ActionMenu:new{
    title = "Notebook 1",
    actions = {
        { icon = "notebook.open", text = "Open", callback = function() end },
        { icon = "notebook.rename", text = "Rename", callback = function() end },
        { icon = "notebook.export", text = "Export as PDF", callback = function() end },
        { icon = "notebook.delete", text = "Delete", callback = function() end },
    },
}, "panel")

io.write(string.format("\n%d problem(s)\n", problems))
os.exit(problems == 0 and 0 or 1)
