-- From plugin root: luajit tools/bench-eraser.lua BASELINE_LUA_DIR [--jit-off]
-- Baseline must include document.lua and markerarea.lua from before the change.
package.path='./lua/?.lua;./lua/spec/?.lua;'..package.path
require('support').installStubs()
if arg[2]=='--jit-off' then jit.off() end
local Stroke=require('stroke')
local current=require('document')
local marker=require('markerarea')
local dir=assert(arg[1],'supply baseline lua directory')
local before=assert(loadfile(dir..'/document.lua'))()
local old_marker=assert(loadfile(dir..'/markerarea.lua'))()
local function fixture(kind)
 local strokes={}
 if kind=='dense pen' then
  for i=1,2000 do
   local s=Stroke:new{width=3}
   for j=1,16 do s:addPoint(j*10,i%40*4,1) end
   strokes[#strokes+1]=s
  end
 else
  for k=1,12 do
   local s=Stroke:new{tool='highlighter',width=48,tint=160}
   for j=0,1000 do s:addPoint(100+j*1.6,500+k*3+(kind=='wavy marker' and 12*math.sin(j/30) or 0),1) end
   strokes[#strokes+1]=s
  end
 end
 return strokes
end
local function same(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not same(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function run(model,area,strokes,kind)
 package.loaded.markerarea=area
 local d=model:new('/tmp/eraser-bench.scribe')
 for i,s in ipairs(strokes) do d.pages[1].strokes[i]=s end
 d:beginBatch()
 local t=os.clock()
 for i=1,12 do
  local path=kind=='dense pen' and {30+i*7,-5,30+i*7,170} or {150+i*115,474,150+i*115,550}
  d:eraseAreaAlongPath(path,8,{})
 end
 local ms=(os.clock()-t)*1000/12
 d:commitBatch()
 local result={}
 for i,s in ipairs(d:getPage().strokes) do result[i]=s:serialize() end
 d:undo();assert(#d:getPage().strokes==#strokes,'undo count changed')
 d:redo()
 for i,s in ipairs(d:getPage().strokes) do assert(same(result[i],s:serialize()),'redo geometry changed') end
 return ms,result
end
print('CPU ms/display batch, 12 cuts, median of 7; '..jit.version..'; JIT='..tostring(jit.status()))
for _,kind in ipairs({'straight marker','wavy marker','dense pen'}) do
 local strokes=fixture(kind)
 local _,a=run(before,old_marker,strokes,kind)
 local _,b=run(current,marker,strokes,kind)
 assert(same(a,b),'baseline geometry/order differs: '..kind)
 local samples={{},{}}
 for n=1,9 do
  for index=1,2 do
   collectgarbage('collect')
   local ms=run(index==1 and before or current,index==1 and old_marker or marker,strokes,kind)
   if n>2 then samples[index][#samples[index]+1]=ms end
  end
 end
 table.sort(samples[1]);table.sort(samples[2])
 local old,new=samples[1][4],samples[2][4]
 print(string.format('%s: before %.3f; after %.3f; %.2fx; identical geometry/order (%d fragments)',kind,old,new,old/new,#b))
end
package.loaded.markerarea=marker
print('Desktop CPU only; panel latency is not measured.')
