-- A private require cache prevents collisions with old Scribe and other plugins
-- using generic names such as canvas, document, settings and i18n. Each chunk
-- retains this require in its environment, including callbacks loaded later.
return function(directory)
    local shared_require = require
    local cache = {}
    local own = {}
    for name in ("_meta actionmenu canvas document export gallery i18n lassomenu lasso launcherbar library " ..
        "newnotebook notebook pagepanel pagegrid pagetile papersample pdfbackground pressure rect raster renderer safe settings shape share " ..
        "stroke textobject textpreview textcache textdialog textsizepicker polygonink penpressure penink liveink viewcanvas xopp svg " ..
        "exportprogress documentstorage documenthistory pageselection exportpagesdialog gallerycard galleryheader pluginicons " ..
        "updatepolicy updateinstaller updatetransport updater releasenotes " ..
        "canvasrender canvasrefresh canvaslifecycle notebooktoolbar notebooksettings galleryexport " ..
        "erasercanvas geometryink highlightink markerarea markerhit markerclip notebooktext selectioncanvas shapecanvas " ..
        "shapesnap snapcanvas stylusbridge stylusinput touchinput zoom zoomcache zoomcanvas zoomrefresh " ..
        "template templatepicker thumbnail tuning tuningdock widgets"):gmatch("%S+") do own[name] = true end
    local function privateRequire(name)
        if not own[name] then return shared_require(name) end
        if cache[name] ~= nil then return cache[name] end
        local chunk = assert(loadfile(directory .. "/" .. name .. ".lua"))
        setfenv(chunk, setmetatable({require=privateRequire}, {__index=_G}))
        local result = chunk(name)
        cache[name] = result == nil and true or result
        return cache[name]
    end
    return privateRequire
end
