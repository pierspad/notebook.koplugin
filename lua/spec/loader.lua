require("spec/support").installStubs()
require("spec/uistubs").install({})
local stale = {legacy=true}
package.loaded._meta = stale
package.loaded.canvas = stale
package.loaded.document = stale
for _,name in ipairs({'raster','textdialog','textsizepicker','notebooktoolbar','notebooksettings','galleryexport','canvasrefresh','liveink','geometryink','penpressure','polygonink','textcache','textpreview',
    'documentstorage','documenthistory','gallerycard','galleryheader','pluginicons','pageselection','exportpagesdialog','updater','updatetransport','updatepolicy','updateinstaller',
    'documentformat','gzipwriter','xoppfiles','gallerythumbnails',
    'imagecodec','imageobject','recents','diagnostics','notebookactions','paperoptions',
    'markerarea','highlightink','zoomcache','zoomcanvas','zoomrefresh','canvaslifecycle','shapecanvas','canvasrender','notebooktext'}) do
    package.loaded[name]=stale
end
local load = dofile("loader.lua")(".")
assert(load("_meta").version == dofile("_meta.lua").version and package.loaded._meta == stale)
local canvas = load("canvas")
assert(canvas ~= stale and canvas.onStylusEvent)
assert(load("canvas") == canvas)
assert(load("document") ~= stale)
assert(load("documenthistory") ~= stale and package.loaded.documenthistory == stale)
assert(load("documentstorage") ~= stale and load("galleryheader") ~= stale)
assert(load("updater") ~= stale and load("updatepolicy") ~= stale)
assert(package.loaded.canvas == stale and package.loaded.document == stale)
assert(load('canvaslifecycle')~=stale and canvas.pause and canvas.resume)
assert(load('raster')~=stale and package.loaded.raster==stale)
assert(load('geometryink')~=stale and load('textpreview')~=stale)
assert(package.loaded.geometryink==stale, 'private module overwrote another plugin')
assert(load("device") == require("device"))
assert(load('documentformat')~=stale and load('gzipwriter')~=stale and load('xoppfiles')~=stale)
assert(load('imagecodec')~=stale and package.loaded.imagecodec==stale)
assert(load('imageobject').base64('foo')=='Zm9v','private image codec unavailable')
local marker=load('stroke'):new{tool='highlighter',width=24,tint=160}
marker:addPoint(10,30);marker:addPoint(100,30)
assert(marker:splitAlongPath({50,20,50,20},5),'private marker area module unavailable')
assert(package.loaded.markerarea==stale and load('markerarea')~=stale)
load('renderer').drawStroke(require('spec/support').FakeBB.new(120,60),marker)
print("private plugin modules and production marker rendering/erasure passed")
assert(load('releasenotes').plain('### Heading')=='Heading','release notes missing from private loader')
