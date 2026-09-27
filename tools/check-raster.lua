-- Native clipping regression, including parent strides, rotation and RGB ink.
require('setupkoenv')
local load=dofile(arg[1]..'/loader.lua')(arg[1])
local BB=require('ffi/blitbuffer');local Raster=load('raster')
for _,cbb in ipairs({false,true}) do
 BB:setUseCBB(cbb)
 for _,kind in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
  for rotation=0,3 do
   for _,width in ipairs({1,2,13}) do
    local bb=BB.new(80,90,kind);bb:fill(BB.COLOR_WHITE);bb:setRotation(rotation)
    local view=bb:viewport(20,20,width,15)
    local rgb=kind==BB.TYPE_BBRGB32
    local color=rgb and BB.ColorRGB32(229,57,53,255) or BB.COLOR_BLACK
    Raster.rect(view,-2,-2,width+4,19,color,rgb)
    for y=0,bb:getHeight()-1 do for x=0,bb:getWidth()-1 do
     local inside=x>=20 and x<20+width and y>=20 and y<35
     local pixel=bb:getPixel(x,y)
     assert(pixel:getR()==(inside and color:getR() or 255)
      and pixel:getG()==(inside and color:getG() or 255)
      and pixel:getB()==(inside and color:getB() or 255),
      string.format('fill escaped clip cbb=%s kind=%d rotation=%d width=%d at %d,%d',tostring(cbb),kind,rotation,width,x,y))
    end end
    bb:free()
   end
  end
 end
end
-- Actual pen rasterization into a narrow dirty region, across the whole clip.
local Renderer=load('renderer');local Stroke=load('stroke')
for _,style in ipairs({'fineliner','fountain','pencil'}) do
 local bb=BB.new(80,80,BB.TYPE_BB8);bb:fill(BB.COLOR_WHITE)
 local stroke=Stroke:new{tool='pen',width=8,pen_style=style,color=0}
 stroke:addPoint(0,25,1);stroke:addPoint(79,25,1)
 Renderer.drawStroke(bb,stroke,{x=20,y=20,w=3,h=10})
 for y=0,79 do for x=0,79 do
  if not (x>=20 and x<23 and y>=20 and y<30) then
   assert(bb:getPixel(x,y):getColor8().a==255,'pen redraw escaped dirty region: '..style)
  end
 end end
 bb:free()
end
print('native raster: bounded fills and pen redraws pass for grayscale/RGB, all rotations and C/Lua backends')
