-- Native old/new pixel equivalence for contained/clipped scaled rendering.
require("setupkoenv")
G_defaults=require("luadefaults"):open()
G_reader_settings=require("luasettings"):open(assert(arg[3]).."/settings.lua")
local Device=require("device")
for _,name in ipairs({"refreshUI","refreshFast","refreshFull","refreshPartial","refreshNoMerge","refreshA2"}) do
 Device.screen[name]=function() end
end
require("document/canvascontext"):init(Device)
local current=dofile(arg[1].."/loader.lua")(arg[1])
local baseline=dofile(arg[2].."/loader.lua")(arg[2])
local Renderer,Old,Stroke=current("renderer"),baseline("renderer"),current("stroke")
local BB=require("ffi/blitbuffer")
local count=0
for _,kind in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
 for rotation=0,3 do
  for _,scale in ipairs({0.1,0.5,1,2}) do
   for _,offset in ipairs({0,-23,31}) do
    local mixed={}
    for _,style in ipairs({"fineliner","fountain","pencil","highlighter","circle","rectangle"}) do
     local s
     if style=="circle" or style=="rectangle" then s=current("shape").create(style,20,20,60,50,5,0x1E53935,true)
     else
      s=Stroke:new{tool=style=="highlighter" and style or "pen",pen_style=style,width=12,color=0x1E53935,tint=0x1FDD835}
      for i=1,35 do s:addPoint(i*3,40+math.sin(i/3)*10,i%10/10) end
     end
     mixed[#mixed+1]=s
     local a,b=BB.new(140,100,kind),BB.new(140,100,kind)
     a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE);a:setRotation(rotation);b:setRotation(rotation)
     Renderer.drawPage(a,{strokes={s}},scale,offset,offset,kind==BB.TYPE_BBRGB32)
     Old.drawPage(b,{strokes={s}},scale,offset,offset,kind==BB.TYPE_BBRGB32)
     for y=0,a:getHeight()-1 do for x=0,a:getWidth()-1 do
      local p,q=a:getPixel(x,y),b:getPixel(x,y)
      assert(p:getR()==q:getR() and p:getG()==q:getG() and p:getB()==q:getB(),
       string.format("scaled pixels changed %s scale %.1f rotation %d offset %d at %d,%d",style,scale,rotation,offset,x,y))
     end end
     a:free();b:free();count=count+1
    end
    for n=1,2 do
     local s=Stroke:new{tool="lasso",width=3}
     s:addPoint(5,15+n*8,1);s:addPoint(130,15+n*8,1);mixed[#mixed+1]=s
    end
    local a,b=BB.new(140,100,kind),BB.new(140,100,kind)
    a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE);a:setRotation(rotation);b:setRotation(rotation)
    Renderer.drawPage(a,{strokes=mixed},scale,offset,offset,kind==BB.TYPE_BBRGB32)
    -- Unscaled lasso rendering advances its dash phase on the original stroke.
    -- Give both implementations the same starting phase.
    for _,stroke in ipairs(mixed) do stroke.accum_len=nil end
    Old.drawPage(b,{strokes=mixed},scale,offset,offset,kind==BB.TYPE_BBRGB32)
    for y=0,a:getHeight()-1 do for x=0,a:getWidth()-1 do
     local p,q=a:getPixel(x,y),b:getPixel(x,y)
     assert(p:getR()==q:getR() and p:getG()==q:getG() and p:getB()==q:getB(),string.format("mixed strokes changed scale %.1f rotation %d offset %d pixel %d,%d",scale,rotation,offset,x,y))
    end end
    a:free();b:free();count=count+1
   end
  end
 end
end
if Device.input and Device.input.teardown then Device.input:teardown() end
print("Scaled renderer: "..count.." native grayscale/RGB, rotation, scale, offset and brush/fill comparisons passed")
