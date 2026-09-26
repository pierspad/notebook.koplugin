local Text = {}

function Text.hasContent(value)
    if not value then return false end
    -- Include common Unicode space/separator characters, without treating a
    -- byte belonging to an ordinary UTF-8 letter as whitespace.
    value=value:gsub("\194\160", ""):gsub("\227\128\128", "")
        :gsub("\226\128[\128-\139]", ""):gsub("\226\128[\168\169\175]", "")
        :gsub("\226\129[\159\160]", ""):gsub("\239\187\191", "")
    return value:find("%S") ~= nil
end

local FONTS = {
    sans = { regular="NotoSans-Regular.ttf", italic="NotoSans-Italic.ttf" },
    serif = { regular="NotoSerif-Regular.ttf", italic="NotoSerif-Italic.ttf" },
    mono = { regular="NimbusMono-Regular.cff", italic="NimbusMono-Oblique.cff" },
}

local function faceName(stroke)
    local family=FONTS[stroke.font_family or "sans"] or FONTS.sans
    return stroke.text_italic and family.italic or family.regular
end

function Text.widget(stroke,scale)
    scale=scale or 1
    return require("ui/widget/textboxwidget"):new{
        text=stroke.text,
        face=require("ui/font"):getFace(faceName(stroke),math.max(5,stroke.font_size*scale)),
        bold=stroke.text_bold or false,
        width=math.max(1,math.floor((stroke.x_max-stroke.x_min)*scale)),
        fgcolor=require("ffi/blitbuffer").Color8(stroke.color or 0),
    }
end

local function cacheKey(stroke, scale)
    return (stroke.text or "") .. "\0" ..
        (stroke.font_family or "sans") .. "\0" ..
        tostring(stroke.font_size) .. "\0" ..
        tostring(scale) .. "\0" ..
        tostring(stroke.text_bold) .. "\0" ..
        tostring(stroke.text_italic) .. "\0" ..
        tostring(stroke.text_underline) .. "\0" ..
        tostring(stroke.text_background) .. "\0" ..
        tostring(stroke.color or 0) .. "\0" ..
        tostring(stroke.x_max - stroke.x_min)
end

function Text.freeCache(stroke)
    require("textcache").remove(stroke)
end

function Text.create(text,x,y,width,size,style)
    style=style or {}
    local stroke=require("stroke"):new{tool="text",shape_kind="text",text=text,font_size=size,width=1,
        font_family=style.font_family or "sans", text_bold=style.text_bold,
        text_italic=style.text_italic, text_underline=style.text_underline,
        text_background=style.text_background == true}
    stroke:addPoint(x,y)
    stroke:addPoint(x+width,y+size)
    local widget=Text.widget(stroke, 1)
    stroke.y_max=y+widget:getSize().h
    stroke.pts[5]=stroke.y_max
    stroke._text_widget = widget
    stroke._text_cache_key = cacheKey(stroke, 1)
    require("textcache").touch(stroke)
    return stroke
end

function Text.draw(bb,stroke,scale,ox,oy,clip)
    scale,ox,oy=scale or 1,ox or 0,oy or 0
    local key = cacheKey(stroke, scale)
    local widget = stroke._text_widget
    if not widget or stroke._text_cache_key ~= key then
        Text.freeCache(stroke)
        widget = Text.widget(stroke, scale)
        stroke._text_widget = widget
        stroke._text_cache_key = key
    end
    require("textcache").touch(stroke)
    local target=bb
    if clip then
        local x,y,w,h=require("rect").clamp(clip.x,clip.y,clip.w,clip.h,
            {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()})
        if not x then return end
        target=bb:viewport(x,y,w,h); ox,oy=ox-x,oy-y
    end
    local px,py=math.floor(stroke.x_min*scale+ox),math.floor(stroke.y_min*scale+oy)
    if stroke.text_background then
        widget:paintTo(target,px,py)
    else
        -- TextBoxWidget renders into an opaque white scratch buffer. Use its
        -- inverse as an alpha mask so only glyph pixels reach the page; this
        -- preserves anti-aliasing without covering a PDF/grid underneath.
        local mask = widget._bb
        if mask and target.colorblitFrom then
            mask:invert()
            target:colorblitFrom(mask, px, py, 0, 0, mask:getWidth(), mask:getHeight(),
                require("ffi/blitbuffer").Color8(stroke.color or 0))
            mask:invert()
        else
            -- Lightweight test doubles do not allocate TextBoxWidget's
            -- scratch buffer; the real KOReader widget always does.
            widget:paintTo(target,px,py)
        end
    end
    if stroke.cursor_pos and widget._getXYForCharPos then
        local cx,cy=widget:_getXYForCharPos(stroke.cursor_pos)
        local caret_w=math.max(1,math.floor(scale))
        local caret_h=widget.line_height_px or stroke.font_size*scale
        cx=math.min(cx, math.max(0,widget:getSize().w-caret_w))
        local rx,ry,rw,rh=require("rect").clamp(px+cx,py+cy,caret_w,caret_h,
            {x=0,y=0,w=target:getWidth(),h=target:getHeight()})
        if rx then target:paintRect(rx,ry,rw,rh,require("ffi/blitbuffer").COLOR_BLACK) end
    end
    if stroke.text_underline then
        local size=widget:getSize()
        local line_h=widget.line_height_px or math.max(5,stroke.font_size*scale)
        local yy=py+line_h-2
        while yy < py+size.h do
            target:paintRect(px,yy,size.w,math.max(1,math.floor(scale)),
                require("ffi/blitbuffer").Color8(stroke.color or 0))
            yy=yy+line_h
        end
    end
end

return Text
