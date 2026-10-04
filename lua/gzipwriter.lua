-- Streaming gzip with stored DEFLATE blocks; temporary payload never exceeds 64 KiB.
local bit=require("bit")
local Writer={}
Writer.__index=Writer
local crc_table={}
for i=0,255 do
    local value=i
    for _=1,8 do
        value=bit.bxor(bit.rshift(value,1),bit.band(value,1)~=0 and 0xedb88320 or 0)
    end
    crc_table[i+1]=value
end
local function u32(n)
    return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)
end
function Writer.new(write)
    write("\31\139\8\0\0\0\0\0\0\255")
    return setmetatable({sink=write,parts={},length=0,size=0,crc=0xffffffff},Writer)
end
function Writer:_flush(final)
    local n=self.length
    self.sink(string.char(final and 1 or 0,n%256,math.floor(n/256),(65535-n)%256,math.floor((65535-n)/256)))
    if n>0 then self.sink(table.concat(self.parts)) end
    self.parts,self.length={},0
end
function Writer:write(data)
    assert(not self.finished,"gzip stream already finished")
    local crc=self.crc
    for i=1,#data do
        local index=bit.band(bit.bxor(crc,data:byte(i)),255)+1
        crc=bit.bxor(bit.rshift(crc,8),crc_table[index])
    end
    self.crc=crc;self.size=(self.size+#data)%4294967296
    local at=1
    while at<=#data do
        local n=math.min(65535-self.length,#data-at+1)
        self.parts[#self.parts+1]=data:sub(at,at+n-1)
        self.length=self.length+n;at=at+n
        if self.length==65535 then self:_flush(false) end
    end
end
function Writer:finish()
    assert(not self.finished,"gzip stream already finished")
    self:_flush(true)
    self.sink(u32(bit.band(bit.bnot(self.crc),0xffffffff))..u32(self.size))
    self.finished=true
end
return Writer
