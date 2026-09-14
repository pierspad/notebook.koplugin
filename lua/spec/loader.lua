require("spec/support").installStubs()
require("spec/uistubs").install({})
local stale = {legacy=true}
package.loaded.canvas = stale
package.loaded.document = stale
local load = dofile("loader.lua")(".")
local canvas = load("canvas")
assert(canvas ~= stale and canvas.onStylusEvent)
assert(load("canvas") == canvas)
assert(load("document") ~= stale)
assert(package.loaded.canvas == stale and package.loaded.document == stale)
assert(load("device") == require("device"))
print("private plugin modules passed")
