-- Portable vector ink, without raster backgrounds or external dependencies.
-- Pages are stacked vertically, each in its own clipped SVG viewport.
local Renderer = require("renderer")
local Svg = {}

local function xml(value)
    return tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
end

local function color(value, tool)
    value = value or (tool == "highlighter" and 0x1ffff66 or 0)
    if value >= 0x1000000 then return string.format("#%06x", value % 0x1000000) end
    value = math.max(0, math.min(255, value))
    return string.format("#%02x%02x%02x", value, value, value)
end

local function strokeXML(s, write)
    local ink = s.tool == "highlighter" and color(s.tint, s.tool) or color(s.color, s.tool)
    if s.text then
        local family = s.font_family == "serif" and "serif"
            or (s.font_family == "mono" and "monospace" or "sans-serif")
        if s.text_background then
            write(string.format('<rect x="%g" y="%g" width="%g" height="%g" fill="white"/>',
                s.x_min, s.y_min, s.x_max-s.x_min, s.y_max-s.y_min))
        end
        write(string.format('<text fill="%s" font-family="%s" font-size="%g" font-weight="%s" ' ..
            'font-style="%s" text-decoration="%s" xml:space="preserve">',
            ink, family, s.font_size or 24, s.text_bold and "bold" or "normal",
            s.text_italic and "italic" or "normal", s.text_underline and "underline" or "none"))
        local line = 0
        for text in (s.text .. "\n"):gmatch("(.-)\n") do
            write(string.format('<tspan x="%g" y="%g">%s</tspan>', s.x_min,
                s.y_min+(s.font_size or 24)*(1+line*1.2), xml(text)))
            line = line+1
        end
        write('</text>\n')
        return
    end
    if not s.n or s.n == 0 then return end
    -- A constant-width fineliner is exactly a round-joined polyline. Keep
    -- pressure-varying strokes on the disc/tangent path below.
    if s.tool == "pen" and s.pen_style == "fineliner" and not s.filled and s.n > 1 then
        local _,_,first_pressure=s:getPoint(1)
        local radius=math.max(0.5,Renderer.radiusFor(s,first_pressure))
        local uniform=true
        for i=2,s.n do
            local _,_,pressure=s:getPoint(i)
            if math.max(0.5,Renderer.radiusFor(s,pressure)) ~= radius then uniform=false; break end
        end
        if uniform then
            write(string.format('<polyline fill="none" stroke="%s" stroke-width="%g" ' ..
                'stroke-linecap="round" stroke-linejoin="round" points="',ink,2*radius))
            for i=1,s.n do
                local x,y=s:getPoint(i)
                write(string.format('%g,%g ',x,y))
            end
            write('"/>\n')
            return
        end
    end
    -- Group opacity avoids dark joints between overlapping segment primitives.
    write(string.format('<g fill="%s" opacity="%g">', ink,
        s.tool == "highlighter" and 0.4 or (s.pen_style == "pencil" and 0.74 or 1)))
    if s.filled then
        local points = {}
        for i=1,s.n do
            local x,y=s:getPoint(i)
            points[#points+1]=string.format('%g,%g',x,y)
        end
        write('<polygon points="'..table.concat(points,' ')..'"/>')
    else
        local function disc(x,y,r)
            write(string.format('<circle cx="%g" cy="%g" r="%g"/>',x,y,r))
        end
        local x0,y0,p0=s:getPoint(1)
        if s.n == 1 then disc(x0,y0,math.max(0.5,Renderer.radiusFor(s,p0))) end
        for i=2,s.n do
            local x1,y1,p1=s:getPoint(i)
            local dx,dy=x1-x0,y1-y0
            local r0=math.max(0.5,Renderer.radiusFor(s,p0,dx,dy))
            local r1=math.max(0.5,Renderer.radiusFor(s,p1,dx,dy))
            local length=math.sqrt(dx*dx+dy*dy)
            disc(x0,y0,r0); disc(x1,y1,r1)
            if length > math.abs(r1-r0) then
                local ux,uy=dx/length,dy/length
                local k=(r0-r1)/length
                local q=math.sqrt(1-k*k)
                local ax,ay=k*ux-q*uy,k*uy+q*ux
                local bx,by=k*ux+q*uy,k*uy-q*ux
                write(string.format('<polygon points="%g,%g %g,%g %g,%g %g,%g"/>',
                    x0+r0*ax,y0+r0*ay,x1+r1*ax,y1+r1*ay,
                    x1+r1*bx,y1+r1*by,x0+r0*bx,y0+r0*by))
            end
            x0,y0,p0=x1,y1,p1
        end
    end
    write('</g>\n')
end

function Svg.toSVG(doc,path)
    if not doc or not doc.pages or #doc.pages == 0 then return false,"document has no pages" end
    if not path or path == "" then return false,"no output path" end
    local ox,oy=0,0
    if doc.contentOrigin then ox,oy=doc:contentOrigin() end
    local size=doc.page_size or {w=1860-ox,h=2480-oy}
    local w,h=size.w,size.h
    if not w or not h or w<=0 or h<=0 then return false,"invalid page dimensions" end
    local temporary=path..".tmp"
    local file,err=io.open(temporary,"wb")
    if not file then return false,err end
    local ok,reason=pcall(function()
        local function write(text) assert(file:write(text)) end
        write(string.format('<?xml version="1.0" encoding="UTF-8"?>\n' ..
            '<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g" viewBox="0 0 %g %g">\n',w,h*#doc.pages,w,h*#doc.pages))
        write('<desc>Notebook vector ink. Pages stacked vertically; paper and PDF backgrounds omitted.</desc>\n')
        for i,page in ipairs(doc.pages) do
            write(string.format('<svg id="page-%d" y="%g" width="%g" height="%g" ' ..
                'viewBox="0 0 %g %g" overflow="hidden"><g transform="translate(%g %g)">\n',
                i,(i-1)*h,w,h,w,h,-ox,-oy))
            for _,stroke in ipairs(page.strokes or {}) do strokeXML(stroke,write) end
            write('</g></svg>\n')
        end
        write('</svg>\n')
    end)
    local closed,close_err=file:close()
    if not ok or not closed then os.remove(temporary); return false,reason or close_err end
    local renamed,rename_err=os.rename(temporary,path)
    if not renamed then os.remove(temporary); return false,rename_err end
    return true
end

return Svg
