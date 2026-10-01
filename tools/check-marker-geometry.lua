-- Compare production area erasing against a preserved tree, pixel for pixel.
-- Run in KOReader: ./luajit CHECK_LUA CURRENT_LUA BASELINE_LUA
require("setupkoenv")
local BB=require("ffi/blitbuffer")
local current=dofile(arg[1].."/loader.lua")(arg[1])
local previous=dofile(arg[2].."/loader.lua")(arg[2])
local cases=0
for _,width in ipairs({24,48,120,300}) do
    for _,wavy in ipairs({false,true}) do
        for _,pressure in ipairs({false,true}) do
            local function build(load)
                local doc=load("document"):new(nil)
                local marker=load("stroke"):new{tool="highlighter",width=width,tint=160}
                for i=0,300 do
                    marker:addPoint(30+i*.6,170+(wavy and 12*math.sin(i/20) or 0),pressure and (.4+.6*(i%17)/16) or 1)
                end
                doc:addStroke(marker)
                return doc
            end
            local actual,want=build(current),build(previous)
            for cut=1,5 do
                local path={35+cut*30,150-width*.2,40+cut*30,180+width*.2}
                assert(actual:eraseAreaAlongPath(path,5)==want:eraseAreaAlongPath(path,5))
                local a,b=BB.new(260,350,BB.TYPE_BB8),BB.new(260,350,BB.TYPE_BB8)
                a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE)
                current("renderer").drawPage(a,actual:getPage())
                previous("renderer").drawPage(b,want:getPage())
                for y=0,349 do for x=0,259 do
                    assert(a:getPixel(x,y).a==b:getPixel(x,y).a,
                        string.format("geometry changed pixels: width=%d wavy=%s pressure=%s cut=%d at %d,%d",width,tostring(wavy),tostring(pressure),cut,x,y))
                end end
                a:free();b:free();cases=cases+1
            end
        end
    end
end
print("Native marker geometry: "..cases.." comparisons passed: repeated cuts match baseline pixels, including wide/curved/pressure nibs")
