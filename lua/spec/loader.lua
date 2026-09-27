require("spec/support").installStubs()
require("spec/uistubs").install({})
local stale = {legacy=true}
package.loaded.canvas = stale
package.loaded.document = stale
for _,name in ipairs({'raster','textdialog','textsizepicker','notebooktoolbar','notebooksettings','galleryexport','canvasrefresh','liveink','geometryink','penpressure','polygonink','textcache','textpreview',
    'zoomcache','zoomcanvas','zoomrefresh','shapecanvas','canvasrender','notebooktext'}) do
    package.loaded[name]=stale
end
local load = dofile("loader.lua")(".")
local canvas = load("canvas")
assert(canvas ~= stale and canvas.onStylusEvent)
assert(load("canvas") == canvas)
assert(load("document") ~= stale)
assert(package.loaded.canvas == stale and package.loaded.document == stale)
assert(load('raster')~=stale and package.loaded.raster==stale)
assert(load('geometryink')~=stale and load('textpreview')~=stale)
assert(package.loaded.geometryink==stale, 'private module overwrote another plugin')
assert(load("device") == require("device"))
print("private plugin modules passed")
