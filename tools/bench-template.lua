-- Offscreen CPU benchmark and pixel check, no panel refresh or user data writes.
-- From a KOReader runtime: ./luajit /path/bench-template.lua /path/lua /tmp/old-template.lua
require('setupkoenv')
local directory=assert(arg[1],'plugin Lua directory required')
local load=dofile(directory..'/loader.lua')(directory)
local current=load('template')
local chunk=assert(loadfile(assert(arg[2],'baseline template.lua required')))
setfenv(chunk,setmetatable({require=load},{__index=_G}))
local baseline=chunk()
local BB=require('ffi/blitbuffer')
local scenarios={
    {name='full 1860x2400',w=1860,h=2400,area={x=0,y=0,w=1860,h=2400},scale=1},
    {name='2x viewport',w=1860,h=2400,area={x=-900,y=-1200,w=3720,h=4800},scale=2},
    {name='100x100 erase clip',w=1860,h=2400,area={x=0,y=0,w=1860,h=2400},scale=1,
        clip={x=900,y=1200,w=100,h=100}},
    {name='2x 100x100 viewport repair',w=100,h=100,area={x=-900,y=-1200,w=3720,h=4800},scale=2},
}
local function median(values)
    table.sort(values);return values[math.ceil(#values/2)]
end
for _,s in ipairs(scenarios) do
    local buffers={BB.new(s.w,s.h,BB.TYPE_BB8),BB.new(s.w,s.h,BB.TYPE_BB8)}
    local modules={baseline,current}
    for i,mod in ipairs(modules) do
        buffers[i]:fill(BB.COLOR_WHITE)
        mod.draw(buffers[i],'dots',s.area,s.scale,s.clip)
    end
    for y=0,s.h-1 do for x=0,s.w-1 do
        assert(buffers[1]:getPixel(x,y)==buffers[2]:getPixel(x,y),s.name..' pixel mismatch')
    end end
    local samples={{},{}}
    for round=1,9 do
        for offset=0,1 do
            local i=(round+offset)%2+1
            for _=1,30 do modules[i].draw(buffers[i],'dots',s.area,s.scale,s.clip) end
            local start=os.clock()
            for _=1,500 do modules[i].draw(buffers[i],'dots',s.area,s.scale,s.clip) end
            samples[i][#samples[i]+1]=(os.clock()-start)*1000/500
        end
    end
    local old,new=median(samples[1]),median(samples[2])
    print(string.format('%s: baseline %.4f ms, current %.4f ms, %.2fx; identical pixels',s.name,old,new,old/new))
    for _,bb in ipairs(buffers) do bb:free() end
end
