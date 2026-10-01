-- Page-range input belongs to export UI, never to the document or PDF encoder.
local InputDialog=require("ui/widget/inputdialog")
local InfoMessage=require("ui/widget/infomessage")
local UIManager=require("ui/uimanager")
local Selection=require("pageselection")
local _=require("i18n")
local T=require("ffi/util").template
local M={}
function M.show(count,on_selected)
    local dialog
    dialog=InputDialog:new{
        title=_("Choose pages to export"),
        input="1-"..count,
        input_hint=T(_("Pages 1–%1; for example: 1, 3-5"),count),
        buttons={{
            {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
            {text=_("Continue"),callback=function()
                local indices=Selection.parse(dialog:getInputText(),count)
                if not indices then
                    UIManager:show(InfoMessage:new{text=_("Invalid page range. Use page numbers or ranges separated by commas.")})
                    return
                end
                UIManager:close(dialog);on_selected(indices)
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
return M
