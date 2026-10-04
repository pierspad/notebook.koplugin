package.path='./?.lua;./spec/?.lua;'..package.path
local Codec=require('imagecodec')
for _,vector in ipairs({{'',''},{'f','Zg=='},{'fo','Zm8='},{'foo','Zm9v'},
    {'foob','Zm9vYg=='},{'fooba','Zm9vYmE='},{'foobar','Zm9vYmFy'}}) do
    assert(Codec.base64(vector[1])==vector[2],'known base64 vector failed')
end
local function reference(data)
    local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local out={}
    for i=1,#data,3 do
        local a,b,c=data:byte(i,i+2);local n=a*65536+(b or 0)*256+(c or 0)
        out[#out+1]=alphabet:sub(math.floor(n/262144)+1,math.floor(n/262144)+1)
            ..alphabet:sub(math.floor(n/4096)%64+1,math.floor(n/4096)%64+1)
            ..(b and alphabet:sub(math.floor(n/64)%64+1,math.floor(n/64)%64+1) or '=')
            ..(c and alphabet:sub(n%64+1,n%64+1) or '=')
    end
    return table.concat(out)
end
local bytes={};for i=0,255 do bytes[#bytes+1]=string.char(i) end
local source=table.concat(bytes):rep(100)
for _,size in ipairs({0,1,2,3,255,12287,12288,12289,24577,#source}) do
    local data=source:sub(1,size);local chunks={}
    Codec.base64(data,function(chunk) assert(#chunk<=16384);chunks[#chunks+1]=chunk end)
    local expected=reference(data)
    assert(table.concat(chunks)==expected and Codec.base64(data)==expected,'chunk boundary changed base64')
end
local count,total=0,0
Codec.base64(source:rep(164):sub(1,Codec.MAX_BYTES),function(chunk)
    count=count+1;total=total+#chunk;assert(#chunk<=16384)
end)
assert(count>300 and total==math.ceil(Codec.MAX_BYTES/3)*4,'large image was not streamed')
local w,h,mime=Codec.info('\255\216\255\192\0\8\8\0\10\0\20\0')
assert(w==20 and h==10 and mime=='image/jpeg')
assert(not Codec.info('\255\216\255\192\0\2\8\0\10\0\20'),'truncated JPEG segment accepted')
print('imagecodec: every byte, padding/chunk boundaries, bounded 4 MiB streaming and malformed JPEG passed')
