-- Run from the plugin root: luajit tools/bench-performance-audit.lua [--jit-off]
-- Compare production lasso with the synchronized upstream baseline. Read-only;
-- uses actual Stroke/Lasso geometry and KOReader module stubs, no Kindle access.
package.path = "./lua/?.lua;./lua/spec/?.lua;" .. package.path
require("support").installStubs()
if arg[1] == "--jit-off" then jit.off() end
local Stroke, Lasso = require("stroke"), require("lasso")
local baseline = assert(io.popen("git show 38fcfd5:lua/lasso.lua", "r"))
local code = assert(baseline:read("*a"))
assert(baseline:close())
local Before = assert(loadstring(code, "upstream:38fcfd5/lasso.lua"))()
local function equivalent(strokes, polygon)
    local old, new = Before.findSelectedStrokes(strokes,polygon), Lasso.findSelectedStrokes(strokes,polygon)
    assert(#old==#new,"selection count changed")
    for i,s in ipairs(old) do assert(s==new[i],"selection identity/order changed") end
end
local function timed(fn, reps)
    for _=1,5 do fn() end
    local samples={}
    for i=1,5 do
        collectgarbage("collect")
        local start=os.clock()
        for _=1,reps do fn() end
        samples[i]=(os.clock()-start)*1000/reps
    end
    table.sort(samples)
    return samples[3]
end
math.randomseed(20261001)
local function loop(x,y,r,n,irregular)
    local p={}
    for i=1,n do
        local angle=i*2*math.pi/n
        local radius=irregular and r*(0.1+math.random()) or r
        p[i]={x=x+radius*math.cos(angle),y=y+radius*math.sin(angle)}
    end
    return p
end
local strokes={Stroke:new{}}
for i=1,2000 do
    local s=Stroke:new{width=1+i%12}
    local x,y=math.random(40,1800),math.random(160,2400)
    s:addPoint(x,y,1)
    s:addPoint(x+math.random(-30,30),y+math.random(-30,30),0.7)
    strokes[#strokes+1]=s
end
for _,p in ipairs{{},{{x=0,y=0}},{{x=0,y=0},{x=100,y=100}}} do equivalent(strokes,p) end
for i=1,60 do
    equivalent(strokes,loop(math.random(0,1860),math.random(0,2480),math.random(10,500),20+i,i%2==0))
end
print("Baseline 38fcfd5; deterministic equivalence probes passed; median of 5 CPU samples.")
print("LuaJIT="..tostring(jit.status()).."; "..jit.version.."; "..jit.arch)
for _,case in ipairs{
    {"20 strokes / 20 vertices",20,loop(900,1200,100,20),200},
    {"2000 strokes / 200 vertices",2000,loop(900,1200,100,200),20},
    {"2000 strokes / enclosing loop",2000,loop(900,1200,3000,200),20},
    {"2000 strokes / distant loop",2000,loop(-500,-500,100,200),20},
} do
    local subset={}
    for i=1,case[2]+1 do subset[i]=strokes[i] end
    equivalent(subset,case[3])
    local old=timed(function() Before.findSelectedStrokes(subset,case[3]) end,case[4])
    local new=timed(function() Lasso.findSelectedStrokes(subset,case[3]) end,case[4])
    print(string.format("%-35s before=%.4f ms after=%.4f ms speedup=%.2fx",case[1],old,new,old/new))
end
print("Desktop CPU only. Framebuffer/panel latency and Kindle responsiveness are not measured.")

-- Complete XOPP writer through its production API, with in-memory output only.
local old_file=assert(io.popen("git show 38fcfd5:lua/xopp.lua","r"))
local old_code=assert(old_file:read("*a")); assert(old_file:close())
local OldXopp=assert(loadstring(old_code,"upstream:38fcfd5/xopp.lua"))()
local Xopp=require("xopp")
local text=Stroke:new{tool="text",shape_kind="text",font_size=24,
    text=string.rep("Caffè < & > ",6000)}
text:addPoint(0,0); text:addPoint(500,100)
local doc={pages={{strokes={text}}},templateFor=function() return "blank" end}
-- This isolated probe intentionally replaces and restores output APIs so no
-- benchmark file reaches disk.
-- luacheck: push ignore 122
local function capture(writer)
    local open,rename=io.open,os.rename
    local chunks={}
    io.open=function(path,mode)
        assert(path=="/benchmark.xopp.tmp" and mode=="wb")
        return {write=function(_,data) chunks[#chunks+1]=data; return true end,
            close=function() return true end}
    end
    os.rename=function(from,to)
        assert(from=="/benchmark.xopp.tmp" and to=="/benchmark.xopp")
        return true
    end
    local ok,done=pcall(writer.toXOPP,doc,"/benchmark.xopp")
    io.open,os.rename=open,rename
    assert(ok and done,"XOPP benchmark failed")
    return table.concat(chunks)
end
-- luacheck: pop
assert(capture(OldXopp)==capture(Xopp),"XOPP byte-for-byte compatibility failed")
local old=timed(function() capture(OldXopp) end,10)
local new=timed(function() capture(Xopp) end,10)
print(string.format("XOPP large Unicode text: before=%.4f ms after=%.4f ms speedup=%.2fx; identical bytes",old,new,old/new))
