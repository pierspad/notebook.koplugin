-- Export selection owns borders and ranges; thumbnail layout is shared with
-- navigation. Selecting pages never changes the document or its undo history.
local InputDialog=require("ui/widget/inputdialog")
local InfoMessage=require("ui/widget/infomessage")
local UIManager=require("ui/uimanager")
local Selection=require("pageselection")
local PageGrid=require("pagegrid")
local Widgets=require("widgets")
local TextBoxWidget=require("ui/widget/textboxwidget")
local TextWidget=require("ui/widget/textwidget")
local Font=require("ui/font")
local Size=require("ui/size")
local VerticalGroup=require("ui/widget/verticalgroup")
local VerticalSpan=require("ui/widget/verticalspan")
local HorizontalGroup=require("ui/widget/horizontalgroup")
local HorizontalSpan=require("ui/widget/horizontalspan")
local Safe=require("safe")
local _=require("i18n")
local T=require("ffi/util").template
local Panel=PageGrid:extend{}
function Panel:init()
    self.selected={}
    for i=1,self.document:pageCount() do self.selected[i]=true end
    PageGrid.init(self)
end
function Panel:isSelected(index) return self.selected[index]==true end
function Panel:indices()
    local indices={}
    for i=1,self.document:pageCount() do if self.selected[i] then indices[#indices+1]=i end end
    return indices
end
function Panel:setRange(text)
    local indices=Selection.parse(text,self.document:pageCount())
    if not indices then return false end
    self.selected={}
    for _,index in ipairs(indices) do self.selected[index]=true end
    self:_layout();UIManager:setDirty(self,"ui")
    return true
end
function Panel:_goToPage(index)
    self.selected[index]=not self.selected[index]
    self:_layout();UIManager:setDirty(self,"ui")
end
function Panel:_actions(index) self:_goToPage(index) end
function Panel:_invalid()
    UIManager:show(InfoMessage:new{text=_("Invalid page range. Use page numbers or ranges separated by commas.")})
end
function Panel:_editRange()
    local dialog
    dialog=InputDialog:new{
        title=_("Choose pages to export"),input=Selection.format(self:indices()),
        input_hint=T(_("Pages 1–%1. Use - for ranges and , to separate pages."),self.document:pageCount()),
        buttons={{
            {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
            {text=_("Continue"),callback=function()
                local text=dialog:getInputText()
                if not Selection.parse(text,self.document:pageCount()) then return self:_invalid() end
                UIManager:close(dialog);self:setRange(text)
            end},
        }},
    }
    UIManager:show(dialog);dialog:onShowKeyboard()
end
function Panel:_buildHeader()
    local avail=self.dimen.w-2*Size.padding.large
    local range=Selection.format(self:indices())
    self.range_button=Widgets.textButton{
        text=range,icon="notebook.page",width=avail-2*Size.padding.button-2*Size.border.thin,
        callback=function() self:_editRange() end,
    }
    local selection=HorizontalGroup:new{align="center"}
    local small_width=math.floor((avail-3*Size.padding.small)/4)-2*Size.padding.button-2*Size.border.thin
    local function button(text,callback)
        if #selection>0 then table.insert(selection,HorizontalSpan:new{width=Size.padding.small}) end
        table.insert(selection,Widgets.textButton{text=text,width=small_width,font_size=15,callback=callback})
    end
    button("‹",function() self:_turnPage(-1) end)
    button(_("All"),function() self:setRange("all") end)
    button(_("None"),function()
        self.selected={};self:_layout();UIManager:setDirty(self,"ui")
    end)
    button("›",function() self:_turnPage(1) end)
    return VerticalGroup:new{align="left",
        TextWidget:new{text=_("Choose pages to export"),face=Font:getFace("tfont",22),max_width=avail},
        VerticalSpan:new{width=Size.padding.small},self.range_button,
        VerticalSpan:new{width=Size.padding.small},selection,
        VerticalSpan:new{width=Size.padding.small},
        TextBoxWidget:new{text=T(_("Pages 1–%1. Use - for ranges and , to separate pages."),self.document:pageCount()),
            face=Font:getFace("cfont",15),width=avail},
    }
end
function Panel:_buildFooter()
    local avail=self.dimen.w-2*Size.padding.large
    local width=math.floor((avail-Size.padding.small)/2)-2*Size.padding.button-2*Size.border.thin
    local controls=HorizontalGroup:new{align="center"}
    table.insert(controls,Widgets.textButton{text=_("Cancel"),width=width,callback=function() self:onClose() end})
    table.insert(controls,HorizontalSpan:new{width=Size.padding.small})
    table.insert(controls,Widgets.textButton{text=_("Continue"),width=width,callback=function()
        local indices=self:indices()
        if #indices==0 then return self:_invalid() end
        UIManager:close(self);self.on_selected(indices)
    end})
    return controls
end
Panel=Safe.widget(Panel,"export page selection")
local M={}
function M.new(document,on_selected)
    return Panel:new{document=document,on_selected=on_selected}
end
function M.show(document,on_selected)
    local panel=M.new(document,on_selected)
    UIManager:show(panel,"ui")
    return panel
end
return M
