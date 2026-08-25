--[[--
Proves that this plugin always gives KOReader's event loop back.

`UIManager:handleInput` is, in essence:

    repeat
        _checkTasks()
        _repaint()
    until not _task_queue_dirty

and input is read only *after* that loop settles. So the number of times round
it is not a performance curiosity: it is how many units of our work the reader
must wait through before a touch can be noticed. A chain of tasks due
immediately never settles at all, and a Kindle whose input is never read is a
Kindle that has to be rebooted -- which is what this measures and forbids.

The gallery is the case that mattered. Rendering a thumbnail means loading a
notebook and rasterising a page of it; nine of those went round this loop nine
times, with the panel and the touchscreen dead throughout. Scheduling a moment
ahead instead (see `Safe.later`) settles the loop after each one.

Run it from the emulator's koreader directory, with the plugin copied into
plugins/ and, ideally, no thumbnail cache:

    rm -rf scribe/.thumbs
    SDL_VIDEODRIVER=dummy ./luajit plugins/notebook.koplugin/spec/loop.lua

@module notebook.spec.loop
--]]--

require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
package.path = "plugins/notebook.koplugin/?.lua;" .. package.path

local UIManager = require("ui/uimanager")

local passed, failed = 0, 0

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", name, "\n         ", tostring(detail), "\n")
    end
end

--[[--
Runs one iteration of the real loop and returns how many rounds it took.

Anything above a handful means the reader is waiting; anything unbounded means
the reader is stuck. The ceiling is here so that a regression reports a failure
rather than hanging this script the way it would hang the device.
--]]
local function rounds(ceiling)
    local n = 0
    repeat
        n = n + 1
        if n > (ceiling or 200) then return nil end
        UIManager:_checkTasks()
        UIManager:_repaint()
    until not UIManager._task_queue_dirty
    return n
end

-- No unit of work may hold the loop for more than a couple of rounds: one for
-- the work itself, and one for it to arrange to be called again.
local LIMIT = 4

local Gallery = require("gallery")
local gallery = Gallery:new{}
UIManager:show(gallery)

local opened = rounds()
check("opening the gallery gives the loop straight back",
    opened ~= nil and opened <= LIMIT,
    opened and ("took " .. opened .. " rounds, which is that many pictures "
        .. "rendered before a touch could be noticed")
        or "never settled: the device would have stopped answering")

-- The pictures should now arrive one per pass, not all inside one.
local worked, budget = 0, 0
while gallery.thumb_working and budget < 60 do
    budget = budget + 1
    local n = rounds()
    if n == nil then break end
    if n > LIMIT then worked = worked + 1 end
end
check("each picture is a pass of its own, with input read between them",
    worked == 0,
    worked .. " passes did more than one unit of work")

local Document = require("document")
local doc = Document:new("/tmp/scribe-loop.scribe")
doc:insertPage(1)

for _, case in ipairs({
    { "the new notebook screen", function() gallery:_createNotebook() end },
    { "the page overview", function()
        UIManager:show(require("pagepanel"):new{ document = doc })
    end },
    { "the settings panel", function()
        local notebook = require("notebook"):new{ document = doc, title = "x" }
        UIManager:show(require("settings"):new{
            canvas = notebook.canvas, on_change = function() end,
        })
    end },
}) do
    local ok, err = pcall(case[2])
    if not ok then
        check("opening " .. case[1], false, err)
    else
        local n = rounds()
        check("opening " .. case[1] .. " gives the loop straight back",
            n ~= nil and n <= LIMIT,
            n and ("took " .. n .. " rounds") or "never settled")
    end
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
