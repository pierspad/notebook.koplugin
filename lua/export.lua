--[[--
Exports a notebook document to PDF.

KOReader runs on memory-constrained e-ink devices without bundled PDF libraries
or zlib bindings, so the PDF is written by hand. Each notebook page is rasterized
into an 8-bit DeviceGray image XObject, scaled to the page box, and compressed
with PDF's own RunLengthDecode filter.

Grayscale rather than bilevel because the highlighter is gray by definition:
thresholding it either erases it or turns it into a black bar over the writing.

Because blank paper dominates a handwritten page and the raster is hard-edged,
run-length encoding still collapses it to a small fraction of its raw size, and
rendering one page at a time keeps peak memory flat regardless of length.

@module notebook.export
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Renderer = require("renderer")
local Template = require("template")

local Export = {}

-- Kindle Scribe screen dimensions used as default target page size.
local DEFAULT_WIDTH = 1860
local DEFAULT_HEIGHT = 2480

-- Pixel density the page size is derived from. The Scribe's panel is 300 dpi,
-- so a page comes out at its true physical size rather than a poster.
local DEFAULT_DPI = 300

-- PDF measures pages in points: 72 to the inch.
local POINTS_PER_INCH = 72

--- Extracts an 8-bit grayscale intensity from a blitbuffer pixel value.
local function getGray(pixel)
    if type(pixel) == "number" then
        return pixel
    end
    -- KOReader Color8 or RGB wrapper exposing :getColor8().
    if pixel.getColor8 then
        return pixel:getColor8().a
    end
    return pixel.a or 255
end

--[[--
Compresses raw byte data using PDF's native RunLengthDecode filter.

PDF specification for RunLengthDecode:
- 0 to 127: (n - 1) followed by n literal bytes (1 to 128 bytes).
- 129 to 255: (257 - n) followed by 1 byte repeated n times (2 to 128 bytes).
- 128: End of Data (EOD) marker.
--]]
function Export.encodeRLE(data)
    local out = {}
    local len = #data
    local i = 1
    local literals = {}

    local function flushLiterals()
        local count = #literals
        if count > 0 then
            table.insert(out, string.char(count - 1))
            table.insert(out, table.concat(literals))
            literals = {}
        end
    end

    while i <= len do
        local b = data:byte(i)
        -- Peak lookahead is capped at 128 to match PDF RLE maximum chunk length.
        local run_len = 1
        while i + run_len <= len and data:byte(i + run_len) == b and run_len < 128 do
            run_len = run_len + 1
        end

        if run_len >= 2 then
            -- A run of 2 or more identical bytes is more compact or equal to literal encoding.
            flushLiterals()
            table.insert(out, string.char(257 - run_len, b))
            i = i + run_len
        else
            table.insert(literals, string.char(b))
            if #literals == 128 then
                flushLiterals()
            end
            i = i + 1
        end
    end

    flushLiterals()
    -- PDF RunLengthDecode filter requires byte 128 as the explicit EOD marker.
    table.insert(out, string.char(128))
    return table.concat(out)
end

--[[--
Packs a blitbuffer into an 8-bit DeviceGray byte sequence, one byte per pixel.

Eight bits rather than one, deliberately. A 1-bit image has to threshold, and
the highlighter's whole point is that it is gray: at any threshold it either
disappears into the paper or turns solid black and buries the writing under it.
Neither is an export worth having.

The cost is eight times the raw bytes, but the raster is hard-edged -- no
antialiasing -- so runs stay long and RunLengthDecode still collapses the blank
paper that dominates a handwritten page.

One byte per pixel also means rows land on byte boundaries by construction, so
there is no padding to get wrong.
--]]
function Export.packPage(bb, w, h)
    local rows = {}

    --[[
    A page is 4.6 million pixels, and getPixel does two ffi.casts plus a
    coordinate transform on every one of them -- far too slow on device.
    getPixelP hands back a pointer to the start of a row, so the cast is paid
    once per row instead of twice per pixel.

    It works in physical coordinates and ignores the inverse flag, so it is only
    safe on an unrotated, uninverted buffer -- which is what the exporter
    allocates for itself. Anything else falls back to the honest slow path,
    which is also what the test doubles use.
    ]]
    local fast = bb.getPixelP
        and (not bb.getRotation or bb:getRotation() == 0)
        and (not bb.getInverse or bb:getInverse() == 0)

    local fetchRow, sample
    if fast then
        fetchRow = function(y) return bb:getPixelP(0, y) end
        sample = function(row, x) return row[x].a end
    else
        fetchRow = function(y) return y end
        sample = function(y, x) return getGray(bb:getPixel(x, y)) end
    end

    local char = string.char
    for y = 0, h - 1 do
        local row = {}
        local src = fetchRow(y)
        for x = 0, w - 1 do
            row[x + 1] = char(sample(src, x))
        end
        rows[y + 1] = table.concat(row)
    end

    return table.concat(rows)
end

--[[--
Exports a document to a PDF file at out_path.

@tparam table doc notebook document exposing doc.pages and doc:pageCount()
@tparam string out_path destination PDF file path
@tparam[opt] table opts configuration table (width, height)
@treturn boolean, string true on success, or false and an error description
--]]
function Export.toPDF(doc, out_path, opts)
    if not doc then
        return false, "no document provided"
    end
    if type(doc.pageCount) ~= "function" then
        return false, "invalid document: pageCount method missing"
    end
    local page_count = doc:pageCount()
    if page_count == 0 then
        return false, "document has no pages"
    end
    if not out_path or out_path == "" then
        return false, "no output path provided"
    end

    opts = opts or {}
    local content_area = opts.content_area
    local width = content_area and content_area.w or (opts.width or DEFAULT_WIDTH)
    local height = content_area and content_area.h or (opts.height or DEFAULT_HEIGHT)
    local offset_x = content_area and content_area.x or 0
    local offset_y = content_area and content_area.y or 0
    local dpi = opts.dpi or DEFAULT_DPI

    local page_w = width * POINTS_PER_INCH / dpi
    local page_h = height * POINTS_PER_INCH / dpi

    local file, err = io.open(out_path, "wb")
    if not file then
        return false, "cannot open output file: " .. tostring(err)
    end

    -- Reusing a single blitbuffer keeps memory consumption flat across multi-page notebooks.
    local bb = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)
    if not bb then
        file:close()
        return false, "failed to allocate blitbuffer"
    end

    local current_offset = 0
    local offsets = {}

    local function write(data)
        file:write(data)
        current_offset = current_offset + #data
    end

    local function startObj(num)
        offsets[num] = current_offset
        write(string.format("%d 0 obj\n", num))
    end

    local function endObj()
        write("endobj\n")
    end

    local ok, write_err = pcall(function()
        write("%PDF-1.4\n")

        -- Catalog dictionary (Object 1).
        startObj(1)
        write("<<\n  /Type /Catalog\n  /Pages 2 0 R\n>>\n")
        endObj()

        -- Page tree root (Object 2).
        local kids = {}
        for i = 1, page_count do
            local page_obj = 3 + (i - 1) * 3
            table.insert(kids, string.format("%d 0 R", page_obj))
        end
        startObj(2)
        write(string.format("<<\n  /Type /Pages\n  /Count %d\n  /Kids [ %s ]\n>>\n",
            page_count, table.concat(kids, " ")))
        endObj()

        -- Emit each page's Page object, Content stream, and Image XObject sequentially.
        for i = 1, page_count do
            local page_obj = 3 + (i - 1) * 3
            local content_obj = page_obj + 1
            local image_obj = page_obj + 2

            -- Page object referencing its dedicated content stream and image resource.
            startObj(page_obj)
            write(string.format("<<\n" ..
                "  /Type /Page\n" ..
                "  /Parent 2 0 R\n" ..
                "  /MediaBox [ 0 0 %.2f %.2f ]\n" ..
                "  /Contents %d 0 R\n" ..
                "  /Resources <<\n" ..
                "    /XObject <<\n" ..
                "      /Im1 %d 0 R\n" ..
                "    >>\n" ..
                "  >>\n" ..
                ">>\n",
                page_w, page_h, content_obj, image_obj))
            endObj()

            -- Position and scale the image onto the page box, in points.
            local content_stream = string.format("q\n%.2f 0 0 %.2f 0 0 cm\n/Im1 Do\nQ\n",
                page_w, page_h)
            startObj(content_obj)
            write(string.format("<<\n  /Length %d\n>>\nstream\n%s\nendstream\n",
                #content_stream, content_stream))
            endObj()

            -- Render page strokes into blitbuffer, pack to 1-bit rows, and RLE compress.
            bb:fill(Blitbuffer.COLOR_WHITE)
            local page = doc.pages and doc.pages[i]
            if page then
                -- The background belongs in the export as much as on the panel:
                -- ruled notes read as ruled notes on paper too.
                -- Strokes are written into this buffer at their page
                -- coordinates, unscaled, so the background is drawn at the same
                -- scale to stay registered with them.
                if doc.templateFor then
                    Template.draw(bb, doc:templateFor(i), { x = 0, y = 0, w = width, h = height }, 1)
                end
                Renderer.drawPage(bb, page, 1, -offset_x, -offset_y)
            end

            local raw_bitmap = Export.packPage(bb, width, height)
            local rle_data = Export.encodeRLE(raw_bitmap)

            -- 1-bit DeviceGray Image XObject.
            startObj(image_obj)
            write(string.format("<<\n" ..
                "  /Type /XObject\n" ..
                "  /Subtype /Image\n" ..
                "  /Width %d\n" ..
                "  /Height %d\n" ..
                "  /ColorSpace /DeviceGray\n" ..
                "  /BitsPerComponent 8\n" ..
                "  /Filter /RunLengthDecode\n" ..
                "  /Length %d\n" ..
                ">>\nstream\n",
                width, height, #rle_data))
            write(rle_data)
            write("\nendstream\n")
            endObj()
        end

        -- PDF cross-reference table. Each entry is formatted to exactly 20 bytes.
        local total_objs = 2 + page_count * 3
        local xref_offset = current_offset

        write(string.format("xref\n0 %d\n", total_objs + 1))
        write("0000000000 65535 f \n")
        for num = 1, total_objs do
            write(string.format("%010d 00000 n \n", offsets[num]))
        end

        -- Trailer dictionary pointing to the Catalog and start of xref.
        write(string.format("trailer\n<<\n  /Size %d\n  /Root 1 0 R\n>>\nstartxref\n%d\n%%%%EOF\n",
            total_objs + 1, xref_offset))
    end)

    file:close()

    -- A page buffer is several megabytes of off-heap memory; on a device this
    -- tight, waiting for the collector to notice is not good enough.
    if bb.free then bb:free() end

    if not ok then
        return false, tostring(write_err)
    end
    return true
end

return Export
