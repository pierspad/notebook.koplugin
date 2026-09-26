-- Run inside KOReader: ./luajit /path/bench-pen.lua /path/plugin/lua [baseline-renderer.lua]
-- Offscreen CPU timings only; no panel refresh and no saved document changes.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/settings.lua')
local directory=assert(arg[1], 'plugin Lua directory required')
local load=dofile(directory..'/loader.lua')(directory)
local new=load('renderer')
local old
if arg[2] then
 local chunk=assert(loadfile(arg[2]));setfenv(chunk,setmetatable({require=load},{__index=_G}));old=chunk()
end
local BB=require('ffi/blitbuffer');local bb=BB.new(1860,2480,BB.TYPE_BB8)
for _,style in ipairs({'fineliner','fountain','pencil'}) do
 for _,scale in ipairs({1,2}) do
  local s={tool='pen',pen_style=style,width=14*scale,color=style=='pencil' and 96 or 0}
  local function bench(r)
   for _=1,3 do r.drawSegment(bb,s,80,100,0.5,1750,2100,1) end
   local start=os.clock()
   for _=1,12 do r.drawSegment(bb,s,80,100,0.5,1750,2100,1) end
   return (os.clock()-start)*1000/12
  end
  print(string.format('%s %dx new %.2f ms%s',style,scale,bench(new),
   old and string.format(' baseline %.2f ms',bench(old)) or ''))
 end
end
bb:free()
