local Text = {}

function Text.widget(stroke,scale)
    scale=scale or 1
    return require("ui/widget/textboxwidget"):new{
        text=stroke.text,
        face=require("ui/font"):getFace("cfont",math.max(5,stroke.font_size*scale)),
        width=math.max(1,math.floor((stroke.x_max-stroke.x_min)*scale)),
        fgcolor=require("ffi/blitbuffer").Color8(stroke.color or 0),
    }
end

function Text.create(text,x,y,width,size)
    local stroke=require("stroke"):new{tool="text",shape_kind="text",text=text,font_size=size,width=1}
    stroke:addPoint(x,y)
    stroke:addPoint(x+width,y+size)
    local widget=Text.widget(stroke)
    stroke.y_max=y+widget:getSize().h
    stroke.pts[5]=stroke.y_max
    widget:free()
    return stroke
end

function Text.draw(bb,stroke,scale,ox,oy,clip)
    scale,ox,oy=scale or 1,ox or 0,oy or 0
    local widget=Text.widget(stroke,scale)
    local target=bb
    if clip then
        local x,y,w,h=require("rect").clamp(clip.x,clip.y,clip.w,clip.h,
            {x=0,y=0,w=bb:getWidth(),h=bb:getHeight()})
        if not x then widget:free(); return end
        target=bb:viewport(x,y,w,h); ox,oy=ox-x,oy-y
    end
    widget:paintTo(target,math.floor(stroke.x_min*scale+ox),math.floor(stroke.y_min*scale+oy))
    widget:free()
end

return Text
