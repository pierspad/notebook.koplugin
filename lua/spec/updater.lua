package.path="./?.lua;./spec/?.lua;"..package.path
require("support").installStubs()
local fs={["/plugins"]={mode="directory"},["/plugins/notebook.koplugin"]={mode="directory"},
 ["/plugins/notebook.koplugin/old.lua"]={mode="file"},["/plugins/stage"]={mode="directory"},
 ["/plugins/stage/main.lua"]={mode="file"}}
local rec=require("uistubs").install(fs)
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
local function published(tag, prerelease)
 return {tag_name=tag,draft=false,prerelease=prerelease,assets={{
  name="notebook.koplugin-"..tag..".zip",state="uploaded",size=123,
  browser_download_url="https://github.com/pierspad/notebook.koplugin/releases/download/"..tag.."/notebook.koplugin-"..tag..".zip",
  digest="sha256:"..string.rep("a",64)}}}
end
local dev=published("v1.8.0-dev.10",true)
assert(not Policy.release(dev),"prerelease accepted by default")
assert(Policy.release(dev,true),"explicit prerelease opt-in ignored")
assert(not Policy.newer(dev.tag_name,"v1.7.2"),"default channel offers prerelease")
assert(Policy.newer(dev.tag_name,"v1.7.2",true))
assert(Policy.newer("v1.8.0-dev.10","v1.8.0-dev.9",true),"numeric identifier comparison")
assert(not Policy.newer("v1.8.0-dev.9","v1.8.0-dev.10",true),"prerelease downgrade")
assert(not Policy.newer("v1.8.0-dev.10","v1.8.0",true),"stable downgraded to same-version prerelease")
assert(Policy.newer("v1.8.0","v1.8.0-dev.10",true),"stable promotion missing")
assert(not Policy.newer("v1.8.0-dev.10","v1.8.0-dev.10",true))
assert(Policy.newer("v1.8.0-beta.1","v1.8.0-alpha.9",true))
assert(Policy.newer("v1.8.0-dev.1.1","v1.8.0-dev.1",true))
assert(not Policy.newer("v1.8.0-dev..1","v1.7.2",true))
assert(not Policy.newer("v1.8.0-dev.01","v1.7.2",true))
dev.draft=true;assert(not Policy.release(dev,true));dev.draft=false
dev.prerelease=false;assert(not Policy.release(dev,true));dev.prerelease=true
local stable=published("v1.8.0",false)
local invalid=published("v9.0.0-dev.1",true);invalid.assets[1].digest=nil
local chosen=assert(Policy.select({dev,invalid,stable},true))
assert(chosen.tag==stable.tag_name,"release order supersedes version order")
assert(Policy.select({dev,stable},false).tag==stable.tag_name)
assert(not Policy.select({dev},false),"stable channel leaked prerelease")
assert(Policy.select({stable,dev},true).tag==stable.tag_name)
dev.assets[1].browser_download_url="https://example.test/unsafe.zip"
assert(not Policy.release(dev,true),"prerelease bypassed download validation")

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

-- Both menu defaults and real asynchronous checks honor explicit opt-in.
Updater.showMenu()
local menu=rec.shown[#rec.shown]
local dirty=#rec.dirty
menu.on_dismiss()
assert(#rec.dirty==dirty+1 and rec.dirty[#rec.dirty].widget=="all","Updates dismissal leaves stale pixels")
assert(not menu.actions[2].selected(),"prerelease menu enabled by default")
menu.actions[2].callback();assert(settings.notebook_update_prereleases==true)
menu.actions[2].callback();assert(settings.notebook_update_prereleases==false)
local response=published("v9.9.9-dev.10",true)
local stableResponse=published("v9.9.8",false)
package.loaded["ui/widget/textviewer"]={new=function(_,options) return options end}
local pending,requested
Transport.fetch=function(url,_,_,_,callback) requested=url;pending=callback end
local decoded
package.loaded.json={decode=function() return decoded end}
local function finish(data)
 decoded=data
 local path=os.tmpname();local file=assert(io.open(path,"w"));file:write("{}");file:close()
 pending(path)
end
settings.notebook_update_prereleases=nil
Updater.check(true);assert(requested==Policy.API,"default used prerelease API")
finish(response)
assert(settings.notebook_update_notified==nil,"default offered prerelease")
settings.notebook_update_prereleases="true"
Updater.check(true);assert(requested==Policy.API,"non-boolean setting enabled prereleases")
finish(response)
settings.notebook_update_prereleases=true
Updater.check(true);assert(requested==Policy.API_ALL)
finish({response,stableResponse})
assert(settings.notebook_update_notified==response.tag_name,"opt-in failed to offer prerelease")
settings.notebook_update_notified=nil
Updater.check(true)
settings.notebook_update_prereleases=false
finish({response,stableResponse})
assert(settings.notebook_update_notified==stableResponse.tag_name,"disabled in-flight channel leaked prerelease")
Updater.install(assert(Policy.release(response,true)))
assert(not Updater.installed and not Updater.busy,"stale offer installed disabled prerelease")

local Notes=require("releasenotes")
assert(Notes.plain("### Changes\n* **Fix** [issue](https://example.org/1)\n[https://example.org](https://example.org)")=="Changes\n• Fix issue (https://example.org/1)\nhttps://example.org")

-- Exercise the real update-offer callback through the packaged private loader.
local private=dofile('loader.lua')('.')
local privateUpdater=private('updater')
local privateTransport=private('updatetransport')
local rawNotes='## [9.9.9](https://example.org/compare)\n\n### Fixes\n\n* **Fast** erasing'
private('updatepolicy').release=function() return {tag='v9.9.9',notes=rawNotes} end
package.loaded.json={decode=function() return {} end}
local viewer
package.loaded['ui/widget/textviewer']={html_text_formats={md=true},new=function(_,options)
 viewer=options;return options
end}
privateTransport.fetch=function(_,_,_,_,callback)
 local path=os.tmpname();local file=assert(io.open(path,'w'));file:write('{}');file:close()
 callback(path)
end
privateUpdater.check(true)
assert(viewer and viewer.text_format=='md','update offer does not enable native Markdown')
assert(viewer.text:find(rawNotes,1,true),'Markdown source must reach native renderer intact')
package.loaded['ui/widget/textviewer'].html_text_formats=nil
viewer=nil
privateUpdater.check(true)
assert(viewer and not viewer.text_format and not viewer.text:find('###',1,true),'old viewer fallback exposes Markdown')
