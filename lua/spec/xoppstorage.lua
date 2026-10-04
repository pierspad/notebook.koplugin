#!/usr/bin/env luajit
package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs()
local Xopp=require('xopp')
local passed,failed=0,0
local function test(kind)
    local path,source=os.tmpname(),os.tmpname()
    local real_open,real_rename=io.open,os.rename
    local function write(name,bytes)
        local f=assert(real_open(name,'wb'));assert(f:write(bytes));assert(f:close())
    end
    write(path,'previous export');write(source,'%PDF-complete source');write(path..'.bg.pdf','previous background')
    if kind=='recovery backup' then write(path..'.bg.pdf.rollback','recovery data') end
    local doc={pages={{strokes={},background={file=source,page=1,size={w=600,h=800}}}},
        templateFor=function() return 'blank' end}
    os.rename=function(from,to)
        if (kind=='primary rename' and from==path..'.tmp')
            or (kind=='companion rename' and from==path..'.bg.pdf.tmp')
            or (kind=='backup rename' and to==path..'.bg.pdf.rollback') then return nil,'rename failed',13 end
        return real_rename(from,to)
    end
    io.open=function(name,mode)
        if kind=='source open' and name==source then return nil,'open failed',13 end
        local file,err=real_open(name,mode)
        if not file then return nil,err end
        local reads=0
        return {
            write=function(_,bytes)
                if (kind=='primary write' and name==path..'.tmp')
                    or (kind=='companion write' and name==path..'.bg.pdf.tmp') then return nil,'write failed' end
                return file:write(bytes)
            end,
            read=function(_,count)
                reads=reads+1
                if kind=='source read' and name==source and reads>1 then return nil,'read failed' end
                return file:read(count)
            end,
            close=function()
                local closed,reason=file:close()
                if (kind=='primary close' and name==path..'.tmp')
                    or (kind=='source close' and name==source)
                    or (kind=='companion close' and name==path..'.bg.pdf.tmp') then
                    return nil,'close failed'
                end
                return closed,reason
            end,
        }
    end
    local ok,err=pcall(function()
        local done,reason=Xopp.toXOPP(doc,path)
        if kind=='success' then
            assert(done and reason==path..'.bg.pdf')
            local f=assert(real_open(reason,'rb'));local bytes=f:read('*a');f:close()
            assert(bytes=='%PDF-complete source','companion changed')
        else
            assert(not done,'I/O failure was reported as success')
            assert(reason and (reason:find('failed',1,true) or kind=='recovery backup' and reason:find('backup',1,true)),'failure reason was lost')
            local f=assert(real_open(path,'rb'));local bytes=f:read('*a');f:close()
            assert(bytes=='previous export','failed export replaced the previous export')
            f=assert(real_open(path..'.bg.pdf','rb'));bytes=f:read('*a');f:close()
            assert(bytes=='previous background','failed export changed the previous background')
        end
    end)
    io.open=real_open;os.rename=real_rename
    assert(not real_open(path..'.tmp','rb') and not real_open(path..'.bg.pdf.tmp','rb'), 'temporary export leaked')
    if kind=='recovery backup' then
        local backup=assert(real_open(path..'.bg.pdf.rollback','rb'))
        assert(backup:read('*a')=='recovery data','existing recovery backup was overwritten');backup:close()
    else assert(not real_open(path..'.bg.pdf.rollback','rb'), 'rollback backup leaked') end
    for _,name in ipairs{path,path..'.tmp',path..'.bg.pdf',path..'.bg.pdf.tmp',path..'.bg.pdf.rollback',source} do os.remove(name) end
    if ok then passed=passed+1;print('  ok   XOPP '..kind)
    else failed=failed+1;print('  FAIL XOPP '..kind..'\n         '..tostring(err)) end
end
for _,kind in ipairs{'success','primary close','source read','source close','companion close',
    'source open','primary write','companion write','backup rename','companion rename','primary rename','recovery backup'} do test(kind) end
print(string.format('\n%d passed, %d failed',passed,failed))
os.exit(failed==0 and 0 or 1)
