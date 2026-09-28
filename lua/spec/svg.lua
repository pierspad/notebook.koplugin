local support=require('spec/support')
support.installStubs()
local Svg=require('svg')
local Stroke=require('stroke')
local path=os.tmpname()
local function read()
    local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s
end
local stroke=Stroke:new{width=8,color=0x1ff0000,pen_style='fountain'}
stroke:addPoint(12,23,0.2);stroke:addPoint(42,53,1)
local doc={page_size={w=100,h=200},contentOrigin=function() return 2,3 end,
    pages={{strokes={stroke,{text='A < B & "C"\nsecond',x_min=3,y_min=4,x_max=80,y_max=90,
        font_size=12,text_bold=true,text_italic=true,text_underline=true,text_background=true}}},
        {strokes={}}}}
assert(Svg.toSVG(doc,path))
local s=read()
assert(s:find('viewBox="0 0 100 400"',1,true))
assert(s:find('id="page-2" y="200"',1,true))
assert(s:find('translate(-2 -3)',1,true))
assert(s:find('#ff0000',1,true) and s:find('<polygon',1,true) and s:find('<circle',1,true))
assert(s:find('A &lt; B &amp; &quot;C&quot;',1,true))
assert(s:find('font-weight="bold"',1,true) and s:find('text-decoration="underline"',1,true))
assert(s:find('fill="white"',1,true))
local marker=Stroke:new{tool='highlighter',width=20,tint=0x100ff00}
marker:addPoint(1,2);marker:addPoint(20,2)
assert(Svg.toSVG({pages={{strokes={marker}}},contentOrigin=function() return 0,100 end},path))
assert(read():find('#00ff00',1,true) and read():find('opacity="0.4"',1,true))
assert(read():find('viewBox="0 0 1860 2380"',1,true))
assert(Svg.toSVG(doc,path))
-- Compact constant-width output must not flatten genuine pressure changes.
local fine=Stroke:new{width=8,pen_style='fineliner'}
fine:addPoint(1,1,1);fine:addPoint(5,5,1);fine:addPoint(10,1,1)
assert(Svg.toSVG({pages={{strokes={fine}}}},path))
assert(read():find('<polyline',1,true) and read():find('stroke-width="8"',1,true))
fine:addPoint(20,2,0.2)
assert(Svg.toSVG({pages={{strokes={fine}}}},path))
assert(not read():find('<polyline',1,true) and read():find('<polygon',1,true))
assert(Svg.toSVG(doc,path))
-- Failed writes must not destroy an existing export or leave a partial SVG.
local old=s
stroke.getPoint=function() error('broken stroke') end
assert(not Svg.toSVG(doc,path))
assert(read()==old and io.open(path..'.tmp')==nil)
assert(not Svg.toSVG({pages={}},path))
assert(not Svg.toSVG({pages={{}},page_size={w=0,h=1}},path))
os.remove(path)
local ui=require('spec/uistubs')
local rec=ui.install({['/data']={mode='directory'},['/data/notebook']={mode='directory'},
    ['/data/notebook/Example.svg']={mode='file',modification=1,size=100}})
local Library=require('library')
local items=Library.list('')
assert(#items==1 and items[1].is_svg and items[1].is_export and items[1].extension=='svg')
local Gallery=require('gallery')
local g=Gallery:new{}
g.on_open=function() error('SVG opened as a notebook') end
g:_open(items[1])
assert(rec.shown[#rec.shown].text=='Open this SVG file in a browser or vector editor.')
print('PASS SVG geometry, text, clipping, atomic failure and gallery integration')
