-- Run from KOReader's root with base Lua paths and libs available.
-- Verifies real RGB blitbuffer output and clipping, without a display.
require('setupkoenv')
package.path = assert(arg[1], 'plugin directory required') .. '/lua/?.lua;' .. package.path
local BB = require('ffi/blitbuffer')
local Renderer = require('renderer')
local Shape = require('shape')
local Stroke = require('stroke')
local bb = BB.new(300, 300, BB.TYPE_BBRGB32)
bb:fill(BB.COLOR_WHITE)
local red = 0x1E53935
local rect = Shape.create('rectangle',40,40,200,160,4,red)
Renderer.drawStroke(bb, rect, {x=90,y=35,w=30,h=20}, true)
local function pixel(x,y) local p=bb:getPixel(x,y); return p:getR(),p:getG(),p:getB() end
local r,g,b = pixel(100,40)
assert(r==229 and g==57 and b==53, 'rectangle lost RGB color')
assert(select(1,pixel(60,40))==255 and select(1,pixel(120,40))==255,
    'rectangle wrote outside clip')
local pen = Stroke:new{tool='pen',width=1,color=red}
pen:addPoint(50,220,1)
Renderer.drawStroke(bb,pen,nil,true)
r,g,b=pixel(50,220)
assert(r==229 and g==57 and b==53, 'fine colored pen dot became gray')
local rotated = Shape.transform(rect,'rotate',220,120,242,100)
Renderer.drawStroke(bb,rotated,nil,true)
bb:free()
print('RGB rectangle, clipping, fine pen and rotation passed')
