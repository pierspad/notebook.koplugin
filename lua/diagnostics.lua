-- Visible, session-wide diagnostics without creating a specially named notebook.
local DataStorage = require("datastorage")
local Diagnostics = {}
function Diagnostics.path() return DataStorage:getDataDir() .. "/notebook/notebook-debug.log" end
function Diagnostics.set(canvas, enabled)
    if enabled then
        if not require("library").ensureDir("") then return false,require("i18n")("Could not create the notebook folder.") end
        local file,err=io.open(Diagnostics.path(),"a")
        if not file then return false,err end
        file:close()
    end
    Diagnostics.enabled = enabled == true
    canvas.debug_log_path = Diagnostics.enabled and Diagnostics.path() or nil
    if canvas.debug_log_path then canvas:_debugEvent("diagnostics-start",nil,nil,nil,canvas.tool) end
    return true
end
return Diagnostics
