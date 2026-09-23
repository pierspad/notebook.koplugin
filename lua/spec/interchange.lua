package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support'); support.installStubs()
local Stroke=require('stroke')
local Xopp=require('xopp')
local text=Stroke:new{tool='text',shape_kind='text',text='A < B & C',font_size=26,
    font_family='mono',text_bold=true,text_italic=true,text_underline=true}
text:addPoint(100,150); text:addPoint(500,210)
local ink=Stroke:new{width=8}; ink:addPoint(100,300,.2); ink:addPoint(500,350,.8)
local clone=Stroke:deserialize(text:serialize())
assert(clone.text==text.text and clone.font_size==26 and clone.font_family=='mono'
    and clone.text_bold and clone.text_italic and clone.text_underline,
    'text metadata did not round trip')
local doc={pages={{strokes={text,ink}}},page_size={w=1000,h=1400},templateFor=function() return 'grid' end}
local path=os.tmpname()..'.xopp'
assert(Xopp.toXOPP(doc,path))
assert(os.execute('gzip -t '..path)==0,'XOPP is not valid gzip')
local pipe=assert(io.popen('gzip -dc '..path,'r')); local xml=pipe:read('*a'); pipe:close()
assert(xml:match('<xournal') and xml:match('<stroke') and xml:match('<text'),'XOPP objects missing')
assert(xml:match('font="Monospace"'),'XOPP text family missing')
assert(xml:match('A &lt; B &amp; C'),'XOPP text is not escaped')
assert(xml:match('style="graph"'),'page template not exported')
os.remove(path)
print('interchange XOPP and editable text passed')
