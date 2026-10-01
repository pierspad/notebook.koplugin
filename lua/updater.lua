-- Update UI and scheduling. Policy, transfers and package installation are separate.
local ActionMenu=require("actionmenu")
local ConfirmBox=require("ui/widget/confirmbox")
local InfoMessage=require("ui/widget/infomessage")
local UIManager=require("ui/uimanager")
local Policy=require("updatepolicy")
local Installer=require("updateinstaller")
local Transport=require("updatetransport")
local DataStorage=require("datastorage")
local lfs=require("libs/libkoreader-lfs")
local _=require("i18n")
local T=require("ffi/util").template
local version=require("_meta").version
local M={installed=false,busy=false}
local serial=0
local function message(text) UIManager:show(InfoMessage:new{text=text,timeout=6}) end
local function setting(key) return G_reader_settings:readSetting("notebook_update_"..key) end
local function save(key,value) G_reader_settings:saveSetting("notebook_update_"..key,value) end
local function paths()
    local parent=M.plugin_dir and M.plugin_dir:match("^(.+)/[^/]+$")
    return parent and parent.."/.notebook-update-stage",parent and parent.."/.notebook-update-backup"
end
local function transfer(url,limit,done)
    local root=DataStorage:getDataDir().."/cache/notebook-updates"
    require("util").makePath(root)
    Transport.sweep(root,os.time())
    serial=serial+1
    local path=root.."/"..tostring(os.time()).."-"..serial
    -- Never reuse an unfinished file, including one left by an interrupted run.
    while lfs.symlinkattributes(path) or lfs.symlinkattributes(path..".status.pending") do
        serial=serial+1;path=root.."/"..tostring(os.time()).."-"..serial
    end
    Transport.fetch(url,path,limit,DataStorage:getDataDir().."/data/ca-bundle.crt",done)
end
function M.install(release,owner)
    if M.busy or M.installed then return end
    local stage,backup=paths()
    if not stage or not M.plugin_dir:match("/notebook%.koplugin$") then
        message(_("Updates can only be installed in a packaged Notebook plugin."));return
    end
    if lfs.symlinkattributes(backup) then
        message(_("A previous update backup exists. Restart KOReader before updating again."));return
    end
    local cleaned,err=Installer.removeTree(stage)
    if not cleaned then message(tostring(err));return end
    M.busy=true
    M.installing=true
    message(_("Downloading Notebook update…"))
    transfer(release.url,Policy.MAX_ZIP,function(zip,error_text)
        if not zip then M.busy=false;M.installing=false;message(T(_("Update failed:\n%1"),tostring(error_text)));return end
        local ok,result,failure=pcall(Installer.prepare,zip,stage,release)
        os.remove(zip)
        if ok and result then
            -- The replacement itself is short and cannot be cancelled midway.
            ok,result,failure=pcall(Installer.install,M.plugin_dir,stage,backup)
        end
        M.busy=false
        M.installing=false
        if not ok or not result then
            Installer.removeTree(stage)
            message(T(_("Update failed:\n%1"),tostring(ok and failure or result)));return
        end
        M.installed=true
        save("installed",release.tag)
        G_reader_settings:flush()
        if owner and not owner.closed then UIManager:close(owner) end
        UIManager:show(ConfirmBox:new{
            text=_("Notebook update installed. Restart KOReader to use the new version."),
            ok_text=_("Restart"),cancel_text=_("Later"),
            ok_callback=function() UIManager:restartKOReader() end,
        })
    end)
end
local function offer(release,owner)
    -- TextViewer is resolved through KOReader, never through a new plugin file.
    local TextViewer=require("ui/widget/textviewer")
    local dialog
    dialog=TextViewer:new{
        title=_("Notebook update available"),
        text=version.." → "..release.tag.."\n\n"..release.notes,
        add_default_buttons=false,
        buttons_table={{
            {text=_("Later"),callback=function() UIManager:close(dialog) end},
            {text=_("Install"),callback=function() UIManager:close(dialog);M.install(release,owner) end},
        }},
    }
    UIManager:show(dialog)
end
function M.check(manual,owner)
    if M.busy or M.installed then return end
    local NetworkMgr=require("ui/network/manager")
    local function run()
        if M.busy or M.installed then return end
        M.busy=true
        save("attempt",os.time())
        if manual then message(_("Checking for Notebook updates…")) end
        transfer(Policy.API,1024*1024,function(path,err)
            M.busy=false
            local release
            if path then
                local file=io.open(path,"rb")
                local body=file and file:read("*a")
                if file then file:close() end
                os.remove(path)
                local ok,data=pcall(require("json").decode,body or "")
                if ok then release,err=Policy.release(data) else err="Invalid release response" end
            end
            if not release then
                if manual then message(T(_("Could not check updates:\n%1"),tostring(err))) end
                return
            end
            save("last_check",os.time())
            if Policy.newer(release.tag,version) then
                local previous=setting("notified")
                save("notified",release.tag)
                if manual then offer(release,owner)
                elseif previous~=release.tag then message(T(_("Notebook update available: %1"),release.tag)) end
            elseif manual then
                message(_("No newer stable Notebook release is available.").."\n"..version.." / "..release.tag)
            end
        end)
    end
    if manual then NetworkMgr:runWhenOnline(run)
    elseif NetworkMgr:isOnline() then run() end
end
function M.start(plugin_dir)
    if M.plugin_dir then return end
    M.plugin_dir=plugin_dir
    local function tick()
        if setting("weekly")~=false and not M.installed
            and Policy.due(os.time(),setting("last_check")) then
            local attempt=setting("attempt")
            if type(attempt)~="number" or attempt~=attempt or attempt>os.time() or os.time()-attempt>=3600 then M.check(false) end
        end
        UIManager:scheduleIn(3600,tick)
    end
    UIManager:scheduleIn(60,tick)
    UIManager:scheduleIn(10,function()
        local _,backup=paths()
        if backup and setting("installed")==version then
            -- Only the newly loaded version retires its previous package.
            local ok=Installer.removeTree(backup)
            if ok then save("installed",nil) end
        end
    end)
end
function M.showMenu(owner,anchor)
    local menu
    menu=ActionMenu:new{
        title=_("Updates"),anchor=anchor,
        actions={
            {text=_("Check updates weekly"),checkbox=true,selected=function() return setting("weekly")~=false end,
                callback=function() save("weekly",setting("weekly")==false) end},
            {text=_("Check update"),icon="notebook.refresh",
                callback=function() UIManager:close(menu);M.check(true,owner) end},
        },
    }
    UIManager:show(menu)
end
return M
