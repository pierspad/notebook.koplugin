#!/usr/bin/env luajit
package.path="lua/?.lua;lua/spec/?.lua;"..package.path
require("support").installStubs()
local Export=require("export")

local function oldRLE(data)
    local out,literals={},{}
    local function flush()
        if #literals>0 then
            out[#out+1]=string.char(#literals-1)
            out[#out+1]=table.concat(literals)
            literals={}
        end
    end
    local i,len=1,#data
    while i<=len do
        local b=data:byte(i)
        local run=1
        while i+run<=len and data:byte(i+run)==b and run<128 do run=run+1 end
        if run>=2 then
            flush(); out[#out+1]=string.char(257-run,b); i=i+run
        else
            literals[#literals+1]=string.char(b)
            if #literals==128 then flush() end
            i=i+1
        end
    end
    flush(); out[#out+1]=string.char(128)
    return table.concat(out)
end

local function measure(fn,data,expected,repetitions)
    collectgarbage("collect")
    local started=os.clock()
    for _=1,repetitions do assert(#fn(data)==#expected) end
    return (os.clock()-started)/repetitions
end

local target=1860*2480
local profiles={
    paper=string.rep(string.rep("\255",1800)..string.rep("\40",60),math.ceil(target/1860)):sub(1,target),
    dense=string.rep((function()
        local t={}; for i=0,255 do t[#t+1]=string.char(i) end; return table.concat(t)
    end)(),math.ceil(target/256)):sub(1,target),
}
for name,data in pairs(profiles) do
    local expected=oldRLE(data)
    assert(Export.encodeRLE(data)==expected,"optimized encoder changed the PDF byte stream")
    local old_time=measure(oldRLE,data,expected,5)
    local new_time=measure(Export.encodeRLE,data,expected,5)
    print(string.format("%s: %d -> %d bytes",name,#data,#expected))
    print(string.format("  old %.4fs; new %.4fs; %.2fx, %.1f%% less CPU",
        old_time,new_time,old_time/new_time,(1-new_time/old_time)*100))
end
