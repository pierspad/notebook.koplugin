-- luacheck: globals G_defaults
-- Baseline-vs-candidate byte parity across polygon shape and output modes.
-- Run from a packaged KOReader runtime directory: this.lua baseline candidate
require('setupkoenv')
G_defaults=require('luadefaults'):open()
local settings_path=os.tmpname();os.remove(settings_path)
G_reader_settings=require('luasettings'):open(settings_path)
local Device=require('device');require('document/canvascontext'):init(Device)
local function load(path) return dofile(path..'/loader.lua')(path) end
local base,candidate=load(assert(arg[1])),load(assert(arg[2]))
local BB=require('ffi/blitbuffer');local ffi=require('ffi')

local function fixture(lib, kind, angle, filled, reverse_order)
    local Shape,Stroke=lib('shape'),lib('stroke')
    local item
    if kind=='bowtie' then
        item=Stroke:new{tool='pen',width=7,color=0x1263B5C,
            shape_kind='triangle',filled=filled}
        for _,p in ipairs({{70,60},{275,240},{70,240},{275,60},{70,60}}) do
            item:addPoint(p[1],p[2],1)
        end
    else
        item=Shape.create(kind,70,60,275,240,7,0x1263B5C,filled)
    end
    if angle~=0 and kind~='bowtie' then
        local cx,cy=(item.x_min+item.x_max)/2,(item.y_min+item.y_max)/2
        local radius=100
        item=Shape.transform(item,'rotate',cx+radius*math.cos(math.rad(angle)),
            cy+radius*math.sin(math.rad(angle)),cx+radius,cy)
    elseif angle~=0 then
        local cx,cy=(item.x_min+item.x_max)/2,(item.y_min+item.y_max)/2
        local radius=100
        item=Shape.transform(item,'rotate',cx+radius*math.cos(math.rad(angle)),
            cy+radius*math.sin(math.rad(angle)),cx+radius,cy)
    end
    if reverse_order then
        local reversed=Stroke:new{tool=item.tool,width=item.width,color=item.color,
            shape_kind=item.shape_kind,filled=item.filled}
        for i=item:count(),1,-1 do
            local x,y,p=item:getPoint(i)
            reversed:addPoint(x,y,p)
        end
        item=reversed
    end
    return item
end

local function bytes(bb) return ffi.string(bb.data,tonumber(bb.stride)*bb:getHeight()) end
local function paint(lib,bb,item,clip,color_on,scale)
    if scale then lib('renderer').drawPage(bb,{strokes={item}},scale,0,0,color_on)
    else lib('renderer').drawStroke(bb,item,clip,color_on) end
end
local function verify(kind,angle,filled,reverse_order,format,color_on,clip,scale)
    local a,b=fixture(base,kind,angle,filled,reverse_order),fixture(candidate,kind,angle,filled,reverse_order)
    local left,right=BB.new(scale and 560 or 360,scale and 520 or 340,format),
        BB.new(scale and 560 or 360,scale and 520 or 340,format)
    left:fill(BB.COLOR_WHITE);right:fill(BB.COLOR_WHITE)
    paint(base,left,a,clip,color_on,scale);paint(candidate,right,b,clip,color_on,scale)
    local same=bytes(left)==bytes(right)
    left:free();right:free()
    assert(same,string.format('pixel mismatch %s angle=%d filled=%s reverse=%s format=%s color=%s clip=%s scale=%s',
        kind,angle,tostring(filled),tostring(reverse_order),tostring(format),tostring(color_on),
        clip and (clip.x..','..clip.y..','..clip.w..','..clip.h) or 'full',tostring(scale)))
    return 1
end

local count=0
local clips={false,{x=35,y=40,w=170,h=170},{x=210,y=145,w=115,h=125},{x=0,y=0,w=55,h=55}}
for _,kind in ipairs({'rectangle','triangle','bowtie'}) do
    for _,angle in ipairs({0,23,89,137,181,337}) do
        for _,filled in ipairs({false,true}) do
            for _,reverse_order in ipairs({false,true}) do
                for _,format in ipairs({BB.TYPE_BB8,BB.TYPE_BBRGB32}) do
                    for _,color_on in ipairs({false,true}) do
                        for _,clip in ipairs(clips) do
                            count=count+verify(kind,angle,filled,reverse_order,format,color_on,clip,false)
                        end
                        count=count+verify(kind,angle,filled,reverse_order,format,color_on,false,2)
                    end
                end
            end
        end
    end
end
print('exact-byte cases passed: '..count)

os.remove(settings_path)
if Device.input and Device.input.teardown then Device.input:teardown() end
