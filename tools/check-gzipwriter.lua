-- Native zlib and portable gzip paths must produce identical bytes, even after GC.
-- From a KOReader runtime: ./luajit THIS PLUGIN_LUA
require("setupkoenv")
local directory=assert(arg[1])
local Writer=dofile(directory.."/loader.lua")(directory)("gzipwriter")
local chunk=assert(loadfile(directory.."/gzipwriter.lua"))
setfenv(chunk,setmetatable({require=function(name)
    if name=="ffi/zlib_h" then error("binding unavailable") end
    return require(name)
end},{__index=_G}))
local Portable=chunk()
local function encode(module,data,step)
    local chunks={}
    local stream=module.new(function(part)
        assert(#part<=65535,"unbounded gzip payload")
        chunks[#chunks+1]=part
    end)
    -- A native function pointer alone must not outlive the library handle.
    collectgarbage("collect");collectgarbage("collect")
    for at=1,#data,step do stream:write(data:sub(at,at+step-1)) end
    stream:write("")
    stream:finish()
    return table.concat(chunks),stream.update_crc
end
local bytes={};for i=0,255 do bytes[#bytes+1]=string.char(i) end
local source=table.concat(bytes):rep(1100)
local checks=0
for _,length in ipairs({0,1,65534,65535,65536,131070,262145}) do
    for _,step in ipairs({1,127,7919,65535}) do
        local data=source:sub(1,length)
        local actual,native=encode(Writer,data,step)
        local portable,fallback=encode(Portable,data,step)
        assert(native and not fallback,"native/fallback branch not exercised")
        assert(actual==portable,"native CRC changed gzip bytes")
        checks=checks+1
    end
end
print("Native gzip: "..checks.." exact byte comparisons, bounded writes and GC lifetime passed")
