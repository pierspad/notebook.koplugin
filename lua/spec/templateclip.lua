package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support');support.installStubs()
local Template=require('template')
local BB=require('ffi/blitbuffer')
local Raster=require('raster')
-- Independent exhaustive dot stamping retains the pre-optimization spacing.
local function reference(bb,area,scale,clip)
    local step=5*11.8*scale
    if step<3 then return end
    local r=math.max(3,math.floor(4*scale+0.5))
    local y=area.y
    while y<=area.y+area.h do
        local x=area.x
        while x<=area.x+area.w do
            local px,py=math.floor(x-r/2),math.floor(y-r/2)
            local w,h=r,r
            if clip then
                local right,bottom=math.min(px+w,clip.x+clip.w),math.min(py+h,clip.y+clip.h)
                px,py=math.max(px,clip.x),math.max(py,clip.y)
                w,h=right-px,bottom-py
            end
            if w>0 and h>0 then Raster.rect(bb,px,py,w,h,BB.COLOR_GRAY_5) end
            x=x+step
        end
        y=y+step
    end
end
math.randomseed(731)
for i=1,240 do
    local scale=({0.04,0.1,0.3,0.75,1,1.3,2})[i%7+1]
    local area={x=math.random(-180,30)/3,y=math.random(-180,30)/3,w=200,h=240}
    local clip=i%3~=0 and {x=math.random(-10,45),y=math.random(-10,55),w=math.random(0,30),h=math.random(0,30)} or nil
    local actual,expected=support.FakeBB.new(64,72),support.FakeBB.new(64,72)
    Template.draw(actual,'dots',area,scale,clip);reference(expected,area,scale,clip)
    for y=0,71 do for x=0,63 do
        assert(actual:get(x,y)==expected:get(x,y),'dot clip changed pixels, case '..i)
    end end
end
local count=0
local bb={getWidth=function() return 80 end,getHeight=function() return 80 end,
    paintRect=function() count=count+1 end}
Template.draw(bb,'dots',{x=-1800,y=-2400,w=3720,h=4800},2)
assert(count<=4,'small viewport still paints offscreen dot rows')
print('dot paper: 240 fractional/offscreen/empty clips match exhaustive stamping; viewport work is bounded')
