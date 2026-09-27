-- Real blitbuffer CPU benchmark, not physical panel latency.
-- ./luajit bench-marker.lua /plugin/lua [baseline-highlightink.lua]
require('setupkoenv')
local load=dofile(arg[1]..'/loader.lua')(arg[1])
local current=load('highlightink')
local previous=arg[2] and assert(loadfile(arg[2]))()
local BB=require('ffi/blitbuffer');local color=BB.Color8(160)
local bb=BB.new(1860,2480,BB.TYPE_BB8)
for _,points in ipairs({{100,300,1600,300},{100,100,1700,2100},{100,100,125,125}}) do
 for _,preview in ipairs({false,true}) do
    local x0,y0,x1,y1=unpack(points)
    local steps=math.max(1,math.ceil(math.sqrt((x1-x0)^2+(y1-y0)^2)/19))
    local function bench(ink)
        for _=1,25 do ink.drawSegment(bb,x0,y0,24,x1,y1,24,color,0,steps,steps,preview) end
        local start=os.clock()
        for _=1,200 do
            bb:fill(BB.COLOR_WHITE)
            ink.drawSegment(bb,x0,y0,24,x1,y1,24,color,0,steps,steps,preview)
        end
        return (os.clock()-start)*1000/200
    end
    local new=bench(current);local old=previous and bench(previous)
    print(string.format('%d,%d -> %d,%d preview=%s: %.3f ms%s',x0,y0,x1,y1,tostring(preview),new,
        old and string.format(' (previous %.3f ms, %.2fx)',old,old/new) or ''))
 end
end
bb:free()
