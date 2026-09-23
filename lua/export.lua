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
local ffi = require("ffi")
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
    local bytes = ffi.cast("const uint8_t*", data)

    while i <= len do
        local b = bytes[i - 1]
        -- Peak lookahead is capped at 128 to match PDF RLE maximum chunk length.
        local run_len = 1
        while i + run_len <= len and bytes[i + run_len - 1] == b and run_len < 128 do
            run_len = run_len + 1
        end

        if run_len >= 2 then
            out[#out + 1] = string.char(257 - run_len, b)
            i = i + run_len
        else
            -- Find the whole literal span and copy it as one substring. The
            -- previous implementation allocated one Lua string per literal
            -- pixel; a dense Scribe page can contain millions of them.
            local first = i
            i = i + 1
            while i <= len and i - first < 128 do
                if i < len and bytes[i - 1] == bytes[i] then break end
                i = i + 1
            end
            local count = i - first
            out[#out + 1] = string.char(count - 1)
            out[#out + 1] = data:sub(first, i - 1)
        end
    end

    -- PDF RunLengthDecode filter requires byte 128 as the explicit EOD marker.
    out[#out + 1] = string.char(128)
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
    local fast = bb.getPixelP and bb.getType and bb:getType() == Blitbuffer.TYPE_BB8
        and bb.getRotation and bb:getRotation() == 0
        and bb.getInverse and bb:getInverse() == 0
    for y = 0, h - 1 do
        if fast then
            -- Copy only visible bytes: a native row may include stride padding.
            rows[y + 1] = ffi.string(bb:getPixelP(0, y), w)
        else
            local row = {}
            for x = 0, w - 1 do
                row[x + 1] = string.char(getGray(bb:getPixel(x, y)))
            end
            rows[y + 1] = table.concat(row)
        end
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
local function validate(doc, out_path, opts)
    if not doc then return nil, "no document provided" end
    if type(doc.pageCount) ~= "function" then return nil, "invalid document: pageCount method missing" end
    local page_count=doc:pageCount()
    if page_count==0 then return nil, "document has no pages" end
    if not out_path or out_path=="" then return nil, "no output path provided" end
    opts=opts or {}
    local area=opts.content_area
    local ox,oy=0,0
    if area then ox,oy=area.x or 0,area.y or 0
    elseif type(doc.contentOrigin)=="function" then ox,oy=doc:contentOrigin() end
    local width=area and area.w or (opts.width or DEFAULT_WIDTH)-ox
    local height=area and area.h or (opts.height or DEFAULT_HEIGHT)-oy
    local dpi=opts.dpi or DEFAULT_DPI
    if width<=0 or height<=0 or dpi<=0 then return nil,"invalid page dimensions" end
    return {doc=doc,out_path=out_path,page_count=page_count,width=width,height=height,
        offset_x=ox,offset_y=oy,dpi=dpi}
end

--[[--
Starts an incremental PDF export. Each `step()` performs one bounded phase:
render, pack, or compress/write. The caller can yield to KOReader between steps,
update progress, and cancel without leaving a partial PDF behind.
--]]
function Export.beginPDF(doc,out_path,opts)
    local cfg,err=validate(doc,out_path,opts)
    if not cfg then return nil,err end
    local temporary=out_path..".tmp"
    local file
    file,err=io.open(temporary,"wb")
    if not file then return nil,"cannot open output file: "..tostring(err) end
    local bb=Blitbuffer.new(cfg.width,cfg.height,Blitbuffer.TYPE_BB8)
    if not bb then file:close(); os.remove(temporary); return nil,"failed to allocate blitbuffer" end

    local job={page=1,phase=1,total=cfg.page_count*3,completed=0,cancelled=false,
        page_count=cfg.page_count,out_path=out_path}
    local current_offset,offsets=0,{}
    local raw_bitmap
    local closed=false
    local function write(data)
        local written,write_error=file:write(data)
        if not written then error(write_error or "PDF write failed") end
        current_offset=current_offset+#data
    end
    local function startObj(num) offsets[num]=current_offset; write(string.format("%d 0 obj\n",num)) end
    local function endObj() write("endobj\n") end
    local function cleanup(remove)
        if not closed then pcall(function() file:close() end); closed=true end
        if bb then if bb.free then bb:free() end; bb=nil end
        raw_bitmap=nil
        if remove then os.remove(temporary) end
    end
    local function fail(message) cleanup(true); job.error=tostring(message); return "error",job.error end
    local function finish()
        local total_objs=2+cfg.page_count*3
        local xref_offset=current_offset
        write(string.format("xref\n0 %d\n",total_objs+1))
        write("0000000000 65535 f \n")
        for num=1,total_objs do write(string.format("%010d 00000 n \n",offsets[num])) end
        write(string.format("trailer\n<<\n  /Size %d\n  /Root 1 0 R\n>>\nstartxref\n%d\n%%%%EOF\n",
            total_objs+1,xref_offset))
        local ok,close_error=file:close(); closed=true
        if not ok then error(close_error or "PDF close failed") end
        if bb and bb.free then bb:free() end; bb=nil
        local renamed,rename_error=os.rename(temporary,out_path)
        if not renamed then os.remove(temporary); error(rename_error or "PDF rename failed") end
    end

    local initialized,init_error=pcall(function()
        write("%PDF-1.4\n")
        startObj(1); write("<<\n  /Type /Catalog\n  /Pages 2 0 R\n>>\n"); endObj()
        local kids={}
        for i=1,cfg.page_count do kids[#kids+1]=string.format("%d 0 R",3+(i-1)*3) end
        startObj(2)
        write(string.format("<<\n  /Type /Pages\n  /Count %d\n  /Kids [ %s ]\n>>\n",
            cfg.page_count,table.concat(kids," ")))
        endObj()
    end)
    if not initialized then cleanup(true); return nil,tostring(init_error) end

    function job:cancel() self.cancelled=true end
    function job:step()
        if self.cancelled then cleanup(true); return "cancelled" end
        if self.error then return "error",self.error end
        local ok,result=pcall(function()
            local i=self.page
            if self.phase==1 then
                local page_obj=3+(i-1)*3
                local content_obj,image_obj=page_obj+1,page_obj+2
                local page_w=cfg.width*POINTS_PER_INCH/cfg.dpi
                local page_h=cfg.height*POINTS_PER_INCH/cfg.dpi
                startObj(page_obj)
                write(string.format([[<<
  /Type /Page
  /Parent 2 0 R
  /MediaBox [ 0 0 %.2f %.2f ]
  /Contents %d 0 R
  /Resources <<
    /XObject <<
      /Im1 %d 0 R
    >>
  >>
>>
]],
                    page_w,page_h,content_obj,image_obj)); endObj()
                local stream=string.format("q\n%.2f 0 0 %.2f 0 0 cm\n/Im1 Do\nQ\n",page_w,page_h)
                startObj(content_obj)
                write(string.format("<<\n  /Length %d\n>>\nstream\n%s\nendstream\n",#stream,stream)); endObj()
                bb:fill(Blitbuffer.COLOR_WHITE)
                local page=cfg.doc.pages and cfg.doc.pages[i]
                if page then
                    if cfg.doc.templateFor then Template.draw(bb,cfg.doc:templateFor(i),
                        {x=0,y=0,w=cfg.width,h=cfg.height},1) end
                    if page.background then require("pdfbackground").draw(bb,page.background,
                        {x=0,y=0,w=cfg.width,h=cfg.height}) end
                    Renderer.drawPage(bb,page,1,-cfg.offset_x,-cfg.offset_y)
                end
                self.phase=2
            elseif self.phase==2 then
                raw_bitmap=Export.packPage(bb,cfg.width,cfg.height)
                self.phase=3
            else
                local rle=Export.encodeRLE(raw_bitmap); raw_bitmap=nil
                local image_obj=3+(i-1)*3+2
                startObj(image_obj)
                write(string.format([[<<
  /Type /XObject
  /Subtype /Image
  /Width %d
  /Height %d
  /ColorSpace /DeviceGray
  /BitsPerComponent 8
  /Filter /RunLengthDecode
  /Length %d
>>
stream
]],
                    cfg.width,cfg.height,#rle))
                write(rle); write("\nendstream\n"); endObj()
                if i==cfg.page_count then finish(); self.completed=self.total; return "done" end
                self.page=i+1; self.phase=1
            end
            self.completed=self.completed+1
            return "working"
        end)
        if not ok then return fail(result) end
        return result
    end
    return job
end

function Export.toPDF(doc,out_path,opts)
    local job,err=Export.beginPDF(doc,out_path,opts)
    if not job then return false,err end
    while true do
        local state,reason=job:step()
        if state=="done" then return true end
        if state=="error" or state=="cancelled" then return false,reason or state end
    end
end

return Export
