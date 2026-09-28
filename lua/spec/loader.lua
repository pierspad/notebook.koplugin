require("spec/support").installStubs()
require("spec/uistubs").install({})
local stale = {legacy=true}
package.loaded._meta = stale
package.loaded.canvas = stale
package.loaded.document = stale
for _,name in ipairs({'raster','textdialog','textsizepicker','notebooktoolbar','notebooksettings','galleryexport','canvasrefresh','liveink','geometryink','penpressure','polygonink','textcache','textpreview',
    'zoomcache','zoomcanvas','zoomrefresh','canvaslifecycle','shapecanvas','canvasrender','notebooktext'}) do
    package.loaded[name]=stale
end
local load = dofile("loader.lua")(".")
assert(load("_meta").version == dofile("_meta.lua").version and package.loaded._meta == stale)
local canvas = load("canvas")
assert(canvas ~= stale and canvas.onStylusEvent)
assert(load("canvas") == canvas)
assert(load("document") ~= stale)
assert(package.loaded.canvas == stale and package.loaded.document == stale)
assert(load('canvaslifecycle')~=stale and canvas.pause and canvas.resume)
assert(load('raster')~=stale and package.loaded.raster==stale)
assert(load('geometryink')~=stale and load('textpreview')~=stale)
assert(package.loaded.geometryink==stale, 'private module overwrote another plugin')
assert(load("device") == require("device"))
print("private plugin modules passed")
