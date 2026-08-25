--[[--
End-to-end PDF export against the real blitbuffer.

The unit tests check the exporter's own arithmetic with a stubbed buffer. This
one runs it for real -- real rendering, real pixels, real file -- so the output
can be handed to an actual PDF reader. A file that satisfies every internal
assertion and still fails to open is exactly the failure mode worth catching.

Run from the emulator's koreader directory:

    SDL_VIDEODRIVER=dummy ./luajit plugins/notebook.koplugin/spec/export_real.lua /tmp/out.pdf

@module notebook.spec.export_real
--]]--

local out_path = arg[1] or "/tmp/scribe-export.pdf"
local pages = tonumber(arg[2]) or 3

require("setupkoenv")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
require("document/canvascontext"):init(Device)

package.path = "plugins/notebook.koplugin/?.lua;" .. package.path

local Document = require("document")
local Export = require("export")
local Stroke = require("stroke")

local W, H = 1860, 2480

local doc = Document:new("/tmp/scribe-export-src.scribe")

for p = 1, pages do
    if p > 1 then doc:addPage() end

    -- Handwriting-ish content: several short strokes plus one long diagonal,
    -- which is the case that stresses both the encoder and the page bounds.
    for row = 1, 12 do
        local s = Stroke:new{ width = 3, color = 0 }
        local y = 200 + row * 150
        for i = 0, 40 do
            local x = 200 + i * 30
            s:addPoint(x, y + math.sin(i / 3 + row + p) * 18, 1)
        end
        doc:addStroke(s)
    end

    local diag = Stroke:new{ width = 4, color = 0 }
    for i = 0, 100 do
        diag:addPoint(100 + i * 16, 100 + i * 22, 1)
    end
    doc:addStroke(diag)

    local hl = Stroke:new{ tool = "highlighter", width = 40 }
    for i = 0, 30 do
        hl:addPoint(250 + i * 40, 500, 1)
    end
    doc:addStroke(hl)
end

local started = os.clock()
local ok, err = Export.toPDF(doc, out_path, { width = W, height = H })
local elapsed = os.clock() - started

if not ok then
    io.write("FAILED: " .. tostring(err) .. "\n")
    os.exit(1)
end

local f = io.open(out_path, "rb")
local size = f:seek("end")
f:close()

io.write(string.format("pages   : %d\n", doc:pageCount()))
io.write(string.format("bytes   : %d (%.1f kB, %.1f kB/page)\n",
    size, size / 1024, size / 1024 / doc:pageCount()))
io.write(string.format("seconds : %.2f (%.2f per page)\n",
    elapsed, elapsed / doc:pageCount()))
io.write("wrote   : " .. out_path .. "\n")
