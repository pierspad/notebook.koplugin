-- Image metadata and bounded base64 encoding, independent of native raster ownership.
local ffi=require("ffi")
local Codec={MAX_BYTES=4*1024*1024,MAX_PIXELS=8*1024*1024}
local function be(data,i,n)
    local value=0
    for k=i,i+n-1 do local b=data:byte(k);if not b then return nil end;value=value*256+b end
    return value
end
function Codec.info(data)
    if type(data)~="string" or #data>Codec.MAX_BYTES then return nil end
    local w,h,mime
    if data:sub(1,8)=="\137PNG\r\n\26\n" and data:sub(13,16)=="IHDR" then
        w,h,mime=be(data,17,4),be(data,21,4),"image/png"
    elseif data:sub(1,2)=="\255\216" then
        local i=3
        while i<#data do
            if data:byte(i)~=255 then return nil end
            while data:byte(i)==255 do i=i+1 end
            local marker=data:byte(i);i=i+1
            if marker==217 or marker==218 then break end
            local length=be(data,i,2)
            if not length or length<2 or i+length-1>#data then return nil end
            if marker==192 or marker==193 or marker==194 then
                if length<8 then return nil end
                h,w,mime=be(data,i+3,2),be(data,i+5,2),"image/jpeg";break
            end
            i=i+length
        end
    end
    if not w or not h or w<1 or h<1 or w*h>Codec.MAX_PIXELS then return nil end
    return w,h,mime
end
-- Each chunk uses a fixed 16 KiB output buffer rather than one Lua string
-- and table slot per three input bytes. A writer can stream chunks directly.
function Codec.base64(data,write)
    local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local result=not write and {} or nil
    local buffer=ffi.new("uint8_t[16384]")
    for first=1,#data,12288 do
        local last=math.min(#data,first+12287)
        local offset=0
        for i=first,last,3 do
            local a,b,c=data:byte(i,math.min(i+2,last))
            local n=a*65536+(b or 0)*256+(c or 0)
            buffer[offset]=alphabet:byte(math.floor(n/262144)+1)
            buffer[offset+1]=alphabet:byte(math.floor(n/4096)%64+1)
            buffer[offset+2]=b and alphabet:byte(math.floor(n/64)%64+1) or 61
            buffer[offset+3]=c and alphabet:byte(n%64+1) or 61
            offset=offset+4
        end
        local chunk=ffi.string(buffer,offset)
        if write then write(chunk) else result[#result+1]=chunk end
    end
    if result then return table.concat(result) end
end
return Codec
