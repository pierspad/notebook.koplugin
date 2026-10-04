-- Commit an XOPP and its PDF companion only after both temporary files are complete.
-- A failed final rename restores the old companion; recovery backups are never overwritten.
local Files={}
local function copy(source_path,target_path)
    local source,err=io.open(source_path,"rb")
    if not source then return false,err end
    local target;target,err=io.open(target_path,"wb")
    if not target then source:close();return false,err end
    local ok=true
    while true do
        local chunk,read_err=source:read(65536)
        if read_err then ok,err=false,read_err;break end
        if not chunk or chunk=="" then break end
        ok,err=target:write(chunk)
        if not ok then break end
    end
    local source_closed,source_err=source:close()
    local target_closed,target_err=target:close()
    if not ok or not source_closed or not target_closed then
        os.remove(target_path)
        return false,err or source_err or target_err
    end
    return true
end
function Files.commit(path,pdf_source)
    local temporary=path..".tmp"
    if not pdf_source then
        local ok,err=os.rename(temporary,path)
        if not ok then os.remove(temporary) end
        return ok,err
    end
    local background=path..".bg.pdf"
    local staged,backup=background..".tmp",background..".rollback"
    local function abort(err) os.remove(temporary);os.remove(staged);return false,err end
    local ok,err=copy(pdf_source,staged)
    if not ok then return abort(err) end
    local previous,open_err,code=io.open(backup,"rb")
    if previous then previous:close();return abort("Recovery backup exists: "..backup) end
    if code and code~=2 then return abort(open_err) end
    local saved,rename_err,rename_code=os.rename(background,backup)
    if not saved and rename_code~=2 then return abort(rename_err) end
    local function rollback(reason)
        if saved then
            local restored,restore_err=os.rename(backup,background)
            if not restored then reason=tostring(reason).."; "..tostring(restore_err).."; previous PDF: "..backup end
        else os.remove(background) end
        return abort(reason)
    end
    ok,err=os.rename(staged,background)
    if not ok then return rollback(err) end
    ok,err=os.rename(temporary,path)
    if not ok then return rollback(err) end
    if saved then os.remove(backup) end
    return true,background
end
return Files
