-- Offscreen native framebuffer comparison; no display, settings or user files.
-- From a configured KOReader runtime: ./luajit /plugin/tools/check-page-cache.lua
-- /plugin/lua /path/to/upstream-canvasrender.lua
require('setupkoenv')
local BB=require('ffi/blitbuffer')
local Screen={isColorEnabled=function(self) return self.color end}
package.loaded.device={screen=Screen}
local load=dofile(assert(arg[1])..'/loader.lua')(arg[1])
local Current=load('canvasrender')
local chunk=assert(loadfile(assert(arg[2])))
setfenv(chunk,setmetatable({require=load},{__index=_G}))
local Before=chunk()
local Stroke=load('stroke')
local function canvas(module,doc,w,h)
    return setmetatable({document=doc,zoom=1,dimen={w=w,h=h},content={x=0,y=20,w=w,h=h-20},
        _visiblePage=function(self) return self.document:getPage() end},{__index=module})
end
local function free(c)
    if c.background_cache then c.background_cache:free() end
    for _,entry in ipairs(c.page_render_cache or {}) do entry.bb:free() end
end
local function document()
    local pages={{strokes={},revision=0,template='lined'},{strokes={},revision=0,template='dots'}}
    for p,page in ipairs(pages) do
        for i=1,10 do
            local s=Stroke:new{width=1+i%5,color=i%2==0 and 0x1E53935 or 0}
            s:addPoint(i*5,25+p*5,0.5);s:addPoint(i*5+10,80,1)
            page.strokes[#page.strokes+1]=s
        end
    end
    return {pages=pages,index=1,getPage=function(self) return self.pages[self.index] end,
        templateFor=function(self) return self:getPage().template end}
end
for _,native in ipairs{false,true} do
    BB:setUseCBB(native)
    for _,kind in ipairs{BB.TYPE_BB8,BB.TYPE_BBRGB32} do
        Screen.color=kind==BB.TYPE_BBRGB32
        local doc=document()
        local old,new=canvas(Before,doc,80,120),canvas(Current,doc,80,120)
        local a,b=BB.new(80,120,kind),BB.new(80,120,kind)
        local function same()
            old:paintTo(a,0,0);new:paintTo(b,0,0)
            for y=0,119 do for x=0,79 do
                assert(a:getPixel(x,y)==b:getPixel(x,y),'native page cache pixels changed')
            end end
        end
        same();same()
        doc.index=2;same();doc.index=1;same()
        -- A cached page restored after visiting different paper must leave
        -- the background cache ready for eraser-driven regional redraws.
        Screen.bb=a;old:_repaintRegion(0,20,80,100,true)
        Screen.bb=b;new:_repaintRegion(0,20,80,100,true)
        for y=20,119 do for x=0,79 do
            assert(a:getPixel(x,y)==b:getPixel(x,y),'cached paper stale after page switch')
        end end
        doc:getPage().strokes[1]:translate(5,5)
        doc:getPage().revision=1;same()
        doc:getPage().template='grid';same();same()
        old.selected_strokes={};new.selected_strokes={};same()
        old.selected_strokes=nil;new.selected_strokes=nil;same()
        free(old);free(new);a:free();b:free()
    end
end
BB:setUseCBB(true);Screen.color=false
local doc=document()
local old,new=canvas(Before,doc,1860,2480),canvas(Current,doc,1860,2480)
local a,b=BB.new(1860,2480,BB.TYPE_BB8),BB.new(1860,2480,BB.TYPE_BB8)
old:paintTo(a,0,0);new:paintTo(b,0,0)
local function median(c,bb)
    local times={}
    for r=1,7 do
        collectgarbage('collect')
        local start=os.clock()
        for _=1,100 do c:paintTo(bb,0,0) end
        times[r]=(os.clock()-start)*1000/100
    end
    table.sort(times);return times[4]
end
local previous,current=median(old,a),median(new,b)
print(string.format('Native BB8 cached 1860x2480 paint: before %.4f ms, after %.4f ms, %.2fx',previous,current,previous/current))
free(old);free(new);a:free();b:free()
print('Native page cache: identical grayscale/RGB pixels, Lua/C backends, page switches, '
    ..'regional paper restoration, revision/template changes and selection bypass')
