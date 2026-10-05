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

local function markerColor(tint)
    if tint == nil then return "#99999980" end
    if tint >= 0x1000000 and tint <= 0x1FFFFFF then
        return string.format("#%06x80", tint - 0x1000000)
    end
    return string.format("#%02x%02x%02x80", tint, tint, tint)
end

local function templateStyle(id)
    if id=="grid" then return "graph" end
    if id=="lined" or id=="narrow" or id=="checklist" then return "lined" end
    if id=="dots" then return "dot" end
    return "plain"
end

local function pageLayout(doc,page,size)
    local ox,oy=0,0
    if type(doc.contentOrigin)=="function" then ox,oy=doc:contentOrigin() end
    local canvas_w,canvas_h=size.w,size.h
    if not page.background then
        return canvas_w*72/300,canvas_h*72/300,72/300,-ox,-oy
    end
    local native=page.background.size
    if not native then
        local ok,w,h=pcall(function()
            return require("pdfbackground").size(page.background.file,page.background.page)
        end)
        if ok then native={w=w,h=h} end
    end
    if not native or not native.w or not native.h then
        return canvas_w*72/300,canvas_h*72/300,72/300,-ox,-oy
    end
    -- Undo the centred aspect-fit used while annotating, then express the ink
    -- in the attached PDF's native point coordinates.
    local zoom=math.min(canvas_w/native.w,canvas_h/native.h)
    local left=(canvas_w-native.w*zoom)/2
    local top=(canvas_h-native.h*zoom)/2
    return native.w,native.h,1/zoom,-ox-left,-oy-top
end

local function documentXML(doc,write)
    local size=doc.page_size or {w=1860,h=2480}
    assert(require("documentformat").dimensions(size),"Invalid page dimensions")
    write('<?xml version="1.0" standalone="no"?>\n')
    write('<xournal creator="Notebook for KOReader" fileversion="4">\n')
    write('<title>Xournal++ document - see https://github.com/xournalpp/xournalpp</title>\n')
    local pdf_source
    for index,page in ipairs(doc.pages or {}) do
        local page_w,page_h,scale,dx,dy=pageLayout(doc,page,size)
        write(string.format('<page width="%.3f" height="%.3f">',page_w,page_h))
        if page.background then
            pdf_source=pdf_source or page.background.file
            write(string.format('<background type="pdf" domain="attach" filename="bg.pdf" pageno="%d"/>',page.background.page or index))
        else
            write(string.format('<background type="solid" color="#ffffffff" style="%s"/>',templateStyle(doc:templateFor(index))))
        end
        write('<layer>')
        local export_strokes={}
        for _,original in ipairs(page.strokes) do
            if original.marker_parts then
                for first,last in require("markerarea").parts(original) do
                    export_strokes[#export_strokes+1]=setmetatable({n=last-first+1,
                        getPoint=function(_,i) return original:getPoint(first+i-1) end}, {__index=original})
                end
            else export_strokes[#export_strokes+1]=original end
        end
        for _,stroke in ipairs(export_strokes) do
            if stroke.image_data then
                write(string.format('<image left="%.3f" top="%.3f" right="%.3f" bottom="%.3f">',
                    (stroke.x_min+dx)*scale,(stroke.y_min+dy)*scale,(stroke.x_max+dx)*scale,(stroke.y_max+dy)*scale))
                require("imagecodec").base64(stroke.image_data,write)
                write('</image>')
            elseif stroke.text then
                local family=stroke.font_family=="serif" and "Serif"
                    or (stroke.font_family=="mono" and "Monospace" or "Sans")
                write(string.format('<text font="%s" size="%.3f" x="%.3f" y="%.3f" color="#000000ff">%s</text>',
                    family,(stroke.font_size or 24)*scale,(stroke.x_min+dx)*scale,(stroke.y_min+dy)*scale,xml(stroke.text)))
            elseif stroke.n>0 then
                local points={}
                local pressure=0
                for i=1,stroke.n do
                    local x,y,p=stroke:getPoint(i); pressure=pressure+(p or 1)
                    points[#points+1]=string.format("%.3f %.3f",(x+dx)*scale,(y+dy)*scale)
                end
                local gray=stroke.tool=="highlighter" and markerColor(stroke.tint) or "#000000ff"
                local width=stroke.width*(.35+.65*pressure/stroke.n)*scale
                local fill=""
                if stroke.tool=="highlighter" and stroke.filled then
                    -- Xournal++ fill is an alpha byte; the closed polygon is
                    -- the remaining area, not a path to retrace with the nib.
                    points[#points+1]=points[1]
                    width=0.001
                    fill=' fill="255"'
                end
                write(string.format('<stroke tool="%s" color="%s" width="%.3f"%s>%s</stroke>',
                    stroke.tool=="highlighter" and "highlighter" or "pen",gray,width,fill,table.concat(points," ")))
            end
        end
        write('</layer></page>')
    end
    write('</xournal>')
    return pdf_source
end

function Xopp.toXOPP(doc,path)
    if type(doc)~="table" or type(doc.pages)~="table" or #doc.pages==0 then return false,"document has no pages" end
    if type(path)~="string" or path=="" then return false,"no output path" end
    local temporary=path..".tmp"
    local file,err=io.open(temporary,"wb")
    if not file then return false,err end
    local ok,pdf_source=pcall(function()
        local stream=require("gzipwriter").new(function(data) assert(file:write(data)) end)
        local source=documentXML(doc,function(data) stream:write(data) end)
        stream:finish()
        return source
    end)
    local closed,close_err=file:close()
    if not ok or not closed then os.remove(temporary);return false,not ok and pdf_source or close_err end
    return require("xoppfiles").commit(path,pdf_source)
end
return Xopp
