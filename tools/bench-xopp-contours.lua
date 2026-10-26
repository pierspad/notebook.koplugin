-- Native paired export benchmark; generated documents only, no panel refresh.
-- From KOReader: ./luajit THIS CURRENT_LUA BASELINE_LUA EMPTY_OUTPUT_DIRECTORY
-- Timings use normal GC; allocated_kib measures a separate call with GC paused.
require('setupkoenv')
local root,base,tmp=assert(arg[1]),assert(arg[2]),assert(arg[3])
local load=dofile(root..'/loader.lua')(root)
local old=dofile(base..'/loader.lua')(base)('xopp')
local new=load('xopp')
local Document,Stroke=load('document'),load('stroke')
local doc=Document:new(nil)
local s=Stroke:new{tool='highlighter',filled=true,width=120,tint=160,marker_parts={}}
for row=1,40 do for col=1,100 do
 local x,y=col*14,row*45
 s:addPoint(x,y,1);s:addPoint(x+10,y,1);s:addPoint(x+10,y+30,1);s:addPoint(x,y+30,1)
 s.marker_parts[#s.marker_parts+1]=s.n
end end
doc:addStroke(s)
local function contents(path)
 local f=assert(io.open(path,'rb'));local data=f:read('*a');f:close();return data
end
assert(old.toXOPP(doc,tmp..'/before.xopp'));assert(new.toXOPP(doc,tmp..'/after.xopp'))
assert(contents(tmp..'/before.xopp')==contents(tmp..'/after.xopp'),'XOPP bytes changed')
local entries={{'before',old},{'after',new}}
local samples={{}, {}}
for round=1,17 do
 for k=1,2 do
  local i=round%2==0 and k or 3-k
  collectgarbage('collect')
  local start=os.clock();assert(entries[i][2].toXOPP(doc,tmp..'/bench.xopp'))
  samples[i][#samples[i]+1]=(os.clock()-start)*1000
 end
end
local results={}
for i,entry in ipairs(entries) do
 collectgarbage('collect');local mem=collectgarbage('count');collectgarbage('stop')
 assert(entry[2].toXOPP(doc,tmp..'/bench.xopp'))
 local allocated=collectgarbage('count')-mem;collectgarbage('restart')
 table.sort(samples[i])
 results[#results+1]={variant=entry[1],ms=samples[i][9],allocated_kib=allocated,contours=#s.marker_parts}
end
print('XOPP_CONTOURS_JSON='..require('json').encode(results))
