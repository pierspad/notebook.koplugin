-- Editable Xournal++ interchange. XOPP is gzip-compressed XML; this writer
-- uses uncompressed DEFLATE blocks so it needs no external process or binding.
local Xopp = {}

function Xopp.backgroundPath(path)
    return path .. ".bg.pdf"
end

local function xml(value)
    return tostring(value or ""):gsub("&","&amp;"):gsub("<","&lt;")
        :gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&apos;")
end

local function u32(n)
    return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end

local function crc32(data)
    local bit=require("bit")
    local crc=0xffffffff
    for i=1,#data do
        crc=bit.bxor(crc,data:byte(i))
        for _=1,8 do
            crc=bit.bxor(bit.rshift(crc,1),bit.band(crc,1)~=0 and 0xedb88320 or 0)
        end
    end
    return bit.band(bit.bnot(crc),0xffffffff)
end

local function gzip(data)
    local out={"\31\139\8\0\0\0\0\0\0\255"}
    local at=1
    while at<=#data do
        local n=math.min(65535,#data-at+1)
        out[#out+1]=string.char(at+n>#data and 1 or 0,n%256,math.floor(n/256),
            (65535-n)%256,math.floor((65535-n)/256))
        out[#out+1]=data:sub(at,at+n-1)
        at=at+n
    end
    out[#out+1]=u32(crc32(data)); out[#out+1]=u32(#data)
    return table.concat(out)
end

local function templateStyle(id)
    if id=="grid" then return "graph" end
    if id=="lined" or id=="narrow" or id=="checklist" then return "lined" end
    if id=="dots" then return "dot" end
    return "plain"
end

function Xopp.toXOPP(doc,path)
    local size=doc.page_size or {w=1860,h=2480}
    local scale=72/300
    local lines={'<?xml version="1.0" standalone="no"?>',
        '<xournal creator="Notebook for KOReader" fileversion="4">',
        '<title>Xournal++ document - see https://github.com/xournalpp/xournalpp</title>'}
    local pdf_source
    for index,page in ipairs(doc.pages or {}) do
        lines[#lines+1]=string.format('<page width="%.3f" height="%.3f">',size.w*scale,size.h*scale)
        if page.background then
            pdf_source=pdf_source or page.background.file
            lines[#lines+1]=string.format('<background type="pdf" domain="attach" filename="bg.pdf" pageno="%d"/>',page.background.page or index)
        else
            lines[#lines+1]=string.format('<background type="solid" color="#ffffffff" style="%s"/>',templateStyle(doc:templateFor(index)))
        end
        lines[#lines+1]='<layer>'
        for _,stroke in ipairs(page.strokes) do
            if stroke.text then
                local family=stroke.font_family=="serif" and "Serif"
                    or (stroke.font_family=="mono" and "Monospace" or "Sans")
                lines[#lines+1]=string.format('<text font="%s" size="%.3f" x="%.3f" y="%.3f" color="#000000ff">%s</text>',
                    family,stroke.font_size*scale,stroke.x_min*scale,stroke.y_min*scale,xml(stroke.text))
            elseif stroke.n>0 then
                local points={}
                local pressure=0
                for i=1,stroke.n do
                    local x,y,p=stroke:getPoint(i); pressure=pressure+(p or 1)
                    points[#points+1]=string.format("%.3f %.3f",x*scale,y*scale)
                end
                local gray=stroke.tool=="highlighter" and "#99999980" or "#000000ff"
                local width=stroke.width*(.35+.65*pressure/stroke.n)*scale
                lines[#lines+1]=string.format('<stroke tool="pen" color="%s" width="%.3f">%s</stroke>',gray,width,table.concat(points," "))
            end
        end
        lines[#lines+1]='</layer></page>'
    end
    lines[#lines+1]='</xournal>'
    local temporary=path..".tmp"
    local file,err=io.open(temporary,"wb")
    if not file then return false,err end
    local ok,write_err=file:write(gzip(table.concat(lines,"\n")))
    file:close()
    if not ok then os.remove(temporary); return false,write_err end
    ok,write_err=os.rename(temporary,path)
    if not ok then os.remove(temporary); return false,write_err end
    if pdf_source then
        local source=io.open(pdf_source,"rb")
        local background=Xopp.backgroundPath(path)
        local background_tmp=background..".tmp"
        local target=source and io.open(background_tmp,"wb")
        if not target then if source then source:close() end; os.remove(path); return false,"cannot copy PDF background" end
        while true do
            local chunk=source:read(65536)
            if not chunk then break end
            ok,write_err=target:write(chunk)
            if not ok then break end
        end
        source:close()
        local closed,close_err=target:close()
        if not ok or not closed then
            os.remove(background_tmp); os.remove(path)
            return false,write_err or close_err or "cannot copy PDF background"
        end
        ok,write_err=os.rename(background_tmp,background)
        if not ok then
            os.remove(background_tmp); os.remove(path)
            return false,write_err or "cannot finish PDF background"
        end
    end
    return true,pdf_source and Xopp.backgroundPath(path) or nil
end

return Xopp
