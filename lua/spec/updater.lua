package.path="./?.lua;./spec/?.lua;"..package.path
require("support").installStubs()
local fs={["/plugins"]={mode="directory"},["/plugins/notebook.koplugin"]={mode="directory"},
 ["/plugins/notebook.koplugin/old.lua"]={mode="file"},["/plugins/stage"]={mode="directory"},
 ["/plugins/stage/main.lua"]={mode="file"}}
require("uistubs").install(fs)
local Policy=require("updatepolicy")
assert(Policy.newer("v1.5.0","v1.5.0-dev.3"))
assert(not Policy.newer("v1.4.0","v1.5.0-dev.3"))
assert(Policy.newer("v1.10.0","v1.9.9"))
assert(not Policy.newer("v1.5.0-dev.4","v1.4.0"))
local release={tag_name="v1.5.0",draft=false,prerelease=false,assets={{
 name="notebook.koplugin-v1.5.0.zip",state="uploaded",size=123,
 browser_download_url="https://github.com/pierspad/notebook.koplugin/releases/download/v1.5.0/notebook.koplugin-v1.5.0.zip",
 digest="sha256:"..string.rep("a",64)}}}
assert(Policy.release(release))
release.prerelease=true;assert(not Policy.release(release));release.prerelease=false
release.tag_name="v1.5.0-dev.1";assert(not Policy.release(release));release.tag_name="v1.5.0"
release.assets[1].digest=nil;assert(not Policy.release(release))
for _,p in ipairs({"/etc/passwd","notebook.koplugin/../x","notebook.koplugin/a/../../x",
 "notebook.koplugin/a\\b","notebook.koplugin/./x","notebook.koplugin/a//b","other/main.lua"}) do
 assert(not Policy.entry(p,"file"),p)
end
assert(not Policy.entry("notebook.koplugin/link","link"))
assert(Policy.entry("notebook.koplugin/locale/it.po","file")=="locale/it.po")
assert(Policy.due(100,200) and Policy.due(Policy.WEEK,0) and not Policy.due(100,99))
local Installer=require("updateinstaller")
local rename=os.rename
os.rename=function(from,to)
 if from=="/plugins/stage" then return nil,"injected rename failure" end
 return rename(from,to)
end
assert(not Installer.install("/plugins/notebook.koplugin","/plugins/stage","/plugins/backup"))
assert(fs["/plugins/notebook.koplugin/old.lua"] and not fs["/plugins/backup"],"rollback lost original package")
os.rename=rename
assert(Installer.install("/plugins/notebook.koplugin","/plugins/stage","/plugins/backup"))
assert(fs["/plugins/notebook.koplugin/main.lua"] and fs["/plugins/backup/old.lua"])
assert(not fs["/plugins/notebook.koplugin/old.lua"],"orphan files survived replacement")
assert(not Installer.install("/plugins/notebook.koplugin","/plugins/stage","/plugins/backup"))
local Transport=require("updatetransport")
fs["/cache"]={mode="directory"}
fs["/cache/1-1"]={mode="file",modification=0}
fs["/cache/1-2"]={mode="file",modification=100000}
fs["/cache/unrelated"]={mode="file",modification=0}
fs["/cache/1-3"]={mode="link",modification=0}
local remove=os.remove
os.remove=function(path) fs[path]=nil;return true end
Transport.sweep("/cache",100001)
os.remove=remove
assert(not fs["/cache/1-1"] and fs["/cache/1-2"] and fs["/cache/unrelated"] and fs["/cache/1-3"],"stale transfer cleanup exceeded its scope")
local cmd=Transport.command("https://example.test/a?x=';touch /tmp/unsafe", "/tmp/a'b",123)
assert(cmd:find("'--proto' '=https'",1,true) and cmd:find("'--proto-redir' '=https'",1,true))
assert(cmd:find("'--max-time' '60'",1,true) and cmd:find("'--max-filesize' '123'",1,true))
assert(cmd:find("'\"'\"'",1,true),"shell apostrophe not escaped")
local settings={}
G_reader_settings={readSetting=function(_,k) return settings[k] end,
 saveSetting=function(_,k,v) settings[k]=v end,flush=function() end}
local scheduled={}
package.loaded["ui/uimanager"].scheduleIn=function(_,delay,callback) scheduled[#scheduled+1]={delay,callback} end
local online=false;local prompted=false;local calls=0
package.loaded["ui/network/manager"]={isOnline=function() return online end,
 runWhenOnline=function(_,callback) prompted=true;callback() end}
package.loaded.util={makePath=function() end}
Transport.fetch=function(_,_,_,_,callback) calls=calls+1;callback(nil,"offline") end
local Updater=require("updater")
Updater.start("/plugins/notebook.koplugin");Updater.start("/plugins/notebook.koplugin")
assert(#scheduled==2,"duplicate startup scheduled two weekly timers")
scheduled[1][2]();assert(calls==0 and not prompted,"automatic check woke network")
online=true
scheduled[1][2]();assert(calls==1 and not prompted)
scheduled[1][2]();assert(calls==1,"failed automatic checks are not throttled")
Updater.check(true);assert(calls==2 and prompted and not Updater.busy)
settings.notebook_update_weekly=false
settings.notebook_update_attempt=nil
scheduled[1][2]();assert(calls==2,"disabled weekly checks ran")

print("updater: stable policy, rollback/orphan removal, HTTPS quoting, weekly/offline scheduling and retry guards passed")
