package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs();require('uistubs').install({})
local Library=require('library');local old=Library.ensureDir
Library.ensureDir=function() return true end
local files={};local real_open=io.open
io.open=function(path,mode)
    if mode=='a' then files[path]=files[path] or '' end
    if not files[path] then return nil,'missing' end
    return {write=function(_,text) files[path]=files[path]..text end,close=function() return true end}
end
local Diagnostics=require('diagnostics')
local canvas={_debugEvent=function(self) local f=assert(io.open(self.debug_log_path,'a'));f:write('test\n');f:close() end}
assert(Diagnostics.set(canvas,true) and canvas.debug_log_path==Diagnostics.path())
assert(io.open(Diagnostics.path())):close()
assert(Diagnostics.set(canvas,false) and not canvas.debug_log_path)
assert(io.open(Diagnostics.path())):close()
-- I/O failure does not turn logging on or silence the notebook.
local open=io.open;io.open=function() return nil,'read only' end
local ok,err=Diagnostics.set(canvas,true);io.open=open
assert(not ok and err=='read only' and not Diagnostics.enabled and not canvas.debug_log_path)
-- Automatic marker logging is checked on opening; an explicit stop wins until restart.
local Lifecycle=require('canvaslifecycle')
Diagnostics.enabled=nil
files['/data/notebook/_debug_']=''
canvas.document={path='/data/notebook/ordinary.scribe'}
assert(Lifecycle._resolveDebugLogPath(canvas)==Diagnostics.path())
canvas.debug_log_path=Lifecycle._resolveDebugLogPath(canvas)
assert(Diagnostics.set(canvas,false) and not canvas.debug_log_path)
assert(not Lifecycle._resolveDebugLogPath(canvas),'marker ignored the explicit stop')
assert(Diagnostics.set(canvas,true) and canvas.debug_log_path==Diagnostics.path())
assert(Lifecycle._resolveDebugLogPath({document={path='/data/notebook/another.scribe'}})==Diagnostics.path(),
    'session logging was lost after switching notebooks')
Diagnostics.enabled=nil
Library.ensureDir=old
io.open=real_open
print('diagnostics: visible start/stop, preserved log and failed I/O passed')
