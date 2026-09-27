package.path='./?.lua;./spec/?.lua;'..package.path
local Raster=require('raster')
-- Model only the unsafe native fill precondition. Any call satisfying it must
-- supply the safe setter; ordinary regions must retain their fast native path.
for rotation=0,3 do
 for _,width in ipairs({1,2,20}) do
  local calls=0
  local bb={w=width,pixel_stride=100,getRotation=function() return rotation end,
   getBoundedRect=function(_,x,y,w,h) return x,y,w,h end,
   getPhysicalRect=function(_,x,y,w,h)
    if rotation%2==1 then return y,x,h,w end
    return x,y,w,h
   end}
  bb.paintRect=function(self,x,y,w,h,color,setter)
   local px,_,pw=self:getPhysicalRect(x,y,w,h)
   assert(px~=0 or pw~=self.w or setter,'unsafe full-stride fill')
   assert(color==42,'fill lost color');calls=calls+1
  end
  local w,h=width,8
  if rotation%2==1 then w,h=h,w end
  Raster.rect(bb,0,0,w,h,42)
  assert(calls==(width==1 and 1 or 2),'fill did not use bounded native spans')
 end
end
local calls=0
Raster.rect({paintRect=function(_,x,y,w,h,color)
 assert(x==2 and y==3 and w==4 and h==5 and color==42);calls=calls+1
end},2,3,4,5,42)
assert(calls==1,'simple buffer path changed')
print('raster: safe viewport stride, rotation, one-pixel fallback and native fast path')
