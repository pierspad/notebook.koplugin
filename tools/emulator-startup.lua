-- Desktop-only user patch, installed by run-notebook-emulator.sh.
local FileManager = require("apps/filemanager/filemanager")
local UIManager = require("ui/uimanager")
local dpi = assert(tonumber(os.getenv("NOTEBOOK_EMULATOR_DPI")))
G_reader_settings:saveSetting("screen_dpi", dpi)
require("device"):setScreenDPI(dpi)
local showFiles = FileManager.showFiles
local launched = false
FileManager.showFiles = function(self, ...)
    showFiles(self, ...)
    if launched or os.getenv("NOTEBOOK_EMULATOR_START") ~= "notebook" then return end
    launched = true
    UIManager:scheduleIn(0.2, function()
        local fm = FileManager.instance
        if not fm or not fm.notebook then return end
        local relative = os.getenv("NOTEBOOK_EMULATOR_NOTEBOOK") or ""
        if relative ~= "" then
            local folder, name = relative:match("^(.*)/([^/]+)$")
            name = (name or relative):gsub("%.scribe$", "")
            fm.notebook:_openByName(name, folder or "")
        else
            fm.notebook:openNotebook()
        end
        print("Notebook emulator: opened Notebook at " .. dpi .. " DPI")
    end)
end
