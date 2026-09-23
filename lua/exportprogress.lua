local Blitbuffer=require("ffi/blitbuffer")
local Button=require("ui/widget/button")
local CenterContainer=require("ui/widget/container/centercontainer")
local Device=require("device")
local Font=require("ui/font")
local FrameContainer=require("ui/widget/container/framecontainer")
local Geom=require("ui/geometry")
local InputContainer=require("ui/widget/container/inputcontainer")
local ProgressWidget=require("ui/widget/progresswidget")
local Safe=require("safe")
local Size=require("ui/size")
local TextWidget=require("ui/widget/textwidget")
local UIManager=require("ui/uimanager")
local VerticalGroup=require("ui/widget/verticalgroup")
local VerticalSpan=require("ui/widget/verticalspan")
local _=require("i18n")
local T=require("ffi/util").template

local Screen=Device.screen

local ExportProgress=InputContainer:extend{
    title=nil,
    total=1,
    on_cancel=nil,
    cancelled=false,
}

function ExportProgress:init()
    self.dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    local width=Screen:getWidth()-Screen:scaleBySize(120)
    self.status=TextWidget:new{text=_("Preparing…"),face=Font:getFace("smallffont"),max_width=width}
    self.bar=ProgressWidget:new{width=width,height=Screen:scaleBySize(20),percentage=0,
        fillcolor=Blitbuffer.COLOR_BLACK,padding=Size.padding.large}
    self.cancel=Button:new{text=_("Cancel"),callback=function()
        if self.cancelled then return end
        self.cancelled=true
        self.status:setText(_("Cancelling…"))
        if self.cancel.setEnabled then self.cancel:setEnabled(false) end
        if self.on_cancel then self.on_cancel() end
        UIManager:setDirty(self,"ui")
    end}
    local group=VerticalGroup:new{align="center",
        TextWidget:new{text=self.title or _("Exporting PDF…"),face=Font:getFace("ffont"),bold=true,
            max_width=width},
        VerticalSpan:new{width=Size.padding.large},self.status,self.bar,
        VerticalSpan:new{width=Size.padding.large},self.cancel}
    self[1]=CenterContainer:new{dimen=self.dimen,FrameContainer:new{
        background=Blitbuffer.COLOR_WHITE,color=Blitbuffer.COLOR_BLACK,
        bordersize=Size.border.window,radius=Size.radius.window,padding=Size.padding.large,group}}
end

function ExportProgress:update(page,pages,phase,completed,total)
    if self.cancelled then return end
    local labels={_("Rendering"),_("Preparing image"),_("Compressing")}
    self.status:setText(T(_("Page %1 of %2 — %3"),page,pages,labels[phase] or labels[1]))
    self.bar:setPercentage(math.min(1,(completed or 0)/math.max(1,total or self.total)))
    UIManager:setDirty(self,"fast")
    UIManager:forceRePaint()
end

function ExportProgress:show() UIManager:show(self,"ui") end
function ExportProgress:close() UIManager:close(self,"ui") end

return Safe.widget(ExportProgress,"export progress")
