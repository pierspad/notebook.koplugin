-- luacheck: globals G_defaults
-- Compare polygon scanline candidate with baseline; exact pixels required.
-- Run inside KOReader: this.lua baseline_lua candidate_lua
require('setupkoenv')
G_defaults=require('luadefaults'):open()
local settings_path=os.tmpname();os.remove(settings_path)
G_reader_settings=require('luasettings'):open(settings_path)
local Device=require('device');require('document/canvascontext'):init(Device)
local function load(path) return dofile(path..'/loader.lua')(path) end
local base,candidate=load(assert(arg[1])),load(assert(arg[2]))
local BB=require('ffi/blitbuffer');local ffi=require('ffi')
local function shape(lib)
 local item=lib('shape').create('rectangle',100,150,1450,1950,14,0,false)
 item=lib('shape').transform(item,'rotate',1600,1800,1450,1050)
 item.filled=true;return item
end
local a,b=shape(base),shape(candidate)
local clips={{x=0,y=0,w=1860,h=2480},{x=700,y=900,w=256,h=256},{x=1400,y=200,w=128,h=128}}
local function bytes(bb) return ffi.string(bb.data,tonumber(bb.stride)*bb:getHeight()) end
local function render(lib,bb,item,clip,color) lib('renderer').drawStroke(bb,item,clip,color) end
local function batch(lib,bb,item,clip,color)
 local start=os.clock();for _=1,8 do render(lib,bb,item,clip,color) end
 return (os.clock()-start)*1000/8
end
local function summary(values) table.sort(values);return values[5],values[1],values[9] end
for _,case in ipairs({{BB.TYPE_BB8,false},{BB.TYPE_BBRGB32,true}}) do
 local kind,color_enabled=unpack(case)
 for ci,clip in ipairs(clips) do
  local left,right=BB.new(1860,2480,kind),BB.new(1860,2480,kind)
  left:fill(BB.COLOR_WHITE);right:fill(BB.COLOR_WHITE)
  render(base,left,a,clip,color_enabled);render(candidate,right,b,clip,color_enabled)
  assert(bytes(left)==bytes(right),'pixel mismatch format='..tostring(kind)..' clip='..ci)
  local old,new={},{}
  for round=1,9 do
   if round%2==1 then old[round]=batch(base,left,a,clip,color_enabled);new[round]=batch(candidate,right,b,clip,color_enabled)
   else new[round]=batch(candidate,right,b,clip,color_enabled);old[round]=batch(base,left,a,clip,color_enabled) end
  end
  local om,omin,omax=summary(old);local nm,nmin,nmax=summary(new)
  io.write(string.format('format=%s clip=%d baseline_ms=%.3f[%.3f,%.3f] candidate_ms=%.3f[%.3f,%.3f] parity=exact\n',
   tostring(kind),ci,om,omin,omax,nm,nmin,nmax))
  left:free();right:free()
 end
end

os.remove(settings_path)
if Device.input and Device.input.teardown then Device.input:teardown() end
