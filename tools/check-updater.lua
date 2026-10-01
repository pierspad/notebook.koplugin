-- Native end-to-end updater probe in disposable directories only.
-- ./luajit CHECK_LUA PLUGIN_LUA TEMP_DIR [--network]
require("setupkoenv")
local load=dofile(assert(arg[1]).."/loader.lua")(arg[1])
local tmp=assert(arg[2])
local lfs=require("libs/libkoreader-lfs")
local sha=require("ffi/sha2")
local json=require("json")
local Installer,Policy=load("updateinstaller"),load("updatepolicy")
local function read(path) local f=assert(io.open(path,"rb"));local data=f:read("*a");f:close();return data end
local function write(path,data) local f=assert(io.open(path,"wb"));assert(f:write(data));assert(f:close()) end
local function release(path,tag) local data=read(path);return {size=#data,digest=sha.sha256(data),tag=tag} end
local function check(zip,tag,good)
    local stage=tmp.."/stage"
    Installer.removeTree(stage)
    local ok,err=Installer.prepare(zip,stage,release(zip,tag))
    assert((ok==true)==good,tostring(err))
    assert(good or not lfs.symlinkattributes(stage),"failed package left staging files")
    return stage
end
check(tmp.."/valid.zip","v9.9.9",true)
check(tmp.."/valid.zip","v9.9.8",false)
for _,name in ipairs({"traversal","symlink","duplicate","invalid-lua","missing-main","oversize"}) do
    check(tmp.."/"..name..".zip","v9.9.9",false)
end
local valid=release(tmp.."/valid.zip","v9.9.9");valid.digest=string.rep("0",64)
assert(not Installer.prepare(tmp.."/valid.zip",tmp.."/checksum-stage",valid))
local stage=check(tmp.."/valid.zip","v9.9.9",true)
local plugin,backup=tmp.."/notebook.koplugin",tmp.."/backup"
assert(lfs.mkdir(plugin));write(plugin.."/old.lua","old version")
local rename=os.rename
os.rename=function(from,to) if from==stage then return nil,"injected replacement failure" end;return rename(from,to) end
assert(not Installer.install(plugin,stage,backup));assert(read(plugin.."/old.lua")=="old version")
os.rename=rename
assert(Installer.install(plugin,stage,backup));assert(read(backup.."/old.lua")=="old version")
assert(not lfs.attributes(plugin.."/old.lua") and lfs.attributes(plugin.."/main.lua"))
print("Native updater: checksum, archive paths/links/duplicates/limits/syntax/version, replacement and rollback passed")
if arg[3]=="--network" then
    -- Exercise the production background transport without running the UI loop.
    local pending={}
    package.loaded["ui/uimanager"]={scheduleIn=function(_,delay,callback) pending[#pending+1]={delay,callback} end}
    local Transport=load("updatetransport")
    local function fetch(url,path,limit)
        local finished,received,failure=false
        Transport.fetch(url,path,limit,require("datastorage"):getDataDir().."/data/ca-bundle.crt",function(p,err)
            finished,received,failure=true,p,err
        end)
        while not finished do
            local task=assert(table.remove(pending,1));require("socket").sleep(task[1]);task[2]()
        end
        assert(received,tostring(failure));return received
    end
    local path=fetch(Policy.API,tmp.."/release.json",1024*1024)
    local official=assert(Policy.release(json.decode(read(path))))
    path=fetch(official.url,tmp.."/official.zip",Policy.MAX_ZIP)
    assert(Installer.prepare(path,tmp.."/official-stage",official))
    -- Install an actual older official archive, then replace it with latest.
    -- This directory is disposable and independent of the running plugin.
    local from_tag=arg[4] or "v1.4.0"
    assert(from_tag:match("^v%d+%.%d+%.%d+$"),"invalid source release tag")
    local old_api=Policy.API:gsub("/latest$","/tags/"..from_tag)
    local old=assert(Policy.release(json.decode(read(fetch(old_api,tmp.."/old-release.json",1024*1024)))))
    assert(Policy.newer(official.tag,old.tag),"latest release is not newer")
    local old_zip=fetch(old.url,tmp.."/old-official.zip",Policy.MAX_ZIP)
    assert(Installer.prepare(old_zip,tmp.."/old-stage",old))
    assert(lfs.mkdir(tmp.."/released"))
    local installed=tmp.."/released/notebook.koplugin"
    assert(os.rename(tmp.."/old-stage",installed))
    write(installed.."/obsolete-test.lua","return true")
    assert(Installer.install(installed,tmp.."/official-stage",tmp.."/released-backup"))
    assert(assert(loadfile(installed.."/_meta.lua"))().version==official.tag)
    assert(assert(loadfile(tmp.."/released-backup/_meta.lua"))().version==old.tag)
    assert(not lfs.attributes(installed.."/obsolete-test.lua"))
    print("Official stable update "..old.tag.." -> "..official.tag..": verified, installed and backup preserved in disposable storage")
end
