-- Text size and a live sample using the same font renderer as page labels.
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local Text = require("textobject")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local _ = require("i18n")
local Screen = Device.screen

local Sample = Widget:extend{}
function Sample:paintTo(bb,x,y)
    local stroke=self.picker.sample
    if not stroke then return end
    local height=stroke.y_max-stroke.y_min
    local lines=stroke._text_widget and stroke._text_widget.vertical_string_list
    local width=lines and lines[1] and lines[1].width or stroke.x_max-stroke.x_min
    Text.draw(bb,stroke,1,x+math.max(Size.padding.large,math.floor((self.dimen.w-width)/2)),
        y+math.max(0,math.floor((self.dimen.h-height)/2)),
        {x=x,y=y,w=self.dimen.w,h=self.dimen.h})
end

local Picker = InputContainer:extend{}
function Picker:init()
    local side=math.floor(self.width/3)
    local overhead=2*(Size.border.thin+Size.padding.button)
    self.value = TextWidget:new{face=Font:getFace("cfont",19),text=""}
    self.minus = Button:new{text="−",width=side-overhead,margin=0,
        padding=Size.padding.button,bordersize=Size.border.thin,
        enabled_func=function() return self.canvas.text_size>10 end,
        callback=function() self:step(-2) end}
    self.plus = Button:new{text="+",width=side-overhead,margin=0,
        padding=Size.padding.button,bordersize=Size.border.thin,
        enabled_func=function() return self.canvas.text_size<96 end,
        callback=function() self:step(2) end}
    local sample = Sample:new{picker=self,
        dimen=Geom:new{w=self.width,h=Screen:scaleBySize(140)}}
    self[1]=VerticalGroup:new{align="left",
        CenterContainer:new{dimen=Geom:new{w=self.width,h=Screen:scaleBySize(28)},
            TextWidget:new{text=_("Text size"),face=Font:getFace("cfont",17),bold=true}},
        HorizontalGroup:new{align="center",self.minus,
            CenterContainer:new{dimen=Geom:new{w=self.width-2*side,h=self.minus:getSize().h},self.value},self.plus},
        sample,
    }
    self:updatePreview()
end

function Picker:step(delta)
    local value=math.max(10,math.min(96,self.canvas.text_size+delta))
    if value==self.canvas.text_size then return end
    self.canvas.text_size=value
    self:updatePreview()
    if self.on_change then self.on_change(value) end
end

function Picker:updatePreview()
    Text.freeCache(self.sample)
    local c=self.canvas
    local size=tonumber(c.text_size) or 26
    if size~=size then size=26 end
    c.text_size=math.max(10,math.min(96,math.floor(size)))
    self.value:setText(c.text_size.." pt")
    self.sample=Text.create("Aa",0,0,self.width-2*Size.padding.large,c.text_size,{
        font_family=c.text_font or "sans",text_bold=c.text_bold,
        text_italic=c.text_italic,text_underline=c.text_underline,text_background=false,
    })
end

function Picker:free(full)
    Text.freeCache(self.sample)
    self.sample=nil
    InputContainer.free(self,full)
end

return Picker
