-- Verified ZIP staging and directory replacement. Never touches the library.
local Policy = require("updatepolicy")
local lfs = require("libs/libkoreader-lfs")
local M = {}

function M.removeTree(path)
    local mode=lfs.symlinkattributes(path,"mode")
    if not mode then return true end
    if mode~="directory" then return os.remove(path) end
    for name in lfs.dir(path) do
        if name~="." and name~=".." then
            local ok,err=M.removeTree(path.."/"..name)
            if not ok then return nil,err end
        end
    end
    return lfs.rmdir(path)
end
local function mkdir(path)
    if lfs.symlinkattributes(path,"mode")=="directory" then return true end
    return lfs.mkdir(path)
end
local function parents(root,rel)
    local path=root
    for name in rel:gmatch("([^/]+)/") do
        path=path.."/"..name
        if not mkdir(path) then return nil,"Cannot create staging directory" end
    end
    return true
end
function M.prepare(zip,stage,release)
    if lfs.symlinkattributes(stage) then return nil,"Staging path already exists" end
    local file,err=io.open(zip,"rb")
    if not file then return nil,err end
    local hash=require("ffi/sha2").sha256()
    local size=0
    while true do
        local chunk=file:read(65536)
        if not chunk then break end
        size=size+#chunk
        if size>Policy.MAX_ZIP then file:close();return nil,"ZIP exceeds size limit" end
        hash(chunk)
    end
    file:close()
    if size~=release.size or hash()~=release.digest then return nil,"ZIP checksum or size mismatch" end
    if not mkdir(stage) then return nil,"Cannot create staging directory" end
    local reader=require("ffi/archiver").Reader:new()
    local opened=reader:open(zip)
    if not opened then M.removeTree(stage);return nil,"Cannot open ZIP" end
    local seen,bytes,count={},0,0
    local ok,failure=pcall(function()
        for entry in reader:iterate() do
            local rel=Policy.entry(entry.path,entry.mode)
            assert(rel~=nil,"Unsafe archive entry")
            assert(not seen[rel],"Duplicate archive entry")
            seen[rel]=entry.mode
            count=count+1
            assert(count<=512,"Too many archive entries")
            local n=tonumber(entry.size)
            assert(n and n>=0 and n%1==0,"Invalid archive entry size")
            bytes=bytes+n
            assert(bytes<=32*1024*1024,"Unpacked archive exceeds size limit")
            if rel~="" then
                assert(parents(stage,rel))
                if entry.mode=="directory" then assert(mkdir(stage.."/"..rel))
                else
                    -- No links are accepted and stage started as a fresh directory.
                    assert(reader:extractToPath(entry.path,stage.."/"..rel),"ZIP extraction failed")
                    if rel:match("%.lua$") then
                        assert(loadfile(stage.."/"..rel),"Invalid Lua source")
                    end
                end
            end
        end
        assert(not reader.err,"Damaged ZIP")
        assert(seen["main.lua"]=="file" and seen["_meta.lua"]=="file"
            and seen["locale"]=="directory" and seen["icons"]=="directory","Incomplete plugin package")
        local meta=assert(io.open(stage.."/_meta.lua","rb"))
        local content=meta:read("*a");meta:close()
        assert(content:match('version%s*=%s*"([^"]+)"')==release.tag,"Package version differs from release")
    end)
    reader:close()
    if not ok then M.removeTree(stage);return nil,tostring(failure) end
    return true
end
function M.install(plugin,stage,backup)
    if not plugin:match("/notebook%.koplugin$") or plugin==stage or plugin==backup then
        return nil,"Unexpected plugin directory"
    end
    if lfs.symlinkattributes(plugin,"mode")~="directory"
        or lfs.symlinkattributes(stage,"mode")~="directory"
        or lfs.symlinkattributes(plugin.."/.git") then return nil,"Not an installed plugin" end
    if lfs.symlinkattributes(backup) then
        return nil,"A previous backup exists; restart KOReader before updating again"
    end
    local ok,err=os.rename(plugin,backup)
    if not ok then return nil,err end
    ok,err=os.rename(stage,plugin)
    if not ok then
        local restored,restore_err=os.rename(backup,plugin)
        if not restored then return nil,"Rollback failed: "..tostring(restore_err).."; backup: "..backup end
        return nil,err
    end
    -- Keep the complete previous package until the next successful startup.
    return true
end
return M
