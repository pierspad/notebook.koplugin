-- The desktop patch opens the same gallery as the Notebook menu entry.
local getenv = os.getenv
local realprint = print
local mode, target, scheduled, gallery, notebook
os.getenv = function(key)
    if key == "NOTEBOOK_EMULATOR_DPI" then return "160" end
    if key == "NOTEBOOK_EMULATOR_START" then return mode end
    if key == "NOTEBOOK_EMULATOR_NOTEBOOK" then return target end
end
print = function() end
G_reader_settings = { saveSetting = function() end }
package.loaded.device = { setScreenDPI = function() end }
package.loaded["ui/uimanager"] = { scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end }
for _, start in ipairs{"gallery", "notebook", "home"} do
    mode, target = start, "Kindle/example.scribe"
    scheduled, gallery, notebook = {}, 0, nil
    local plugin = {
        openNotebook = function() gallery = gallery + 1 end,
        _openByName = function(_, name, folder) notebook = folder .. "/" .. name end,
    }
    local fm = { showFiles = function(self) self.instance = { notebook = plugin } end }
    package.loaded["apps/filemanager/filemanager"] = fm
    dofile("../tools/emulator-startup.lua")
    fm:showFiles()
    for _, fn in ipairs(scheduled) do fn() end
    if start == "gallery" then assert(gallery == 1 and notebook == nil, "gallery startup opened seeded notebook") end
    if start == "notebook" then assert(notebook == "Kindle/example", "explicit notebook startup failed") end
    if start == "home" then assert(#scheduled == 0, "home startup was overridden") end
    local count = #scheduled
    fm:showFiles()
    assert(#scheduled == count, "returning to FileManager reopens Notebook")
end
os.getenv, print = getenv, realprint
print("emulatorstartup: gallery default, explicit notebook, home opt-out and one-shot launch passed")
