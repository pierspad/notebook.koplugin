package.path="./?.lua;./spec/?.lua;"..package.path
local support=require("support");support.installStubs()
local Renderer,Stroke=require("renderer"),require("stroke")
local BB=support.FakeBB
-- Reference: always render a scaled proxy through a full-buffer viewport.
local function reference(bb,s,scale,ox,oy)
    local proxy={tool=s.tool,pen_style=s.pen_style,width=math.max(1,s.width*scale),
        color=s.color,tint=s.tint,grain_x=-ox,grain_y=-oy,
        count=function() return s:count() end,
        getPoint=function(_,i) local x,y,p=s:getPoint(i);return x*scale+ox,y*scale+oy,p end}
    Renderer.drawStroke(bb,proxy,{x=0,y=0,w=bb.w,h=bb.h})
end
for _,style in ipairs({"fineliner","fountain","pencil","highlighter"}) do
 for _,scale in ipairs({0.1,0.5,1,2}) do
  for _,offset in ipairs({0,-23,31}) do
   local s=Stroke:new{tool=style=="highlighter" and style or "pen",pen_style=style,width=12,tint=160}
   for i=1,35 do s:addPoint(i*3,40+math.sin(i/3)*10,i%10/10) end
   local actual,expected=BB.new(140,100),BB.new(140,100)
   Renderer.drawPage(actual,{strokes={s}},scale,offset,offset)
   reference(expected,s,scale,offset,offset)
   for y=0,99 do for x=0,139 do
    assert(actual:get(x,y)==expected:get(x,y),style.." scaled/clipped pixels changed")
   end end
  end
 end
end
local s=Stroke:new{width=3};s:addPoint(30,30);s:addPoint(70,40)
local bb=BB.new(100,100)
local viewport=bb.viewport;local views=0
bb.viewport=function(self,...) views=views+1;return viewport(self,...) end
Renderer.drawPage(bb,{strokes={s}},0.5)
assert(views==0,"fully contained scaled stroke still allocates a viewport")
print("renderfast: identical scaled/clipped brush pixels; contained strokes avoid viewport allocation")
