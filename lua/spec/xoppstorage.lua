#!/usr/bin/env luajit
package.path='./?.lua;./spec/?.lua;'..package.path
require('support').installStubs()
local Xopp=require('xopp')
local passed,failed=0,0
local function test(kind)
    local path,source=os.tmpname(),os.tmpname()
    local real_open=io.open
    local function write(name,bytes)
        local f=assert(real_open(name,'wb'));assert(f:write(bytes));assert(f:close())
    end
    write(path,'previous export');write(source,'%PDF-complete source')
    local doc={pages={{strokes={},background={file=source,page=1,size={w=600,h=800}}}},
        templateFor=function() return 'blank' end}
    io.open=function(name,mode)
        local file,err=real_open(name,mode)
        if not file then return nil,err end
        local reads=0
        return {
            write=function(_,bytes) return file:write(bytes) end,
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
            assert(reason and reason:find('failed',1,true),'failure reason was lost')
            if kind=='primary close' then
                local f=assert(real_open(path,'rb'));local bytes=f:read('*a');f:close()
                assert(bytes=='previous export','failed close replaced the previous export')
            end
        end
    end)
    io.open=real_open
    for _,name in ipairs{path,path..'.tmp',path..'.bg.pdf',path..'.bg.pdf.tmp',source} do os.remove(name) end
    if ok then passed=passed+1;print('  ok   XOPP '..kind)
    else failed=failed+1;print('  FAIL XOPP '..kind..'\n         '..tostring(err)) end
end
for _,kind in ipairs{'success','primary close','source read','source close','companion close'} do test(kind) end
print(string.format('\n%d passed, %d failed',passed,failed))
os.exit(failed==0 and 0 or 1)
