package.path='./?.lua;./spec/?.lua;'..package.path
local Writer=require('gzipwriter')
local path=os.tmpname()
local bytes={};for i=0,255 do bytes[#bytes+1]=string.char(i) end
local source=table.concat(bytes):rep(1100)
for _,length in ipairs({0,1,65534,65535,65536,131070,262145}) do
    local data=source:sub(1,length)
    local file=assert(io.open(path,'wb'))
    local stream=Writer.new(function(chunk)
        assert(#chunk<=65535,'gzip wrote an unbounded payload')
        assert(file:write(chunk))
    end)
    for at=1,#data,7919 do stream:write(data:sub(at,at+7918)) end
    stream:finish();assert(file:close())
    assert(not pcall(function() stream:finish() end),'gzip accepted duplicate finish')
    assert(not pcall(function() stream:write('x') end),'gzip accepted data after its trailer')
    -- Decode with the external gzip implementation, including CRC32/ISIZE checking.
    local pipe=assert(io.popen('gzip -dc '..path,'r'))
    local decoded=pipe:read('*a');local ok=pipe:close()
    assert(ok and decoded==data,'gzip changed bytes at block boundary '..length)
end
os.remove(path)
print('gzipwriter: independent decoding, empty/exact/partial blocks, every byte and bounded writes passed')
