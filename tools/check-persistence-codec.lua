-- Optional integration probe using KOReader's actual bitser source (read-only).
-- luajit tools/check-persistence-codec.lua /path/to/koreader/base/ffi/bitser.lua
-- Writes only disposable notebooks in the OS temporary directory. The Persist
-- adapter below tests encoding and atomic Document save/load, not KOReader fsync.
package.path = "./lua/?.lua;./lua/spec/?.lua;" .. package.path
require("support").installStubs()
local codec=assert(loadfile(assert(arg[1],"KOReader bitser.lua path required")))()
local Persist={}
function Persist:new(opts) return setmetatable({path=opts.path},{__index=self}) end
function Persist:save(data)
    local file,err=io.open(self.path,"wb")
    if not file then return false,err end
    local written,reason=file:write(codec.dumps(data))
    local closed,close_err=file:close()
    return written and closed,reason or close_err
end
function Persist:load()
    local file=io.open(self.path,"rb")
    if not file then return nil end
    local bytes=file:read("*a"); assert(file:close())
    return codec.loads(bytes)
end
package.loaded.persist=Persist
local Document,Stroke=require("document"),require("stroke")
local path=os.tmpname()
local function check()
    local doc=Document:new(path)
    doc:setContentOrigin(0,100)
    doc.page_size={w=1860,h=2380}
    for i=1,3 do
        if i>1 then doc:addPage() end
        local s=Stroke:new{tool=i==2 and "highlighter" or "pen",color=0x1E53935,
            tint=i==2 and 0x1FDD835 or nil,width=12}
        s:addPoint(30,120,0.2);s:addPoint(80,200,0.9)
        doc:addStroke(s)
    end
    local label=Stroke:new{tool="text",shape_kind="text",text="Caffè & appunti",
        font_size=24,font_family="serif",text_bold=true,text_background=true}
    label:addPoint(10,130);label:addPoint(300,200)
    doc:addStroke(label)
    doc.pages[2].background={file="/immutable.pdf",page=2,size={w=600,h=800}}
    assert(doc:save())
    local loaded=Document:new(path);assert(loaded:load())
    assert(loaded.current_page==3 and loaded:pageCount()==3)
    assert(loaded.pages[2].strokes[1].tint==0x1FDD835)
    assert(loaded.pages[2].background.size.w==600)
    assert(loaded.pages[3].strokes[2].text==label.text)
    assert(loaded.pages[3].strokes[2].text_background)
    assert(loaded.page_size.h==2380)
    loaded:removeStrokes{loaded.pages[3].strokes[2]};loaded:undo();loaded:redo()
    assert(loaded:save())
    assert(Document:new(path):load())
end
local ok,err=pcall(check)
os.remove(path);os.remove(path..".saving")
assert(ok,err)
print("Real KOReader bitser: RGB pen/marker, Unicode text, PDF metadata, page navigation, undo/redo and atomic disk round trips passed")
