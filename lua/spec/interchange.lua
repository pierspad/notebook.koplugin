package.path='./?.lua;./spec/?.lua;'..package.path
local support=require('support'); support.installStubs()
local Stroke=require('stroke')
local Xopp=require('xopp')
local invalid_path=os.tmpname()
local previous=assert(io.open(invalid_path,'wb'));previous:write('previous export');previous:close()
local invalid={pages={{strokes={}}},page_size={w=math.huge,h=100},templateFor=function() return 'blank' end}
assert(not Xopp.toXOPP(invalid,invalid_path),'nonfinite page dimensions exported')
previous=assert(io.open(invalid_path,'rb'));assert(previous:read('*a')=='previous export');previous:close()
os.remove(invalid_path)
local function temporary()
    local path=os.tmpname();os.remove(path);return path..'.xopp'
end
local text=Stroke:new{tool='text',shape_kind='text',text='A < B & C',font_size=26,
    font_family='mono',text_bold=true,text_italic=true,text_underline=true,text_background=true}
text:addPoint(100,150); text:addPoint(500,210)
local ink=Stroke:new{width=8}; ink:addPoint(100,300,.2); ink:addPoint(500,350,.8)
local marker=Stroke:new{tool='highlighter',filled=true,width=30,tint=160,marker_parts={4,8}}
marker:addPoint(10,20);marker:addPoint(50,20);marker:addPoint(50,40);marker:addPoint(10,40)
marker:addPoint(80,80);marker:addPoint(100,80);marker:addPoint(100,100);marker:addPoint(80,100)
local clone=Stroke:deserialize(text:serialize())
assert(clone.text==text.text and clone.font_size==26 and clone.font_family=='mono'
    and clone.text_bold and clone.text_italic and clone.text_underline and clone.text_background,
    'text metadata did not round trip')
local doc={pages={{strokes={text,ink,marker}}},page_size={w=1000,h=1400},templateFor=function() return 'grid' end}
local path=temporary()
assert(Xopp.toXOPP(doc,path))
assert(os.execute('gzip -t '..path)==0,'XOPP is not valid gzip')
local pipe=assert(io.popen('gzip -dc '..path,'r')); local xml=pipe:read('*a'); pipe:close()
assert(xml:match('<xournal') and xml:match('<stroke') and xml:match('<text'),'XOPP objects missing')
assert(xml:match('font="Monospace"'),'XOPP text family missing')
assert(xml:match('A &lt; B &amp; C'),'XOPP text is not escaped')
assert(xml:match('style="graph"'),'page template not exported')
assert(xml:find('tool="highlighter"',1,true) and xml:find('width="0.001" fill="255"',1,true),
    'erased marker exported as a thick polygon outline')
local _,filled_count=xml:gsub('fill="255"','')
assert(filled_count==2,'XOPP joined marker contours or lost one of them')
os.remove(path)
local pdf=os.tmpname()
local pdf_file=assert(io.open(pdf,'wb')); pdf_file:write('%PDF-test'); pdf_file:close()
local attached_path=temporary()
local overlay=Stroke:new{width=4}; overlay:addPoint(0,200); overlay:addPoint(1000,1200)
local attached={pages={{strokes={overlay},background={file=pdf,page=1,size={w=600,h=800}}}},
    page_size={w=1000,h=1400},contentOrigin=function() return 0,100 end,
    templateFor=function() return 'blank' end}
local ok,companion=Xopp.toXOPP(attached,attached_path)
assert(ok and companion==attached_path..'.bg.pdf','attached PDF companion path is wrong')
local companion_file=assert(io.open(companion,'rb'));local companion_data=companion_file:read('*a');companion_file:close()
assert(companion_data=='%PDF-test','attached PDF was not copied')
local attached_pipe=assert(io.popen('gzip -dc '..attached_path,'r'))
local attached_xml=attached_pipe:read('*a'); attached_pipe:close()
assert(attached_xml:match('domain="attach" filename="bg.pdf"'),
    'XOPP does not use the Xournal++ attached-PDF convention')
assert(attached_xml:match('<page width="600%.000" height="800%.000">'),
    'attached PDF native proportions were not preserved')
assert(attached_xml:match('0%.000 40%.000 600%.000 640%.000'),
    'letterbox and content origin were not removed from overlay coordinates')
os.remove(pdf); os.remove(attached_path); os.remove(companion)
-- Large interchange documents cross stored-DEFLATE block boundaries. Verify
-- the byte checksum independently and bound checksum work per input byte.
local big=Stroke:new{tool='text',shape_kind='text',font_size=24,
    text=string.rep('Caffè < & > " ',12000)}
big:addPoint(0,0); big:addPoint(500,100)
local large={pages={{strokes={big}}},templateFor=function() return 'blank' end}
local large_path=temporary()
local bit=require('bit')
local shift, shifts=bit.rshift,0
bit.rshift=function(...) shifts=shifts+1; return shift(...) end
local generated,reason=pcall(Xopp.toXOPP,large,large_path)
bit.rshift=shift
assert(generated and reason,'large XOPP failed')
local file=assert(io.open(large_path,'rb')); local compressed=file:read('*a'); file:close()
local parts,at={},11
while true do
    local final=compressed:byte(at)
    local n=compressed:byte(at+1)+compressed:byte(at+2)*256
    local inverse=compressed:byte(at+3)+compressed:byte(at+4)*256
    assert(n+inverse==65535,'invalid stored block length')
    parts[#parts+1]=compressed:sub(at+5,at+4+n)
    at=at+5+n
    if final==1 then break end
    assert(final==0,'invalid DEFLATE block header')
end
local payload=table.concat(parts)
local function u32(n)
    return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end
local crc=0xffffffff
for i=1,#payload do
    crc=bit.bxor(crc,payload:byte(i))
    for _=1,8 do crc=bit.bxor(shift(crc,1),bit.band(crc,1)~=0 and 0xedb88320 or 0) end
end
assert(compressed:sub(at)==u32(bit.bnot(crc))..u32(#payload),'CRC32/ISIZE changed')
assert(payload:find('Caffè &lt; &amp; &gt; &quot;',1,true),'large Unicode text changed')
assert(os.execute('gzip -t '..large_path)==0,'large XOPP is not valid gzip')
os.remove(large_path)
assert(shifts<=#payload+4096,'CRC checksum repeats eight bit steps for every byte')
print('interchange XOPP and editable text: metadata, PDF coordinates, large gzip blocks and CRC32 passed')
