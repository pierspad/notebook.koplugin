package.path="./?.lua;./spec/?.lua;"..package.path
local support=require("support");support.installStubs()
local Selection=require("pageselection")
local function equal(a,b) assert(#a==#b);for i,n in ipairs(a) do assert(n==b[i]) end end
equal(assert(Selection.parse("1, 3-5, 3",6)),{1,3,4,5})
equal(assert(Selection.parse("all",3)),{1,2,3})
for _,text in ipairs({"", "0", "7", "5-3", "1,,2", "1,", "1.5", "1-", "x", "-1", "1 2"}) do
 assert(not Selection.parse(text,6),text)
end
local doc=require("document"):new("/selection")
for i=1,4 do if i>1 then doc:addPage() end;doc.pages[i].template=i%2==0 and "ruled" or "blank" end
doc.pages[3].background={file="source.pdf"}
local view=assert(Selection.view(doc,{3,1}))
assert(view:pageCount()==2 and view.pages[2]==doc.pages[1])
assert(view:templateFor(1)==doc:templateFor(3))
assert(view.pages[1].background.page==3 and doc.pages[3].background.page==nil)
assert(not Selection.view(doc,{1,1}) and not Selection.view(doc,{0}))
assert(#doc.pages==4 and #doc.undo_stack==3)
-- PDF background rendering is outside this stubbed export test.
view.pages[1]={strokes={},template=view.pages[1].template}
package.loaded["ffi/blitbuffer"].new=function(w,h) return support.FakeBB.new(w,h) end
local Renderer=require("renderer")
local draw=Renderer.drawPage;local rendered={}
Renderer.drawPage=function(_,page) rendered[#rendered+1]=page end
local path=os.tmpname()
assert(require("export").toPDF(view,path,{width=8,height=8}))
assert(#rendered==2 and rendered[1]==view.pages[1] and rendered[2]==doc.pages[1])
local f=assert(io.open(path,"rb"));local pdf=f:read("*a");f:close()
assert(pdf:find("/Count 2",1,true));os.remove(path)
Renderer.drawPage=draw
print("pageselection: strict ranges, deduplication, templates/PDF source mapping and two-page export passed")
