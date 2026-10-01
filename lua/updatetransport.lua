-- Bounded HTTPS transfers in a background process; UI polls completion only.
local UIManager=require("ui/uimanager")
local function shellEscape(args)
    local out={}
    for i,value in ipairs(args) do out[i]="'"..tostring(value):gsub("'", "'\"'\"'").."'" end
    return table.concat(out," ")
end
local lfs=require("libs/libkoreader-lfs")
local M={}
function M.command(url,path,limit,ca)
    local args={"curl","--silent","--show-error","--fail","--location",
        "--proto","=https","--proto-redir","=https","--max-redirs","5",
        "--connect-timeout","10","--max-time","60","--max-filesize",tostring(limit),
        "--user-agent","KOReader-Notebook-Updater","--output",path,
        "--write-out","%{http_code}","--header","Accept: application/vnd.github+json"}
    if ca and lfs.attributes(ca,"mode")=="file" then
        args[#args+1]="--cacert";args[#args+1]=ca
    end
    args[#args+1]=url
    local status=path..".status"
    return "( "..shellEscape(args).." > "..shellEscape({status..".pending"})
        .." 2> "..shellEscape({path..".error"}).."; mv "
        ..shellEscape({status..".pending",status}).." ) &"
end
function M.sweep(root,now)
    if lfs.symlinkattributes(root,"mode")~="directory" then return end
    for name in lfs.dir(root) do
        local stem=name:match("^(%d+%-%d+)")
        if stem and (name==stem or name==stem..".status" or name==stem..".status.pending" or name==stem..".error") then
            local path=root.."/"..name
            local attr=lfs.symlinkattributes(path)
            if attr and attr.mode=="file" and type(attr.modification)=="number"
                and now-attr.modification>86400 then os.remove(path) end
        end
    end
end
function M.fetch(url,path,limit,ca,done)
    local result=os.execute(M.command(url,path,limit,ca))
    if result~=0 and result~=true then done(nil,"Cannot start curl");return end
    local attempts=0
    local function poll()
        local file=io.open(path..".status","rb")
        if file then
            local status=file:read("*a");file:close()
            os.remove(path..".status")
            local errfile=io.open(path..".error","rb")
            local err=errfile and errfile:read(2048) or ""
            if errfile then errfile:close() end
            os.remove(path..".error")
            local size=lfs.attributes(path,"size")
            if status=="200" and err=="" and size and size>0 and size<=limit then done(path)
            else os.remove(path);done(nil,err~="" and err or "HTTP "..status) end
            return
        end
        attempts=attempts+1
        if attempts>=260 then
            -- curl's own deadline precedes this; leave an unfinished transfer
            -- isolated instead of racing its writer by reusing its filename.
            done(nil,"Update request timed out")
            return
        end
        UIManager:scheduleIn(0.25,poll)
    end
    UIManager:scheduleIn(0.25,poll)
end
return M
